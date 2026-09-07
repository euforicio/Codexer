import AppKit
import CoreGraphics
import Darwin
import Foundation
import Security

public struct IsolatedCodexLaunchConfiguration: Codable, Equatable, Sendable {
    public var product: DesktopProduct?
    public var codexAppPath: String
    public var codexHomePath: String
    public var electronUserDataPath: String
    public var claudeUserDataPath: String?
    public var mcpOAuthCallbackPort: Int?
    public var profileID: UUID?
    public var profileSlug: String?
    public var codexLaunchProfileSelection: CodexLaunchProfileSelection?

    public init(
        codexAppURL: URL,
        codexHomeURL: URL,
        electronUserDataURL: URL,
        mcpOAuthCallbackPort: Int? = nil,
        profileID: UUID? = nil,
        profileSlug: String? = nil,
        codexLaunchProfileSelection: CodexLaunchProfileSelection = .builtIn
    ) {
        product = .codex
        codexAppPath = codexAppURL.path
        codexHomePath = codexHomeURL.path
        electronUserDataPath = electronUserDataURL.path
        claudeUserDataPath = nil
        self.mcpOAuthCallbackPort = mcpOAuthCallbackPort
        self.profileID = profileID
        self.profileSlug = profileSlug
        self.codexLaunchProfileSelection = codexLaunchProfileSelection
    }

    public init(profile: CodexProfile, codexAppURL: URL) {
        product = profile.product
        codexAppPath = codexAppURL.path
        codexHomePath = profile.product == .codex ? profile.codexHomePath.path : ""
        electronUserDataPath = profile.product == .codex ? profile.electronUserDataPath.path : ""
        claudeUserDataPath = profile.product == .claude ? profile.claudeUserDataPath.path : nil
        mcpOAuthCallbackPort = profile.product == .codex ? profile.mcpOAuthCallbackPort : nil
        profileID = profile.id
        profileSlug = profile.slug
        codexLaunchProfileSelection = profile.product == .codex
            ? profile.codexLaunchProfileSelection
            : nil
    }

    public var resolvedProduct: DesktopProduct { product ?? .codex }
    public var appURL: URL { codexAppURL }
    public var codexAppURL: URL { URL(fileURLWithPath: codexAppPath) }
    public var codexHomeURL: URL { URL(fileURLWithPath: codexHomePath, isDirectory: true) }
    public var electronUserDataURL: URL { URL(fileURLWithPath: electronUserDataPath, isDirectory: true) }
    public var claudeUserDataURL: URL? {
        claudeUserDataPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    public var appExecutableURL: URL {
        Self.appExecutableURL(for: codexAppURL)
    }
    public var codexConfigProfile: CodexConfigProfile? {
        guard case let .some(.named(profile)) = codexLaunchProfileSelection else { return nil }
        return profile
    }

    public static func appExecutableURL(for codexAppURL: URL) -> URL {
        let infoPlistURL = codexAppURL.appendingPathComponent("Contents/Info.plist")
        let executableName: String? = {
            guard
                let data = try? BoundedFileReader.data(
                    at: infoPlistURL,
                    maximumBytes: LocalControlFileLimit.propertyList
                ),
                let plist = try? PropertyListSerialization.propertyList(
                    from: data,
                    format: nil
                ) as? [String: Any]
            else {
                return nil
            }
            return plist["CFBundleExecutable"] as? String
        }()

        return codexAppURL
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(executableName ?? "Codex")
    }
}

public struct CodexInstanceStatus: Equatable, Sendable {
    public var processIDs: [Int32]

    public init(processIDs: [Int32] = []) {
        self.processIDs = processIDs.sorted()
    }

    public var isRunning: Bool { !processIDs.isEmpty }
    public var primaryProcessID: Int32? { processIDs.first }
}

public enum CodexOpenOutcome: Equatable, Sendable {
    case launched(processID: Int32)
    case focused(processID: Int32)
}

public enum CodexCloseOutcome: Equatable, Sendable {
    case alreadyStopped
    case closed(processIDs: [Int32])
}

public protocol CodexAppValidating: Sendable {
    func validateCodexApp(at url: URL) throws
}

public struct OfficialCodexAppValidator: CodexAppValidating, @unchecked Sendable {
    public static let bundleIdentifier = "com.openai.codex"
    public static let teamIdentifier = "2DC432GLL2"

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func validateCodexApp(at url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodexLauncherError.codexAppMissing(url.path)
        }

