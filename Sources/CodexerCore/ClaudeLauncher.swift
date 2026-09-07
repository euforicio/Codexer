import AppKit
import Darwin
import Foundation

public struct ClaudeProcessSnapshot: Sendable {
    public struct Entry: Equatable, Sendable {
        public let processID: Int32
        public let parentProcessID: Int32
        public let command: String
    }

    public let entries: [Int32: Entry]

    public init(entries: [Int32: Entry]) {
        self.entries = entries
    }

    public init(text: String) {
        var parsed: [Int32: Entry] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(
                maxSplits: 2,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 3,
                  let processID = Int32(fields[0]),
                  let parentProcessID = Int32(fields[1])
            else {
                continue
            }
            parsed[processID] = Entry(
                processID: processID,
                parentProcessID: parentProcessID,
                command: String(fields[2])
            )
        }
        entries = parsed
    }
}

public enum ClaudeInstanceDiscovery {
    public static func profileMainProcessIDs(
        in snapshot: ClaudeProcessSnapshot,
        appURL: URL,
        userDataURL: URL
    ) -> [Int32] {
        mainProcessIDs(in: snapshot, appURL: appURL, userDataURL: userDataURL)
    }

    public static func stockMainProcessIDs(
        in snapshot: ClaudeProcessSnapshot,
        appURL: URL,
        defaultUserDataURL: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Claude", isDirectory: true)
    ) -> [Int32] {
        mainProcessIDs(in: snapshot, appURL: appURL, userDataURL: defaultUserDataURL)
    }

    private static func mainProcessIDs(
        in snapshot: ClaudeProcessSnapshot,
        appURL: URL,
        userDataURL: URL
    ) -> [Int32] {
        let canonicalUserDataPath = canonical(userDataURL)
        return userDataPathsByMainProcess(in: snapshot, appURL: appURL)
            .compactMap { processID, paths in
                paths == [canonicalUserDataPath] ? processID : nil
            }.sorted()
    }

    static func userDataPathsByMainProcess(
        in snapshot: ClaudeProcessSnapshot,
        appURL: URL
    ) -> [Int32: Set<String>] {
        let contentsPrefix = appURL.standardizedFileURL
            .appendingPathComponent("Contents", isDirectory: true)
            .path + "/"
        let mainExecutable = DesktopAppRegistry.claude
            .executableURL(for: appURL)
            .standardizedFileURL
            .path

        var pathsByMainProcess: [Int32: Set<String>] = [:]
        for entry in snapshot.entries.values {
            guard entry.command.hasPrefix(contentsPrefix),
                  let mainProcessID = mainAncestor(
                      from: entry.processID,
                      snapshot: snapshot,
                      executablePath: mainExecutable
                  )
            else {
                continue
            }
            let paths = CodexInstanceDiscovery.userDataArguments(in: entry.command)
            for path in paths {
                pathsByMainProcess[mainProcessID, default: []].insert(
                    path.isEmpty ? "" : canonical(URL(fileURLWithPath: path, isDirectory: true))
                )
            }
        }
        return pathsByMainProcess
    }

