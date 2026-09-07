import AppKit
import XCTest
@testable import CodexerCore

final class CodexLauncherTests: XCTestCase {
    func testManagedLaunchEnvironmentPinsBundledCLIAndSelectedHome() {
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let inheritedEnvironment = [
            "CODEX_CLI_PATH": "/Applications/Cursor Bridge.app/Contents/MacOS/cursor-bridge",
            "CODEX_HOME": "/tmp/wrong-home",
            "CODEX_ELECTRON_USER_DATA_PATH": "/tmp/wrong-desktop",
            "CODEX_APP_SERVER_WS_URL": "ws://127.0.0.1:9999/another-profile",
            "CLAUDE_USER_DATA_DIR": "/tmp/wrong-claude",
            "HOME": "/tmp/shared-home",
            "PRESERVED_VALUE": "unchanged"
        ]

        let environment = SystemCodexWorkspaceLauncher.launchEnvironment(
            inheriting: inheritedEnvironment,
            codexAppURL: appURL,
            codexHomePath: "/tmp/selected-home",
            electronUserDataPath: "/tmp/selected-desktop"
        )

        XCTAssertEqual(
            environment["CODEX_CLI_PATH"],
            "/Applications/Codex.app/Contents/Resources/codex"
        )
        XCTAssertEqual(environment["CODEX_HOME"], "/tmp/selected-home")
        XCTAssertEqual(environment["CODEX_ELECTRON_USER_DATA_PATH"], "/tmp/selected-desktop")
        XCTAssertNil(environment["CODEX_APP_SERVER_WS_URL"])
        XCTAssertNil(environment["CLAUDE_USER_DATA_DIR"])
        XCTAssertEqual(environment["HOME"], "/tmp/shared-home")
        XCTAssertEqual(environment["PRESERVED_VALUE"], "unchanged")
    }

    func testStockLaunchEnvironmentPinsBundledCLIAndRemovesManagedHome() {
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let inheritedEnvironment = [
            "CODEX_CLI_PATH": "/Applications/Cursor Bridge.app/Contents/MacOS/cursor-bridge",
            "CODEX_HOME": "/tmp/wrong-home",
            "CODEX_ELECTRON_USER_DATA_PATH": "/tmp/wrong-desktop",
            "CODEX_APP_SERVER_WS_URL": "ws://127.0.0.1:9999/another-profile",
            "PRESERVED_VALUE": "unchanged"
        ]

        let environment = SystemCodexWorkspaceLauncher.launchEnvironment(
            inheriting: inheritedEnvironment,
            codexAppURL: appURL,
            codexHomePath: nil,
            electronUserDataPath: nil
        )

        XCTAssertEqual(
            environment["CODEX_CLI_PATH"],
            "/Applications/Codex.app/Contents/Resources/codex"
        )
        XCTAssertNil(environment["CODEX_HOME"])
        XCTAssertNil(environment["CODEX_ELECTRON_USER_DATA_PATH"])
        XCTAssertNil(environment["CODEX_APP_SERVER_WS_URL"])
        XCTAssertEqual(environment["PRESERVED_VALUE"], "unchanged")
    }

    func testNamedConfigProfileUsesBundledProxyAndExplicitProfileEnvironment() throws {
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let proxyURL = URL(fileURLWithPath: "/Applications/AgentDock.app/Contents/Resources/AgentDockShortcutLauncher")
        let configProfile = try CodexConfigProfile(validating: "ollama")

        let environment = SystemCodexWorkspaceLauncher.launchEnvironment(
            inheriting: ["AGENTDOCK_CODEX_CONFIG_PROFILE": "stale"],
            codexAppURL: appURL,
            codexHomePath: "/tmp/selected-home",
            configProfile: configProfile,
            profileProxyURL: proxyURL
        )

        XCTAssertEqual(environment["CODEX_CLI_PATH"], proxyURL.path)
        XCTAssertEqual(environment["CODEX_HOME"], "/tmp/selected-home")
        XCTAssertEqual(environment["AGENTDOCK_CODEX_PROFILE_PROXY"], "1")
        XCTAssertEqual(environment["AGENTDOCK_CODEX_APP_PATH"], appURL.path)
        XCTAssertEqual(environment["AGENTDOCK_CODEX_CONFIG_PROFILE"], "ollama")
    }

    func testDiscoverySeparatesMainAppProfilesAndIgnoresHelpers() {
        let profile = makeProfile(slug: "work")
        let configuration = configuration(for: profile)
        let otherData = profile.profileDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("personal/ElectronUserData")
            .path
        let executable = configuration.appExecutableURL.path
        let snapshot = """
          101 \(executable)
          202 \(executable) --user-data-dir=\(configuration.electronUserDataPath)
          303 \(executable) --user-data-dir=\(otherData)
          404 /Applications/Codex.app/Contents/Frameworks/Codex Helper.app/Contents/MacOS/Codex Helper --type=renderer --user-data-dir=\(configuration.electronUserDataPath)
        """

        XCTAssertEqual(
            CodexInstanceDiscovery.processIDs(in: snapshot, configuration: configuration),
            [202]
        )
        XCTAssertEqual(
            CodexInstanceDiscovery.profileProcessIDs(in: snapshot, configuration: configuration),
            [202, 404]
        )
        XCTAssertEqual(
            CodexInstanceDiscovery.stockProcessIDs(
                in: snapshot,
                appExecutableURL: configuration.appExecutableURL
            ),
            [101]
        )
    }

    func testDiscoveryUsesOnlyExactUserDataArgumentWithTrailingFlags() {
        let selected = configuration(for: makeProfile(slug: "selected"))
        let other = configuration(for: makeProfile(slug: "other"))
        let executable = selected.appExecutableURL.path
        let snapshot = """
          101 \(executable) --diagnostic=--user-data-dir=/tmp/not-a-profile
          202 \(executable) --user-data-dir=\(selected.electronUserDataPath) --start-stack-profiler --lang=en-US
          303 \(executable) --user-data-dir=\(other.electronUserDataPath) --lang=en-US
        """

        XCTAssertEqual(
            CodexInstanceDiscovery.processIDs(in: snapshot, configuration: selected),
            [202]
        )
        XCTAssertEqual(
            CodexInstanceDiscovery.processIDs(in: snapshot, configuration: other),
            [303]
        )
        XCTAssertEqual(
            CodexInstanceDiscovery.stockProcessIDs(
                in: snapshot,
                appExecutableURL: selected.appExecutableURL
            ),
            [101]
        )
    }