        let infoPlist = url.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? BoundedFileReader.data(
                at: infoPlist,
                maximumBytes: LocalControlFileLimit.propertyList
            ),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            plist["CFBundleIdentifier"] as? String == Self.bundleIdentifier
        else {
            throw CodexLauncherError.invalidCodexBundle(url.path)
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            throw CodexLauncherError.invalidCodexSignature(url.path)
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(Self.requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        else {
            throw CodexLauncherError.invalidCodexSignature(url.path)
        }
    }

    fileprivate static var requirementText: String {
        "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    fileprivate static var teamRequirementText: String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

public protocol CodexProcessSnapshotProviding: Sendable {
    func processSnapshot() throws -> String
}

public struct SystemCodexProcessSnapshotProvider: CodexProcessSnapshotProviding {
    public init() {}

    public func processSnapshot() throws -> String {
        let result: BoundedSubprocessResult
        do {
            result = try BoundedSubprocess.run(
                executableURL: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-ax", "-o", "pid=,command="],
                timeout: 3,
                maximumOutputBytes: 8 * 1_024 * 1_024
            )
        } catch {
            throw CodexLauncherError.processInspectionUnavailable
        }
        guard !result.exceededOutputLimit else {
            throw CodexLauncherError.processInspectionUnavailable
        }
        guard result.terminationStatus == 0 else {
            throw CodexLauncherError.processInspectionFailed(result.terminationStatus)
        }
        return String(decoding: result.output, as: UTF8.self)
    }
}

public enum CodexInstanceDiscovery {
    public static func canonicalUserDataPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    public static func processIDsByUserDataPath(
        in processSnapshot: String,
        appExecutableURL: URL
    ) -> [String: [Int32]] {
        let executable = appExecutableURL.standardizedFileURL.path
        var result: [String: [Int32]] = [:]

        for line in processSnapshot.split(whereSeparator: \.isNewline) {
            let trimmed = line.drop(while: \.isWhitespace)
            guard let separator = trimmed.firstIndex(where: \.isWhitespace) else { continue }
            let pidText = trimmed[..<separator]
            let command = trimmed[separator...].drop(while: \.isWhitespace)
            guard let processID = Int32(pidText),
                  command.hasPrefix("\(executable) ")
            else {
                continue
            }
            let paths = userDataArguments(in: String(command))
            guard paths.count == 1, let path = paths.first, !path.isEmpty else { continue }
            result[canonicalUserDataPath(path), default: []].append(processID)
        }

        return result.mapValues { $0.sorted() }
    }

    public static func processIDs(
        in processSnapshot: String,
        configuration: IsolatedCodexLaunchConfiguration
    ) -> [Int32] {
        processIDsByUserDataPath(
            in: processSnapshot,
            appExecutableURL: configuration.appExecutableURL
        )[canonicalUserDataPath(configuration.electronUserDataPath)] ?? []
    }

    public static func stockProcessIDs(
        in processSnapshot: String,
        appExecutableURL: URL
    ) -> [Int32] {
        let executable = appExecutableURL.standardizedFileURL.path
        return processSnapshot.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.drop(while: \.isWhitespace)
            guard let separator = trimmed.firstIndex(where: \.isWhitespace),
                  let processID = Int32(trimmed[..<separator])
            else {
                return nil
            }
            let command = String(trimmed[separator...].drop(while: \.isWhitespace))
            guard command == executable || command.hasPrefix("\(executable) ") else {
                return nil
            }
            return userDataArguments(in: command).isEmpty ? processID : nil
        }.sorted()
    }

    public static func profileProcessIDs(
        in processSnapshot: String,
        configuration: IsolatedCodexLaunchConfiguration
    ) -> [Int32] {
        let bundledProcessIDs = Set(
            bundledProfileProcessIDs(
                in: processSnapshot,
                configuration: configuration
            )
        )
        let codexHomeExecutablePrefix = canonicalUserDataPath(
            configuration.codexHomePath
        ) + "/"

        return processSnapshot.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.drop(while: \.isWhitespace)
            guard let separator = trimmed.firstIndex(where: \.isWhitespace),
                  let processID = Int32(trimmed[..<separator])
            else {
                return nil
            }
            let command = String(trimmed[separator...].drop(while: \.isWhitespace))
            return bundledProcessIDs.contains(processID)
                || command.hasPrefix(codexHomeExecutablePrefix)
                ? processID
                : nil
        }.sorted()
    }

    static func bundledProfileProcessIDs(
        in processSnapshot: String,
        configuration: IsolatedCodexLaunchConfiguration
    ) -> [Int32] {
        let profilePath = canonicalUserDataPath(configuration.electronUserDataPath)
        let appBundlePrefix = configuration.codexAppURL
            .standardizedFileURL
            .appendingPathComponent("Contents")
            .path + "/"

        return processSnapshot.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.drop(while: \.isWhitespace)
            guard let separator = trimmed.firstIndex(where: \.isWhitespace),
                  let processID = Int32(trimmed[..<separator])
            else {
                return nil
            }
            let command = String(trimmed[separator...].drop(while: \.isWhitespace))
            guard command.hasPrefix(appBundlePrefix) else { return nil }
            let userDataPaths = userDataArguments(in: command)
            let databasePaths = argumentValues(named: "--database", in: command)
            guard userDataPaths.count <= 1, databasePaths.count <= 1,
                  !userDataPaths.isEmpty || !databasePaths.isEmpty,
                  userDataPaths.allSatisfy({ !$0.isEmpty && canonicalUserDataPath($0) == profilePath }),
                  databasePaths.allSatisfy({
                      !$0.isEmpty && canonicalUserDataPath($0) == profilePath + "/Crashpad"
                  })
            else {
                return nil
            }
            return processID
        }.sorted()
    }

    static func isExecutable(
        _ executableURL: URL,
        containedBy directoryURL: URL
    ) -> Bool {
        let executableComponents = executableURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .pathComponents
        let directoryComponents = directoryURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .pathComponents
        guard executableComponents.count > directoryComponents.count else {
            return false
        }
        return zip(directoryComponents, executableComponents).allSatisfy {
            $0.0 == $0.1
        }
    }

    static func userDataArguments(in command: String) -> [String] {
        argumentValues(named: "--user-data-dir", in: command)
    }

    private static func argumentValues(named name: String, in command: String) -> [String] {
        let marker = name + "="
        var values: [String] = []
        var searchStart = command.startIndex
        while let markerRange = command.range(
            of: marker,
            range: searchStart..<command.endIndex
        ) {
            let beginsArgument = markerRange.lowerBound == command.startIndex
                || command[command.index(before: markerRange.lowerBound)].isWhitespace
            let valueStart = markerRange.upperBound
            let remaining = command[valueStart...]
            let valueEnd = remaining.range(of: " --")?.lowerBound ?? command.endIndex
            if beginsArgument {
                let value = command[valueStart..<valueEnd]
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                values.append(value)
            }
            searchStart = valueEnd
        }
        return values
    }
}

public protocol CodexWorkspaceLaunching: Sendable {
    func launch(configuration: IsolatedCodexLaunchConfiguration) async throws -> Int32
    func launchStock(
        codexAppURL: URL,
        codexHomeURL: URL,
        configProfile: CodexConfigProfile?
    ) async throws -> Int32
}

public extension CodexWorkspaceLaunching {
    func launchStock(
        codexAppURL _: URL,
        codexHomeURL _: URL,
        configProfile _: CodexConfigProfile?
    ) async throws -> Int32 {
        throw CodexLauncherError.launchDidNotReturnProcess
    }
}

public struct SystemCodexWorkspaceLauncher: CodexWorkspaceLaunching {
    private let profileProxyURL: URL?

