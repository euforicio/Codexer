import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security

public protocol ClaudeUsageFetching: Sendable {
    func fetchOfficialUsage(
        claudeCodeHomeURL: URL,
        claudeUserDataURL: URL,
        allowKeychainInteraction: Bool,
        forceRefresh: Bool
    ) async -> ProfileRateLimits

    func fetchManagedUsage(
        claudeUserDataURL: URL,
        allowKeychainInteraction: Bool,
        forceRefresh: Bool
    ) async -> ProfileRateLimits
}

enum ClaudeUsageRefreshPolicy {
    static let freshnessInterval: TimeInterval = 5 * 60
    static let failureRetryBackoff: TimeInterval = 60
    static let defaultRateLimitCooldown: TimeInterval = 5 * 60

    static func canReuse(_ limits: ProfileRateLimits, now: Date) -> Bool {
        let age = now.timeIntervalSince(limits.fetchedAt)
        return age >= 0 && age < freshnessInterval
    }

    static func rateLimitCooldown(retryAfter: TimeInterval?) -> TimeInterval {
        max(failureRetryBackoff, retryAfter ?? defaultRateLimitCooldown)
    }
}

public actor ClaudeUsageClient: ClaudeUsageFetching {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private struct CachedUsage {
        var limits: ProfileRateLimits
        var retryAfter: Date?
    }

    private let session: URLSession
    private var cache: [String: CachedUsage] = [:]
    private var refreshWaiters: [String: [CheckedContinuation<ProfileRateLimits, Never>]] = [:]

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func fetchOfficialUsage(
        claudeCodeHomeURL: URL,
        claudeUserDataURL: URL,
        allowKeychainInteraction: Bool,
        forceRefresh: Bool = false
    ) async -> ProfileRateLimits {
        let reader = ClaudeCredentialReader(allowKeychainInteraction: allowKeychainInteraction)
        let codeCredential = reader.readCodeCredential(homeURL: claudeCodeHomeURL)
        let credential = if let codeCredential,
                            codeCredential.scopes.isEmpty
                                || codeCredential.scopes.contains("user:profile")
        {
            codeCredential
        } else {
            reader.readDesktopCredential(userDataURL: claudeUserDataURL) ?? codeCredential
        }
        return await fetch(credential, forceRefresh: forceRefresh)
    }

    public func fetchManagedUsage(
        claudeUserDataURL: URL,
        allowKeychainInteraction: Bool,
        forceRefresh: Bool = false
    ) async -> ProfileRateLimits {
        let credential = ClaudeCredentialReader(
            allowKeychainInteraction: allowKeychainInteraction
        ).readDesktopCredential(userDataURL: claudeUserDataURL)
        return await fetch(credential, forceRefresh: forceRefresh)
    }

    private func fetch(
        _ credential: ClaudeUsageCredential?,
        forceRefresh: Bool
    ) async -> ProfileRateLimits {
        guard let credential else {
            return ProfileRateLimits(
                errorMessage: "Live usage is unavailable. Open Claude and sign in, then refresh."
            )
        }
        guard credential.scopes.isEmpty || credential.scopes.contains("user:profile") else {
            return ProfileRateLimits(
                planType: credential.subscriptionType,
                errorMessage: "This login cannot read live usage. Sign in again to grant profile access."
            )
        }

        let key = credential.cacheKey
        let now = Date()
        if !forceRefresh,
           let cached = cache[key],
           cached.retryAfter == nil,
           ClaudeUsageRefreshPolicy.canReuse(cached.limits, now: now)
        {
            return cached.limits
        }
        if !forceRefresh, let retryAfter = cache[key]?.retryAfter, retryAfter > now {
            return cachedLimits(
                for: key,
                warning: "Live usage is rate limited; showing the last successful update."
            ) ?? ProfileRateLimits(
                planType: credential.subscriptionType,
                errorMessage: "Live usage is rate limited. Try again later."
            )
        }

        if refreshWaiters[key] != nil {
            return await withCheckedContinuation { continuation in
                refreshWaiters[key, default: []].append(continuation)
            }
        }

        refreshWaiters[key] = []
        let limits = await fetchUncached(credential, key: key)
        let waiters = refreshWaiters.removeValue(forKey: key) ?? []
        waiters.forEach { $0.resume(returning: limits) }
        return limits
    }

    private func fetchUncached(
        _ credential: ClaudeUsageCredential,
        key: String
    ) async -> ProfileRateLimits {
        do {
            if let identity = credential.identity {
                try await verifyIdentity(identity, accessToken: credential.accessToken)
            }
            let (data, response) = try await request(Self.usageURL, token: credential.accessToken)
            if response.statusCode == 429 {
                let retryAt = Date().addingTimeInterval(
                    ClaudeUsageRefreshPolicy.rateLimitCooldown(
                        retryAfter: retryAfter(from: response)
                    )
                )
                recordFailureCooldown(
                    for: key,
                    fallback: ProfileRateLimits(planType: credential.subscriptionType),
                    retryAt: retryAt
                )
                return cachedLimits(
                    for: key,
                    warning: "Live usage is rate limited; showing the last successful update."
                ) ?? ProfileRateLimits(
                    planType: credential.subscriptionType,
                    errorMessage: "Live usage is rate limited. Try again later."
                )
            }
            guard (200..<300).contains(response.statusCode) else {
                let failure = requestFailure(response.statusCode, credential: credential)
                let retryDelay = response.statusCode == 401 || response.statusCode == 403
                    ? ClaudeUsageRefreshPolicy.defaultRateLimitCooldown
                    : ClaudeUsageRefreshPolicy.failureRetryBackoff
                recordFailureCooldown(
                    for: key,
                    fallback: failure,
                    retryAt: Date().addingTimeInterval(retryDelay)
                )
                return cachedLimits(
                    for: key,
                    warning: failure.errorMessage ?? "Live usage could not be refreshed."
                ) ?? failure
            }
            var limits = try ClaudeUsageResponseParser.parse(
                data,
                planType: credential.subscriptionType
            )
            limits.fetchedAt = Date()
            cache[key] = CachedUsage(limits: limits, retryAfter: nil)
            return limits
        } catch ClaudeUsageClientError.identityMismatch {
            cache.removeValue(forKey: key)
            return ProfileRateLimits(
                errorMessage: "The Claude login no longer matches this account. Open Claude and sign in, then refresh."
            )
        } catch ClaudeUsageClientError.rateLimited(let retryAfter) {
            let retryAt = Date().addingTimeInterval(
                ClaudeUsageRefreshPolicy.rateLimitCooldown(retryAfter: retryAfter)
            )
            recordFailureCooldown(
                for: key,
                fallback: ProfileRateLimits(planType: credential.subscriptionType),
                retryAt: retryAt
            )
            return cachedLimits(
                for: key,
                warning: "Live usage is rate limited; showing the last successful update."
            ) ?? ProfileRateLimits(
                planType: credential.subscriptionType,
                errorMessage: "Live usage is rate limited. Try again later."
            )
        } catch ClaudeUsageClientError.requestFailed(let statusCode) {
            let failure = requestFailure(statusCode, credential: credential)
            let retryDelay = statusCode == 401 || statusCode == 403
                ? ClaudeUsageRefreshPolicy.defaultRateLimitCooldown
                : ClaudeUsageRefreshPolicy.failureRetryBackoff
            recordFailureCooldown(
                for: key,
                fallback: failure,
                retryAt: Date().addingTimeInterval(retryDelay)
            )
            return cachedLimits(
                for: key,
                warning: failure.errorMessage ?? "Live usage could not be refreshed."
            ) ?? failure
        } catch {
            recordFailureCooldown(
                for: key,
                fallback: ProfileRateLimits(planType: credential.subscriptionType),
                retryAt: Date().addingTimeInterval(ClaudeUsageRefreshPolicy.failureRetryBackoff)
            )
            return cachedLimits(
                for: key,
                warning: "Live usage could not be refreshed; showing the last successful update."
            ) ?? ProfileRateLimits(
                planType: credential.subscriptionType,
                errorMessage: "Live usage could not be loaded. Check the connection and refresh."
            )
        }
    }

    private func recordFailureCooldown(
        for key: String,
        fallback: ProfileRateLimits,
        retryAt: Date
    ) {
        if var existing = cache[key] {
            existing.retryAfter = retryAt
            cache[key] = existing
        } else {
            cache[key] = CachedUsage(limits: fallback, retryAfter: retryAt)
        }
    }

    private func verifyIdentity(_ expected: ClaudeAccountIdentity, accessToken: String) async throws {
        let (data, response) = try await request(Self.profileURL, token: accessToken)
        if response.statusCode == 429 {
            throw ClaudeUsageClientError.rateLimited(retryAfter(from: response))
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ClaudeUsageClientError.requestFailed(response.statusCode)
        }
        let profile = try JSONDecoder().decode(ClaudeAccountProfile.self, from: data)
        guard profile.account.uuid.caseInsensitiveCompare(expected.accountUUID) == .orderedSame,
              profile.organization?.uuid.caseInsensitiveCompare(expected.organizationUUID) == .orderedSame
        else {
            throw ClaudeUsageClientError.identityMismatch
        }
    }

    private func request(_ url: URL, token: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
        let maximumResponseBytes = 1 * 1_024 * 1_024
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ClaudeUsageClientError.invalidResponse
        }
        guard response.expectedContentLength <= maximumResponseBytes else {
            throw ClaudeUsageClientError.responseTooLarge
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw ClaudeUsageClientError.responseTooLarge
            }
            data.append(byte)
        }
        return (data, response)
    }

    private func requestFailure(
        _ statusCode: Int,
        credential: ClaudeUsageCredential
    ) -> ProfileRateLimits {
        let message = switch statusCode {
        case 401: "The Claude session expired. Sign in again, then refresh."
        case 403: "This Claude login is not permitted to read live usage."
        default: "Live usage request failed (HTTP \(statusCode))."
        }
        return ProfileRateLimits(planType: credential.subscriptionType, errorMessage: message)
    }

    private func cachedLimits(for key: String, warning: String) -> ProfileRateLimits? {
        guard var limits = cache[key]?.limits, !limits.buckets.isEmpty else { return nil }
        limits.warningMessage = warning
        return limits
    }

    private func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value), seconds >= 0 { return seconds }
        return nil
    }
}