    private static func mainAncestor(
        from processID: Int32,
        snapshot: ClaudeProcessSnapshot,
        executablePath: String
    ) -> Int32? {
        var current = processID
        var visited = Set<Int32>()
        while current > 0,
              visited.insert(current).inserted,
              let entry = snapshot.entries[current]
        {
            if entry.command == executablePath || entry.command.hasPrefix("\(executablePath) ") {
                return current
            }
            current = entry.parentProcessID
        }
        return nil
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

public struct SystemClaudeProcessSnapshotProvider: Sendable {
    public init() {}

    public func snapshot() throws -> ClaudeProcessSnapshot {
        let result = try BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-ax", "-o", "pid=,ppid=,command="],
            timeout: 3,
            maximumOutputBytes: 8 * 1_024 * 1_024
        )
        guard result.terminationStatus == 0, !result.exceededOutputLimit else {
            throw ClaudeLauncherError.processInspectionUnavailable
        }
        return ClaudeProcessSnapshot(text: String(decoding: result.output, as: UTF8.self))
    }
}

public actor ClaudeInstanceController {
    private let validator: OfficialDesktopAppValidator
    private let contractProbe: ClaudeDesktopContractProbe
    private let snapshotProvider: SystemClaudeProcessSnapshotProvider
    private let processTreeProvider: SystemProcessTreeSnapshotProvider
    private let processSignaler: SystemProcessIdentitySignaler

    static func launchEnvironment(
        inheriting inheritedEnvironment: [String: String],
        userDataPath: String?
    ) -> [String: String] {
        var environment = DesktopLaunchEnvironment.sanitized(inheritedEnvironment)
        environment["CLAUDE_USER_DATA_DIR"] = userDataPath
        return environment
    }

    static func validateLaunchedProcessID(
        _ processID: Int32,
        existingProcessIDs: Set<Int32>
    ) throws {
        guard processID > 0 else {
            throw ClaudeLauncherError.launchDidNotReturnProcess
        }
        guard !existingProcessIDs.contains(processID) else {
            throw ClaudeLauncherError.launchReturnedExistingProcess(processID)
        }
    }

    public init(
        validator: OfficialDesktopAppValidator = OfficialDesktopAppValidator(),
        contractProbe: ClaudeDesktopContractProbe = ClaudeDesktopContractProbe()
    ) {
        self.validator = validator
        self.contractProbe = contractProbe
        snapshotProvider = SystemClaudeProcessSnapshotProvider()
        processTreeProvider = SystemProcessTreeSnapshotProvider()
        processSignaler = SystemProcessIdentitySignaler()
    }

    public func validateClaudeApp(at appURL: URL) throws {
        try validator.validateApp(at: appURL, product: .claude)
        try contractProbe.validate(appURL: appURL)
    }

    public func statuses(
        for profiles: [CodexProfile],
        appURL: URL
    ) throws -> [CodexProfile.ID: CodexInstanceStatus] {
        try validateClaudeApp(at: appURL)
        let snapshot = try snapshotProvider.snapshot()
        return Dictionary(uniqueKeysWithValues: profiles.map { profile in
            let trustedProcessIDs = ClaudeInstanceDiscovery.profileMainProcessIDs(
                in: snapshot,
                appURL: appURL,
                userDataURL: profile.claudeUserDataPath
            ).filter {
                validator.isTrustedProcess(processID: $0, product: .claude)
            }
            return (
                profile.id,
                CodexInstanceStatus(
                    processIDs: trustedProcessIDs
                )
            )
        })
    }

    public func status(
        for profile: CodexProfile,
        appURL: URL
    ) throws -> CodexInstanceStatus {
        guard profile.product == .claude else {
            throw ClaudeLauncherError.wrongProduct
        }
        return try statuses(for: [profile], appURL: appURL)[profile.id]
            ?? CodexInstanceStatus()
    }

    public func stockStatus(appURL: URL) throws -> CodexInstanceStatus {
        try validateClaudeApp(at: appURL)
        let snapshot = try snapshotProvider.snapshot()
        return CodexInstanceStatus(
            processIDs: ClaudeInstanceDiscovery.stockMainProcessIDs(
                in: snapshot,
                appURL: appURL
            ).filter {
                validator.isTrustedProcess(processID: $0, product: .claude)
            }
        )
    }

    public func open(
        profile: CodexProfile,
        appURL: URL
    ) async throws -> CodexOpenOutcome {
        let operationLock = try await ProfileOperationLock.acquire(for: profile.profileDirectory)
        defer { withExtendedLifetime(operationLock) {} }
        try validateProfileLayout(profile)

        if let processID = try status(for: profile, appURL: appURL).primaryProcessID {
            guard activate(processID: processID) else {
                throw ClaudeLauncherError.couldNotFocus(processID)
            }
            return .focused(processID: processID)
        }

        try validateClaudeApp(at: appURL)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.createsNewApplicationInstance = true
        // Pin Chromium storage from process startup as well as the app's
        // JavaScript userData override.
        configuration.arguments = ["--user-data-dir=\(profile.claudeUserDataPath.path)"]
        configuration.environment = Self.launchEnvironment(
            inheriting: ProcessInfo.processInfo.environment,
            userDataPath: profile.claudeUserDataPath.path
        )

        let existingProcessIDs = Set(NSRunningApplication.runningApplications(
            withBundleIdentifier: DesktopAppRegistry.claude.bundleIdentifier
        ).map(\.processIdentifier))
        let application = try await NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: configuration
        )
        let processID = application.processIdentifier
        try Self.validateLaunchedProcessID(processID, existingProcessIDs: existingProcessIDs)
        // A launch response does not establish profile ownership. Leave an
        // unverified process running instead of risking another active profile.
        try await waitForLaunch(
            expectedProcessID: processID,
            status: { try self.status(for: profile, appURL: appURL) }
        )
        return .launched(processID: processID)
    }