    public init() {
        profileProxyURL = CodexCLIProfileProxy.launcherURL()
    }

    init(profileProxyURL: URL?) {
        self.profileProxyURL = profileProxyURL
    }

    static func launchEnvironment(
        inheriting inheritedEnvironment: [String: String],
        codexAppURL: URL,
        codexHomePath: String?,
        electronUserDataPath: String? = nil,
        configProfile: CodexConfigProfile? = nil,
        profileProxyURL: URL? = nil
    ) -> [String: String] {
        var environment = DesktopLaunchEnvironment.sanitized(inheritedEnvironment)
        let bundledCLIURL = codexAppURL
            .appendingPathComponent("Contents/Resources/codex", isDirectory: false)
        environment["CODEX_CLI_PATH"] = (configProfile == nil ? bundledCLIURL : profileProxyURL)?.path
        environment.removeValue(forKey: CodexCLIProfileProxy.enabledEnvironmentKey)
        environment.removeValue(forKey: CodexCLIProfileProxy.appPathEnvironmentKey)
        environment.removeValue(forKey: CodexCLIProfileProxy.profileEnvironmentKey)
        if let configProfile {
            environment[CodexCLIProfileProxy.enabledEnvironmentKey] = "1"
            environment[CodexCLIProfileProxy.appPathEnvironmentKey] = codexAppURL.path
            environment[CodexCLIProfileProxy.profileEnvironmentKey] = configProfile.name
        }
        if let codexHomePath {
            environment["CODEX_HOME"] = codexHomePath
        }
        // Codex also uses this explicit path to preserve CODEX_HOME while loading
        // the user's login-shell environment during startup.
        environment["CODEX_ELECTRON_USER_DATA_PATH"] = electronUserDataPath
        return environment
    }

    public func launch(configuration: IsolatedCodexLaunchConfiguration) async throws -> Int32 {
        if configuration.codexConfigProfile != nil, profileProxyURL == nil {
            throw CodexLauncherError.profileProxyMissing
        }
        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.activates = true
        openConfiguration.addsToRecentItems = false
        openConfiguration.allowsRunningApplicationSubstitution = false
        openConfiguration.createsNewApplicationInstance = true
        openConfiguration.arguments = [
            "--user-data-dir=\(configuration.electronUserDataPath)"
        ]
        openConfiguration.environment = Self.launchEnvironment(
            inheriting: ProcessInfo.processInfo.environment,
            codexAppURL: configuration.codexAppURL,
            codexHomePath: configuration.codexHomePath,
            electronUserDataPath: configuration.electronUserDataPath,
            configProfile: configuration.codexConfigProfile,
            profileProxyURL: profileProxyURL
        )

        let application = try await NSWorkspace.shared.openApplication(
            at: configuration.codexAppURL,
            configuration: openConfiguration
        )
        let processID = application.processIdentifier
        guard processID > 0 else {
            throw CodexLauncherError.launchDidNotReturnProcess
        }
        return processID
    }

    public func launchStock(
        codexAppURL: URL,
        codexHomeURL: URL,
        configProfile: CodexConfigProfile?
    ) async throws -> Int32 {
        if configProfile != nil, profileProxyURL == nil {
            throw CodexLauncherError.profileProxyMissing
        }
        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.activates = true
        openConfiguration.addsToRecentItems = false
        openConfiguration.allowsRunningApplicationSubstitution = false
        openConfiguration.createsNewApplicationInstance = true
        openConfiguration.environment = Self.launchEnvironment(
            inheriting: ProcessInfo.processInfo.environment,
            codexAppURL: codexAppURL,
            codexHomePath: configProfile == nil ? nil : codexHomeURL.path,
            configProfile: configProfile,
            profileProxyURL: profileProxyURL
        )

        let application = try await NSWorkspace.shared.openApplication(
            at: codexAppURL,
            configuration: openConfiguration
        )
        let processID = application.processIdentifier
        guard processID > 0 else {
            throw CodexLauncherError.launchDidNotReturnProcess
        }
        return processID
    }
}

public protocol CodexApplicationLifecycleControlling: Sendable {
    func focus(processID: Int32, configuration: IsolatedCodexLaunchConfiguration) -> Bool
    func requestPresentation(
        processID: Int32,
        configuration: IsolatedCodexLaunchConfiguration
    ) -> Bool
    func isPresentingWindow(processID: Int32) -> Bool
    func terminate(processID: Int32, configuration: IsolatedCodexLaunchConfiguration) -> Bool
    func isRunning(processID: Int32) -> Bool
    func isVerifiedRunning(
        processID: Int32,
        configuration: IsolatedCodexLaunchConfiguration
    ) -> Bool
    func isVerifiedProfileProcess(
        processID: Int32,
        configuration: IsolatedCodexLaunchConfiguration,
        processSnapshot: String
    ) -> Bool
    func invalidateUnverifiedLaunch(
        processID: Int32,
        configuration: IsolatedCodexLaunchConfiguration
    )
    func focusStock(processID: Int32, codexAppURL: URL) -> Bool
    func terminateStock(processID: Int32, codexAppURL: URL) -> Bool
    func isVerifiedStockRunning(processID: Int32, codexAppURL: URL) -> Bool
    func invalidateUnverifiedStockLaunch(processID: Int32, codexAppURL: URL)
}

public extension CodexApplicationLifecycleControlling {
    func requestPresentation(
        processID: Int32,
        configuration: IsolatedCodexLaunchConfiguration
    ) -> Bool {
        focus(processID: processID, configuration: configuration)
    }