struct ClaudeAccountIdentity: Equatable, Sendable {
    var accountUUID: String
    var organizationUUID: String

    static func desktop(accountUUID: String?, organizationUUID: String) -> Self? {
        guard let accountUUID,
              let account = UUID(uuidString: accountUUID),
              let organization = UUID(uuidString: organizationUUID)
        else { return nil }
        return Self(
            accountUUID: account.uuidString.lowercased(),
            organizationUUID: organization.uuidString.lowercased()
        )
    }
}

struct ClaudeUsageCredential: Sendable {
    var accessToken: String
    var expiresAt: Double?
    var subscriptionType: String?
    var scopes: Set<String>
    var identity: ClaudeAccountIdentity?

    var cacheKey: String {
        let digest = SHA256.hash(data: Data(accessToken.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        if let identity {
            return "\(identity.accountUUID.lowercased())|\(identity.organizationUUID.lowercased())|\(digest)"
        }
        return digest
    }
}

enum ClaudeUsageResponseParser {
    static func parse(
        _ data: Data,
        planType: String? = nil,
        fetchedAt: Date = Date()
    ) throws -> ProfileRateLimits {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageClientError.invalidResponse
        }

        var buckets: [RateLimitBucket] = []
        let session = window(root["five_hour"], minutes: 300)
        let weekly = window(root["seven_day"], minutes: 10_080)
        if session != nil || weekly != nil {
            buckets.append(RateLimitBucket(
                id: "claude",
                name: "Claude",
                primary: session,
                secondary: weekly
            ))
        }
        if let sonnet = window(root["seven_day_sonnet"], minutes: 10_080) {
            buckets.append(RateLimitBucket(
                id: "sonnet",
                name: "Sonnet",
                primary: sonnet,
                secondary: nil
            ))
        }
        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits where limit["kind"] as? String == "weekly_scoped" {
                guard let scope = limit["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let name = nonempty(model["display_name"] as? String),
                      let percent = number(limit["percent"])
                else { continue }
                let reset = date(limit["resets_at"])
                buckets.append(RateLimitBucket(
                    id: "model-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
                    name: name,
                    primary: RateLimitWindowUsage(
                        usedPercent: percent,
                        windowDurationMins: 10_080,
                        resetsAt: reset
                    ),
                    secondary: nil
                ))
            }
        }

        return ProfileRateLimits(
            planType: planType,
            buckets: buckets,
            credits: credits(root["extra_usage"]),
            fetchedAt: fetchedAt
        )
    }

    private static func window(_ value: Any?, minutes: Int) -> RateLimitWindowUsage? {
        guard let object = value as? [String: Any],
              let percent = number(object["utilization"])
        else { return nil }
        return RateLimitWindowUsage(
            usedPercent: percent,
            windowDurationMins: minutes,
            resetsAt: date(object["resets_at"])
        )
    }

    private static func credits(_ value: Any?) -> CreditsUsage? {
        guard let object = value as? [String: Any], object["is_enabled"] as? Bool == true,
              let usedCents = number(object["used_credits"])
        else { return nil }
        let used = usedCents / 100
        if let limitCents = number(object["monthly_limit"]), limitCents > 0 {
            return CreditsUsage(
                hasCredits: true,
                unlimited: false,
                balance: String(format: "$%.2f of $%.2f used", used, limitCents / 100)
            )
        }
        return CreditsUsage(
            hasCredits: true,
            unlimited: true,
            balance: String(format: "$%.2f used", used)
        )
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let number as Double: number
        case let number as Int: Double(number)
        default: nil
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = nonempty(value as? String) else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(text)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct ClaudeCredentialReader {
    private static let codeService = "Claude Code-credentials"
    private static let safeStorageService = "Claude Safe Storage"
    private static let safeStorageAccount = "Claude Key"
    private static let cacheKeys = ["oauth:tokenCacheV2", "oauth:tokenCache"]
    private let allowKeychainInteraction: Bool

    init(allowKeychainInteraction: Bool) {
        self.allowKeychainInteraction = allowKeychainInteraction
    }

    func readCodeCredential(homeURL: URL) -> ClaudeUsageCredential? {
        let identity = codeIdentity(homeURL: homeURL)
        if let text = readKeychainPassword(
            service: Self.codeService,
            account: NSUserName()
        ) ?? readKeychainPassword(service: Self.codeService, account: nil),
           let credential = parseCredential(text, identity: identity)
        {
            return credential
        }
        let file = homeURL.appendingPathComponent(".credentials.json")
        guard let text = try? BoundedFileReader.string(
            at: file,
            maximumBytes: LocalControlFileLimit.providerCredentialState
        ) else { return nil }
        return parseCredential(text, identity: identity)
    }

    func readDesktopCredential(userDataURL: URL) -> ClaudeUsageCredential? {
        let configURL = userDataURL.appendingPathComponent("config.json")
        guard let data = try? BoundedFileReader.data(
                  at: configURL,
                  maximumBytes: LocalControlFileLimit.providerCredentialState
              ),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let password = readKeychainPassword(
                  service: Self.safeStorageService,
                  account: Self.safeStorageAccount
              ),
              let key = try? deriveKey(password: password)
        else { return nil }

        let caches = Self.cacheKeys.compactMap { cacheKey -> [String: Any]? in
            guard let encoded = root[cacheKey] as? String,
                  let encrypted = Data(base64Encoded: encoded),
                  let plaintext = try? decrypt(encrypted, key: key)
            else { return nil }
            return try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any]
        }
        let organizations = Set(caches.flatMap(desktopOrganizations))
        guard let activeOrganization = activeOrganization(userDataURL: userDataURL, key: key)
            ?? (organizations.count == 1 ? organizations.first : nil)
        else { return nil }

        guard let identity = ClaudeAccountIdentity.desktop(
            accountUUID: root["lastKnownAccountUuid"] as? String,
            organizationUUID: activeOrganization
        ) else { return nil }
        for cache in caches {
            guard let credential = selectDesktopCredential(
                cache,
                organization: activeOrganization,
                identity: identity
            ) else { continue }
            return credential
        }
        return nil
    }

    private func parseCredential(
        _ text: String,
        identity: ClaudeAccountIdentity?
    ) -> ClaudeUsageCredential? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = nonempty(oauth["accessToken"] as? String)
        else { return nil }
        return ClaudeUsageCredential(
            accessToken: token,
            expiresAt: number(oauth["expiresAt"]),
            subscriptionType: nonempty(oauth["subscriptionType"] as? String),
            scopes: Set((oauth["scopes"] as? [String]) ?? []),
            identity: identity
        )
    }

    private func codeIdentity(homeURL: URL) -> ClaudeAccountIdentity? {
        let stateURL = homeURL.deletingLastPathComponent().appendingPathComponent(".claude.json")
        guard let data = try? BoundedFileReader.data(
                  at: stateURL,
                  maximumBytes: LocalControlFileLimit.providerCredentialState
              ),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any],
              let accountUUID = nonempty(account["accountUuid"] as? String),
              let organizationUUID = nonempty(account["organizationUuid"] as? String)
        else { return nil }
        return ClaudeAccountIdentity(
            accountUUID: accountUUID.lowercased(),
            organizationUUID: organizationUUID.lowercased()
        )
    }

