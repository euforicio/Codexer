import AppKit
import XCTest
@testable import CodexerCore

final class LiveProfileIsolationTests: XCTestCase {
    func testTwoTemporaryCodexProfilesRemainIndependentAcrossRestart() async throws {
        try await verifyIsolation(for: .codex)
    }

    func testTwoTemporaryClaudeProfilesRemainIndependentAcrossRestart() async throws {
        try await verifyIsolation(for: .claude)
    }

    private func verifyIsolation(for product: DesktopProduct) async throws {
        guard ProcessInfo.processInfo.environment["AGENTDOCK_LIVE_ISOLATION_TEST"] == "1" else {
            throw XCTSkip("Set AGENTDOCK_LIVE_ISOLATION_TEST=1 to open two temporary provider profiles.")
        }
        let descriptor = DesktopAppRegistry.descriptor(for: product)
        let appURL = descriptor.defaultAppURL
        let controller = DesktopInstanceController()
        try await controller.validateApp(product: product, at: appURL)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDock-LiveIsolation-\(UUID().uuidString)", isDirectory: true)
        let store = try ProfileStore(rootDirectory: root,
                                     shortcutDirectory: root.appendingPathComponent("Shortcuts"))
        let first = try store.createProfile(product: product, name: "Isolation A")
        let second = try store.createProfile(product: product, name: "Isolation B")
        let profiles = [first, second]
        let existing = Set(NSRunningApplication.runningApplications(
            withBundleIdentifier: descriptor.bundleIdentifier
        ).map(\.processIdentifier))

        // Failures preserve test data: failed discovery cannot prove ownership
        // or process exit well enough to close instances or remove their files.
        for (index, profile) in profiles.enumerated() {
            try await openTestProfile(
                profile,
                controller: controller,
                appURL: appURL,
                existingProcessIDs: existing,
                phase: "initial-\(index + 1)"
            )
        }
        let running = try await controller.statuses(for: profiles, appURLs: [product: appURL])
        let firstIDs = Set(try XCTUnwrap(running[first.id]).processIDs)
        let secondIDs = Set(try XCTUnwrap(running[second.id]).processIDs)
        guard !firstIDs.isEmpty, !secondIDs.isEmpty,
              firstIDs.isDisjoint(with: secondIDs),
              firstIDs.isDisjoint(with: existing),
              secondIDs.isDisjoint(with: existing) else {
            XCTFail("Profile process identity is ambiguous; retaining test data without cleanup.")
            return
        }

        if product == .claude {
            try await verifyClaudeStorage(profile: first, processIDs: firstIDs, sibling: second, controller: controller, appURL: appURL)
            try await verifyClaudeStorage(profile: second, processIDs: secondIDs, sibling: first, controller: controller, appURL: appURL)
            guard testRun?.failureCount == 0 else { return }
        }

        let sentinel = first.profileDirectory.appendingPathComponent(".isolation-sentinel")
        try Data("first-profile-only".utf8).write(to: sentinel)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: second.profileDirectory.appendingPathComponent(".isolation-sentinel").path
        ))
        guard testRun?.failureCount == 0 else { return }
        _ = try await controller.close(profile: first, appURL: appURL)
        let afterClose = try await controller.statuses(for: profiles, appURLs: [product: appURL])
        XCTAssertFalse(try XCTUnwrap(afterClose[first.id]).isRunning)
        XCTAssertEqual(Set(try XCTUnwrap(afterClose[second.id]).processIDs), secondIDs)
        guard testRun?.failureCount == 0 else { return }

        try await openTestProfile(
            first,
            controller: controller,
            appURL: appURL,
            existingProcessIDs: existing,
            phase: "restart-1"
        )
        let restarted = try await controller.statuses(for: profiles, appURLs: [product: appURL])
        XCTAssertTrue(try XCTUnwrap(restarted[first.id]).isRunning)
        XCTAssertEqual(Set(try XCTUnwrap(restarted[second.id]).processIDs), secondIDs)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("first-profile-only".utf8))
        if product == .claude {
            try await verifyClaudeStorage(
                profile: first,
                processIDs: Set(try XCTUnwrap(restarted[first.id]).processIDs),
                sibling: second,
                controller: controller,
                appURL: appURL
            )
        }
        guard testRun?.failureCount == 0 else { return }
        for profile in profiles {
            _ = try await controller.close(profile: profile, appURL: appURL)
        }
        let stopped = try await controller.statuses(for: profiles, appURLs: [product: appURL])
        XCTAssertTrue(stopped.values.allSatisfy { !$0.isRunning })
        XCTAssertEqual(Set(NSRunningApplication.runningApplications(
            withBundleIdentifier: descriptor.bundleIdentifier
        ).map(\.processIdentifier)), existing)
        if stopped.values.allSatisfy({ !$0.isRunning }), testRun?.failureCount == 0 {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func verifyClaudeStorage(
        profile: CodexProfile,
        processIDs: Set<Int32>,
        sibling: CodexProfile,
        controller: DesktopInstanceController,
        appURL: URL
    ) async throws {
        var capture: BoundedSubprocessResult?
        var lastStatus: Int32 = -1
        var exceededLimit = false
        for attempt in 0..<3 {
            let verified = try await controller.statuses(for: [profile], appURLs: [.claude: appURL])
            guard !processIDs.isEmpty,
                  Set(try XCTUnwrap(verified[profile.id]).processIDs) == processIDs else {
                XCTFail("The temporary profile exited or changed identity before storage inspection.")
                return
            }
            let tree = try SystemProcessTreeSnapshotProvider().processTreeSnapshot()
            let descendants = SystemProcessTreeSnapshotProvider.descendants(of: processIDs, in: tree)
            let allIDs = processIDs.union(descendants.map(\.processID))
            let result = try BoundedSubprocess.run(
                executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
                arguments: ["-nP", "-a", "-p", allIDs.sorted().map(String.init).joined(separator: ","), "-Fn"],
                timeout: 5,
                maximumOutputBytes: 2 * 1_024 * 1_024
            )
            if result.terminationStatus == 0, !result.exceededOutputLimit {
                capture = result
                break
            }
            lastStatus = result.terminationStatus
            exceededLimit = result.exceededOutputLimit
            // Startup helpers can exit between ps and lsof. Retry the inventory,
            // while still requiring the original verified main process each time.
            if attempt < 2 { try await Task.sleep(for: .milliseconds(250)) }
        }
        guard let result = capture else {
            XCTFail("Storage inspection failed: status=\(lastStatus), outputLimit=\(exceededLimit).")
            return
        }
        let paths = String(decoding: result.output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("n/") }
            .map { URL(fileURLWithPath: String($0.dropFirst()))
                .resolvingSymlinksInPath().standardizedFileURL.path }
        let ownPrefix = profile.claudeUserDataPath.resolvingSymlinksInPath().path + "/"
        let siblingPrefix = sibling.claudeUserDataPath.resolvingSymlinksInPath().path + "/"
        let officialPrefix = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
            .resolvingSymlinksInPath().path + "/"
        let ownCount = paths.filter { $0.hasPrefix(ownPrefix) }.count
        let otherCount = paths.filter {
            $0.hasPrefix(siblingPrefix) || $0.hasPrefix(officialPrefix)
        }.count
        // Classifications only: never print provider paths or open-file names.
        print("Claude storage diagnostic: selectedRootFiles=\(ownCount) otherRootFiles=\(otherCount)")
        XCTAssertGreaterThan(ownCount, 0, "The temporary profile must open its own provider state.")
        XCTAssertEqual(otherCount, 0, "The temporary profile opened another profile's provider state.")
    }

    private func openTestProfile(
        _ profile: CodexProfile,
        controller: DesktopInstanceController,
        appURL: URL,
        existingProcessIDs: Set<Int32>,
        phase: String
    ) async throws {
        do {
            _ = try await controller.open(profile: profile, appURL: appURL)
        } catch {
            let remaining = Set(NSRunningApplication.runningApplications(
                withBundleIdentifier: DesktopAppRegistry.descriptor(for: profile.product).bundleIdentifier
            ).map(\.processIdentifier))
            XCTAssertTrue(existingProcessIDs.isSubset(of: remaining), "An existing provider instance disappeared.")
            if profile.product == .claude {
                reportClaudeLaunchFailure(error, profile: profile, appURL: appURL, phase: phase)
            }
            throw error
        }
    }

    private func reportClaudeLaunchFailure(
        _ error: Error,
        profile: CodexProfile,
        appURL: URL,
        phase: String
    ) {
        guard let error = error as? ClaudeLauncherError else { return }
        let processID: Int32
        let returnedExisting: Bool
        switch error {
        case let .launchReturnedExistingProcess(value):
            processID = value
            returnedExisting = true
        case let .launchedProcessFailedValidation(value):
            processID = value
            returnedExisting = false
        default:
            return
        }
        guard let snapshot = try? SystemClaudeProcessSnapshotProvider().snapshot() else {
            print("Claude launch diagnostic: phase=\(phase) snapshotUnavailable=true")
            return
        }
        let expectedExecutable = DesktopAppRegistry.claude.executableURL(for: appURL)
            .standardizedFileURL.resolvingSymlinksInPath()
        let actualExecutable = SystemProcessTreeSnapshotProvider.executableURL(for: processID)?
            .standardizedFileURL.resolvingSymlinksInPath()
        let paths = ClaudeInstanceDiscovery.userDataPathsByMainProcess(
            in: snapshot,
            appURL: appURL
        )[processID] ?? []
        let selectedPath = profile.claudeUserDataPath.standardizedFileURL.resolvingSymlinksInPath().path
        let command = snapshot.entries[processID]?.command
        let commandMatches = command == expectedExecutable.path
            || command?.hasPrefix(expectedExecutable.path + " ") == true
        let trusted = OfficialDesktopAppValidator().isTrustedProcess(processID: processID, product: .claude)
        let otherRootCount = paths.filter { !$0.isEmpty && $0 != selectedPath }.count
        // Emit only classifications; process arguments and profile/account paths
        // stay out of test output, including when LaunchServices reused an app.
        print("""
        Claude launch diagnostic: phase=\(phase) returnedExisting=\(returnedExisting) \
        alive=\(snapshot.entries[processID] != nil) executableMatches=\(actualExecutable == expectedExecutable) \
        commandMatches=\(commandMatches) trusted=\(trusted) selectedRoot=\(paths.contains(selectedPath)) \
        otherRootCount=\(otherRootCount) emptyRoot=\(paths.contains(""))
        """)
    }
}
