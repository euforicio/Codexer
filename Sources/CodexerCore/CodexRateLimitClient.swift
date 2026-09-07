import Darwin
import Foundation

public final class CodexRateLimitClient: @unchecked Sendable {
    private let nativeClient: AppServerRateLimitClient
    private let customClient: CustomProviderRateLimitClient
    private let fileManager: FileManager

    public init(
        nativeClient: AppServerRateLimitClient = AppServerRateLimitClient(),
        fileManager: FileManager = .default
    ) {
        self.nativeClient = nativeClient
        customClient = CustomProviderRateLimitClient()
        self.fileManager = fileManager
    }

    public func fetchRateLimits(
        for profile: CodexProfile,
        codexAppURL: URL
    ) async -> ProfileRateLimits {
        await fetchRateLimits(
            codexHomeURL: profile.codexHomePath,
            codexAppURL: codexAppURL,
            configProfile: profile.codexLaunchProfileSelection.configProfile
        )
    }

    public func fetchRateLimits(
        codexHomeURL: URL,
        codexAppURL: URL
    ) async -> ProfileRateLimits {
        await fetchRateLimits(
            codexHomeURL: codexHomeURL,
            codexAppURL: codexAppURL,
            configProfile: nil
        )
    }

    public func fetchRateLimits(
        codexHomeURL: URL,
        codexAppURL: URL,
        configProfile: CodexConfigProfile?
    ) async -> ProfileRateLimits {
        do {
            switch try CodexProviderConfiguration.resolve(
                codexHomeURL: codexHomeURL,
                fileManager: fileManager,
                configProfile: configProfile
            ) {
            case .openAI:
                return nativeClient.fetchRateLimits(
                    codexHomeURL: codexHomeURL,
                    codexAppURL: codexAppURL
                )
            case let .custom(provider):
                return await customClient.fetchRateLimits(provider: provider)
            case let .unsupported(providerID):
                return ProfileRateLimits(
                    errorMessage: "Usage limits are unavailable for the \(providerID) provider."
                )
            }
        } catch {
            return ProfileRateLimits(
                errorMessage: "The active Codex provider configuration could not be read safely."
            )
        }
    }
}

enum CodexProviderConfiguration: Equatable, Sendable {
    case openAI
    case custom(CustomCodexProvider)
    case unsupported(String)

    private static let maximumConfigBytes = 1_048_576

    static func resolve(
        codexHomeURL: URL,
        fileManager: FileManager = .default,
        configProfile: CodexConfigProfile? = nil
    ) throws -> Self {
        let configURL = codexHomeURL.appendingPathComponent("config.toml")
        var status = Darwin.stat()
        let content: String
        if Darwin.lstat(configURL.path, &status) == 0 {
            content = try readBoundedConfig(at: configURL)
        } else {
            guard errno == ENOENT else { throw CodexProviderConfigurationError.unsafeConfig }
            content = ""
        }
        var document = NarrowTOMLDocument(content)
        if let configProfile {
            try configProfile.validate(in: codexHomeURL)
            document.overlay(NarrowTOMLDocument(try readBoundedConfig(
                at: configProfile.configurationURL(in: codexHomeURL)
            )))
        }
        guard !document.isEmpty else { return .openAI }
        let providerID = try document.topLevelString("model_provider") ?? "openai"
        guard providerID != "openai" else { return .openAI }
        guard let baseURLString = document.string(
            "base_url",
            in: ["model_providers", providerID]
        ), let baseURL = URL(string: baseURLString) else {
            return .unsupported(providerID)
        }

        let providerTable = ["model_providers", providerID]
        let directHeaders = document.stringMap(
            "http_headers",
            in: providerTable
        )
        let environmentHeaders = document.stringMap(
            "env_http_headers",
            in: providerTable
        )
        let queryParameters = document.stringMap(
            "query_params",
            in: providerTable
        )
        return .custom(CustomCodexProvider(
            id: providerID,
            name: document.string("name", in: ["model_providers", providerID])
                ?? providerID,
            baseURL: baseURL,
            environmentKey: document.string(
                "env_key",
                in: ["model_providers", providerID]
            ),
            bearerToken: document.string(
                "experimental_bearer_token",
                in: ["model_providers", providerID]
            ),
            directHeaders: directHeaders,
            environmentHeaders: environmentHeaders,
            queryParameters: queryParameters
        ))
    }