    private func selectDesktopCredential(
        _ cache: [String: Any],
        organization: String,
        identity: ClaudeAccountIdentity?
    ) -> ClaudeUsageCredential? {
        let now = Date().timeIntervalSince1970 * 1_000
        var candidates: [(rank: Int, expiry: Double, credential: ClaudeUsageCredential)] = []
        for (key, raw) in cache {
            guard let metadata = desktopCacheMetadata(key),
                  metadata.organization.caseInsensitiveCompare(organization) == .orderedSame,
                  metadata.host == "https://api.anthropic.com",
                  metadata.scopes.contains("user:profile"),
                  let entry = raw as? [String: Any],
                  let token = nonempty(entry["token"] as? String),
                  let expiry = number(entry["expiresAt"]),
                  expiry > now + 120_000
            else { continue }
            let fullScope = metadata.scopes.contains("user:inference")
            let productionClient = metadata.clientID == "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
            let rank = (productionClient && fullScope ? 10_000 : 0)
                + (fullScope ? 1_000 : 0) + metadata.scopes.count
            candidates.append((
                rank,
                expiry,
                ClaudeUsageCredential(
                    accessToken: token,
                    expiresAt: expiry,
                    subscriptionType: nonempty(entry["subscriptionType"] as? String),
                    scopes: Set(metadata.scopes),
                    identity: identity
                )
            ))
        }
        return candidates.max {
            $0.rank == $1.rank ? $0.expiry < $1.expiry : $0.rank < $1.rank
        }?.credential
    }