    public func openStock(appURL: URL) async throws -> CodexOpenOutcome {
        if let processID = try stockStatus(appURL: appURL).primaryProcessID {
            guard activate(processID: processID) else {
                throw ClaudeLauncherError.couldNotFocus(processID)
            }
            return .focused(processID: processID)
        }

        try validateClaudeApp(at: appURL)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.createsNewApplicationInstance = true
        configuration.environment = Self.launchEnvironment(
            inheriting: ProcessInfo.processInfo.environment,
            userDataPath: nil
        )

        let existingProcessIDs = Set(NSRunningApplication.runningApplications(
            withBundleIdentifier: DesktopAppRegistry.claude.bundleIdentifier
        ).map(\.processIdentifier))
        let application = try await NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: configuration
        )
        let processID = application.processIdentifier
        try Self.validateLaunchedProcessID(processID, existingProcessIDs: existingProcessIDs)
        try await waitForLaunch(
            expectedProcessID: processID,
            status: { try self.stockStatus(appURL: appURL) }
        )
        return .launched(processID: processID)
    }

    public func close(
        profile: CodexProfile,
        appURL: URL
    ) async throws -> CodexCloseOutcome {
        let operationLock = try await ProfileOperationLock.acquire(for: profile.profileDirectory)
        defer { withExtendedLifetime(operationLock) {} }
        try validateProfileLayout(profile)
        let processIDs = try status(for: profile, appURL: appURL).processIDs
        guard !processIDs.isEmpty else { return .alreadyStopped }

        let tree = try processTreeProvider.processTreeSnapshot()
        let processIDSet = Set(processIDs)
        let roots = tree.filter { processIDSet.contains($0.processID) }
        let descendants = SystemProcessTreeSnapshotProvider.descendants(
            of: Set(processIDs),
            in: tree
        )
        let capturedProcesses = (roots + descendants).map { process in
            var process = process
            process.kernelStartKey = SystemProcessTreeSnapshotProvider.kernelStartKey(
                for: process.processID
            )
            return process
        }

        try processSignaler.signal(
            SIGTERM,
            identities: Array(capturedProcesses.reversed())
        )

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            try Task.checkCancellation()
            if try status(for: profile, appURL: appURL).processIDs.isEmpty,
               try remainingCapturedProcesses(capturedProcesses).isEmpty
            {
                return .closed(processIDs: processIDs)
            }
            try await clock.sleep(for: .milliseconds(100))
        }

        try processSignaler.signal(
            SIGKILL,
            identities: Array(capturedProcesses.reversed())
        )
        let killDeadline = clock.now.advanced(by: .seconds(2))
        while clock.now < killDeadline {
            try Task.checkCancellation()
            if try status(for: profile, appURL: appURL).processIDs.isEmpty,
               try remainingCapturedProcesses(capturedProcesses).isEmpty
            {
                return .closed(processIDs: processIDs)
            }
            try await clock.sleep(for: .milliseconds(100))
        }
        let remaining = try remainingCapturedProcesses(capturedProcesses)
            .map(\.processID)
        throw ClaudeLauncherError.closeTimedOut(
            Array(Set(processIDs + remaining)).sorted()
        )
    }

    private func waitForLaunch(
        expectedProcessID: Int32,
        status: () throws -> CodexInstanceStatus
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            try Task.checkCancellation()
            if try status().processIDs.contains(expectedProcessID) {
                return
            }
            try await clock.sleep(for: .milliseconds(100))
        }
        throw ClaudeLauncherError.launchedProcessFailedValidation(expectedProcessID)
    }

    private func activate(processID: Int32) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processID) else {
            return false
        }
        return application.activate(options: [.activateAllWindows])
    }

    private func remainingCapturedProcesses(
        _ captured: [ProcessIdentity]
    ) throws -> [ProcessIdentity] {
        let currentByPID = Dictionary(
            uniqueKeysWithValues: try processTreeProvider.processTreeSnapshot().map {
                ($0.processID, $0)
            }
        )
        return captured.filter { capturedProcess in
            guard let current = currentByPID[capturedProcess.processID],
                  current.startKey == capturedProcess.startKey,
                  current.command == capturedProcess.command
            else {
                return false
            }
            guard let kernelStartKey = capturedProcess.kernelStartKey else {
                return true
            }
            return SystemProcessTreeSnapshotProvider.kernelStartKey(
                for: capturedProcess.processID
            ) == kernelStartKey
        }
    }

    private func validateProfileLayout(_ profile: CodexProfile) throws {
        guard profile.product == .claude else {
            throw ClaudeLauncherError.wrongProduct
        }
        let profileDirectory = profile.profileDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let userDataValues = try? profile.claudeUserDataPath.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        struct OwnershipMarker: Decodable {
            let profileID: UUID
            let product: DesktopProduct
            let slug: String
        }
        let markerURL = profileDirectory.appendingPathComponent(".codexer-profile.json")
        guard userDataValues?.isDirectory == true,
              userDataValues?.isSymbolicLink != true,
              profile.claudeUserDataPath
                  .standardizedFileURL
                  .resolvingSymlinksInPath()
                  .deletingLastPathComponent() == profileDirectory,
              let markerData = try? BoundedFileReader.data(
                  at: markerURL,
                  maximumBytes: LocalControlFileLimit.ownershipMarker
              ),
              let marker = try? JSONDecoder().decode(OwnershipMarker.self, from: markerData),
              marker.profileID == profile.id,
              marker.product == .claude,
              marker.slug == profile.slug
        else {
            throw ClaudeLauncherError.invalidIsolationLayout(profile.profileDirectory.path)
        }
    }
}