    func isPresentingWindow(processID: Int32) -> Bool {
        isRunning(processID: processID)
    }

    func isVerifiedRunning(
        processID: Int32,
        configuration _: IsolatedCodexLaunchConfiguration
    ) -> Bool {
        isRunning(processID: processID)
    }

    func invalidateUnverifiedLaunch(
        processID _: Int32,
        configuration _: IsolatedCodexLaunchConfiguration
    ) {}

    func focusStock(processID _: Int32, codexAppURL _: URL) -> Bool { false }

    func terminateStock(processID _: Int32, codexAppURL _: URL) -> Bool { false }

    func isVerifiedStockRunning(processID: Int32, codexAppURL _: URL) -> Bool {
        isRunning(processID: processID)
    }

    func invalidateUnverifiedStockLaunch(processID _: Int32, codexAppURL _: URL) {}

    func isVerifiedProfileProcess(
        processID: Int32,
        configuration: IsolatedCodexLaunchConfiguration,
        processSnapshot _: String
    ) -> Bool {
        isVerifiedRunning(processID: processID, configuration: configuration)
    }
}

public struct SystemCodexApplicationLifecycleController: CodexApplicationLifecycleControlling {
    public init() {}

    public func focus(
        processID: Int32,
        configuration: IsolatedCodexLaunchConfiguration
    ) -> Bool {
        guard let application = verifiedApplication(
            processID: processID,
            configuration: configuration
        ) else {
            return false
        }
        sendReopenEvent(to: processID)
        return application.activate(options: [.activateAllWindows])
    }

    public func requestPresentation(
        processID: Int32,
        configuration: IsolatedCodexLaunchConfiguration
    ) -> Bool {
        focus(processID: processID, configuration: configuration)
    }

    public func isPresentingWindow(processID: Int32) -> Bool {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        return windowInfo.contains { window in
            guard
                (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds)
            else {
                return false
            }
            return frame.width > 0 && frame.height > 0
        }
    }

    public func terminate(
        processID: Int32,
        configuration: IsolatedCodexLaunchConfiguration
    ) -> Bool {
        guard let application = verifiedApplication(
            processID: processID,
            configuration: configuration
        ) else {
            return !isStillClaimingProfile(
                processID: processID,
                configuration: configuration
            )
        }
        if application.terminate() {
            return true
        }
        return kill(processID, SIGTERM) == 0 || errno == ESRCH
    }

    public func isRunning(processID: Int32) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processID) else {
            return false
        }
        return !application.isTerminated
    }

    public func isVerifiedRunning(
        processID: Int32,
        configuration: IsolatedCodexLaunchConfiguration
    ) -> Bool {
        verifiedApplication(
            processID: processID,
            configuration: configuration
        ) != nil
    }

    public func invalidateUnverifiedLaunch(
        processID: Int32,
        configuration: IsolatedCodexLaunchConfiguration
    ) {
        officialMainApplication(
            processID: processID,
            configuration: configuration
        )?.terminate()
    }

    public func focusStock(processID: Int32, codexAppURL: URL) -> Bool {
        guard let application = officialMainApplication(
            processID: processID,
            codexAppURL: codexAppURL
        ), isStockProcess(processID: processID, codexAppURL: codexAppURL) else {
            return false
        }
        sendReopenEvent(to: processID)
        return application.activate(options: [.activateAllWindows])
    }

    public func terminateStock(processID: Int32, codexAppURL: URL) -> Bool {
        guard let application = officialMainApplication(
            processID: processID,
            codexAppURL: codexAppURL
        ), isStockProcess(processID: processID, codexAppURL: codexAppURL) else {
            return false
        }
        return application.terminate()
    }

    public func isVerifiedStockRunning(processID: Int32, codexAppURL: URL) -> Bool {
        officialMainApplication(processID: processID, codexAppURL: codexAppURL) != nil
            && isStockProcess(processID: processID, codexAppURL: codexAppURL)
    }

    public func invalidateUnverifiedStockLaunch(processID: Int32, codexAppURL: URL) {
        officialMainApplication(processID: processID, codexAppURL: codexAppURL)?.terminate()
    }

    public func isVerifiedProfileProcess(
        processID: Int32,
        configuration: IsolatedCodexLaunchConfiguration,
        processSnapshot: String
    ) -> Bool {
        guard hasOfficialDynamicSignature(
            processID: processID,
            requirementText: OfficialCodexAppValidator.teamRequirementText
        )
        else {
            return false
        }
        if CodexInstanceDiscovery.bundledProfileProcessIDs(
            in: processSnapshot,
            configuration: configuration
        ).contains(processID) {
            return true
        }
        guard let executableURL = SystemProcessTreeSnapshotProvider.executableURL(
            for: processID
        ) else {
            return false
        }
        return CodexInstanceDiscovery.isExecutable(
            executableURL,
            containedBy: configuration.codexHomeURL
        )
    }

    private func sendReopenEvent(to processID: Int32) {
        let target = NSAppleEventDescriptor(processIdentifier: processID)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        _ = try? event.sendEvent(options: .noReply, timeout: 1)
    }

    private func isStillClaimingProfile(
        processID: Int32,
        configuration: IsolatedCodexLaunchConfiguration
    ) -> Bool {
        guard let snapshot = try? SystemCodexProcessSnapshotProvider().processSnapshot() else {
            return true
        }
        return CodexInstanceDiscovery.profileProcessIDs(
            in: snapshot,
            configuration: configuration
        ).contains(processID)
    }

    private func verifiedApplication(
        processID: Int32,
        configuration: IsolatedCodexLaunchConfiguration
    ) -> NSRunningApplication? {
        guard let application = officialMainApplication(
            processID: processID,
            configuration: configuration
        ) else { return nil }
        guard let snapshot = try? SystemCodexProcessSnapshotProvider().processSnapshot(),
              CodexInstanceDiscovery.processIDs(
                in: snapshot,
                configuration: configuration
              ).contains(processID)
        else {
            return nil
        }
        return application
    }

    private func officialMainApplication(
        processID: Int32,
        configuration: IsolatedCodexLaunchConfiguration
    ) -> NSRunningApplication? {
        officialMainApplication(
            processID: processID,
            codexAppURL: configuration.codexAppURL
        )
    }

    private func officialMainApplication(
        processID: Int32,
        codexAppURL: URL
    ) -> NSRunningApplication? {
        guard let application = NSRunningApplication(processIdentifier: processID),
              application.bundleIdentifier == OfficialCodexAppValidator.bundleIdentifier,
              application.executableURL?.standardizedFileURL
                == IsolatedCodexLaunchConfiguration.appExecutableURL(for: codexAppURL)
                    .standardizedFileURL,
              hasOfficialDynamicSignature(
                processID: processID,
                requirementText: OfficialCodexAppValidator.requirementText
              )
        else {
            return nil
        }
        return application
    }

    private func isStockProcess(processID: Int32, codexAppURL: URL) -> Bool {
        guard let snapshot = try? SystemCodexProcessSnapshotProvider().processSnapshot() else {
            return false
        }
        return CodexInstanceDiscovery.stockProcessIDs(
            in: snapshot,
            appExecutableURL: IsolatedCodexLaunchConfiguration.appExecutableURL(for: codexAppURL)
        ).contains(processID)
    }

    private func hasOfficialDynamicSignature(
        processID: Int32,
        requirementText: String
    ) -> Bool {
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: processID)
        ] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code
        else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        ) == errSecSuccess,
              let requirement
        else {
            return false
        }
        return SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            requirement
        ) == errSecSuccess
    }
}