    func testDiscoveryRejectsConflictingProfileArgumentsAndBundlePrefixLookalikes() {
        let selected = configuration(for: makeProfile(slug: "selected"))
        let other = configuration(for: makeProfile(slug: "other"))
        let executable = selected.appExecutableURL.path
        let helper = selected.codexAppURL.appendingPathComponent("Contents/Frameworks/Helper").path
        let lookalike = selected.codexAppURL.appendingPathComponent("Contents-other/Helper").path
        let snapshot = """
          101 \(executable) --user-data-dir=\(selected.electronUserDataPath) --user-data-dir=\(other.electronUserDataPath)
          202 \(helper) --user-data-dir=\(selected.electronUserDataPath) --user-data-dir=\(other.electronUserDataPath)
          303 \(lookalike) --user-data-dir=\(selected.electronUserDataPath)
          404 \(helper) --user-data-dir=\(other.electronUserDataPath) --database=\(selected.electronUserDataPath)/Crashpad
        """

        for configuration in [selected, other] {
            XCTAssertTrue(CodexInstanceDiscovery.processIDs(
                in: snapshot,
                configuration: configuration
            ).isEmpty)
        }
        XCTAssertTrue(CodexInstanceDiscovery.profileProcessIDs(
            in: snapshot,
            configuration: selected
        ).isEmpty)
        XCTAssertTrue(CodexInstanceDiscovery.stockProcessIDs(
            in: snapshot,
            appExecutableURL: selected.appExecutableURL
        ).isEmpty)
    }

    func testProfileProcessDiscoveryIncludesOnlyExecutablesOwnedBySelectedCodexHome() {
        let profile = makeProfile(slug: "work")
        let selectedConfiguration = configuration(for: profile)
        let selectedHelper = selectedConfiguration.codexHomeURL
            .appendingPathComponent("computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService")
            .path
        let siblingHelper = selectedConfiguration.codexHomeURL
            .deletingLastPathComponent()
            .appendingPathComponent("CODEX_HOME-other/computer-use/SkyComputerUseService")
            .path
        let otherProfile = makeProfile(slug: "personal")
        let otherHelper = configuration(for: otherProfile).codexHomeURL
            .appendingPathComponent("computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService")
            .path
        let snapshot = """
          202 \(selectedConfiguration.appExecutableURL.path) --user-data-dir=\(selectedConfiguration.electronUserDataPath)
          404 \(selectedHelper)
          405 \(siblingHelper)
          406 \(otherHelper)
        """

        XCTAssertEqual(
            CodexInstanceDiscovery.profileProcessIDs(in: snapshot, configuration: selectedConfiguration),
            [202, 404]
        )
    }

