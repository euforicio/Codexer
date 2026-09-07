import Foundation
import ImageIO

public protocol ProfileUsageChecking {
    func isProfileInUse(_ profile: CodexProfile) -> Bool
}

public struct SystemProfileUsageChecker: ProfileUsageChecking {
    public init() {}

    public func isProfileInUse(_ profile: CodexProfile) -> Bool {
        do {
            let result = try BoundedSubprocess.run(
                executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
                arguments: ["-t", "+D", profile.profileDirectory.path],
                timeout: 10,
                maximumOutputBytes: 1_024 * 1_024,
                captureStandardError: true
            )
            guard !result.exceededOutputLimit else { return true }
            if result.terminationStatus == 0 {
                return true
            }
            if result.terminationStatus == 1, result.output.isEmpty {
                return hasProfileProcess(profile)
            }
            return true
        } catch {
            // Failing closed prevents destructive deletion when activity cannot be established.
            return true
        }
    }

    private func hasProfileProcess(_ profile: CodexProfile) -> Bool {
        do {
            let result = try BoundedSubprocess.run(
                executableURL: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-ax", "-o", "command="],
                timeout: 3,
                maximumOutputBytes: 8 * 1_024 * 1_024
            )
            guard result.terminationStatus == 0, !result.exceededOutputLimit else {
                return true
            }
            let rawPath = switch profile.product {
            case .codex: profile.electronUserDataPath.path
            case .claude: profile.claudeUserDataPath.path
            }
            let canonicalPath = CodexInstanceDiscovery.canonicalUserDataPath(rawPath)
            let aliases = Set([
                rawPath,
                canonicalPath,
                canonicalPath.replacingOccurrences(of: "/private/var/", with: "/var/")
            ])
            let snapshot = String(decoding: result.output, as: UTF8.self)
            return aliases.contains { snapshot.contains("--user-data-dir=\($0)") }
        } catch {
            return true
        }
    }
}

public final class ProfileStore: @unchecked Sendable {
    private let transactionLock = NSRecursiveLock()
    private let stateLock = NSLock()
    private var storedProfiles: [CodexProfile]
    private var publishedProfiles: [CodexProfile]
    public var profiles: [CodexProfile] {
        stateLock.withLock { publishedProfiles }
    }

    public let rootDirectory: URL
    public let shortcutDirectory: URL
    public var profilesRootDirectory: URL {
        rootDirectory.appendingPathComponent("Profiles", isDirectory: true)
    }

    public func profilesRootDirectory(for product: DesktopProduct) -> URL {
        product == .codex
            ? profilesRootDirectory
            : profilesRootDirectory.appendingPathComponent(product.rawValue, isDirectory: true)
    }

    public func shortcutDirectory(for product: DesktopProduct) -> URL {
        product == .codex
            ? shortcutDirectory
            : shortcutDirectory.appendingPathComponent(product.rawValue, isDirectory: true)
    }

    private let fileManager: FileManager
    private let codexAppURL: URL?
    private let operationLockTimeout: Duration
    private let profilesFile: URL
    private let usageChecker: any ProfileUsageChecking
    private var storeLockURL: URL {
        rootDirectory.appendingPathComponent(".profiles.lock")
    }
    private var restoreJournalURL: URL {
        rootDirectory.appendingPathComponent(".restore-profile-journal.json")
    }
    private var deletionJournalURL: URL {
        rootDirectory.appendingPathComponent(".delete-profile-journal.json")
    }

    public init(
        rootDirectory: URL = ProfileStore.defaultRootDirectory(),
        shortcutDirectory: URL = ProfileStore.defaultShortcutDirectory(),
        fileManager: FileManager = .default,
        codexAppURL: URL? = nil,
        usageChecker: any ProfileUsageChecking = SystemProfileUsageChecker(),
        operationLockTimeout: Duration = .seconds(10)
    ) throws {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.shortcutDirectory = shortcutDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.codexAppURL = codexAppURL
        self.usageChecker = usageChecker
        self.operationLockTimeout = operationLockTimeout
        self.profilesFile = self.rootDirectory.appendingPathComponent("profiles.json")
        self.storedProfiles = []
        self.publishedProfiles = []

        try fileManager.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: profilesRootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: self.shortcutDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: profilesRootDirectory(for: .claude),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: self.shortcutDirectory(for: .claude),
            withIntermediateDirectories: true
        )

