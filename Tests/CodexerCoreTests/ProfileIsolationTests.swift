import XCTest
@testable import CodexerCore

final class ProfileIsolationTests: XCTestCase {
    func testProfileLockSerializesSymlinkAliases() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDock-Isolation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("Profiles/selected")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: profile)
        let firstLock = try ProfileOperationLock.acquireSynchronously(for: profile)
        defer { withExtendedLifetime(firstLock) {} }

        XCTAssertThrowsError(try ProfileOperationLock.acquireSynchronously(
            for: alias,
            timeout: .milliseconds(100)
        )) { error in
            XCTAssertEqual(error as? ProfileOperationLockError, .timedOut)
        }
    }

    func testAdvisoryLockRejectsSymlinkedLockFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDock-Isolation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target")
        let original = Data("preserved".utf8)
        try original.write(to: target)
        let alias = root.appendingPathComponent("alias.lock")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        XCTAssertThrowsError(try AdvisoryFileLock.acquireSynchronously(at: alias)) { error in
            guard case ProfileOperationLockError.couldNotOpen = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testPersistedShortcutCannotClaimProviderNamespaceOrAnotherProfile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDock-Isolation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let shortcutRoot = root.appendingPathComponent("Shortcuts")
        let store = try ProfileStore(rootDirectory: root, shortcutDirectory: shortcutRoot)
        let first = try store.createProfile(name: "First")
        let second = try store.createProfile(name: "Second")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let unrelatedBundle = shortcutRoot.appendingPathComponent("unrelated.app")
        try FileManager.default.createDirectory(at: unrelatedBundle, withIntermediateDirectories: true)
        let sentinel = unrelatedBundle.appendingPathComponent("sentinel")
        try Data("preserved".utf8).write(to: sentinel)

        for unsafeName in ["claude", first.shortcutFileName, "unrelated.app"] {
            var unsafe = second
            unsafe.shortcutFileName = unsafeName
            try encoder.encode([first, unsafe]).write(
                to: root.appendingPathComponent("profiles.json"),
                options: .atomic
            )

            XCTAssertThrowsError(try ProfileStore(
                rootDirectory: root,
                shortcutDirectory: shortcutRoot
            )) { error in
                guard case ProfileStoreError.invalidShortcutDirectory = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserved".utf8))
        }
    }

    func testRecoveryCannotDeleteProviderNamespaces() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDock-Isolation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let shortcutRoot = root.appendingPathComponent("Shortcuts")
        let store = try ProfileStore(rootDirectory: root, shortcutDirectory: shortcutRoot)
        let claude = try store.createProfile(product: .claude, name: "Work")

        for providerRoot in [
            store.profilesRootDirectory(for: .claude),
            store.shortcutDirectory(for: .claude)
        ] {
            let quarantine = providerRoot.deletingLastPathComponent()
                .appendingPathComponent(".codexer-deleting-\(UUID().uuidString)-claude")
            try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
            let sentinel = quarantine.appendingPathComponent("sentinel")
            try Data("preserved".utf8).write(to: sentinel)
            let journal: [String: Any] = [
                "profileID": UUID().uuidString,
                "moves": [["original": providerRoot.absoluteString, "quarantine": quarantine.absoluteString]]
            ]
            try JSONSerialization.data(withJSONObject: journal).write(
                to: root.appendingPathComponent(".delete-profile-journal.json"),
                options: .atomic
            )

            XCTAssertThrowsError(try ProfileStore(
                rootDirectory: root,
                shortcutDirectory: shortcutRoot
            )) { error in
                guard case ProfileStoreError.invalidRecoveryJournal = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: claude.claudeUserDataPath.path))
        }
    }

    func testRestoreCannotClaimAnotherProvidersProfileRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDock-Isolation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts")
        )
        let claude = try store.createProfile(product: .claude, name: "Work")
        let providerRoot = store.profilesRootDirectory(for: .claude)
        for child in ["CODEX_HOME", "ElectronUserData"] {
            try FileManager.default.createDirectory(
                at: providerRoot.appendingPathComponent(child),
                withIntermediateDirectories: true
            )
        }

        XCTAssertThrowsError(
            try store.restoreProfile(name: "Claude", profileDirectory: providerRoot)
        ) { error in
            guard case ProfileStoreError.unmanagedProfileDirectory = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(store.profiles.map(\.id), [claude.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: claude.claudeUserDataPath.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: providerRoot.appendingPathComponent(".codexer-profile.json").path
        ))
    }
}
