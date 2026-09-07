import Foundation
import XCTest
@testable import CodexerCore

final class CodexRateLimitClientTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRateLimitClientTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMissingProviderConfigurationUsesOpenAI() throws {
        XCTAssertEqual(
            try CodexProviderConfiguration.resolve(codexHomeURL: root),
            .openAI
        )
    }

    func testResolvesSelectedCustomProviderAndCompatibleRequestSettings() throws {
        try Data(#"""
        model_provider = "cursor_bridge"

        [model_providers.cursor_bridge]
        name = "Cursor Bridge"
        base_url = "http://127.0.0.1:32124/v1"
        wire_api = "responses"
        env_key = "SYNTHETIC_PROVIDER_TOKEN"
        http_headers = { "X-Client" = "AgentDock" }
        query_params = { region = "local" }

        [model_providers.cursor_bridge.env_http_headers]
        X-Workspace = "SYNTHETIC_WORKSPACE"
        """#.utf8).write(to: root.appendingPathComponent("config.toml"))

        let resolved = try CodexProviderConfiguration.resolve(codexHomeURL: root)
        guard case let .custom(provider) = resolved else {
            return XCTFail("Expected a custom provider")
        }
        XCTAssertEqual(provider.id, "cursor_bridge")
        XCTAssertEqual(provider.name, "Cursor Bridge")
        XCTAssertEqual(provider.environmentKey, "SYNTHETIC_PROVIDER_TOKEN")
        XCTAssertEqual(provider.directHeaders, ["X-Client": "AgentDock"])
        XCTAssertEqual(provider.environmentHeaders, ["X-Workspace": "SYNTHETIC_WORKSPACE"])
        XCTAssertEqual(provider.queryParameters, ["region": "local"])
        XCTAssertEqual(
            CustomProviderEndpoint.usageURL(provider)?.absoluteString,
            "http://127.0.0.1:32124/v1/usage?region=local"
        )
    }

    func testSelectedProviderWithoutConfiguredBaseURLDoesNotUseOpenAIQuota() throws {
        try Data("model_provider = \"ollama\"\n".utf8)
            .write(to: root.appendingPathComponent("config.toml"))

        XCTAssertEqual(
            try CodexProviderConfiguration.resolve(codexHomeURL: root),
            .unsupported("ollama")
        )
    }

    func testNamedConfigProfileOverlaysBaseConfigurationForUsageProvider() throws {
        try Data(#"""
        [model_providers.ollama]
        name = "Ollama"
        base_url = "http://127.0.0.1:11434/v1"
        """#.utf8).write(to: root.appendingPathComponent("config.toml"))
        try Data("model_provider = \"ollama\"\n".utf8)
            .write(to: root.appendingPathComponent("ollama.config.toml"))

        XCTAssertEqual(
            try CodexProviderConfiguration.resolve(codexHomeURL: root),
            .openAI
        )

        let profile = try XCTUnwrap(CodexConfigProfile(validating: "ollama"))
        let resolved = try CodexProviderConfiguration.resolve(
            codexHomeURL: root,
            configProfile: profile
        )
        guard case let .custom(provider) = resolved else {
            return XCTFail("Expected the named profile to select Ollama")
        }
        XCTAssertEqual(provider.id, "ollama")
        XCTAssertEqual(provider.name, "Ollama")
        XCTAssertEqual(provider.baseURL.absoluteString, "http://127.0.0.1:11434/v1")
    }

    func testNamedConfigProfileSelectsProviderWithoutBaseConfiguration() throws {
        try Data("model_provider = \"custom\"\n".utf8)
            .write(to: root.appendingPathComponent("custom.config.toml"))
        let profile = try XCTUnwrap(CodexConfigProfile(validating: "custom"))
        XCTAssertEqual(
            try CodexProviderConfiguration.resolve(codexHomeURL: root, configProfile: profile),
            .unsupported("custom")
        )
    }

    func testDuplicateSelectionInNamedConfigProfileFailsClosed() throws {
        try Data("model_provider = \"custom\"\nmodel_provider = \"openai\"\n".utf8)
            .write(to: root.appendingPathComponent("custom.config.toml"))
        let profile = try XCTUnwrap(CodexConfigProfile(validating: "custom"))
        XCTAssertThrowsError(
            try CodexProviderConfiguration.resolve(codexHomeURL: root, configProfile: profile)
        )
    }

    func testBrokenConfigurationSymlinkDoesNotUseOpenAIQuota() throws {
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("config.toml"),
            withDestinationURL: root.appendingPathComponent("missing.toml")
        )

        XCTAssertThrowsError(try CodexProviderConfiguration.resolve(codexHomeURL: root))
    }

    func testUnsupportedProviderSelectionDoesNotUseOpenAIQuota() throws {
        for selection in ["", "# Empty selection", "123", "\"\"", "\"\"\"custom\"\"\"", "\"\"\"\ncustom\n\"\"\""] {
            try Data("model_provider = \(selection)\n".utf8)
                .write(to: root.appendingPathComponent("config.toml"))

            XCTAssertThrowsError(
                try CodexProviderConfiguration.resolve(codexHomeURL: root),
                "Unsupported selection must fail closed: \(selection)"
            )
        }
    }

    func testDuplicateProviderSelectionFailsClosedInEitherOrder() throws {
        for selections in [["custom", "openai"], ["openai", "custom"], ["openai", "openai"]] {
            let content = selections.map { "model_provider = \"\($0)\"" }.joined(separator: "\n")
            try Data(content.utf8).write(to: root.appendingPathComponent("config.toml"))
            XCTAssertThrowsError(try CodexProviderConfiguration.resolve(codexHomeURL: root))
        }
    }

    func testMultilineDelimitersInCommentsDoNotHideCustomProviderSelection() throws {
        try Data("# Documentation uses \"\"\" for multiline strings\nmodel_provider = \"custom\"\n".utf8)
            .write(to: root.appendingPathComponent("config.toml"))

        XCTAssertEqual(
            try CodexProviderConfiguration.resolve(codexHomeURL: root),
            .unsupported("custom")
        )
    }

    func testArrayTableCannotOverrideTopLevelProviderSelection() throws {
        try Data("model_provider = \"custom\"\n[[tools]]\nmodel_provider = \"openai\"\n".utf8)
            .write(to: root.appendingPathComponent("config.toml"))

        XCTAssertEqual(
            try CodexProviderConfiguration.resolve(codexHomeURL: root),
            .unsupported("custom")
        )
    }

    func testCustomProviderUsageAllowsHTTPSAndLoopbackHTTPOnly() throws {
        XCTAssertNotNil(CustomProviderEndpoint.usageURL(provider("https://provider.example/v1")))
        XCTAssertNotNil(CustomProviderEndpoint.usageURL(provider("http://localhost:8080/v1")))
        XCTAssertNil(CustomProviderEndpoint.usageURL(provider("http://provider.example/v1")))
        XCTAssertNil(CustomProviderEndpoint.usageURL(provider("http://127.evil.example/v1")))
        XCTAssertNil(CustomProviderEndpoint.usageURL(provider("file:///tmp/provider/v1")))
        XCTAssertNil(CustomProviderEndpoint.usageURL(provider("https://user:secret@provider.example/v1")))
    }

    func testParsesNormalizedProviderQuotaMeters() throws {
        let reset = "2099-01-01T00:00:00Z"
        let data = Data(#"""
        {
          "object":"cursor.usage",
          "plan":"business",
          "meters":[
            {
              "id":"grok_bot_weekly",
              "label":"Grok Bot weekly",
              "used_percent":37.5,
              "window_seconds":604800,
              "resets_at":"\#(reset)"
            },
            {
              "id":"credits",
              "label":"Credits",
              "remaining_amount":12.5,
              "limit_amount":20,
              "amount_unit":"usd"
            }
          ]
        }
        """#.utf8)

        let limits = try CustomProviderUsageParser.parse(
            data,
            providerName: "Cursor Bridge",
            fetchedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(limits.planType, "business")
        XCTAssertEqual(limits.buckets.map(\.id), ["grok_bot_weekly"])
        XCTAssertEqual(limits.buckets.first?.primary?.usedPercent, 37.5)
        XCTAssertEqual(limits.buckets.first?.primary?.windowDurationMins, 10_080)
        XCTAssertEqual(limits.buckets.first?.primary?.resetsAt, ISO8601DateFormatter().date(from: reset))
        XCTAssertEqual(limits.credits?.balance, "12.50 USD")
        XCTAssertEqual(limits.fetchedAt, Date(timeIntervalSince1970: 100))
    }

    func testRejectsOrSkipsInvalidProviderQuotaValuesWithoutOverflowing() throws {
        let data = Data(#"""
        {
          "meters":[
            {"id":"large-percent","used_percent":1e308},
            {"id":"negative-credit","remaining_amount":-1},
            {"id":"huge-credit","remaining_amount":1e308},
            {"id":"valid","used_percent":125,"window_seconds":3600}
          ]
        }
        """#.utf8)

        let limits = try CustomProviderUsageParser.parse(data, providerName: "Synthetic")

        XCTAssertEqual(limits.buckets.map(\.id), ["large-percent", "valid"])
        XCTAssertTrue(limits.buckets.allSatisfy { $0.primary?.usedPercent == 100 })
        XCTAssertNil(limits.credits)
    }

    func testRejectsExcessiveProviderMeterCount() {
        let meters = (0..<65).map { "{\"id\":\"m\($0)\",\"used_percent\":1}" }.joined(separator: ",")
        let data = Data("{\"meters\":[\(meters)]}".utf8)

        XCTAssertThrowsError(
            try CustomProviderUsageParser.parse(data, providerName: "Synthetic")
        )
    }

    private func provider(_ baseURL: String) -> CustomCodexProvider {
        CustomCodexProvider(
            id: "custom",
            name: "Custom",
            baseURL: URL(string: baseURL)!,
            environmentKey: nil,
            bearerToken: nil,
            directHeaders: [:],
            environmentHeaders: [:],
            queryParameters: [:]
        )
    }
}