public enum ClaudeLauncherError: Error, LocalizedError, Equatable {
    case wrongProduct
    case processInspectionUnavailable
    case invalidIsolationLayout(String)
    case launchDidNotReturnProcess
    case launchReturnedExistingProcess(Int32)
    case launchedProcessFailedValidation(Int32)
    case couldNotFocus(Int32)
    case couldNotTerminate(Int32)
    case closeTimedOut([Int32])

    public var errorDescription: String? {
        switch self {
        case .wrongProduct:
            "A Claude Desktop operation received a non-Claude profile."
        case .processInspectionUnavailable:
            "AgentDock could not inspect Claude Desktop processes safely."
        case let .invalidIsolationLayout(path):
            "The managed Claude profile at \(path) is missing its verified UserData layout."
        case .launchDidNotReturnProcess:
            "Claude Desktop launched without returning a process identifier."
        case .launchReturnedExistingProcess:
            "Claude Desktop returned an existing application instance. It was left running to protect its active profile."
        case let .launchedProcessFailedValidation(processID):
            "Claude Desktop process \(processID) did not adopt the selected managed profile."
        case let .couldNotFocus(processID):
            "Claude Desktop process \(processID) could not be focused."
        case let .couldNotTerminate(processID):
            "Claude Desktop process \(processID) refused to close."
        case let .closeTimedOut(processIDs):
            "Claude Desktop processes \(processIDs) did not close before the safety timeout."
        }
    }
}