    func testExecutableContainmentRejectsTraversalSiblingAndSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDock Containment-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = root.appendingPathComponent("selected/CODEX_HOME")
        let siblingHome = root.appendingPathComponent("sibling/CODEX_HOME")
        let siblingHelper = siblingHome.appendingPathComponent("computer-use/helper")
        try FileManager.default.createDirectory(
            at: siblingHelper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: siblingHelper.path,
                contents: Data()
            )
        )
        try FileManager.default.createDirectory(
            at: codexHome,
            withIntermediateDirectories: true
        )
        let escapedLink = codexHome.appendingPathComponent("linked-helper")
        try FileManager.default.createSymbolicLink(
            at: escapedLink,
            withDestinationURL: siblingHelper
        )

        XCTAssertTrue(
            CodexInstanceDiscovery.isExecutable(
                codexHome.appendingPathComponent("computer-use/helper"),
                containedBy: codexHome
            )
        )
        XCTAssertFalse(
            CodexInstanceDiscovery.isExecutable(
                codexHome.appendingPathComponent("../../sibling/CODEX_HOME/computer-use/helper"),
                containedBy: codexHome
            )
        )
        XCTAssertFalse(
            CodexInstanceDiscovery.isExecutable(
                siblingHelper,
                containedBy: codexHome
            )
        )
        XCTAssertFalse(
            CodexInstanceDiscovery.isExecutable(
                escapedLink,
                containedBy: codexHome
            )
        )
    }

    func testOpenStockFocusesOnlyExistingDefaultInstance() async throws {
        let profile = makeProfile(slug: "work")
        let configuration = configuration(for: profile)
        let snapshot = """
          111 \(configuration.appExecutableURL.path)
          222 \(configuration.appExecutableURL.path) --user-data-dir=\(configuration.electronUserDataPath)
        """
        let launcher = RecordingWorkspaceLauncher(processID: 999)
        let lifecycle = RecordingLifecycleController(running: [111, 222])
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: snapshot),
            workspaceLauncher: launcher,
            lifecycleController: lifecycle
        )

        let outcome = try await controller.openStock(codexAppURL: configuration.codexAppURL)

        XCTAssertEqual(outcome, .focused(processID: 111))
        XCTAssertEqual(lifecycle.focusedStockProcessIDs, [111])
        let stockLaunchCount = await launcher.stockLaunchCount()
        XCTAssertEqual(stockLaunchCount, 0)
    }

    func testOpenStockLaunchesNewDefaultInstanceWithoutProfileConfiguration() async throws {
        let launcher = RecordingWorkspaceLauncher(processID: 741)
        let lifecycle = RecordingLifecycleController(running: [741])
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: ""),
            workspaceLauncher: launcher,
            lifecycleController: lifecycle
        )
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")

        let outcome = try await controller.openStock(codexAppURL: appURL)

        XCTAssertEqual(outcome, .launched(processID: 741))
        let stockLaunchCount = await launcher.stockLaunchCount()
        let stockAppURLs = await launcher.stockAppURLs()
        let profileConfigurations = await launcher.configurations()
        XCTAssertEqual(stockLaunchCount, 1)
        XCTAssertEqual(stockAppURLs, [appURL])
        XCTAssertTrue(profileConfigurations.isEmpty)
    }

    func testOpenStockLaunchesOfficialHomeWithSelectedNativeProfile() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficialCodexHome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("model_provider = \"ollama\"\n".utf8)
            .write(to: home.appendingPathComponent("ollama.config.toml"))
        let ollama = try CodexConfigProfile(validating: "ollama")
        let launcher = RecordingWorkspaceLauncher(processID: 742)
        let lifecycle = RecordingLifecycleController(running: [742])
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: ""),
            workspaceLauncher: launcher,
            lifecycleController: lifecycle
        )

        let outcome = try await controller.openStock(
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            codexHomeURL: home,
            configProfile: ollama
        )

        XCTAssertEqual(outcome, .launched(processID: 742))
        let selectedProfiles = await launcher.stockConfigProfiles()
        XCTAssertEqual(selectedProfiles, [ollama])
    }

    func testCloseStockTerminatesOnlyVerifiedOfficialInstance() async throws {
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let executable = IsolatedCodexLaunchConfiguration.appExecutableURL(for: appURL).path
        let snapshots = SequencedProcessSnapshotProvider([
            "811 \(executable)",
            ""
        ])
        let lifecycle = RecordingLifecycleController(running: [811])
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: snapshots,
            lifecycleController: lifecycle,
            closeTimeout: .seconds(1),
            closePollInterval: .milliseconds(10)
        )

        let outcome = try await controller.closeStock(codexAppURL: appURL)

        XCTAssertEqual(outcome, .closed(processIDs: [811]))
        XCTAssertEqual(lifecycle.terminatedStockProcessIDs, [811])
    }

    func testOpenLaunchesNewInstanceWithIsolatedConfiguration() async throws {
        let profile = makeProfile(slug: "work")
        try prepareIsolationLayout(for: profile)
        let launcher = RecordingWorkspaceLauncher(processID: 741)
        let lifecycle = RecordingLifecycleController(running: [741])
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: ""),
            workspaceLauncher: launcher,
            lifecycleController: lifecycle
        )

        let outcome = try await controller.open(
            profile: profile,
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app")
        )

        XCTAssertEqual(outcome, .launched(processID: 741))
        let launchedConfigurations = await launcher.configurations()
        XCTAssertEqual(launchedConfigurations, [configuration(for: profile)])
        XCTAssertEqual(lifecycle.focusedProcessIDs, [741])
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.codexHomePath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.electronUserDataPath.path))
    }

    func testOpenTerminatesVerifiedOrphanedHelperBeforeLaunchingReplacement() async throws {
        let profile = makeProfile(slug: "orphan-recovery")
        try prepareIsolationLayout(for: profile)
        let configuration = configuration(for: profile)
        let profileOwnedHelper = configuration.codexHomeURL
            .appendingPathComponent("computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService")
            .path
        let snapshot = "224 \(profileOwnedHelper)"
        let lifecycle = RecordingLifecycleController(running: [224, 741])
        let launcher = RecordingWorkspaceLauncher(processID: 741)
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: snapshot),
            workspaceLauncher: launcher,
            lifecycleController: lifecycle,
            processTreeProvider: LifecycleBackedTreeProvider(snapshot: snapshot, lifecycle: lifecycle),
            processIdentitySignaler: LifecycleBackedIdentitySignaler(lifecycle: lifecycle),
            kernelStartKeyProvider: { "test-\($0)" }
        )

        let outcome = try await controller.open(configuration: configuration)

        XCTAssertEqual(outcome, .launched(processID: 741))
        XCTAssertEqual(lifecycle.terminatedProcessIDs, [224])
        let launchedConfigurations = await launcher.configurations()
        XCTAssertEqual(launchedConfigurations, [configuration])
    }

    func testOpenStopsFreshInstanceThatDoesNotPresentAWindow() async throws {
        let profile = makeProfile(slug: "windowless")
        try prepareIsolationLayout(for: profile)
        let lifecycle = PresentationLifecycleController(processID: 742)
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: ""),
            workspaceLauncher: RecordingWorkspaceLauncher(processID: 742),
            lifecycleController: lifecycle,
            launchValidationTimeout: .milliseconds(1),
            windowPresentationTimeout: .milliseconds(1)
        )

        do {
            _ = try await controller.open(
                profile: profile,
                codexAppURL: configuration(for: profile).codexAppURL
            )
            XCTFail("Expected window presentation failure")
        } catch {
            XCTAssertEqual(
                error as? CodexLauncherError,
                .launchedProcessDidNotPresentWindow(742)
            )
        }
        XCTAssertEqual(lifecycle.presentationRequests, [742])
        XCTAssertEqual(lifecycle.terminatedProcessIDs, [742])
    }

    func testOpenAllowsWindowPresentationToOutlastLaunchValidation() async throws {
        let profile = makeProfile(slug: "slow-window")
        try prepareIsolationLayout(for: profile)
        let lifecycle = PresentationLifecycleController(
            processID: 744,
            hiddenWindowChecks: 2
        )
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: ""),
            workspaceLauncher: RecordingWorkspaceLauncher(processID: 744),
            lifecycleController: lifecycle,
            launchValidationTimeout: .milliseconds(1),
            windowPresentationTimeout: .milliseconds(250)
        )

        let outcome = try await controller.open(
            profile: profile,
            codexAppURL: configuration(for: profile).codexAppURL
        )

        XCTAssertEqual(outcome, .launched(processID: 744))
        XCTAssertGreaterThanOrEqual(lifecycle.windowCheckCount, 3)
        XCTAssertTrue(lifecycle.terminatedProcessIDs.isEmpty)
    }

    func testCancellingWindowPresentationStopsFreshInstance() async throws {
        let profile = makeProfile(slug: "cancelled-window")
        try prepareIsolationLayout(for: profile)
        let presentationRequested = expectation(description: "presentation requested")
        let lifecycle = PresentationLifecycleController(processID: 743) {
            presentationRequested.fulfill()
        }
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: ""),
            workspaceLauncher: RecordingWorkspaceLauncher(processID: 743),
            lifecycleController: lifecycle,
            launchValidationTimeout: .seconds(2)
        )
        let codexAppURL = configuration(for: profile).codexAppURL
        let task = Task {
            try await controller.open(profile: profile, codexAppURL: codexAppURL)
        }
        await fulfillment(of: [presentationRequested], timeout: 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(lifecycle.presentationRequests, [743])
        XCTAssertEqual(lifecycle.terminatedProcessIDs, [743])
    }

    func testOpenRejectsUnverifiedLaunchedProcess() async throws {
        let profile = makeProfile(slug: "unverified")
        try prepareIsolationLayout(for: profile)
        let lifecycle = RejectingLaunchedProcessController()
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: ""),
            workspaceLauncher: RecordingWorkspaceLauncher(processID: 991),
            lifecycleController: lifecycle,
            launchValidationTimeout: .milliseconds(1)
        )

        do {
            _ = try await controller.open(profile: profile, codexAppURL: configuration(for: profile).codexAppURL)
            XCTFail("Expected launched process validation to fail")
        } catch {
            XCTAssertEqual(error as? CodexLauncherError, .launchedProcessFailedValidation(991))
        }
        XCTAssertEqual(lifecycle.invalidatedProcessIDs, [991])
    }

    func testCancellingPostLaunchValidationStopsReturnedProcess() async throws {
        let profile = makeProfile(slug: "cancelled")
        try prepareIsolationLayout(for: profile)
        let verificationRequested = expectation(description: "launch verification requested")
        let lifecycle = RejectingLaunchedProcessController {
            verificationRequested.fulfill()
        }
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: ""),
            workspaceLauncher: RecordingWorkspaceLauncher(processID: 992),
            lifecycleController: lifecycle,
            launchValidationTimeout: .seconds(2)
        )
        let codexAppURL = configuration(for: profile).codexAppURL
        let task = Task {
            try await controller.open(profile: profile, codexAppURL: codexAppURL)
        }
        await fulfillment(of: [verificationRequested], timeout: 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(lifecycle.invalidatedProcessIDs, [992])
    }

    func testOpenFocusesExistingProfileWithoutLaunchingDuplicate() async throws {
        let profile = makeProfile(slug: "work")
        try prepareIsolationLayout(for: profile)
        let configuration = configuration(for: profile)
        let launcher = RecordingWorkspaceLauncher(processID: 999)
        let lifecycle = RecordingLifecycleController(running: [222])
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(
                snapshot: "222 \(configuration.appExecutableURL.path) --user-data-dir=\(configuration.electronUserDataPath)"
            ),
            workspaceLauncher: launcher,
            lifecycleController: lifecycle
        )

        let outcome = try await controller.open(
            profile: profile,
            codexAppURL: configuration.codexAppURL
        )

        XCTAssertEqual(outcome, .focused(processID: 222))
        XCTAssertEqual(lifecycle.focusedProcessIDs, [222])
        let launchedConfigurations = await launcher.configurations()
        XCTAssertEqual(launchedConfigurations, [])
    }

    func testOpenFocusesRunningProfileWhenMCPConfigDriftsOnDisk() async throws {
        let profile = makeProfile(slug: "running-drift")
        try prepareIsolationLayout(for: profile, configureMCP: false)
        let configuration = configuration(for: profile)
        let launcher = RecordingWorkspaceLauncher(processID: 999)
        let lifecycle = RecordingLifecycleController(running: [222])
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(
                snapshot: "222 \(configuration.appExecutableURL.path) --user-data-dir=\(configuration.electronUserDataPath)"
            ),
            workspaceLauncher: launcher,
            lifecycleController: lifecycle
        )

        let outcome = try await controller.open(configuration: configuration)

        XCTAssertEqual(outcome, .focused(processID: 222))
        let launchedConfigurations = await launcher.configurations()
        XCTAssertTrue(launchedConfigurations.isEmpty)
    }

    func testOpenReportsFocusFailure() async throws {
        let profile = makeProfile(slug: "work")
        try prepareIsolationLayout(for: profile)
        let configuration = configuration(for: profile)
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(
                snapshot: "222 \(configuration.appExecutableURL.path) --user-data-dir=\(configuration.electronUserDataPath)"
            ),
            workspaceLauncher: RecordingWorkspaceLauncher(processID: 999),
            lifecycleController: RecordingLifecycleController(running: [])
        )

        do {
            _ = try await controller.open(profile: profile, codexAppURL: configuration.codexAppURL)
            XCTFail("Expected focus failure")
        } catch {
            XCTAssertEqual(error as? CodexLauncherError, .couldNotFocus(222))
        }
    }

    func testOpenRejectsDeletedOrStaleProfileLayout() async throws {
        let profile = makeProfile(slug: "deleted")
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: ""),
            workspaceLauncher: RecordingWorkspaceLauncher(processID: 999),
            lifecycleController: RecordingLifecycleController()
        )

        do {
            _ = try await controller.open(
                profile: profile,
                codexAppURL: configuration(for: profile).codexAppURL
            )
            XCTFail("Expected stale profile rejection")
        } catch {
            guard case CodexLauncherError.invalidIsolationLayout = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testOpenRejectsMissingMCPConfiguration() async throws {
        let profile = makeProfile(slug: "missing-mcp")
        try prepareIsolationLayout(for: profile, configureMCP: false)
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: ""),
            workspaceLauncher: RecordingWorkspaceLauncher(processID: 999),
            lifecycleController: RecordingLifecycleController()
        )

        do {
            _ = try await controller.open(
                profile: profile,
                codexAppURL: configuration(for: profile).codexAppURL
            )
            XCTFail("Expected MCP configuration rejection")
        } catch {
            XCTAssertEqual(
                error as? CodexLauncherError,
                .invalidMCPConfiguration(
                    profile.codexHomePath.appendingPathComponent("config.toml").path
                )
            )
        }
    }

    func testOpenRejectsSymlinkedIsolationDirectory() async throws {
        let profile = makeProfile(slug: "linked")
        try prepareIsolationLayout(for: profile)
        try FileManager.default.removeItem(at: profile.codexHomePath)
        let external = profile.profileDirectory.deletingLastPathComponent()
            .appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: profile.codexHomePath,
            withDestinationURL: external
        )
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: ""),
            workspaceLauncher: RecordingWorkspaceLauncher(processID: 999),
            lifecycleController: RecordingLifecycleController()
        )

        do {
            _ = try await controller.open(profile: profile, codexAppURL: configuration(for: profile).codexAppURL)
            XCTFail("Expected symlink rejection")
        } catch {
            guard case CodexLauncherError.invalidIsolationLayout = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCloseAlreadyStoppedDoesNotTerminateAnything() async throws {
        let profile = makeProfile(slug: "stopped")
        let lifecycle = RecordingLifecycleController()
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: ""),
            workspaceLauncher: RecordingWorkspaceLauncher(processID: 999),
            lifecycleController: lifecycle
        )

        let outcome = try await controller.close(
            profile: profile,
            codexAppURL: configuration(for: profile).codexAppURL
        )

        XCTAssertEqual(outcome, .alreadyStopped)
        XCTAssertEqual(lifecycle.terminatedProcessIDs, [])
    }

    func testCloseReportsTerminationRefusal() async throws {
        let profile = makeProfile(slug: "work")
        let configuration = configuration(for: profile)
        let snapshot = "222 \(configuration.appExecutableURL.path) --user-data-dir=\(configuration.electronUserDataPath)"
        let lifecycle = RecordingLifecycleController(running: [])
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: snapshot),
            workspaceLauncher: RecordingWorkspaceLauncher(processID: 999),
            lifecycleController: lifecycle,
            processTreeProvider: LifecycleBackedTreeProvider(snapshot: snapshot, lifecycle: lifecycle)
        )

        do {
            _ = try await controller.close(profile: profile, codexAppURL: configuration.codexAppURL)
            XCTFail("Expected termination failure")
        } catch {
            XCTAssertEqual(error as? CodexLauncherError, .couldNotTerminate(222))
        }
    }

    func testCloseTimesOutWhenProcessIgnoresTermination() async throws {
        let profile = makeProfile(slug: "work")
        let configuration = configuration(for: profile)
        let snapshot = "222 \(configuration.appExecutableURL.path) --user-data-dir=\(configuration.electronUserDataPath)"
        let lifecycle = RecordingLifecycleController(
            running: [222],
            removesOnTerminate: false
        )
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: snapshot),
            workspaceLauncher: RecordingWorkspaceLauncher(processID: 999),
            lifecycleController: lifecycle,
            closeTimeout: .milliseconds(10),
            closePollInterval: .milliseconds(1),
            processTreeProvider: LifecycleBackedTreeProvider(snapshot: snapshot, lifecycle: lifecycle)
        )

        do {
            _ = try await controller.close(profile: profile, codexAppURL: configuration.codexAppURL)
            XCTFail("Expected close timeout")
        } catch {
            XCTAssertEqual(error as? CodexLauncherError, .closeTimedOut([222]))
        }
    }

    func testCloseDoesNotTreatTransientVerificationFailureAsProcessExit() async throws {
        let profile = makeProfile(slug: "work")
        let configuration = configuration(for: profile)
        let snapshot = "222 \(configuration.appExecutableURL.path) --user-data-dir=\(configuration.electronUserDataPath)"
        let lifecycle = RecordingLifecycleController(
            running: [222],
            removesOnTerminate: false,
            verifiesProfileProcesses: false
        )
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: snapshot),
            workspaceLauncher: RecordingWorkspaceLauncher(processID: 999),
            lifecycleController: lifecycle,
            closeTimeout: .milliseconds(10),
            closePollInterval: .milliseconds(1),
            processTreeProvider: LifecycleBackedTreeProvider(snapshot: snapshot, lifecycle: lifecycle)
        )

        do {
            _ = try await controller.close(profile: profile, codexAppURL: configuration.codexAppURL)
            XCTFail("Expected close timeout")
        } catch {
            XCTAssertEqual(error as? CodexLauncherError, .closeTimedOut([222]))
        }
    }

    func testCloseTerminatesOnlyProcessesForSelectedProfile() async throws {
        let profile = makeProfile(slug: "work")
        let selectedConfiguration = configuration(for: profile)
        let otherProfile = makeProfile(slug: "personal")
        let otherConfiguration = configuration(for: otherProfile)
        let snapshot = """
          222 \(selectedConfiguration.appExecutableURL.path) --user-data-dir=\(selectedConfiguration.electronUserDataPath)
          223 \(selectedConfiguration.appExecutableURL.path) --user-data-dir=\(selectedConfiguration.electronUserDataPath)
          333 \(otherConfiguration.appExecutableURL.path) --user-data-dir=\(otherConfiguration.electronUserDataPath)
          444 \(selectedConfiguration.appExecutableURL.path)
        """
        let lifecycle = RecordingLifecycleController(running: [222, 223, 333, 444])
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: snapshot),
            workspaceLauncher: RecordingWorkspaceLauncher(processID: 999),
            lifecycleController: lifecycle,
            closeTimeout: .milliseconds(50),
            closePollInterval: .milliseconds(1),
            processTreeProvider: LifecycleBackedTreeProvider(snapshot: snapshot, lifecycle: lifecycle)
        )

        let outcome = try await controller.close(
            profile: profile,
            codexAppURL: selectedConfiguration.codexAppURL
        )

        XCTAssertEqual(outcome, .closed(processIDs: [222, 223]))
        XCTAssertEqual(lifecycle.terminatedProcessIDs, [222, 223])
        XCTAssertTrue(lifecycle.isRunning(processID: 333))
        XCTAssertTrue(lifecycle.isRunning(processID: 444))
    }

    func testCloseWaitsForAndTerminatesProfileHelpers() async throws {
        let profile = makeProfile(slug: "helpers")
        let configuration = configuration(for: profile)
        let bundledHelper = configuration.codexAppURL
            .appendingPathComponent("Contents/Frameworks/Codex Helper.app/Contents/MacOS/Codex Helper")
            .path
        let profileOwnedHelper = configuration.codexHomeURL
            .appendingPathComponent("computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService")
            .path
        let snapshot = """
          222 \(configuration.appExecutableURL.path) --user-data-dir=\(configuration.electronUserDataPath)
          223 \(bundledHelper) --type=renderer --user-data-dir=\(configuration.electronUserDataPath)
          224 \(profileOwnedHelper)
        """
        let lifecycle = RecordingLifecycleController(running: [222, 223, 224])
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: snapshot),
            workspaceLauncher: RecordingWorkspaceLauncher(processID: 999),
            lifecycleController: lifecycle,
            processTreeProvider: LifecycleBackedTreeProvider(snapshot: snapshot, lifecycle: lifecycle),
            processIdentitySignaler: LifecycleBackedIdentitySignaler(lifecycle: lifecycle),
            kernelStartKeyProvider: { "test-\($0)" }
        )

        let outcome = try await controller.close(profile: profile, codexAppURL: configuration.codexAppURL)

        XCTAssertEqual(outcome, .closed(processIDs: [222]))
        XCTAssertEqual(lifecycle.terminatedProcessIDs.first, 222)
        XCTAssertEqual(Set(lifecycle.terminatedProcessIDs.dropFirst()), Set([223, 224]))
    }

    func testCloseTerminatesVerifiedOrphanedProfileHelper() async throws {
        let profile = makeProfile(slug: "orphan")
        let configuration = configuration(for: profile)
        let profileOwnedHelper = configuration.codexHomeURL
            .appendingPathComponent("computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService")
            .path
        let snapshot = "224 \(profileOwnedHelper)"
        let lifecycle = RecordingLifecycleController(running: [224])
        let controller = CodexInstanceController(
            validator: AcceptingValidator(),
            processSnapshotProvider: FixedProcessSnapshotProvider(snapshot: snapshot),
            workspaceLauncher: RecordingWorkspaceLauncher(processID: 999),
            lifecycleController: lifecycle,
            processTreeProvider: LifecycleBackedTreeProvider(snapshot: snapshot, lifecycle: lifecycle),
            processIdentitySignaler: LifecycleBackedIdentitySignaler(lifecycle: lifecycle),
            kernelStartKeyProvider: { "test-\($0)" }
        )

        let outcome = try await controller.close(
            profile: profile,
            codexAppURL: configuration.codexAppURL
        )

        XCTAssertEqual(outcome, .closed(processIDs: []))
        XCTAssertEqual(lifecycle.terminatedProcessIDs, [224])
    }

    func testManyProfilesAlwaysHaveDistinctIsolationConfiguration() {
        let configurations = (0..<100).map { index in
            configuration(for: makeProfile(slug: "profile-\(index)"))
        }

        XCTAssertEqual(Set(configurations.map(\.codexHomePath)).count, 100)
        XCTAssertEqual(Set(configurations.map(\.electronUserDataPath)).count, 100)
    }

    func testProcessTreeCapturesNestedDescendantsWithStableIdentity() {
        let snapshot = """
          100 1 Wed Jul 22 10:00:00 2026 /Applications/Codex.app/Contents/MacOS/Codex
          101 100 Wed Jul 22 10:00:01 2026 helper
          102 101 Wed Jul 22 10:00:02 2026 app-server --listen
          200 1 Wed Jul 22 10:00:03 2026 unrelated
        """
        let parsed = SystemProcessTreeSnapshotProvider.parse(snapshot)
        let descendants = SystemProcessTreeSnapshotProvider.descendants(
            of: Set([Int32(100)]),
            in: parsed
        )

        XCTAssertEqual(Set(descendants.map(\.processID)), Set([101, 102]))
        XCTAssertEqual(descendants.first(where: { $0.processID == 102 })?.startKey, "Wed Jul 22 10:00:02 2026")
    }

    func testIdentitySignalerSkipsReusedOrCommandMismatchedProcesses() throws {
        let current = [
            ProcessIdentity(processID: 10, parentProcessID: 1, startKey: "same", command: "match"),
            ProcessIdentity(processID: 11, parentProcessID: 1, startKey: "new", command: "match"),
            ProcessIdentity(processID: 12, parentProcessID: 1, startKey: "same", command: "different"),
        ]
        let recorder = SignalRecorder()
        let signaler = SystemProcessIdentitySignaler(
            snapshotProvider: FixedProcessTreeProvider(identities: current),
            signalSender: { processID, signal in
                recorder.record(processID: processID, signal: signal)
                return 0
            }
        )

        try signaler.signal(SIGTERM, identities: [
            ProcessIdentity(processID: 10, parentProcessID: 1, startKey: "same", command: "match"),
            ProcessIdentity(processID: 11, parentProcessID: 1, startKey: "old", command: "match"),
            ProcessIdentity(processID: 12, parentProcessID: 1, startKey: "same", command: "match"),
        ])

        XCTAssertEqual(recorder.recorded, [.init(processID: 10, signal: SIGTERM)])
    }

    func testSystemIdentitySignalerRejectsWrongKernelStartKeyForRealProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        defer { SubprocessTerminator.terminateAndWait(process) }
        let snapshotProvider = SystemProcessTreeSnapshotProvider()
        guard var identity = try snapshotProvider.processTreeSnapshot().first(where: {
            $0.processID == process.processIdentifier
        }) else {
            return XCTFail("Could not inspect the real test process.")
        }
        identity.kernelStartKey = "deliberately-wrong"

        try SystemProcessIdentitySignaler(snapshotProvider: snapshotProvider).signal(
            SIGTERM,
            identities: [identity]
        )
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(process.isRunning)
    }

    func testOfficialInstalledCodexSignatureIsAccepted() throws {
        guard ProcessInfo.processInfo.environment["AGENTDOCK_INSTALLED_APP_TEST"] == "1" else {
            throw XCTSkip("Set AGENTDOCK_INSTALLED_APP_TEST=1 to validate the installed Codex app.")
        }
        try OfficialCodexAppValidator().validateCodexApp(
            at: URL(fileURLWithPath: "/Applications/Codex.app")
        )
    }

    func testBundleWithOfficialIdentifierButNoSignatureIsRejected() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unsigned-Official-Codex-\(UUID().uuidString).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let plist = ["CFBundleIdentifier": OfficialCodexAppValidator.bundleIdentifier]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        XCTAssertThrowsError(try OfficialCodexAppValidator().validateCodexApp(at: bundle)) { error in
            XCTAssertEqual(error as? CodexLauncherError, .invalidCodexSignature(bundle.path))
        }
    }

    func testProfileOperationLockExcludesConcurrentOperations() async throws {
        let profile = makeProfile(slug: "locked")
        try FileManager.default.createDirectory(at: profile.profileDirectory, withIntermediateDirectories: true)
        let firstLock = try await ProfileOperationLock.acquire(for: profile.profileDirectory)

        do {
            _ = try await ProfileOperationLock.acquire(
                for: profile.profileDirectory,
                timeout: .milliseconds(50)
            )
            XCTFail("Expected the second operation to time out")
        } catch {
            XCTAssertEqual(error as? ProfileOperationLockError, .timedOut)
        }
        withExtendedLifetime(firstLock) {}
    }

    func testSynchronousProfileOperationLockTimesOutInsteadOfBlockingForever() throws {
        let profile = makeProfile(slug: "synchronously-locked")
        try FileManager.default.createDirectory(
            at: profile.profileDirectory,
            withIntermediateDirectories: true
        )
        let firstLock = try ProfileOperationLock.acquireSynchronously(
            for: profile.profileDirectory
        )

        XCTAssertThrowsError(
            try ProfileOperationLock.acquireSynchronously(
                for: profile.profileDirectory,
                timeout: .milliseconds(50)
            )
        ) { error in
            XCTAssertEqual(error as? ProfileOperationLockError, .timedOut)
        }
        withExtendedLifetime(firstLock) {}
    }

    func testLiveProfileCanOpenAndCloseWithoutTouchingStockInstance() async throws {
        guard ProcessInfo.processInfo.environment["AGENTDOCK_LIVE_LIFECYCLE"] == "1" else {
            throw XCTSkip("Set AGENTDOCK_LIVE_LIFECYCLE=1 to exercise the installed Codex app.")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Codexer Live Lifecycle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = CodexProfile(
            name: "Lifecycle Test",
            slug: "lifecycle-test",
            rootDirectory: root,
            mcpOAuthCallbackPort: CodexMCPConfiguration.managedCallbackPorts.lowerBound
        )
        try prepareIsolationLayout(for: profile)
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let controller = CodexInstanceController()
        let stockProcessIDs = Set(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: OfficialCodexAppValidator.bundleIdentifier
            ).map(\.processIdentifier)
        )

        let openOutcome: CodexOpenOutcome
        do {
            openOutcome = try await controller.open(profile: profile, codexAppURL: appURL)
        } catch {
            return XCTFail("Live open failed: \(error)")
        }
        let launchedProcessID: Int32
        switch openOutcome {
        case let .launched(processID), let .focused(processID):
            launchedProcessID = processID
        }
        let launchedConfiguration = IsolatedCodexLaunchConfiguration(
            profile: profile,
            codexAppURL: appURL
        )
        defer {
            _ = SystemCodexApplicationLifecycleController().terminate(
                processID: launchedProcessID,
                configuration: launchedConfiguration
            )
        }

        try await Task.sleep(for: .seconds(1))
        let running = try await controller.status(for: profile, codexAppURL: appURL)
        XCTAssertTrue(running.processIDs.contains(launchedProcessID))
        let processTreeProvider = SystemProcessTreeSnapshotProvider()
        let capturedDescendants = SystemProcessTreeSnapshotProvider.descendants(
            of: Set([launchedProcessID]),
            in: try processTreeProvider.processTreeSnapshot()
        )

        let closeOutcome: CodexCloseOutcome
        do {
            closeOutcome = try await controller.close(profile: profile, codexAppURL: appURL)
        } catch {
            return XCTFail("Live close failed: \(error)")
        }
        XCTAssertEqual(closeOutcome, .closed(processIDs: [launchedProcessID]))
        let stopped = try await controller.status(for: profile, codexAppURL: appURL)
        XCTAssertFalse(stopped.isRunning)
        let remainingProcessIDs = Set(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: OfficialCodexAppValidator.bundleIdentifier
            ).map(\.processIdentifier)
        )
        XCTAssertEqual(remainingProcessIDs, stockProcessIDs)
        let currentIdentities = try processTreeProvider.processTreeSnapshot()
        for captured in capturedDescendants {
            XCTAssertFalse(currentIdentities.contains {
                $0.processID == captured.processID
                    && $0.startKey == captured.startKey
                    && $0.command == captured.command
            })
        }
    }

    func testLiveExistingCodexProfileClosesAllOwnedProcessesWithoutTouchingStock() async throws {
        guard let profilePath = ProcessInfo.processInfo.environment[
            "AGENTDOCK_LIVE_EXISTING_CODEX_PROFILE"
        ] else {
            throw XCTSkip(
                "Set AGENTDOCK_LIVE_EXISTING_CODEX_PROFILE to an active managed profile directory."
            )
        }
        let profileDirectory = URL(fileURLWithPath: profilePath, isDirectory: true)
        let profile = CodexProfile(
            name: "Live Existing Profile",
            slug: profileDirectory.lastPathComponent,
            profileDirectory: profileDirectory,
            shortcutDirectory: FileManager.default.temporaryDirectory
        )
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let controller = CodexInstanceController()
        let running = try await controller.status(for: profile, codexAppURL: appURL)
        guard running.isRunning else {
            return XCTFail("The selected live profile is not running.")
        }
        let stockBefore = try await controller.stockStatus(codexAppURL: appURL)
        let processTreeProvider = SystemProcessTreeSnapshotProvider()
        let before = try processTreeProvider.processTreeSnapshot()
        let selectedHelpers = before.filter {
            $0.command.contains(profileDirectory.path)
                && $0.command.contains("SkyComputerUseService")
        }
        XCTAssertFalse(selectedHelpers.isEmpty)
        let unrelatedComputerUseHelpers = before.filter {
            !$0.command.contains(profileDirectory.path)
                && $0.command.contains("SkyComputerUseService")
        }

        let outcome = try await controller.close(profile: profile, codexAppURL: appURL)
        let stopped = try await controller.status(for: profile, codexAppURL: appURL)
        let stockAfter = try await controller.stockStatus(codexAppURL: appURL)

        XCTAssertEqual(outcome, .closed(processIDs: running.processIDs))
        XCTAssertFalse(stopped.isRunning)
        XCTAssertEqual(stockAfter, stockBefore)
        let remaining = try processTreeProvider.processTreeSnapshot()
        XCTAssertFalse(remaining.contains {
            $0.command.contains(profileDirectory.path)
        })
        for unrelated in unrelatedComputerUseHelpers {
            XCTAssertTrue(remaining.contains {
                $0.processID == unrelated.processID
                    && $0.startKey == unrelated.startKey
                    && $0.command == unrelated.command
            })
        }
    }

    func testMissingCodexAppIsRejected() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("Missing-Codex-\(UUID().uuidString).app")

        XCTAssertThrowsError(try OfficialCodexAppValidator().validateCodexApp(at: missing)) { error in
            XCTAssertEqual(error as? CodexLauncherError, .codexAppMissing(missing.path))
        }
    }

    func testBundleWithoutOfficialIdentifierIsRejected() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unsigned-Codex-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        XCTAssertThrowsError(try OfficialCodexAppValidator().validateCodexApp(at: bundle)) { error in
            XCTAssertEqual(error as? CodexLauncherError, .invalidCodexBundle(bundle.path))
        }
    }

    private func makeProfile(slug: String) -> CodexProfile {
        CodexProfile(
            name: slug,
            slug: slug,
            rootDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("Codexer Launcher Tests-\(UUID().uuidString)"),
            mcpOAuthCallbackPort: 49_152
        )
    }

    private func configuration(for profile: CodexProfile) -> IsolatedCodexLaunchConfiguration {
        IsolatedCodexLaunchConfiguration(
            profile: profile,
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app")
        )
    }

    private func prepareIsolationLayout(
        for profile: CodexProfile,
        configureMCP: Bool = true
    ) throws {
        try FileManager.default.createDirectory(
            at: profile.codexHomePath,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: profile.electronUserDataPath,
            withIntermediateDirectories: true
        )
        if configureMCP {
            try CodexMCPConfiguration.configure(
                codexHomeURL: profile.codexHomePath,
                callbackPort: profile.mcpOAuthCallbackPort
            )
        }
        let marker: [String: String] = [
            "profileID": profile.id.uuidString,
            "slug": profile.slug
        ]
        try JSONSerialization.data(withJSONObject: marker)
            .write(to: profile.profileDirectory.appendingPathComponent(".codexer-profile.json"))
    }
}