    private func desktopCacheMetadata(
        _ value: String
    ) -> (clientID: String, organization: String, host: String, scopes: [String])? {
        let marker = ":https://api.anthropic.com:"
        guard let range = value.range(of: marker) else { return nil }
        let prefix = value[..<range.lowerBound]
        guard let separator = prefix.firstIndex(of: ":") else { return nil }
        return (
            String(prefix[..<separator]),
            String(prefix[prefix.index(after: separator)...]).lowercased(),
            "https://api.anthropic.com",
            value[range.upperBound...].split(whereSeparator: \.isWhitespace).map(String.init)
        )
    }

    private func desktopOrganizations(_ cache: [String: Any]) -> [String] {
        cache.keys.compactMap { desktopCacheMetadata($0)?.organization }
    }

    private func activeOrganization(userDataURL: URL, key: Data) -> String? {
        let cookieURLs = [
            userDataURL.appendingPathComponent("Cookies"),
            userDataURL.appendingPathComponent("Network/Cookies")
        ]
        let query = """
        SELECT host_key || '|' || CASE
          WHEN length(value) > 0 THEN 'plain:' || hex(CAST(value AS BLOB))
          ELSE 'encrypted:' || hex(encrypted_value)
        END
        FROM cookies
        WHERE name = 'lastActiveOrg' AND host_key IN ('.claude.ai', 'claude.ai')
        ORDER BY last_update_utc DESC LIMIT 1;
        """
        for cookieURL in cookieURLs where FileManager.default.fileExists(atPath: cookieURL.path) {
            guard let databaseArgument = try? SQLiteReadOnly.databaseArgument(
                for: cookieURL,
                under: userDataURL
            ),
                  let result = try? BoundedSubprocess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                arguments: ["-nofollow", "-readonly", databaseArgument, query],
                timeout: 2,
                maximumOutputBytes: 4_096
            ), result.terminationStatus == 0, !result.exceededOutputLimit,
            let line = String(data: result.output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let hostSeparator = line.firstIndex(of: "|")
            else { continue }
            let host = String(line[..<hostSeparator])
            let encoded = String(line[line.index(after: hostSeparator)...])
            guard let modeSeparator = encoded.firstIndex(of: ":"),
                  let stored = Data(hexString: String(encoded[encoded.index(after: modeSeparator)...]))
            else { continue }
            let mode = encoded[..<modeSeparator]
            let value: Data
            if mode == "plain" {
                value = stored
            } else if mode == "encrypted",
                      let decrypted = try? decrypt(stored, key: key)
            {
                let hostHash = Data(SHA256.hash(data: Data(host.utf8)))
                guard decrypted.starts(with: hostHash) else { continue }
                value = decrypted.dropFirst(hostHash.count)
            } else {
                continue
            }
            guard let organization = String(data: value, encoding: .utf8),
                  UUID(uuidString: organization) != nil
            else { continue }
            return organization.lowercased()
        }
        return nil
    }