    private static func readBoundedConfig(at url: URL) throws -> String {
        let data: Data
        do {
            data = try BoundedFileReader.data(at: url, maximumBytes: maximumConfigBytes)
        } catch {
            throw CodexProviderConfigurationError.unsafeConfig
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw CodexProviderConfigurationError.invalidEncoding
        }
        return content
    }
}

private extension CodexLaunchProfileSelection {
    var configProfile: CodexConfigProfile? {
        guard case let .named(profile) = self else { return nil }
        return profile
    }
}

struct CustomCodexProvider: Equatable, Sendable {
    var id: String
    var name: String
    var baseURL: URL
    var environmentKey: String?
    var bearerToken: String?
    var directHeaders: [String: String]
    var environmentHeaders: [String: String]
    var queryParameters: [String: String]
}

private enum CodexProviderConfigurationError: Error {
    case unsafeConfig
    case invalidEncoding
    case unsupportedProviderSelection
}

private struct NarrowTOMLDocument {
    private var values: [[String]: [String: String]] = [:]
    private var duplicateTopLevelKeys: Set<String> = []

    var isEmpty: Bool { values.isEmpty }

    init(_ content: String) {
        var table: [String] = []
        var multilineDelimiter: String?
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let delimiter = multilineDelimiter {
                if Self.delimiterCount(in: line, delimiter: delimiter).isMultiple(of: 2) == false {
                    multilineDelimiter = nil
                }
                continue
            }
            let stripped = Self.stripComment(line).trimmingCharacters(in: .whitespaces)
            if let (key, value) = Self.assignment(stripped),
               let delimiter = Self.startingMultilineDelimiter(in: value)
            {
                // Preserve the selection's presence even when this narrow parser
                // cannot decode its TOML representation. It must not select OpenAI.
                if table.isEmpty, values[table]?[key] != nil {
                    duplicateTopLevelKeys.insert(key)
                }
                values[table, default: [:]][key] = value
                multilineDelimiter = delimiter
                continue
            }
            guard !stripped.isEmpty else { continue }
            if let parsedTable = Self.tablePath(stripped) {
                table = parsedTable
                continue
            }
            guard let (key, value) = Self.assignment(stripped) else { continue }
            if table.isEmpty, values[table]?[key] != nil {
                duplicateTopLevelKeys.insert(key)
            }
            values[table, default: [:]][key] = value
        }
    }

    mutating func overlay(_ other: Self) {
        duplicateTopLevelKeys.formUnion(other.duplicateTopLevelKeys)
        for (table, entries) in other.values {
            values[table, default: [:]].merge(entries) { _, overlayValue in overlayValue }
        }
    }

    func topLevelString(_ key: String) throws -> String? {
        guard !duplicateTopLevelKeys.contains(key) else {
            throw CodexProviderConfigurationError.unsupportedProviderSelection
        }
        guard let raw = values[[]]?[key] else { return nil }
        guard let value = Self.stringValue(raw), !value.isEmpty else {
            throw CodexProviderConfigurationError.unsupportedProviderSelection
        }
        return value
    }

    func string(_ key: String, in table: [String]) -> String? {
        Self.stringValue(values[table]?[key])
    }

    func stringMap(_ key: String, in table: [String]) -> [String: String] {
        var result: [String: String] = (values[table + [key]] ?? [:]).reduce(
            into: [String: String]()
        ) { result, entry in
            if let value = Self.stringValue(entry.value) {
                result[entry.key] = value
            }
        }
        if let inline = values[table]?[key] {
            result.merge(Self.inlineStringMap(inline)) { _, inlineValue in inlineValue }
        }
        return result
    }

    private static func assignment(_ line: String) -> (String, String)? {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = quote == nil ? character : (quote == character ? nil : quote)
                continue
            }
            if character == "=", quote == nil {
                let key = line[..<index].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return nil }
                return (unquotedKey(String(key)), String(value))
            }
        }
        return nil
    }

    private static func tablePath(_ line: String) -> [String]? {
        guard line.first == "[", line.last == "]" else { return nil }
        let isArray = line.hasPrefix("[[")
        guard !isArray || line.hasSuffix("]]") else { return nil }
        let body = line.dropFirst(isArray ? 2 : 1).dropLast(isArray ? 2 : 1)
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in body {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                current.append(character)
                quote = quote == nil ? character : (quote == character ? nil : quote)
                continue
            }
            if character == ".", quote == nil {
                result.append(unquotedKey(current.trimmingCharacters(in: .whitespaces)))
                current = ""
            } else {
                current.append(character)
            }
        }
        guard quote == nil else { return nil }
        result.append(unquotedKey(current.trimmingCharacters(in: .whitespaces)))
        return result.allSatisfy { !$0.isEmpty } ? result : nil
    }

    private static func stringValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") {
            return try? JSONDecoder().decode(String.self, from: Data(raw.utf8))
        }
        if raw.hasPrefix("'") && raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast())
        }
        return nil
    }

    private static func inlineStringMap(_ raw: String) -> [String: String] {
        guard raw.first == "{", raw.last == "}" else { return [:] }
        let body = raw.dropFirst().dropLast()
        var entries: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in body {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                current.append(character)
                quote = quote == nil ? character : (quote == character ? nil : quote)
                continue
            }
            if character == ",", quote == nil {
                entries.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        entries.append(current)
        return entries.reduce(into: [:]) { result, entry in
            guard let (key, value) = assignment(entry) else { return }
            if let parsed = stringValue(value) {
                result[key] = parsed
            }
        }
    }

    private static func unquotedKey(_ key: String) -> String {
        stringValue(key) ?? key
    }

    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = quote == nil ? character : (quote == character ? nil : quote)
            } else if character == "#", quote == nil {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func startingMultilineDelimiter(in line: String) -> String? {
        for delimiter in ["\"\"\"", "'''"]
        where delimiterCount(in: line, delimiter: delimiter).isMultiple(of: 2) == false {
            return delimiter
        }
        return nil
    }

    private static func delimiterCount(in value: String, delimiter: String) -> Int {
        value.components(separatedBy: delimiter).count - 1
    }
}