public actor CodexInstanceController {
    private let fileManager: FileManager
    private let validator: any CodexAppValidating
    private let processSnapshotProvider: any CodexProcessSnapshotProviding
    private let workspaceLauncher: any CodexWorkspaceLaunching
    private let lifecycleController: any CodexApplicationLifecycleControlling
    private let closeTimeout: Duration
    private let closePollInterval: Duration
    private let launchValidationTimeout: Duration
    private let windowPresentationTimeout: Duration
    private let processTreeProvider: any ProcessTreeSnapshotProviding
    private let processIdentitySignaler: any ProcessIdentitySignaling
    private let kernelStartKeyProvider: @Sendable (Int32) -> String?

    public init(
        fileManager: FileManager = .default,
        validator: any CodexAppValidating = OfficialCodexAppValidator(),
        processSnapshotProvider: any CodexProcessSnapshotProviding = SystemCodexProcessSnapshotProvider(),
        workspaceLauncher: any CodexWorkspaceLaunching = SystemCodexWorkspaceLauncher(),
        lifecycleController: any CodexApplicationLifecycleControlling = SystemCodexApplicationLifecycleController(),
        closeTimeout: Duration = .seconds(5),
        closePollInterval: Duration = .milliseconds(100),
        launchValidationTimeout: Duration = .seconds(2),
        windowPresentationTimeout: Duration = .seconds(10),
        processTreeProvider: any ProcessTreeSnapshotProviding = SystemProcessTreeSnapshotProvider(),
        processIdentitySignaler: (any ProcessIdentitySignaling)? = nil,
        kernelStartKeyProvider: (@Sendable (Int32) -> String?)? = nil
    ) {
        self.fileManager = fileManager
        self.validator = validator
        self.processSnapshotProvider = processSnapshotProvider
        self.workspaceLauncher = workspaceLauncher
        self.lifecycleController = lifecycleController
        self.closeTimeout = closeTimeout
        self.closePollInterval = closePollInterval
        self.launchValidationTimeout = launchValidationTimeout
        self.windowPresentationTimeout = windowPresentationTimeout
        self.processTreeProvider = processTreeProvider
        self.processIdentitySignaler = processIdentitySignaler
            ?? SystemProcessIdentitySignaler(snapshotProvider: processTreeProvider)
        self.kernelStartKeyProvider = kernelStartKeyProvider ?? {
            SystemProcessTreeSnapshotProvider.kernelStartKey(for: $0)
        }
    }

    public func status(
        for profile: CodexProfile,
        codexAppURL: URL
    ) throws -> CodexInstanceStatus {
        try status(configuration: IsolatedCodexLaunchConfiguration(profile: profile, codexAppURL: codexAppURL))
    }

    public func statuses(
        for profiles: [CodexProfile],
        codexAppURL: URL
    ) throws -> [CodexProfile.ID: CodexInstanceStatus] {
        let snapshot = try processSnapshotProvider.processSnapshot()
        let appExecutableURL = IsolatedCodexLaunchConfiguration.appExecutableURL(
            for: codexAppURL
        )
        let processIDsByPath = CodexInstanceDiscovery.processIDsByUserDataPath(
            in: snapshot,
            appExecutableURL: appExecutableURL
        )
        return Dictionary(uniqueKeysWithValues: profiles.map { profile in
            return (
                profile.id,
                CodexInstanceStatus(
                    processIDs: processIDsByPath[
                        CodexInstanceDiscovery.canonicalUserDataPath(
                            profile.electronUserDataPath.path
                        )
                    ] ?? []
                )
            )
        })
    }

    public func stockStatus(codexAppURL: URL) throws -> CodexInstanceStatus {
        let snapshot = try processSnapshotProvider.processSnapshot()
        return CodexInstanceStatus(
            processIDs: CodexInstanceDiscovery.stockProcessIDs(
                in: snapshot,
                appExecutableURL: IsolatedCodexLaunchConfiguration.appExecutableURL(
                    for: codexAppURL
                )
            )
        )
    }

    public func open(
        profile: CodexProfile,
        codexAppURL: URL
    ) async throws -> CodexOpenOutcome {
        try await open(configuration: IsolatedCodexLaunchConfiguration(profile: profile, codexAppURL: codexAppURL))
    }

    public func openStock(
        codexAppURL: URL,
        codexHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true),
        configProfile: CodexConfigProfile? = nil
    ) async throws -> CodexOpenOutcome {
        try validator.validateCodexApp(at: codexAppURL)

        if let configProfile {
            try configProfile.validate(in: codexHomeURL)
        }

        if let processID = try stockStatus(codexAppURL: codexAppURL).primaryProcessID {
            guard lifecycleController.focusStock(
                processID: processID,
                codexAppURL: codexAppURL
            ) else {
                throw CodexLauncherError.couldNotFocus(processID)
            }
            return .focused(processID: processID)
        }

        try validator.validateCodexApp(at: codexAppURL)
        let processID = try await workspaceLauncher.launchStock(
            codexAppURL: codexAppURL,
            codexHomeURL: codexHomeURL,
            configProfile: configProfile
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: launchValidationTimeout)
        do {
            while clock.now < deadline {
                try Task.checkCancellation()
                if lifecycleController.isVerifiedStockRunning(
                    processID: processID,
                    codexAppURL: codexAppURL
                ) {
                    return .launched(processID: processID)
                }
                try await clock.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            if lifecycleController.isVerifiedStockRunning(
                processID: processID,
                codexAppURL: codexAppURL
            ) {
                return .launched(processID: processID)
            }
        } catch {
            lifecycleController.invalidateUnverifiedStockLaunch(
                processID: processID,
                codexAppURL: codexAppURL
            )
            throw error
        }
        lifecycleController.invalidateUnverifiedStockLaunch(
            processID: processID,
            codexAppURL: codexAppURL
        )
        throw CodexLauncherError.launchedProcessFailedValidation(processID)
    }

    public func closeStock(codexAppURL: URL) async throws -> CodexCloseOutcome {
        try validator.validateCodexApp(at: codexAppURL)
        let processIDs = try stockStatus(codexAppURL: codexAppURL).processIDs
        guard !processIDs.isEmpty else { return .alreadyStopped }
        for processID in processIDs {
            guard lifecycleController.terminateStock(
                processID: processID,
                codexAppURL: codexAppURL
            ) else {
                throw CodexLauncherError.couldNotTerminate(processID)
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: closeTimeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if try stockStatus(codexAppURL: codexAppURL).processIDs.isEmpty {
                return .closed(processIDs: processIDs)
            }
            try await clock.sleep(for: closePollInterval)
        }
        throw CodexLauncherError.closeTimedOut(
            try stockStatus(codexAppURL: codexAppURL).processIDs
        )
    }

    public func open(
        configuration: IsolatedCodexLaunchConfiguration
    ) async throws -> CodexOpenOutcome {
        guard configuration.resolvedProduct == .codex else {
            throw CodexLauncherError.invalidIsolationLayout(
                configuration.claudeUserDataURL?.deletingLastPathComponent().path
                    ?? configuration.codexHomeURL.deletingLastPathComponent().path
            )
        }
        try validator.validateCodexApp(at: configuration.codexAppURL)
        let operationLock = try await ProfileOperationLock.acquire(
            for: configuration.codexHomeURL.deletingLastPathComponent()
        )
        defer { withExtendedLifetime(operationLock) {} }
        try validateIsolationLayout(configuration)

        if let processID = try status(configuration: configuration).primaryProcessID {
            guard lifecycleController.focus(
                processID: processID,
                configuration: configuration
            ) else {
                throw CodexLauncherError.couldNotFocus(processID)
            }
            return .focused(processID: processID)
        }

        let orphanSnapshot = try processSnapshotProvider.processSnapshot()
        if !CodexInstanceDiscovery.profileProcessIDs(
            in: orphanSnapshot,
            configuration: configuration
        ).isEmpty {
            _ = try await closeProcesses(configuration: configuration)
        }
        try validateConfigProfile(configuration)
        try validateMCPConfiguration(configuration)
        try validator.validateCodexApp(at: configuration.codexAppURL)
        let processID = try await workspaceLauncher.launch(configuration: configuration)
        let isVerified: Bool
        do {
            isVerified = try await waitForVerifiedLaunch(
                processID: processID,
                configuration: configuration
            )
        } catch {
            lifecycleController.invalidateUnverifiedLaunch(
                processID: processID,
                configuration: configuration
            )
            throw error
        }
        guard isVerified else {
            lifecycleController.invalidateUnverifiedLaunch(
                processID: processID,
                configuration: configuration
            )
            throw CodexLauncherError.launchedProcessFailedValidation(processID)
        }
        let didPresentWindow: Bool
        do {
            if lifecycleController.requestPresentation(
                processID: processID,
                configuration: configuration
            ) {
                didPresentWindow = try await waitForPresentedWindow(processID: processID)
            } else {
                didPresentWindow = false
            }
        } catch {
            _ = lifecycleController.terminate(
                processID: processID,
                configuration: configuration
            )
            throw error
        }
        guard didPresentWindow else {
            _ = lifecycleController.terminate(
                processID: processID,
                configuration: configuration
            )
            throw CodexLauncherError.launchedProcessDidNotPresentWindow(processID)
        }
        return .launched(processID: processID)
    }

    public func close(
        profile: CodexProfile,
        codexAppURL: URL
    ) async throws -> CodexCloseOutcome {
        let configuration = IsolatedCodexLaunchConfiguration(profile: profile, codexAppURL: codexAppURL)
        let operationLock = try await ProfileOperationLock.acquire(
            for: configuration.codexHomeURL.deletingLastPathComponent()
        )
        defer { withExtendedLifetime(operationLock) {} }
        return try await closeProcesses(configuration: configuration)
    }

    private func closeProcesses(
        configuration: IsolatedCodexLaunchConfiguration
    ) async throws -> CodexCloseOutcome {
        let snapshot = try processSnapshotProvider.processSnapshot()
        let processIDs = CodexInstanceDiscovery.processIDs(
            in: snapshot,
            configuration: configuration
        )
        let processTree = try processTreeProvider.processTreeSnapshot()
        let descendants = SystemProcessTreeSnapshotProvider.descendants(
            of: Set(processIDs),
            in: processTree
        )
        var capturedProcesses = descendants.map { identity in
            var identity = identity
            identity.kernelStartKey = kernelStartKeyProvider(identity.processID)
            return identity
        }
        capturedProcesses.append(
            contentsOf: verifiedAuxiliaryProcesses(
                configuration: configuration,
                excluding: Set(processIDs),
                in: processTree
            )
        )
        capturedProcesses = Array(Set(capturedProcesses))
        guard !processIDs.isEmpty || !capturedProcesses.isEmpty else {
            return .alreadyStopped
        }

        for processID in processIDs {
            guard lifecycleController.terminate(
                processID: processID,
                configuration: configuration
            ) else {
                throw CodexLauncherError.couldNotTerminate(processID)
            }
        }
        capturedProcesses.append(
            contentsOf: verifiedAuxiliaryProcesses(
                configuration: configuration,
                excluding: Set(processIDs),
                in: try processTreeProvider.processTreeSnapshot()
            )
        )
        capturedProcesses = Array(Set(capturedProcesses))
        try processIdentitySignaler.signal(
            SIGTERM,
            identities: Array(capturedProcesses.reversed())
        )

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: closeTimeout)
        while clock.now < deadline {
            let (remaining, remainingDescendants) = try remainingProcesses(
                configuration: configuration,
                captured: capturedProcesses
            )
            if remaining.isEmpty, remainingDescendants.isEmpty {
                return .closed(processIDs: processIDs)
            }
            try await clock.sleep(for: closePollInterval)
        }

        var (remaining, remainingDescendants) = try remainingProcesses(
            configuration: configuration,
            captured: capturedProcesses
        )
        if !remainingDescendants.isEmpty {
            try processIdentitySignaler.signal(SIGKILL, identities: remainingDescendants)
            try await clock.sleep(for: .milliseconds(100))
            (remaining, remainingDescendants) = try remainingProcesses(
                configuration: configuration,
                captured: capturedProcesses
            )
        }
        guard remaining.isEmpty, remainingDescendants.isEmpty else {
            let allRemaining = Set(remaining + remainingDescendants.map(\.processID)).sorted()
            throw CodexLauncherError.closeTimedOut(allRemaining)
        }
        return .closed(processIDs: processIDs)
    }

    private func verifiedAuxiliaryProcesses(
        configuration: IsolatedCodexLaunchConfiguration,
        excluding processIDs: Set<Int32>,
        in processTree: [ProcessIdentity]
    ) -> [ProcessIdentity] {
        let processSnapshot = processTree.map {
            "\($0.processID) \($0.command)"
        }.joined(separator: "\n")
        var verifiedStartKeys: [Int32: String] = [:]
        for processID in CodexInstanceDiscovery.profileProcessIDs(
            in: processSnapshot,
            configuration: configuration
        ) where !processIDs.contains(processID) {
            guard let startKeyBeforeVerification = kernelStartKeyProvider(processID),
                  lifecycleController.isVerifiedProfileProcess(
                      processID: processID,
                      configuration: configuration,
                      processSnapshot: processSnapshot
                  ),
                  let startKeyAfterVerification = kernelStartKeyProvider(processID),
                  startKeyBeforeVerification == startKeyAfterVerification
            else {
                continue
            }
            verifiedStartKeys[processID] = startKeyAfterVerification
        }
        return processTree.compactMap { identity in
            guard let kernelStartKey = verifiedStartKeys[identity.processID] else {
                return nil
            }
            var identity = identity
            identity.kernelStartKey = kernelStartKey
            return identity
        }
    }

    public func validateCodexApp(at url: URL) throws {
        try validator.validateCodexApp(at: url)
    }

    private func status(
        configuration: IsolatedCodexLaunchConfiguration
    ) throws -> CodexInstanceStatus {
        let snapshot = try processSnapshotProvider.processSnapshot()
        return CodexInstanceStatus(
            processIDs: CodexInstanceDiscovery.processIDs(
                in: snapshot,
                configuration: configuration
            )
        )
    }

    private func waitForVerifiedLaunch(
        processID: Int32,
        configuration: IsolatedCodexLaunchConfiguration
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: launchValidationTimeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if lifecycleController.isVerifiedRunning(
                processID: processID,
                configuration: configuration
            ) {
                return true
            }
            try await clock.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        return lifecycleController.isVerifiedRunning(
            processID: processID,
            configuration: configuration
        )
    }

    private func waitForPresentedWindow(processID: Int32) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: windowPresentationTimeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if lifecycleController.isPresentingWindow(processID: processID) {
                return true
            }
            try await clock.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        return lifecycleController.isPresentingWindow(processID: processID)
    }

    private func remainingProcesses(
        configuration: IsolatedCodexLaunchConfiguration,
        captured: [ProcessIdentity]
    ) throws -> ([Int32], [ProcessIdentity]) {
        let current = try processTreeProvider.processTreeSnapshot()
        let currentByPID = Dictionary(uniqueKeysWithValues: current.map { ($0.processID, $0) })
        let commandSnapshot = current.map { "\($0.processID) \($0.command)" }
            .joined(separator: "\n")
        let mainProcessIDs = CodexInstanceDiscovery.processIDs(
            in: commandSnapshot,
            configuration: configuration
        )
        let auxiliaryProcessIDs = CodexInstanceDiscovery.profileProcessIDs(
            in: commandSnapshot,
            configuration: configuration
        ).filter {
            !mainProcessIDs.contains($0)
                && lifecycleController.isVerifiedProfileProcess(
                    processID: $0,
                    configuration: configuration,
                    processSnapshot: commandSnapshot
                )
        }
        let descendants = captured.filter { identity in
            guard let current = currentByPID[identity.processID] else { return false }
            return current.startKey == identity.startKey && current.command == identity.command
        }
        return (mainProcessIDs + auxiliaryProcessIDs, descendants)
    }

    private func validateIsolationLayout(
        _ configuration: IsolatedCodexLaunchConfiguration
    ) throws {
        let profileDirectory = configuration.codexHomeURL
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let electronParent = configuration.electronUserDataURL
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard configuration.codexHomeURL.lastPathComponent == "CODEX_HOME",
              configuration.electronUserDataURL.lastPathComponent == "ElectronUserData",
              profileDirectory == electronParent
        else {
            throw CodexLauncherError.invalidIsolationLayout(profileDirectory.path)
        }

        for directory in [configuration.codexHomeURL, configuration.electronUserDataURL] {
            let values = try? directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values?.isDirectory == true,
                  values?.isSymbolicLink != true,
                  directory.resolvingSymlinksInPath()
                    .deletingLastPathComponent().standardizedFileURL.path == profileDirectory.path
            else {
                throw CodexLauncherError.invalidIsolationLayout(profileDirectory.path)
            }
        }

        struct OwnershipMarker: Decodable {
            var profileID: UUID
            var product: DesktopProduct?
            var slug: String
        }
        let markerURL = profileDirectory.appendingPathComponent(".codexer-profile.json")
        guard let expectedID = configuration.profileID,
              let expectedSlug = configuration.profileSlug,
              let markerData = try? BoundedFileReader.data(
                  at: markerURL,
                  maximumBytes: LocalControlFileLimit.ownershipMarker
              ),
              let marker = try? JSONDecoder().decode(OwnershipMarker.self, from: markerData),
              marker.profileID == expectedID,
              marker.product == nil || marker.product == .codex,
              marker.slug == expectedSlug
        else {
            throw CodexLauncherError.invalidIsolationLayout(profileDirectory.path)
        }
    }

    private func validateMCPConfiguration(
        _ configuration: IsolatedCodexLaunchConfiguration
    ) throws {
        do {
            try CodexMCPConfiguration.validate(
                codexHomeURL: configuration.codexHomeURL,
                expectedCallbackPort: configuration.mcpOAuthCallbackPort
            )
            if validator is OfficialCodexAppValidator {
                try CodexMCPConfiguration.validateWithBundledCodex(
                    codexAppURL: configuration.codexAppURL,
                    codexHomeURL: configuration.codexHomeURL
                )
            }
        } catch {
            throw CodexLauncherError.invalidMCPConfiguration(
                configuration.codexHomeURL.appendingPathComponent("config.toml").path
            )
        }
    }

    private func validateConfigProfile(
        _ configuration: IsolatedCodexLaunchConfiguration
    ) throws {
        switch configuration.codexLaunchProfileSelection ?? .builtIn {
        case .builtIn, .useDefault:
            return
        case let .named(profile):
            do {
                try profile.validate(in: configuration.codexHomeURL)
            } catch {
                throw CodexLauncherError.invalidConfigProfile(
                    profile.configurationURL(in: configuration.codexHomeURL).path
                )
            }
        }
    }
}