private struct AcceptingValidator: CodexAppValidating {
    func validateCodexApp(at _: URL) throws {}
}

private struct FixedProcessSnapshotProvider: CodexProcessSnapshotProviding {
    var snapshot: String

    func processSnapshot() throws -> String {
        snapshot
    }
}

private final class SequencedProcessSnapshotProvider: CodexProcessSnapshotProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String]

    init(_ snapshots: [String]) {
        self.snapshots = snapshots
    }

    func processSnapshot() throws -> String {
        lock.withLock {
            guard snapshots.count > 1 else { return snapshots.first ?? "" }
            return snapshots.removeFirst()
        }
    }
}

private actor RecordingWorkspaceLauncher: CodexWorkspaceLaunching {
    private let processID: Int32
    private var recordedConfigurations: [IsolatedCodexLaunchConfiguration] = []
    private var recordedStockAppURLs: [URL] = []
    private var recordedStockConfigProfiles: [CodexConfigProfile?] = []

    init(processID: Int32) {
        self.processID = processID
    }

    func launch(configuration: IsolatedCodexLaunchConfiguration) async throws -> Int32 {
        recordedConfigurations.append(configuration)
        return processID
    }

    func launchStock(
        codexAppURL: URL,
        codexHomeURL _: URL,
        configProfile: CodexConfigProfile?
    ) async throws -> Int32 {
        recordedStockAppURLs.append(codexAppURL)
        recordedStockConfigProfiles.append(configProfile)
        return processID
    }

    func configurations() -> [IsolatedCodexLaunchConfiguration] {
        recordedConfigurations
    }

    func stockLaunchCount() -> Int {
        recordedStockAppURLs.count
    }

    func stockAppURLs() -> [URL] {
        recordedStockAppURLs
    }

    func stockConfigProfiles() -> [CodexConfigProfile?] {
        recordedStockConfigProfiles
    }
}

