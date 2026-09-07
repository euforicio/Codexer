import XCTest
@testable import CodexerCore

final class ClaudeDesktopTests: XCTestCase {
    func testLaunchRejectsExistingAndInvalidReturnedProcessIdentifiers() throws {
        let existing: Set<Int32> = [101, 202]
        for processID in existing {
            XCTAssertThrowsError(try ClaudeInstanceController.validateLaunchedProcessID(
                processID,
                existingProcessIDs: existing
            )) { error in
                XCTAssertEqual(error as? ClaudeLauncherError, .launchReturnedExistingProcess(processID))
            }
        }
        XCTAssertThrowsError(try ClaudeInstanceController.validateLaunchedProcessID(
            0,
            existingProcessIDs: existing
        )) { error in
            XCTAssertEqual(error as? ClaudeLauncherError, .launchDidNotReturnProcess)
        }
        XCTAssertNoThrow(try ClaudeInstanceController.validateLaunchedProcessID(
            303,
            existingProcessIDs: existing
        ))
    }

    func testLaunchEnvironmentsDiscardInheritedProfileAndRuntimeSelection() {
        let inherited = [
            "CLAUDE_USER_DATA_DIR": "/tmp/wrong-desktop",
            "CLAUDE_CONFIG_DIR": "/tmp/wrong-config",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/wrong-credentials",
            "CODEX_HOME": "/tmp/other-provider",
            "CODEX_CLI_PATH": "/tmp/other-cli",
            "CODEX_ELECTRON_USER_DATA_PATH": "/tmp/other-desktop",
            "ELECTRON_RUN_AS_NODE": "1",
            "NODE_OPTIONS": "--require=/tmp/other-profile.js",
            "NODE_PATH": "/tmp/other-modules",
            "HOME": "/tmp/shared-home",
            "PATH": "/usr/bin:/bin",
            "CUSTOM_PROVIDER_TOKEN": "configured-value"
        ]

        for selectedPath in ["/tmp/selected/UserData", nil] {
            let environment = ClaudeInstanceController.launchEnvironment(
                inheriting: inherited,
                userDataPath: selectedPath
            )
            XCTAssertEqual(environment["CLAUDE_USER_DATA_DIR"], selectedPath)
            for key in ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CODEX_HOME",
                        "CODEX_CLI_PATH", "CODEX_ELECTRON_USER_DATA_PATH", "ELECTRON_RUN_AS_NODE",
                        "NODE_OPTIONS", "NODE_PATH"] {
                XCTAssertNil(environment[key])
            }
            XCTAssertEqual(environment["HOME"], inherited["HOME"])
            XCTAssertEqual(environment["PATH"], inherited["PATH"])
            XCTAssertEqual(environment["CUSTOM_PROVIDER_TOKEN"], inherited["CUSTOM_PROVIDER_TOKEN"])
        }
    }

    func testRegistryPinsClaudePublisherIdentity() {
        XCTAssertEqual(DesktopAppRegistry.claude.bundleIdentifier, "com.anthropic.claudefordesktop")
        XCTAssertEqual(DesktopAppRegistry.claude.teamIdentifier, "Q6L2SF6YDW")
        XCTAssertEqual(DesktopAppRegistry.claude.executableName, "Claude")
        XCTAssertEqual(DesktopAppRegistry.claude.defaultAppURL.path, "/Applications/Claude.app")
    }

    func testContractProbeRequiresNearbyUserDataAndLogsSetPathCalls() throws {
        let unrelatedOccurrence = "CLAUDE_USER_DATA_DIR"
            + String(
                repeating: "x",
                count: ClaudeDesktopContractProbe.maximumContractWindowBytes + 1
            )
        let appURL = try temporaryClaudeApp(
            archive: unrelatedOccurrence + """
            bootstrap();
            if(process.env.CLAUDE_USER_DATA_DIR){
              const root=process.env.CLAUDE_USER_DATA_DIR;
              app.setPath("userData",root);
              app.setPath("logs",resolve(root,"Logs"));
            }
            require("./index.js");
            """
        )
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }

        XCTAssertNoThrow(try ClaudeDesktopContractProbe().validate(appURL: appURL))
    }

    func testContractProbeFailsClosedForIncidentalTokens() throws {
        let appURL = try temporaryClaudeApp(
            archive: "CLAUDE_USER_DATA_DIR setPath userData logs"
        )
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }

        XCTAssertThrowsError(try ClaudeDesktopContractProbe().validate(appURL: appURL)) {
            XCTAssertEqual($0 as? ClaudeDesktopContractError, .unsupportedBuild)
        }
    }

    func testContractProbeAcceptsMinifiedTemplateLiteralPathNames() throws {
        let appURL = try temporaryClaudeApp(
            archive: """
            if(process.env.CLAUDE_USER_DATA_DIR){
              let root=process.env.CLAUDE_USER_DATA_DIR;
              app.setPath(`userData`,root);
              app.setPath(`logs`,resolve(root,`Logs`));
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }

        XCTAssertNoThrow(try ClaudeDesktopContractProbe().validate(appURL: appURL))
    }

    func testUnsignedBundleCannotControlTrustedClaudeIdentity() throws {
        let appURL = try temporaryClaudeApp(
            archive: """
            CLAUDE_USER_DATA_DIR
            setPath("userData",root)
            setPath("logs",root)
            """,
            bundleIdentifier: DesktopAppRegistry.claude.bundleIdentifier
        )
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }

        XCTAssertThrowsError(
            try OfficialDesktopAppValidator().validateApp(at: appURL, product: .claude)
        ) {
            XCTAssertEqual(
                $0 as? DesktopAppValidationError,
                .invalidSignature(.claude, appURL.path)
            )
        }
    }

    func testDiscoveryUsesExactHelperRootAndSignedMainProcessAncestryShape() {
        let appURL = URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true)
        let profileA = URL(fileURLWithPath: "/tmp/Profile A/UserData", isDirectory: true)
        let profileB = URL(fileURLWithPath: "/tmp/Profile B/UserData", isDirectory: true)
        let stock = URL(fileURLWithPath: "/tmp/Stock Claude", isDirectory: true)
        let executable = "/Applications/Claude.app/Contents/MacOS/Claude"
        let helper = "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
        let snapshot = ClaudeProcessSnapshot(text: """
        100 1 \(executable)
        101 100 \(helper) --type=renderer --user-data-dir=\(profileA.path) --lang=en
        200 1 \(executable)
        201 200 \(helper) --type=gpu-process --user-data-dir=\(profileB.path) --lang=en
        300 1 \(executable)
        301 300 \(helper) --type=renderer --user-data-dir=\(stock.path) --lang=en
        400 1 /tmp/Unsigned.app/Contents/MacOS/Claude
        401 400 \(helper) --type=renderer --user-data-dir=\(profileA.path) --lang=en
        500 1 \(helper) --type=renderer --user-data-dir=\(profileA.path) --lang=en
        """)

        XCTAssertEqual(
            ClaudeInstanceDiscovery.profileMainProcessIDs(
                in: snapshot,
                appURL: appURL,
                userDataURL: profileA
            ),
            [100]
        )
        XCTAssertEqual(
            ClaudeInstanceDiscovery.profileMainProcessIDs(
                in: snapshot,
                appURL: appURL,
                userDataURL: profileB
            ),
            [200]
        )
        XCTAssertEqual(
            ClaudeInstanceDiscovery.stockMainProcessIDs(
                in: snapshot,
                appURL: appURL,
                defaultUserDataURL: stock
            ),
            [300]
        )
    }

    func testDiscoveryRejectsEmbeddedArgumentsAndConflictingProfileRoots() {
        let appURL = URL(fileURLWithPath: "/Applications/Claude.app")
        let selected = URL(fileURLWithPath: "/tmp/Selected Profile/UserData")
        let other = URL(fileURLWithPath: "/tmp/Other Profile/UserData")
        let executable = "/Applications/Claude.app/Contents/MacOS/Claude"
        let helper = "/Applications/Claude.app/Contents/Frameworks/Claude Helper"
        let snapshot = ClaudeProcessSnapshot(text: """
        100 1 \(executable)
        101 100 \(helper) --diagnostic=--user-data-dir=\(selected.path)
        200 1 \(executable)
        201 200 \(helper) --user-data-dir=\(selected.path) --user-data-dir=\(other.path)
        300 1 \(executable)
        301 300 /Applications/Claude.app/Contents-other/Helper --user-data-dir=\(selected.path)
        400 1 \(executable)
        401 400 \(helper) --user-data-dir=\(selected.path)
        402 400 \(helper) --user-data-dir=\(other.path)
        """)

        for profile in [selected, other] {
            XCTAssertTrue(ClaudeInstanceDiscovery.profileMainProcessIDs(
                in: snapshot,
                appURL: appURL,
                userDataURL: profile
            ).isEmpty)
        }
    }

    func testClaudeProfilesUseProductScopedStateAndPreserveCodexLayout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Codexer-ClaudeProfiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts"),
            usageChecker: ClaudeNeverInUseChecker()
        )

        let codex = try store.createProfile(product: .codex, name: "Work")
        let claude = try store.createProfile(product: .claude, name: "Work")

        XCTAssertEqual(codex.slug, "work")
        XCTAssertEqual(claude.slug, "work")
        XCTAssertEqual(codex.profileDirectory, root.appendingPathComponent("Profiles/work"))
        XCTAssertEqual(
            claude.profileDirectory,
            root.appendingPathComponent("Profiles/claude/work")
        )
        XCTAssertEqual(
            claude.shortcutDirectory,
            root.appendingPathComponent("Shortcuts/claude")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: claude.claudeUserDataPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.codexHomePath.path))
        XCTAssertEqual(claude.mcpOAuthCallbackPort, 0)

        let reopened = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts"),
            usageChecker: ClaudeNeverInUseChecker()
        )
        XCTAssertEqual(Set(reopened.profiles.map(\.product)), Set([.codex, .claude]))

        try reopened.removeProfile(id: claude.id, policy: .deleteAllData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.profileDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: codex.profileDirectory.path))
    }

    func testClaudeProfileCanBeRemovedAndRestoredWithoutCodexProvisioning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Codexer-ClaudeRestore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts"),
            usageChecker: ClaudeNeverInUseChecker()
        )
        let original = try store.createProfile(product: .claude, name: "Personal")
        try store.removeProfile(id: original.id, policy: .removeFromList)

        let restored = try store.restoreProfile(
            product: .claude,
            name: "Restored",
            profileDirectory: original.profileDirectory
        )

        XCTAssertEqual(restored.product, .claude)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.claudeUserDataPath, original.claudeUserDataPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.codexHomePath.path))
    }

    func testInstalledClaudeSignatureAndStartupContract() throws {
        guard ProcessInfo.processInfo.environment["AGENTDOCK_INSTALLED_CLAUDE_TEST"] == "1" else {
            throw XCTSkip(
                "Set AGENTDOCK_INSTALLED_CLAUDE_TEST=1 to validate the installed Claude Desktop app."
            )
        }
        let appURL = DesktopAppRegistry.claude.defaultAppURL
        try OfficialDesktopAppValidator().validateApp(at: appURL, product: .claude)
        try ClaudeDesktopContractProbe().validate(appURL: appURL)
    }

    func testLiveClaudeProfileCanOpenAndCloseWithoutTouchingStock() async throws {
        guard ProcessInfo.processInfo.environment["AGENTDOCK_CLAUDE_LIVE_LIFECYCLE"] == "1" else {
            throw XCTSkip(
                "Set AGENTDOCK_CLAUDE_LIVE_LIFECYCLE=1 to exercise a temporary Claude profile."
            )
        }
        let appURL = DesktopAppRegistry.claude.defaultAppURL
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Codexer-ClaudeLive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts"),
            usageChecker: ClaudeNeverInUseChecker()
        )
        let profile = try store.createProfile(product: .claude, name: "Lifecycle")
        let controller = ClaudeInstanceController()
        let stockBefore = try await controller.stockStatus(appURL: appURL)

        _ = try await controller.open(profile: profile, appURL: appURL)
        let running = try await controller.status(for: profile, appURL: appURL)
        let stockWhileRunning = try await controller.stockStatus(appURL: appURL)
        XCTAssertTrue(running.isRunning)
        XCTAssertEqual(stockWhileRunning.processIDs, stockBefore.processIDs)

        _ = try await controller.close(profile: profile, appURL: appURL)
        let stopped = try await controller.status(for: profile, appURL: appURL)
        let stockAfterClose = try await controller.stockStatus(appURL: appURL)
        XCTAssertFalse(stopped.isRunning)
        XCTAssertEqual(stockAfterClose.processIDs, stockBefore.processIDs)
    }

    private func temporaryClaudeApp(
        archive: String,
        bundleIdentifier: String = "com.example.fixture"
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Codexer-ClaudeFixture-\(UUID().uuidString)")
        let appURL = root.appendingPathComponent("Claude.app", isDirectory: true)
        let resources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": "Claude"
        ]
        try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ).write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        try Data(archive.utf8).write(to: resources.appendingPathComponent("app.asar"))
        return appURL
    }
}

private struct ClaudeNeverInUseChecker: ProfileUsageChecking {
    func isProfileInUse(_: CodexProfile) -> Bool { false }
}