public enum CodexLauncherError: Error, LocalizedError, Equatable {
    case codexAppMissing(String)
    case invalidCodexBundle(String)
    case invalidCodexSignature(String)
    case invalidIsolationLayout(String)
    case invalidMCPConfiguration(String)
    case invalidConfigProfile(String)
    case profileProxyMissing
    case processInspectionFailed(Int32)
    case processInspectionUnavailable
    case launchDidNotReturnProcess
    case launchedProcessFailedValidation(Int32)
    case launchedProcessDidNotPresentWindow(Int32)
    case couldNotFocus(Int32)
    case couldNotTerminate(Int32)
    case closeTimedOut([Int32])

    public var errorDescription: String? {
        switch self {
        case let .codexAppMissing(path):
            "Codex.app was not found at \(path)."
        case let .invalidCodexBundle(path):
            "\(path) does not have the official Codex bundle identifier."
        case let .invalidCodexSignature(path):
            "\(path) is not signed by OpenAI with the expected Developer ID."
        case let .invalidIsolationLayout(path):
            "The Codex profile at \(path) is missing or has an invalid isolation layout."
        case let .invalidMCPConfiguration(path):
            "The Codex profile has an invalid MCP OAuth configuration at \(path)."
        case let .invalidConfigProfile(path):
            "The selected Codex config profile is missing or unsafe at \(path)."
        case .profileProxyMissing:
            "AgentDock could not find its bundled Codex profile launcher."
        case let .processInspectionFailed(status):
            "AgentDock could not inspect running Codex instances (ps exited with status \(status))."
        case .processInspectionUnavailable:
            "AgentDock could not safely inspect running Codex instances."
        case .launchDidNotReturnProcess:
            "macOS did not return the process for the new Codex instance."
        case let .launchedProcessFailedValidation(processID):
            "The launched process \(processID) could not be verified as the selected signed app profile."
        case let .launchedProcessDidNotPresentWindow(processID):
            "Codex profile process \(processID) launched but did not present a window."
        case let .couldNotFocus(processID):
            "Codex profile process \(processID) is running but could not be focused."
        case let .couldNotTerminate(processID):
            "Codex profile process \(processID) could not be asked to quit."
        case let .closeTimedOut(processIDs):
            "Codex did not quit cleanly. Still running: \(processIDs.map(String.init).joined(separator: ", "))."
        }
    }
}

public enum CodexAppLocator {
    public static func defaultCodexAppURL(fileManager: FileManager = .default) -> URL? {
        let defaultURL = URL(fileURLWithPath: "/Applications/Codex.app")
        if fileManager.fileExists(atPath: defaultURL.path) {
            return defaultURL
        }
        return nil
    }
}