private final class RecordingLifecycleController: CodexApplicationLifecycleControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var runningProcessIDs: Set<Int32>
    private let removesOnTerminate: Bool
    private let verifiesProfileProcesses: Bool
    private(set) var focusedProcessIDs: [Int32] = []
    private(set) var focusedStockProcessIDs: [Int32] = []
    private(set) var terminatedStockProcessIDs: [Int32] = []
    private(set) var terminatedProcessIDs: [Int32] = []

    init(
        running: Set<Int32> = [],
        removesOnTerminate: Bool = true,
        verifiesProfileProcesses: Bool = true
    ) {
        runningProcessIDs = running
        self.removesOnTerminate = removesOnTerminate
        self.verifiesProfileProcesses = verifiesProfileProcesses
    }

    func focus(
        processID: Int32,
        configuration _: IsolatedCodexLaunchConfiguration
    ) -> Bool {
        lock.withLock {
            focusedProcessIDs.append(processID)
            return runningProcessIDs.contains(processID)
        }
    }

    func focusStock(processID: Int32, codexAppURL _: URL) -> Bool {
        lock.withLock {
            focusedStockProcessIDs.append(processID)
            return runningProcessIDs.contains(processID)
        }
    }

    func terminateStock(processID: Int32, codexAppURL _: URL) -> Bool {
        lock.withLock {
            guard runningProcessIDs.contains(processID) else { return false }
            if removesOnTerminate {
                runningProcessIDs.remove(processID)
            }
            terminatedStockProcessIDs.append(processID)
            return true
        }
    }

    func terminate(
        processID: Int32,
        configuration _: IsolatedCodexLaunchConfiguration
    ) -> Bool {
        lock.withLock {
            guard runningProcessIDs.contains(processID) else { return false }
            if removesOnTerminate {
                runningProcessIDs.remove(processID)
            }
            terminatedProcessIDs.append(processID)
            return true
        }
    }

    func isRunning(processID: Int32) -> Bool {
        lock.withLock { runningProcessIDs.contains(processID) }
    }

    func markStopped(processID: Int32) {
        lock.withLock {
            if runningProcessIDs.remove(processID) != nil {
                terminatedProcessIDs.append(processID)
            }
        }
    }

    func isVerifiedProfileProcess(
        processID: Int32,
        configuration _: IsolatedCodexLaunchConfiguration,
        processSnapshot _: String
    ) -> Bool {
        verifiesProfileProcesses && isRunning(processID: processID)
    }
}

