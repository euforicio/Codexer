import XCTest
@testable import CodexerCore

final class ClaudeUsageClientTests: XCTestCase {
    func testDesktopCredentialRequiresExplicitAccountAndOrganizationIdentity() {
        let account = "00000000-0000-0000-0000-000000000001"
        let organization = "00000000-0000-0000-0000-000000000002"

        XCTAssertEqual(
            ClaudeAccountIdentity.desktop(accountUUID: account, organizationUUID: organization),
            ClaudeAccountIdentity(accountUUID: account, organizationUUID: organization)
        )
        XCTAssertNil(ClaudeAccountIdentity.desktop(accountUUID: nil, organizationUUID: organization))
        XCTAssertNil(ClaudeAccountIdentity.desktop(accountUUID: "", organizationUUID: organization))
        XCTAssertNil(ClaudeAccountIdentity.desktop(accountUUID: "invalid", organizationUUID: organization))
        XCTAssertNil(ClaudeAccountIdentity.desktop(accountUUID: account, organizationUUID: "invalid"))
    }

    func testCredentialCacheSeparatesAccountAndOrganizationForTheSameToken() {
        let identity = ClaudeAccountIdentity(
            accountUUID: "00000000-0000-0000-0000-000000000001",
            organizationUUID: "00000000-0000-0000-0000-000000000002"
        )
        let original = ClaudeUsageCredential(
            accessToken: "synthetic-token",
            scopes: ["user:profile"],
            identity: identity
        )
        var otherAccount = original
        otherAccount.identity?.accountUUID = "00000000-0000-0000-0000-000000000003"
        var otherOrganization = original
        otherOrganization.identity?.organizationUUID = "00000000-0000-0000-0000-000000000004"

        XCTAssertNotEqual(original.cacheKey, otherAccount.cacheKey)
        XCTAssertNotEqual(original.cacheKey, otherOrganization.cacheKey)
        XCTAssertFalse(original.cacheKey.contains(original.accessToken))
    }

    func testInstalledOfficialUsageWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AGENTDOCK_LIVE_CLAUDE_USAGE_TEST"] == "1" else {
            throw XCTSkip("Set AGENTDOCK_LIVE_CLAUDE_USAGE_TEST=1 to validate the signed-in official account.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let limits = await ClaudeUsageClient().fetchOfficialUsage(
            claudeCodeHomeURL: home.appendingPathComponent(".claude", isDirectory: true),
            claudeUserDataURL: home.appendingPathComponent(
                "Library/Application Support/Claude",
                isDirectory: true
            ),
            allowKeychainInteraction: false,
            forceRefresh: true
        )

        XCTAssertNil(limits.errorMessage)
        XCTAssertFalse(limits.buckets.isEmpty)
    }

    func testMapsLiveWindowsScopedModelsAndExtraUsage() throws {
        let data = Data(#"""
        {
          "five_hour":{"utilization":12.5,"resets_at":"2099-01-01T00:00:00.000Z"},
          "seven_day":{"utilization":41,"resets_at":"2099-01-07T00:00:00Z"},
          "seven_day_sonnet":{"utilization":7,"resets_at":"2099-01-07T00:00:00.000Z"},
          "limits":[
            {"kind":"weekly_scoped","percent":23,"resets_at":"2099-01-07T00:00:00.000Z",
             "scope":{"model":{"display_name":"Fable"}}},
            {"kind":"other","percent":99,"scope":{"model":{"display_name":"Ignored"}}}
          ],
          "extra_usage":{"is_enabled":true,"used_credits":525,"monthly_limit":2000}
        }
        """#.utf8)

        let limits = try ClaudeUsageResponseParser.parse(
            data,
            planType: "max",
            fetchedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(limits.planType, "max")
        XCTAssertEqual(limits.fetchedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(limits.buckets.map(\.id), ["claude", "sonnet", "model-fable"])
        XCTAssertEqual(limits.buckets[0].primary?.usedPercent, 12.5)
        XCTAssertEqual(limits.buckets[0].primary?.windowDurationMins, 300)
        XCTAssertEqual(limits.buckets[0].secondary?.usedPercent, 41)
        XCTAssertEqual(limits.buckets[0].secondary?.windowDurationMins, 10_080)
        XCTAssertEqual(limits.buckets[2].name, "Fable")
        XCTAssertEqual(limits.buckets[2].primary?.usedPercent, 23)
        XCTAssertEqual(limits.credits?.balance, "$5.25 of $20.00 used")
    }

    func testMissingAndNullWindowsRemainHonest() throws {
        let data = Data(#"""
        {
          "five_hour":null,
          "seven_day":{"resets_at":"invalid"},
          "extra_usage":{"is_enabled":false,"used_credits":500}
        }
        """#.utf8)

        let limits = try ClaudeUsageResponseParser.parse(data)

        XCTAssertTrue(limits.buckets.isEmpty)
        XCTAssertNil(limits.credits)
    }

    func testRejectsNonObjectResponse() {
        XCTAssertThrowsError(try ClaudeUsageResponseParser.parse(Data("[]".utf8)))
    }

    func testSuccessfulUsageIsReusableForFiveMinutes() {
        let fetchedAt = Date(timeIntervalSince1970: 1_000)
        let limits = ProfileRateLimits(fetchedAt: fetchedAt)

        XCTAssertTrue(ClaudeUsageRefreshPolicy.canReuse(
            limits,
            now: fetchedAt.addingTimeInterval(299)
        ))
        XCTAssertFalse(ClaudeUsageRefreshPolicy.canReuse(
            limits,
            now: fetchedAt.addingTimeInterval(300)
        ))
        XCTAssertFalse(ClaudeUsageRefreshPolicy.canReuse(ProfileRateLimits(), now: fetchedAt))
    }

    func testRateLimitCooldownUsesProviderDelayWithOneMinuteMinimum() {
        XCTAssertEqual(ClaudeUsageRefreshPolicy.rateLimitCooldown(retryAfter: nil), 300)
        XCTAssertEqual(ClaudeUsageRefreshPolicy.rateLimitCooldown(retryAfter: 15), 60)
        XCTAssertEqual(ClaudeUsageRefreshPolicy.rateLimitCooldown(retryAfter: 600), 600)
    }
}