    private func readKeychainPassword(service: String, account: String?) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if !allowKeychainInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return nonempty(value)
    }

    private func deriveKey(password: String) throws -> Data {
        let password = Data(password.utf8)
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let count = key.count
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1_003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw ClaudeUsageClientError.invalidCredential }
        return key
    }

    private func decrypt(_ encrypted: Data, key: Data) throws -> Data {
        guard encrypted.count > 3,
              encrypted.prefix(3) == Data("v10".utf8),
              key.count == kCCKeySizeAES128
        else { throw ClaudeUsageClientError.invalidCredential }
        let payload = encrypted.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        var outputLength = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outputBytes.baseAddress,
                            capacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ClaudeUsageClientError.invalidCredential }
        output.count = outputLength
        return output
    }

    private func number(_ value: Any?) -> Double? {
        switch value {
        case let value as NSNumber: value.doubleValue
        case let value as Double: value
        case let value as Int: Double(value)
        default: nil
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct ClaudeAccountProfile: Decodable {
    struct Identity: Decodable { var uuid: String }
    var account: Identity
    var organization: Identity?
}

private enum ClaudeUsageClientError: Error {
    case invalidResponse
    case responseTooLarge
    case invalidCredential
    case identityMismatch
    case rateLimited(TimeInterval?)
    case requestFailed(Int)
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