private struct LifecycleBackedIdentitySignaler: ProcessIdentitySignaling {
    var lifecycle: RecordingLifecycleController

    func signal(_ signal: Int32, identities: [ProcessIdentity]) throws {
        guard signal == SIGTERM || signal == SIGKILL else { return }
        for identity in identities {
            lifecycle.markStopped(processID: identity.processID)
        }
    }
}

private struct FixedProcessTreeProvider: ProcessTreeSnapshotProviding {
    var identities: [ProcessIdentity]

    func processTreeSnapshot() throws -> [ProcessIdentity] {
        identities
    }
}

private final class SignalRecorder: @unchecked Sendable {
    struct Record: Equatable {
        var processID: Int32
        var signal: Int32
    }

    private let lock = NSLock()
    private var storage: [Record] = []

    var recorded: [Record] {
        lock.withLock { storage }
    }

    func record(processID: Int32, signal: Int32) {
        lock.withLock {
            storage.append(.init(processID: processID, signal: signal))
        }
    }
}

private struct LifecycleBackedTreeProvider: ProcessTreeSnapshotProviding {
    var snapshot: String
    var lifecycle: RecordingLifecycleController

    func processTreeSnapshot() throws -> [ProcessIdentity] {
        snapshot.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.drop(while: \.isWhitespace)
            guard let separator = trimmed.firstIndex(where: \.isWhitespace),
                  let processID = Int32(trimmed[..<separator]),
                  lifecycle.isRunning(processID: processID)
            else {
                return nil
            }
            return ProcessIdentity(
                processID: processID,
                parentProcessID: 1,
                startKey: "test-\(processID)",
                command: String(trimmed[separator...].drop(while: \.isWhitespace))
            )
        }
    }
}