private final class CustomProviderRateLimitClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let timeoutSeconds: TimeInterval = 8
    private let maximumResponseBytes = 1_048_576
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func fetchRateLimits(provider: CustomCodexProvider) async -> ProfileRateLimits {
        guard let usageURL = Self.usageURL(provider) else {
            return failure(provider, "The provider usage URL is not safe.")
        }
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyHeaders(provider, to: &request)

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                return failure(provider, "The provider returned an invalid response.")
            }
            guard (200..<300).contains(response.statusCode) else {
                return failure(provider, "The provider usage request failed (HTTP \(response.statusCode)).")
            }
            var data = Data()
            if response.expectedContentLength > Int64(maximumResponseBytes) {
                return failure(provider, "The provider usage response was too large.")
            }
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else {
                    return failure(provider, "The provider usage response was too large.")
                }
                data.append(byte)
            }
            return try CustomProviderUsageParser.parse(data, providerName: provider.name)
        } catch is CancellationError {
            return failure(provider, "Usage-limit refresh was cancelled.")
        } catch {
            return failure(provider, "The provider usage endpoint is unavailable.")
        }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url,
              let redirected = request.url,
              Self.sameOrigin(original, redirected),
              CustomProviderEndpoint.isSafeBaseURL(redirected)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private func applyHeaders(_ provider: CustomCodexProvider, to request: inout URLRequest) {
        for (name, value) in provider.directHeaders where Self.isSafeHeader(name, value: value) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for (name, environmentName) in provider.environmentHeaders {
            guard let value = ProcessInfo.processInfo.environment[environmentName],
                  Self.isSafeHeader(name, value: value)
            else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        let token = provider.environmentKey.flatMap {
            ProcessInfo.processInfo.environment[$0]
        } ?? provider.bearerToken
        if let token, Self.isSafeHeader("Authorization", value: token) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func failure(_ provider: CustomCodexProvider, _ message: String) -> ProfileRateLimits {
        ProfileRateLimits(errorMessage: "\(provider.name): \(message)")
    }

    private static func usageURL(_ provider: CustomCodexProvider) -> URL? {
        CustomProviderEndpoint.usageURL(provider)
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }

    private static func isSafeHeader(_ name: String, value: String) -> Bool {
        !name.isEmpty
            && !name.contains(where: { $0 == "\r" || $0 == "\n" || $0 == ":" })
            && !value.contains(where: { $0 == "\r" || $0 == "\n" })
    }
}

enum CustomProviderEndpoint {
    static func usageURL(_ provider: CustomCodexProvider) -> URL? {
        guard isSafeBaseURL(provider.baseURL) else { return nil }
        guard var components = URLComponents(
            url: provider.baseURL.appendingPathComponent("usage"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        let configuredItems = provider.queryParameters.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        components.queryItems = (components.queryItems ?? []) + configuredItems
        return components.url
    }

    static func isSafeBaseURL(_ url: URL) -> Bool {
        guard url.user == nil,
              url.password == nil,
              url.fragment == nil,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased()
        else {
            return false
        }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return host == "localhost" || host == "::1" || isIPv4Loopback(host)
    }

    private static func isIPv4Loopback(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else {
            return false
        }
        return octets.allSatisfy { octet in
            guard !octet.isEmpty, octet.allSatisfy(\.isNumber) else {
                return false
            }
            return UInt8(octet) != nil
        }
    }
}

enum CustomProviderUsageParser {
    static func parse(
        _ data: Data,
        providerName: String,
        fetchedAt: Date = Date()
    ) throws -> ProfileRateLimits {
        let snapshot = try JSONDecoder().decode(ProviderUsageSnapshot.self, from: data)
        guard !snapshot.meters.isEmpty,
              snapshot.meters.count <= 64
        else { throw CustomProviderUsageError.invalidMeters }

        var credits: CreditsUsage?
        var buckets: [RateLimitBucket] = []
        for meter in snapshot.meters {
            guard let id = cleanText(meter.id, maximumLength: 64) else { continue }
            if id == "credits" {
                guard let remaining = remainingAmount(for: meter),
                      let balance = formattedAmount(remaining, unit: meter.amountUnit)
                else { continue }
                let limit = validAmount(meter.limitAmount)
                credits = CreditsUsage(
                    hasCredits: (limit ?? remaining) > 0,
                    unlimited: false,
                    balance: balance
                )
                continue
            }
            guard let usedPercent = meter.usedPercent,
                  usedPercent.isFinite
            else { continue }
            let windowMinutes = meter.windowSeconds.flatMap { seconds -> Int? in
                guard seconds > 0, seconds <= 315_576_000 else { return nil }
                return Int(seconds / 60)
            }
            buckets.append(RateLimitBucket(
                id: id,
                name: cleanText(meter.label, maximumLength: 80) ?? id,
                primary: RateLimitWindowUsage(
                    usedPercent: min(max(usedPercent, 0), 100),
                    windowDurationMins: windowMinutes,
                    resetsAt: meter.resetsAt.flatMap(parseDate)
                ),
                secondary: nil
            ))
        }
        guard !buckets.isEmpty || credits != nil else {
            throw CustomProviderUsageError.invalidMeters
        }
        return ProfileRateLimits(
            planType: cleanText(snapshot.plan, maximumLength: 64),
            buckets: buckets,
            credits: credits,
            fetchedAt: fetchedAt,
            warningMessage: snapshot.object == nil
                ? "Usage limits were read from \(cleanText(providerName, maximumLength: 64) ?? "the provider")'s quota API."
                : nil
        )
    }

    private static func remainingAmount(for meter: ProviderUsageMeter) -> Double? {
        if let remaining = validAmount(meter.remainingAmount) {
            return remaining
        }
        guard let limit = validAmount(meter.limitAmount),
              let used = validAmount(meter.usedAmount)
        else { return nil }
        return max(0, limit - used)
    }

    private static func validAmount(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= 1_000_000_000_000_000 else {
            return nil
        }
        return value
    }

    private static func formattedAmount(_ value: Double, unit: String?) -> String? {
        guard let value = validAmount(value) else { return nil }
        let format = value.rounded() == value ? "%.0f" : "%.2f"
        let number = String(format: format, locale: Locale(identifier: "en_US_POSIX"), value)
        guard let unit = cleanText(unit, maximumLength: 12)?.uppercased() else {
            return number
        }
        return "\(number) \(unit)"
    }

    private static func parseDate(_ value: String) -> Date? {
        guard value.utf8.count <= 64 else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func cleanText(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let cleaned = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let result = String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }
        return String(result.prefix(maximumLength))
    }
}

private enum CustomProviderUsageError: Error {
    case invalidMeters
}

private struct ProviderUsageSnapshot: Decodable {
    var object: String?
    var plan: String?
    var meters: [ProviderUsageMeter]
}

private struct ProviderUsageMeter: Decodable {
    var id: String
    var label: String?
    var usedPercent: Double?
    var resetsAt: String?
    var windowSeconds: Int64?
    var usedAmount: Double?
    var limitAmount: Double?
    var remainingAmount: Double?
    var amountUnit: String?

    enum CodingKeys: String, CodingKey {
        case id, label
        case usedPercent = "used_percent"
        case resetsAt = "resets_at"
        case windowSeconds = "window_seconds"
        case usedAmount = "used_amount"
        case limitAmount = "limit_amount"
        case remainingAmount = "remaining_amount"
        case amountUnit = "amount_unit"
    }
}