        let storeLock = try AdvisoryFileLock.acquireSynchronously(
            at: storeLockURL,
            timeout: operationLockTimeout
        )
        defer { withExtendedLifetime(storeLock) {} }
        try loadProfilesUnlocked()
        publishProfiles()
    }

    public static func defaultRootDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let agentDock = support.appendingPathComponent("AgentDock", isDirectory: true)
        let legacy = support.appendingPathComponent("Codexer", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.appendingPathComponent("profiles.json").path),
           !FileManager.default.fileExists(atPath: agentDock.appendingPathComponent("profiles.json").path)
        {
            return legacy
        }
        return agentDock
    }

    public static func defaultShortcutDirectory() -> URL {
        let applications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let agentDock = applications.appendingPathComponent("AgentDock", isDirectory: true)
        let legacy = applications.appendingPathComponent("Codexer", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.path),
           !FileManager.default.fileExists(atPath: agentDock.path)
        {
            return legacy
        }
        return agentDock
    }

    @discardableResult
    public func createProfile(
        product: DesktopProduct = .codex,
        name: String,
        iconColor: String = "#2563EB",
        iconKind: ProfileIconKind = .monogram,
        iconValue: String = "",
        customIconData: Data? = nil
    ) throws -> CodexProfile {
        try withStoreTransaction {
            try createProfileUnlocked(
                product: product,
                name: name,
                iconColor: iconColor,
                iconKind: iconKind,
                iconValue: iconValue,
                customIconData: customIconData
            )
        }
    }

    @discardableResult
    private func createProfileUnlocked(
        product: DesktopProduct,
        name: String,
        iconColor: String,
        iconKind: ProfileIconKind,
        iconValue: String,
        customIconData: Data?
    ) throws -> CodexProfile {
        try Task.checkCancellation()
        let cleanName = try validatedName(name)
        let slug = uniqueSlug(from: cleanName, product: product)
        let callbackPort = product == .codex ? try allocateCallbackPort() : 0
        let profile = CodexProfile(
            product: product,
            name: cleanName,
            slug: slug,
            rootDirectory: rootDirectory,
            shortcutDirectory: shortcutDirectory,
            mcpOAuthCallbackPort: callbackPort,
            iconColor: iconColor,
            iconKind: iconKind,
            iconValue: iconValue
        )

        let previous = storedProfiles
        do {
            try createOwnedProfileDirectories(for: profile)
            try Task.checkCancellation()
            if let customIconData {
                guard
                    iconKind == .image,
                    Self.isValidCustomIconData(customIconData)
                else {
                    throw ProfileStoreError.invalidCustomIcon
                }
                try customIconData.write(to: profile.customIconPath, options: [.atomic])
            }
            try Task.checkCancellation()
            storedProfiles.append(profile)
            try saveUnlocked()
        } catch {
            storedProfiles = previous
            try? fileManager.removeItem(at: profile.profileDirectory)
            throw error
        }
        return profile
    }

    @discardableResult
    public func restoreProfile(
        product: DesktopProduct = .codex,
        name: String,
        profileDirectory: URL,
        iconColor: String = "#64748B"
    ) throws -> CodexProfile {
        try withStoreTransaction {
            switch product {
            case .codex:
                try restoreProfileUnlocked(
                    name: name,
                    profileDirectory: profileDirectory,
                    iconColor: iconColor
                )
            case .claude:
                try restoreClaudeProfileUnlocked(
                    name: name,
                    profileDirectory: profileDirectory,
                    iconColor: iconColor
                )
            }
        }
    }

    private func restoreClaudeProfileUnlocked(
        name: String,
        profileDirectory: URL,
        iconColor: String
    ) throws -> CodexProfile {
        let cleanName = try validatedName(name)
        let canonicalDirectory = canonical(profileDirectory)
        try validateRestorableDirectory(canonicalDirectory, product: .claude)
        let operationLock = try ProfileOperationLock.acquireSynchronously(
            for: canonicalDirectory,
            timeout: operationLockTimeout
        )
        defer { withExtendedLifetime(operationLock) {} }

        let slug = canonicalDirectory.lastPathComponent
        let profile = CodexProfile(
            id: try restoredProfileID(
                in: canonicalDirectory,
                product: .claude,
                slug: slug
            ),
            product: .claude,
            name: cleanName,
            slug: slug,
            profileDirectory: canonicalDirectory,
            shortcutDirectory: shortcutDirectory(for: .claude),
            iconColor: iconColor
        )
        try validateNoStorageOverlap(for: profile, against: storedProfiles)

        let previous = storedProfiles
        let markerURL = ownershipMarkerURL(for: profile)
        let priorMarker = try? BoundedFileReader.data(
            at: markerURL,
            maximumBytes: LocalControlFileLimit.ownershipMarker
        )
        let journal = RestoreJournal(
            profileID: profile.id,
            profileDirectory: profile.profileDirectory,
            priorMarker: priorMarker,
            priorConfig: nil,
            priorConfigExisted: nil,
            priorConfigPermissions: nil
        )
        try writeRestoreJournal(journal)
        do {
            try writeOwnershipMarker(for: profile, replacingLegacyMarker: true)
            storedProfiles.append(profile)
            try saveUnlocked()
        } catch {
            storedProfiles = previous
            try recoverRestoreJournal(journal, committedProfileIDs: Set(storedProfiles.map(\.id)))
            throw error
        }
        try? fileManager.removeItem(at: restoreJournalURL)
        return profile
    }

    @discardableResult
    private func restoreProfileUnlocked(
        name: String,
        profileDirectory: URL,
        iconColor: String
    ) throws -> CodexProfile {
        let cleanName = try validatedName(name)
        let canonicalDirectory = canonical(profileDirectory)
        try validateRestorableDirectory(canonicalDirectory)
        let operationLock = try ProfileOperationLock.acquireSynchronously(
            for: canonicalDirectory,
            timeout: operationLockTimeout
        )
        defer { withExtendedLifetime(operationLock) {} }

        let codexHome = canonicalDirectory.appendingPathComponent("CODEX_HOME")
        let reservedPorts = try reservedCallbackPorts(
            excludingProfileDirectory: canonicalDirectory
        )
        let configuredPort = try CodexMCPConfiguration.existingCallbackPort(
            codexHomeURL: codexHome,
            fileManager: fileManager
        )
        let isManaged = try CodexMCPConfiguration.isManaged(
            codexHomeURL: codexHome,
            fileManager: fileManager
        )
        let callbackPort: Int
        if isManaged {
            try CodexMCPConfiguration.validate(
                codexHomeURL: codexHome,
                fileManager: fileManager
            )
            if let codexAppURL {
                try CodexMCPConfiguration.validateWithBundledCodex(
                    codexAppURL: codexAppURL,
                    codexHomeURL: codexHome
                )
            }
            guard let configuredPort else {
                throw ProfileStoreError.invalidMCPCallbackPort(0)
            }
            guard !reservedPorts.contains(configuredPort) else {
                throw ProfileStoreError.duplicateMCPCallbackPort(configuredPort)
            }
            callbackPort = configuredPort
        } else if let configuredPort,
                  CodexMCPConfiguration.managedCallbackPorts.contains(configuredPort),
                  !reservedPorts.contains(configuredPort)
        {
            callbackPort = configuredPort
        } else {
            callbackPort = try allocateCallbackPort(
                excluding: reservedPorts,
                excludingProfileDirectory: canonicalDirectory
            )
        }
        let slug = canonicalDirectory.lastPathComponent
        let profile = CodexProfile(
            id: try restoredProfileID(
                in: canonicalDirectory,
                product: .codex,
                slug: slug
            ),
            name: cleanName,
            slug: slug,
            profileDirectory: canonicalDirectory,
            shortcutDirectory: shortcutDirectory,
            mcpOAuthCallbackPort: callbackPort,
            iconColor: iconColor
        )
        try validateNoStorageOverlap(for: profile, against: storedProfiles)

        let previous = storedProfiles
        let markerURL = ownershipMarkerURL(for: profile)
        let priorMarker = try? BoundedFileReader.data(
            at: markerURL,
            maximumBytes: LocalControlFileLimit.ownershipMarker
        )
        let configURL = profile.codexHomePath.appendingPathComponent("config.toml")
        let priorConfigExisted = fileManager.fileExists(atPath: configURL.path)
        let priorConfig = priorConfigExisted
            ? try BoundedFileReader.data(
                at: configURL,
                maximumBytes: LocalControlFileLimit.providerConfiguration
            )
            : nil
        let priorConfigPermissions = priorConfigExisted
            ? (try fileManager.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber)?.uint16Value
            : nil
        let journal = RestoreJournal(
            profileID: profile.id,
            profileDirectory: profile.profileDirectory,
            priorMarker: priorMarker,
            priorConfig: priorConfig,
            priorConfigExisted: priorConfigExisted,
            priorConfigPermissions: priorConfigPermissions
        )
        try writeRestoreJournal(journal)
        do {
            if !isManaged {
                try CodexMCPConfiguration.configure(
                    codexHomeURL: profile.codexHomePath,
                    callbackPort: profile.mcpOAuthCallbackPort,
                    codexAppURL: codexAppURL,
                    fileManager: fileManager
                )
            }
            try writeOwnershipMarker(for: profile, replacingLegacyMarker: true)
            storedProfiles.append(profile)
            try saveUnlocked()
        } catch {
            storedProfiles = previous
            try recoverRestoreJournal(journal, committedProfileIDs: Set(storedProfiles.map(\.id)))
            throw error
        }
        try? fileManager.removeItem(at: restoreJournalURL)
        return profile
    }

    @discardableResult
    public func renameProfile(id: UUID, name: String) throws -> CodexProfile {
        try updateProfile(
            id: id,
            name: name,
            iconColor: nil,
            iconKind: nil,
            iconValue: nil,
            customIconData: nil
        )
    }

    @discardableResult
    public func updateProfile(
        id: UUID,
        name: String,
        iconColor: String?,
        iconKind: ProfileIconKind?,
        iconValue: String?,
        customIconData: Data?
    ) throws -> CodexProfile {
        try withStoreTransaction {
            try updateProfileUnlocked(
                id: id,
                name: name,
                iconColor: iconColor,
                iconKind: iconKind,
                iconValue: iconValue,
                customIconData: customIconData
            )
        }
    }

    @discardableResult
    private func updateProfileUnlocked(
        id: UUID,
        name: String,
        iconColor: String?,
        iconKind: ProfileIconKind?,
        iconValue: String?,
        customIconData: Data?
    ) throws -> CodexProfile {
        let cleanName = try validatedName(name)
        guard let index = storedProfiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError.profileNotFound
        }
        let previous = storedProfiles[index]
        storedProfiles[index].name = cleanName
        if let iconColor {
            storedProfiles[index].iconColor = iconColor
        }
        if let iconKind {
            storedProfiles[index].iconKind = iconKind
        }
        if let iconValue {
            storedProfiles[index].iconValue = iconValue
        }

        let iconURL = storedProfiles[index].customIconPath
        let priorIconData = try? BoundedFileReader.data(
            at: iconURL,
            maximumBytes: LocalControlFileLimit.customIcon
        )
        do {
            if let customIconData {
                guard
                    Self.isValidCustomIconData(customIconData)
                else {
                    throw ProfileStoreError.invalidCustomIcon
                }
                try customIconData.write(to: iconURL, options: [.atomic])
            } else if storedProfiles[index].iconKind != .image {
                try? fileManager.removeItem(at: iconURL)
            }
            try saveUnlocked()
        } catch {
            storedProfiles[index] = previous
            if let priorIconData {
                try? priorIconData.write(to: iconURL, options: [.atomic])
            } else {
                try? fileManager.removeItem(at: iconURL)
            }
            throw error
        }
        return storedProfiles[index]
    }

    public func markLaunched(id: UUID, at date: Date = Date()) throws {
        try withStoreTransaction {
            try markLaunchedUnlocked(id: id, at: date)
        }
    }

    @discardableResult
    public func setCodexLaunchProfileSelection(
        id: UUID,
        selection: CodexLaunchProfileSelection
    ) throws -> CodexProfile {
        try withStoreTransaction {
            guard let index = storedProfiles.firstIndex(where: { $0.id == id }) else {
                throw ProfileStoreError.profileNotFound
            }
            guard storedProfiles[index].product == .codex else {
                return storedProfiles[index]
            }
            let previous = storedProfiles[index].codexLaunchProfileSelection
            storedProfiles[index].codexLaunchProfileSelection = selection
            do {
                try saveUnlocked()
            } catch {
                storedProfiles[index].codexLaunchProfileSelection = previous
                throw error
            }
            return storedProfiles[index]
        }
    }

    @discardableResult
    public func setCodexDefaultConfigProfile(
        id: UUID,
        configProfile: CodexConfigProfile?
    ) throws -> CodexProfile {
        try withStoreTransaction {
            guard let index = storedProfiles.firstIndex(where: { $0.id == id }) else {
                throw ProfileStoreError.profileNotFound
            }
            guard storedProfiles[index].product == .codex else {
                return storedProfiles[index]
            }
            let previous = storedProfiles[index].codexDefaultConfigProfile
            storedProfiles[index].codexDefaultConfigProfile = configProfile
            do {
                try saveUnlocked()
            } catch {
                storedProfiles[index].codexDefaultConfigProfile = previous
                throw error
            }
            return storedProfiles[index]
        }
    }

    public func reorderProfiles(
        product: DesktopProduct,
        orderedIDs: [CodexProfile.ID]
    ) throws {
        try withStoreTransaction {
            try reorderProfilesUnlocked(product: product, orderedIDs: orderedIDs)
        }
    }

    private func reorderProfilesUnlocked(
        product: DesktopProduct,
        orderedIDs: [CodexProfile.ID]
    ) throws {
        let currentProfiles = storedProfiles.filter { $0.product == product }
        let currentIDs = currentProfiles.map(\.id)
        guard orderedIDs.count == currentIDs.count,
              Set(orderedIDs).count == orderedIDs.count,
              Set(orderedIDs) == Set(currentIDs)
        else {
            throw ProfileStoreError.invalidProfileOrder
        }
        guard orderedIDs != currentIDs else { return }

        let previous = storedProfiles
        let profilesByID = Dictionary(uniqueKeysWithValues: currentProfiles.map { ($0.id, $0) })
        var orderedIterator = orderedIDs.makeIterator()
        for index in storedProfiles.indices where storedProfiles[index].product == product {
            guard let id = orderedIterator.next(), let profile = profilesByID[id] else {
                storedProfiles = previous
                throw ProfileStoreError.invalidProfileOrder
            }
            storedProfiles[index] = profile
        }
        do {
            try saveUnlocked()
        } catch {
            storedProfiles = previous
            throw error
        }
    }

    private func markLaunchedUnlocked(id: UUID, at date: Date) throws {
        guard let index = storedProfiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError.profileNotFound
        }
        let previous = storedProfiles[index].lastLaunchedAt
        storedProfiles[index].lastLaunchedAt = date
        do {
            try saveUnlocked()
        } catch {
            storedProfiles[index].lastLaunchedAt = previous
            throw error
        }
    }

    public func removeProfile(id: UUID, policy: ProfileRemovalPolicy) throws {
        try withStoreTransaction {
            try removeProfileUnlocked(id: id, policy: policy)
        }
    }

    private func removeProfileUnlocked(id: UUID, policy: ProfileRemovalPolicy) throws {
        guard let index = storedProfiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError.profileNotFound
        }
        let profile = storedProfiles[index]

        switch policy {
        case .removeFromList:
            let previous = storedProfiles
            storedProfiles.remove(at: index)
            do {
                try saveUnlocked()
            } catch {
                storedProfiles = previous
                throw error
            }
        case .deleteAllData:
            try deleteAllData(for: profile, at: index)
        }
    }

    public func reload() throws {
        try transactionLock.withLock {
            let storeLock = try AdvisoryFileLock.acquireSynchronously(
                at: storeLockURL,
                timeout: operationLockTimeout
            )
            defer { withExtendedLifetime(storeLock) {} }
            try loadProfilesUnlocked()
            publishProfiles()
        }
    }

    private func saveUnlocked() throws {
        let data = try JSONEncoder.codexer.encode(storedProfiles)
        let temporaryURL = profilesFile
            .deletingLastPathComponent()
            .appendingPathComponent(".profiles.json.\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: profilesFile.path) {
            _ = try fileManager.replaceItemAt(profilesFile, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: profilesFile)
        }
    }

    private func withStoreTransaction<T>(_ operation: () throws -> T) throws -> T {
        try transactionLock.withLock {
            let storeLock = try AdvisoryFileLock.acquireSynchronously(
                at: storeLockURL,
                timeout: operationLockTimeout
            )
            defer { withExtendedLifetime(storeLock) {} }
            try loadProfilesUnlocked()
            defer { publishProfiles() }
            return try operation()
        }
    }

    private func publishProfiles() {
        let snapshot = storedProfiles
        stateLock.withLock {
            publishedProfiles = snapshot
        }
    }

    private func loadProfilesUnlocked() throws {
        if fileManager.fileExists(atPath: profilesFile.path) {
            let data = try BoundedFileReader.data(
                at: profilesFile,
                maximumBytes: LocalControlFileLimit.profiles
            )
            storedProfiles = try JSONDecoder.codexer.decode([CodexProfile].self, from: data)
        } else {
            storedProfiles = []
        }
        try recoverPendingRestoreIfNeeded()
        try recoverPendingDeletionIfNeeded()
        try validatePersistedProfilesAndMigrateOwnership()
    }

    private func createOwnedProfileDirectories(for profile: CodexProfile) throws {
        try validateManagedDirectory(profile.profileDirectory, product: profile.product)
        guard !fileManager.fileExists(atPath: profile.profileDirectory.path) else {
            throw ProfileStoreError.profileDirectoryAlreadyExists(profile.profileDirectory.path)
        }
        do {
            switch profile.product {
            case .codex:
                try fileManager.createDirectory(at: profile.codexHomePath, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: profile.electronUserDataPath, withIntermediateDirectories: true)
                try CodexMCPConfiguration.configure(
                    codexHomeURL: profile.codexHomePath,
                    callbackPort: profile.mcpOAuthCallbackPort,
                    codexAppURL: codexAppURL,
                    fileManager: fileManager
                )
            case .claude:
                try fileManager.createDirectory(
                    at: profile.claudeUserDataPath,
                    withIntermediateDirectories: true
                )
            }
            try writeOwnershipMarker(for: profile, replacingLegacyMarker: false)
        } catch {
            try? fileManager.removeItem(at: profile.profileDirectory)
            throw error
        }
    }

    private func validatePersistedProfilesAndMigrateOwnership() throws {
        var ids = Set<UUID>()
        var directories = Set<String>()
        var shortcuts = Set<String>()
        var configuredPortsByDirectory = try configuredCallbackPortsByDirectory()
        var portUseCounts = configuredPortsByDirectory.values.reduce(into: [Int: Int]()) {
            $0[$1, default: 0] += 1
        }
        var reservedPorts = Set(portUseCounts.keys)

        for index in storedProfiles.indices {
            var profile = storedProfiles[index]
            guard ids.insert(profile.id).inserted else {
                throw ProfileStoreError.duplicateProfileID(profile.id)
            }
            try validateManagedDirectory(profile.profileDirectory, product: profile.product)
            guard profile.profileDirectory.lastPathComponent == profile.slug else {
                throw ProfileStoreError.invalidProfileLayout(profile.profileDirectory.path)
            }
            guard directories.insert(canonical(profile.profileDirectory).path).inserted else {
                throw ProfileStoreError.overlappingProfileDirectory(profile.profileDirectory.path)
            }
            let expectedShortcutDirectory = canonical(shortcutDirectory(for: profile.product))
            let shortcutPath = canonical(profile.shortcutPath)
            guard canonical(profile.shortcutDirectory).path
                    == expectedShortcutDirectory.path
            else {
                throw ProfileStoreError.invalidShortcutDirectory(profile.shortcutDirectory.path)
            }
            guard profile.shortcutFileName == URL(fileURLWithPath: profile.shortcutFileName).lastPathComponent,
                  !profile.shortcutFileName.isEmpty,
                  profile.shortcutPath.pathExtension.lowercased() == "app",
                  slugify(profile.shortcutPath.deletingPathExtension().lastPathComponent)
                    == slugify(profile.slug),
                  shortcutPath.deletingLastPathComponent().path
                    == expectedShortcutDirectory.path,
                  shortcuts.insert(shortcutPath.path).inserted
            else {
                throw ProfileStoreError.invalidShortcutDirectory(profile.shortcutPath.path)
            }
            try validateProfileLayout(profile.profileDirectory, product: profile.product)
            let operationLock = try ProfileOperationLock.acquireSynchronously(
                for: profile.profileDirectory,
                timeout: operationLockTimeout
            )
            defer { withExtendedLifetime(operationLock) {} }
            if profile.product == .claude {
                profile.mcpOAuthCallbackPort = 0
                storedProfiles[index] = profile
                try writeOwnershipMarker(for: profile, replacingLegacyMarker: false)
                continue
            }
            let profileDirectoryPath = canonical(profile.profileDirectory).path
            if let previouslyConfiguredPort = configuredPortsByDirectory[profileDirectoryPath],
               let count = portUseCounts[previouslyConfiguredPort]
            {
                if count == 1 {
                    portUseCounts.removeValue(forKey: previouslyConfiguredPort)
                    reservedPorts.remove(previouslyConfiguredPort)
                } else {
                    portUseCounts[previouslyConfiguredPort] = count - 1
                }
            }
            let isManaged = try CodexMCPConfiguration.isManaged(
                codexHomeURL: profile.codexHomePath,
                fileManager: fileManager
            )
            let existing = try CodexMCPConfiguration.existingCallbackPort(
                codexHomeURL: profile.codexHomePath,
                fileManager: fileManager
            )
            if isManaged {
                try CodexMCPConfiguration.validate(
                    codexHomeURL: profile.codexHomePath,
                    fileManager: fileManager
                )
                if let codexAppURL {
                    try CodexMCPConfiguration.validateWithBundledCodex(
                        codexAppURL: codexAppURL,
                        codexHomeURL: profile.codexHomePath
                    )
                }
                guard let existing else {
                    throw ProfileStoreError.invalidMCPCallbackPort(0)
                }
                guard !reservedPorts.contains(existing) else {
                    throw ProfileStoreError.duplicateMCPCallbackPort(existing)
                }
                profile.mcpOAuthCallbackPort = existing
            } else {
                if let existing,
                   CodexMCPConfiguration.managedCallbackPorts.contains(existing),
                   !reservedPorts.contains(existing)
                {
                    profile.mcpOAuthCallbackPort = existing
                } else {
                    profile.mcpOAuthCallbackPort = try firstAvailableCallbackPort(
                        excluding: reservedPorts
                    )
                }
                try CodexMCPConfiguration.configure(
                    codexHomeURL: profile.codexHomePath,
                    callbackPort: profile.mcpOAuthCallbackPort,
                    codexAppURL: codexAppURL,
                    fileManager: fileManager
                )
            }
            configuredPortsByDirectory[profileDirectoryPath] = profile.mcpOAuthCallbackPort
            portUseCounts[profile.mcpOAuthCallbackPort, default: 0] += 1
            reservedPorts.insert(profile.mcpOAuthCallbackPort)
            storedProfiles[index] = profile
            try writeOwnershipMarker(for: profile, replacingLegacyMarker: false)
        }
    }

    private func allocateCallbackPort(
        excluding additionalPorts: Set<Int> = [],
        excludingProfileDirectory: URL? = nil
    ) throws -> Int {
        let used = try reservedCallbackPorts(
            excludingProfileDirectory: excludingProfileDirectory
        ).union(additionalPorts)
        return try firstAvailableCallbackPort(excluding: used)
    }

    private func firstAvailableCallbackPort(
        excluding used: Set<Int>
    ) throws -> Int {
        guard let port = CodexMCPConfiguration.managedCallbackPorts.first(where: {
            !used.contains($0) && CodexMCPConfiguration.isAvailableForBinding($0)
        }) else {
            throw ProfileStoreError.noAvailableMCPCallbackPort
        }
        return port
    }

    private func reservedCallbackPorts(
        excludingProfileDirectory: URL? = nil
    ) throws -> Set<Int> {
        let excludedPath = excludingProfileDirectory.map { canonical($0).path }
        return Set(
            try configuredCallbackPortsByDirectory()
                .filter { $0.key != excludedPath }
                .map(\.value)
        )
    }

    private func configuredCallbackPortsByDirectory() throws -> [String: Int] {
        let profileDirectories = try fileManager.contentsOfDirectory(
            at: profilesRootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var portsByDirectory = [String: Int]()
        for directory in profileDirectories {
            let values = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                continue
            }
            if let port = try CodexMCPConfiguration.existingCallbackPort(
                codexHomeURL: directory.appendingPathComponent("CODEX_HOME"),
                fileManager: fileManager
            ) {
                portsByDirectory[canonical(directory).path] = port
            }
        }
        return portsByDirectory
    }

    private func validateRestorableDirectory(
        _ directory: URL,
        product: DesktopProduct = .codex
    ) throws {
        try validateManagedDirectory(directory, product: product)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ProfileStoreError.invalidProfileLayout(directory.path)
        }
        try validateProfileLayout(directory, product: product)
    }

    private func validateProfileLayout(
        _ directory: URL,
        product: DesktopProduct = .codex
    ) throws {
        let canonicalDirectory = canonical(directory)
        let requiredChildren = switch product {
        case .codex: ["CODEX_HOME", "ElectronUserData"]
        case .claude: ["UserData"]
        }
        for name in requiredChildren {
            let child = directory.appendingPathComponent(name, isDirectory: true)
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true,
                  values?.isSymbolicLink != true,
                  canonical(child).deletingLastPathComponent().path == canonicalDirectory.path
            else {
                throw ProfileStoreError.invalidProfileLayout(directory.path)
            }
        }
    }

    private func validateManagedDirectory(
        _ directory: URL,
        product: DesktopProduct = .codex
    ) throws {
        let canonicalDirectory = canonical(directory)
        let canonicalRoot = canonical(profilesRootDirectory(for: product))
        guard canonicalDirectory.deletingLastPathComponent().path == canonicalRoot.path,
              !DesktopProduct.allCases.contains(where: {
                  canonical(profilesRootDirectory(for: $0)).path == canonicalDirectory.path
              })
        else {
            throw ProfileStoreError.unmanagedProfileDirectory(directory.path)
        }
    }

    private func validateNoStorageOverlap(for profile: CodexProfile, against others: [CodexProfile]) throws {
        let candidate = canonical(profile.profileDirectory)
        let existingDirectories = Set(others.map { canonical($0.profileDirectory).path })
        guard !existingDirectories.contains(candidate.path),
              !others.contains(where: {
                  $0.product == profile.product && $0.slug == profile.slug
              })
        else {
            throw ProfileStoreError.overlappingProfileDirectory(candidate.path)
        }
        guard !others.contains(where: { $0.id == profile.id }) else {
            throw ProfileStoreError.duplicateProfileID(profile.id)
        }
    }

    private func deleteAllData(for profile: CodexProfile, at index: Int) throws {
        try validateManagedDirectory(profile.profileDirectory, product: profile.product)
        try validateOwnershipMarker(for: profile)
        let operationLock = try ProfileOperationLock.acquireSynchronously(
            for: profile.profileDirectory,
            timeout: operationLockTimeout
        )
        defer { withExtendedLifetime(operationLock) {} }
        guard !usageChecker.isProfileInUse(profile) else {
            throw ProfileStoreError.profileInUse(profile.name)
        }

        let moves = try quarantineExistingItems(
            [profile.shortcutPath, profile.profileDirectory],
            profileID: profile.id
        )
        let previous = storedProfiles
        storedProfiles.remove(at: index)

        do {
            try saveUnlocked()
        } catch {
            storedProfiles = previous
            do {
                try rollbackQuarantine(moves)
                try? fileManager.removeItem(at: deletionJournalURL)
            } catch {
                throw error
            }
            throw error
        }

        var residualPaths: [String] = []
        for move in moves {
            do {
                try fileManager.removeItem(at: move.quarantine)
            } catch {
                residualPaths.append(move.quarantine.path)
            }
        }
        if !residualPaths.isEmpty {
            throw ProfileStoreError.deletionCleanupIncomplete(residualPaths)
        }
        try? fileManager.removeItem(at: deletionJournalURL)
    }

    private struct QuarantineMove: Codable {
        var original: URL
        var quarantine: URL
    }

    private struct DeletionJournal: Codable {
        var profileID: UUID
        var moves: [QuarantineMove]
    }

    private func quarantineExistingItems(
        _ urls: [URL],
        profileID: UUID
    ) throws -> [QuarantineMove] {
        let moves = urls.compactMap { url -> QuarantineMove? in
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return QuarantineMove(
                original: url,
                quarantine: url.deletingLastPathComponent()
                    .appendingPathComponent(".codexer-deleting-\(UUID().uuidString)-\(url.lastPathComponent)")
            )
        }
        try JSONEncoder.codexer.encode(
            DeletionJournal(profileID: profileID, moves: moves)
        ).write(to: deletionJournalURL, options: .atomic)

        var completedMoves: [QuarantineMove] = []
        do {
            for move in moves {
                try fileManager.moveItem(at: move.original, to: move.quarantine)
                completedMoves.append(move)
            }
            return moves
        } catch {
            try rollbackQuarantine(completedMoves)
            try? fileManager.removeItem(at: deletionJournalURL)
            throw error
        }
    }

    private func rollbackQuarantine(_ moves: [QuarantineMove]) throws {
        var residualPaths: [String] = []
        for move in moves.reversed() where fileManager.fileExists(atPath: move.quarantine.path) {
            do {
                guard !fileManager.fileExists(atPath: move.original.path) else {
                    residualPaths.append(move.quarantine.path)
                    continue
                }
                try fileManager.moveItem(at: move.quarantine, to: move.original)
            } catch {
                residualPaths.append(move.quarantine.path)
            }
        }
        if !residualPaths.isEmpty {
            throw ProfileStoreError.deletionRollbackIncomplete(residualPaths)
        }
    }

    private struct OwnershipMarker: Codable {
        var profileID: UUID
        var product: DesktopProduct?
        var slug: String
    }

    private struct RestoreJournal: Codable {
        var profileID: UUID
        var profileDirectory: URL
        var priorMarker: Data?
        var priorConfig: Data?
        var priorConfigExisted: Bool?
        var priorConfigPermissions: UInt16?
    }

    private func restoredProfileID(
        in profileDirectory: URL,
        product: DesktopProduct,
        slug: String
    ) throws -> UUID {
        let markerURL = profileDirectory.appendingPathComponent(".codexer-profile.json")
        guard fileManager.fileExists(atPath: markerURL.path) else {
            return UUID()
        }
        guard let data = try? BoundedFileReader.data(
                  at: markerURL,
                  maximumBytes: LocalControlFileLimit.ownershipMarker
              ),
              let marker = try? JSONDecoder().decode(OwnershipMarker.self, from: data),
              marker.product == product || (marker.product == nil && product == .codex),
              marker.slug == slug
        else {
            throw ProfileStoreError.invalidOwnershipMarker(profileDirectory.path)
        }
        return marker.profileID
    }

    private func ownershipMarkerURL(for profile: CodexProfile) -> URL {
        profile.profileDirectory.appendingPathComponent(".codexer-profile.json")
    }

    private func writeOwnershipMarker(for profile: CodexProfile, replacingLegacyMarker: Bool) throws {
        let markerURL = ownershipMarkerURL(for: profile)
        if fileManager.fileExists(atPath: markerURL.path), !replacingLegacyMarker {
            try validateOwnershipMarker(for: profile)
            return
        }
        let marker = OwnershipMarker(
            profileID: profile.id,
            product: profile.product,
            slug: profile.slug
        )
        let data = try JSONEncoder().encode(marker)
        try data.write(to: markerURL, options: .atomic)
    }

    private func validateOwnershipMarker(for profile: CodexProfile) throws {
        let markerURL = ownershipMarkerURL(for: profile)
        guard let data = try? BoundedFileReader.data(
                  at: markerURL,
                  maximumBytes: LocalControlFileLimit.ownershipMarker
              ),
              let marker = try? JSONDecoder().decode(OwnershipMarker.self, from: data),
              marker.profileID == profile.id,
              marker.product == profile.product
                || (marker.product == nil && profile.product == .codex),
              marker.slug == profile.slug
        else {
            throw ProfileStoreError.invalidOwnershipMarker(profile.profileDirectory.path)
        }
    }

    private func writeRestoreJournal(_ journal: RestoreJournal) throws {
        let data = try JSONEncoder.codexer.encode(journal)
        try data.write(to: restoreJournalURL, options: .atomic)
    }

    private func recoverPendingRestoreIfNeeded() throws {
        guard fileManager.fileExists(atPath: restoreJournalURL.path) else { return }
        let data = try BoundedFileReader.data(
            at: restoreJournalURL,
            maximumBytes: LocalControlFileLimit.journal
        )
        let journal = try JSONDecoder.codexer.decode(RestoreJournal.self, from: data)
        try recoverRestoreJournal(journal, committedProfileIDs: Set(storedProfiles.map(\.id)))
    }

    private func recoverPendingDeletionIfNeeded() throws {
        guard fileManager.fileExists(atPath: deletionJournalURL.path) else { return }
        let data = try BoundedFileReader.data(
            at: deletionJournalURL,
            maximumBytes: LocalControlFileLimit.journal
        )
        let journal = try JSONDecoder.codexer.decode(DeletionJournal.self, from: data)
        try validateDeletionJournal(journal)
        if storedProfiles.contains(where: { $0.id == journal.profileID }) {
            try rollbackQuarantine(journal.moves)
        } else {
            var residualPaths: [String] = []
            for move in journal.moves where fileManager.fileExists(atPath: move.quarantine.path) {
                do {
                    try fileManager.removeItem(at: move.quarantine)
                } catch {
                    residualPaths.append(move.quarantine.path)
                }
            }
            if !residualPaths.isEmpty {
                throw ProfileStoreError.deletionCleanupIncomplete(residualPaths)
            }
        }
        try fileManager.removeItem(at: deletionJournalURL)
    }

    private func recoverRestoreJournal(
        _ journal: RestoreJournal,
        committedProfileIDs: Set<UUID>
    ) throws {
        try validateAnyManagedDirectory(journal.profileDirectory)
        if let owner = storedProfiles.first(where: {
            canonical($0.profileDirectory).path == canonical(journal.profileDirectory).path
        }), owner.id != journal.profileID {
            throw ProfileStoreError.invalidRecoveryJournal(journal.profileDirectory.path)
        }
        let markerURL = journal.profileDirectory.appendingPathComponent(".codexer-profile.json")
        if !committedProfileIDs.contains(journal.profileID) {
            if let priorMarker = journal.priorMarker {
                try priorMarker.write(to: markerURL, options: .atomic)
            } else if fileManager.fileExists(atPath: markerURL.path) {
                try fileManager.removeItem(at: markerURL)
            }
            if let priorConfigExisted = journal.priorConfigExisted {
                let configURL = journal.profileDirectory
                    .appendingPathComponent("CODEX_HOME/config.toml")
                if priorConfigExisted, let priorConfig = journal.priorConfig {
                    try priorConfig.write(to: configURL, options: .atomic)
                    if let permissions = journal.priorConfigPermissions {
                        try fileManager.setAttributes(
                            [.posixPermissions: NSNumber(value: permissions)],
                            ofItemAtPath: configURL.path
                        )
                    }
                } else if !priorConfigExisted,
                          fileManager.fileExists(atPath: configURL.path)
                {
                    try fileManager.removeItem(at: configURL)
                }
            }
        }
        if fileManager.fileExists(atPath: restoreJournalURL.path) {
            try fileManager.removeItem(at: restoreJournalURL)
        }
    }

    private func validateDeletionJournal(_ journal: DeletionJournal) throws {
        guard !journal.moves.isEmpty else {
            throw ProfileStoreError.invalidRecoveryJournal(deletionJournalURL.path)
        }
        var originals = Set<String>()
        var quarantines = Set<String>()
        let profileParents = Set(DesktopProduct.allCases.map {
            canonical(profilesRootDirectory(for: $0)).path
        })
        let shortcutParents = Set(DesktopProduct.allCases.map {
            canonical(shortcutDirectory(for: $0)).path
        })

        for move in journal.moves {
            let original = move.original.standardizedFileURL
            let quarantine = move.quarantine.standardizedFileURL
            let parent = canonical(original.deletingLastPathComponent()).path
            guard profileParents.contains(parent) || shortcutParents.contains(parent),
                  !profileParents.contains(canonical(original).path),
                  !shortcutParents.contains(canonical(original).path),
                  canonical(quarantine.deletingLastPathComponent()).path == parent,
                  quarantine.lastPathComponent.hasPrefix(".codexer-deleting-"),
                  quarantine.lastPathComponent.hasSuffix("-\(original.lastPathComponent)"),
                  originals.insert(canonical(original).path).inserted,
                  quarantines.insert(canonical(quarantine).path).inserted
            else {
                throw ProfileStoreError.invalidRecoveryJournal(quarantine.path)
            }
            if storedProfiles.contains(where: {
                $0.id != journal.profileID
                    && (canonical($0.profileDirectory).path == canonical(original).path
                        || canonical($0.shortcutPath).path == canonical(original).path)
            })
            {
                throw ProfileStoreError.invalidRecoveryJournal(original.path)
            }
        }
    }

    private func validateAnyManagedDirectory(_ directory: URL) throws {
        let canonicalDirectory = canonical(directory)
        let parent = canonicalDirectory.deletingLastPathComponent().path
        let allowedParents = Set(DesktopProduct.allCases.map {
            canonical(profilesRootDirectory(for: $0)).path
        })
        guard allowedParents.contains(parent), !allowedParents.contains(canonicalDirectory.path) else {
            throw ProfileStoreError.unmanagedProfileDirectory(directory.path)
        }
    }

    private func validatedName(_ name: String) throws -> String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw ProfileStoreError.emptyProfileName
        }
        guard cleanName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw ProfileStoreError.invalidProfileName
        }
        return cleanName
    }

    private func uniqueSlug(
        from value: String,
        product: DesktopProduct,
        reservingDirectory: URL? = nil
    ) -> String {
        let base = slugify(value)
        let existing = Set(
            storedProfiles.lazy.filter { $0.product == product }.map(\.slug)
        )
        var candidate = base
        var suffix = 2
        while existing.contains(candidate)
            || onDiskDirectoryExists(
                for: candidate,
                product: product,
                excluding: reservingDirectory
            )
        {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func onDiskDirectoryExists(
        for slug: String,
        product: DesktopProduct,
        excluding reserved: URL?
    ) -> Bool {
        let candidate = canonical(
            profilesRootDirectory(for: product)
                .appendingPathComponent(slug, isDirectory: true)
        )
        if let reserved, candidate.path == canonical(reserved).path {
            return false
        }
        return fileManager.fileExists(atPath: candidate.path)
    }

    private func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isValidCustomIconData(_ data: Data) -> Bool {
        guard
            !data.isEmpty,
            data.count <= 10 * 1_024 * 1_024,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil
        else {
            return false
        }
        return true
    }

}

public enum ProfileStoreError: Error, LocalizedError, Equatable {
    case emptyProfileName
    case invalidProfileName
    case profileNotFound
    case duplicateProfileID(UUID)
    case duplicateMCPCallbackPort(Int)
    case invalidMCPCallbackPort(Int)
    case noAvailableMCPCallbackPort
    case profileDirectoryAlreadyExists(String)
    case unmanagedProfileDirectory(String)
    case overlappingProfileDirectory(String)
    case invalidProfileLayout(String)
    case invalidShortcutDirectory(String)
    case invalidCustomIcon
    case invalidProfileOrder
    case invalidOwnershipMarker(String)
    case profileInUse(String)
    case deletionCleanupIncomplete([String])
    case deletionRollbackIncomplete([String])
    case invalidRecoveryJournal(String)

    public var errorDescription: String? {
        switch self {
        case .emptyProfileName:
            "Profile name cannot be empty."
        case .invalidProfileName:
            "Profile name contains unsupported control characters."
        case .profileNotFound:
            "Profile was not found."
        case let .duplicateProfileID(id):
            "Profile metadata contains the duplicate identifier \(id.uuidString)."
        case let .duplicateMCPCallbackPort(port):
            "More than one profile is assigned MCP OAuth callback port \(port)."
        case let .invalidMCPCallbackPort(port):
            "Profile metadata contains invalid MCP OAuth callback port \(port)."
        case .noAvailableMCPCallbackPort:
            "No MCP OAuth callback ports are available for a new AgentDock profile."
        case let .profileDirectoryAlreadyExists(path):
            "A profile directory already exists at \(path). Restore it instead of creating a new profile."
        case let .unmanagedProfileDirectory(path):
            "AgentDock will only manage profile folders directly under its Profiles directory: \(path)"
        case let .overlappingProfileDirectory(path):
            "Another profile already owns this profile directory: \(path)"
        case let .invalidProfileLayout(path):
            "The selected folder is not an AgentDock profile with CODEX_HOME and ElectronUserData directories: \(path)"
        case let .invalidShortcutDirectory(path):
            "Profile metadata points to an unmanaged shortcut directory: \(path)"
        case .invalidCustomIcon:
            "The selected profile icon is empty or larger than 10 MB."
        case .invalidProfileOrder:
            "The requested profile order does not match the saved profiles."
        case let .invalidOwnershipMarker(path):
            "AgentDock could not verify ownership of the profile data at \(path)."
        case let .profileInUse(name):
            "Quit every Codex window for \(name) before deleting its data."
        case let .deletionCleanupIncomplete(paths):
            "Profile metadata was removed, but cleanup is incomplete at: \(paths.joined(separator: ", "))"
        case let .deletionRollbackIncomplete(paths):
            "Profile deletion was cancelled, but data recovery is incomplete at: \(paths.joined(separator: ", "))"
        case let .invalidRecoveryJournal(path):
            "AgentDock rejected an invalid recovery journal path: \(path)"
        }
    }
}

private extension JSONEncoder {
    static var codexer: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var codexer: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension NSRecursiveLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