private final class RejectingLaunchedProcessController: CodexApplicationLifecycleControlling, @unchecked Sendable {
    private(set) var invalidatedProcessIDs: [Int32] = []
    private let onVerificationRequested: () -> Void

    init(onVerificationRequested: @escaping () -> Void = {}) {
        self.onVerificationRequested = onVerificationRequested
    }

    func focus(processID _: Int32, configuration _: IsolatedCodexLaunchConfiguration) -> Bool { false }
    func terminate(processID _: Int32, configuration _: IsolatedCodexLaunchConfiguration) -> Bool { false }
    func isRunning(processID _: Int32) -> Bool { true }
    func isVerifiedRunning(
        processID _: Int32,
        configuration _: IsolatedCodexLaunchConfiguration
    ) -> Bool {
        onVerificationRequested()
        return false
    }
    func invalidateUnverifiedLaunch(
        processID: Int32,
        configuration _: IsolatedCodexLaunchConfiguration
    ) {
        invalidatedProcessIDs.append(processID)
    }
}

private final class PresentationLifecycleController: CodexApplicationLifecycleControlling, @unchecked Sendable {
    let processID: Int32
    private(set) var presentationRequests: [Int32] = []
    private(set) var terminatedProcessIDs: [Int32] = []
    private(set) var windowCheckCount = 0
    private let hiddenWindowChecks: Int?
    private let onPresentationRequested: () -> Void

    init(
        processID: Int32,
        hiddenWindowChecks: Int? = nil,
        onPresentationRequested: @escaping () -> Void = {}
    ) {
        self.processID = processID
        self.hiddenWindowChecks = hiddenWindowChecks
        self.onPresentationRequested = onPresentationRequested
    }

    func focus(
        processID _: Int32,
        configuration _: IsolatedCodexLaunchConfiguration
    ) -> Bool {
        true
    }

    func requestPresentation(
        processID: Int32,
        configuration _: IsolatedCodexLaunchConfiguration
    ) -> Bool {
        presentationRequests.append(processID)
        onPresentationRequested()
        return true
    }

    func isPresentingWindow(processID _: Int32) -> Bool {
        windowCheckCount += 1
        guard let hiddenWindowChecks else { return false }
        return windowCheckCount > hiddenWindowChecks
    }

    func terminate(
        processID: Int32,
        configuration _: IsolatedCodexLaunchConfiguration
    ) -> Bool {
        terminatedProcessIDs.append(processID)
        return true
    }

    func isRunning(processID: Int32) -> Bool {
        processID == self.processID
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
