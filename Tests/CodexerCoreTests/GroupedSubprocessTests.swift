import Darwin
import XCTest
@testable import CodexerCore

final class GroupedSubprocessTests: XCTestCase {
    func testWritingAfterChildExitThrowsWithoutTerminatingTheParent() throws {
        let process = try GroupedSubprocess(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            environment: [:]
        )
        defer { process.terminateAndWait() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertFalse(process.isRunning)
        // Assert descriptor policy even if the test host happens to ignore SIGPIPE.
        XCTAssertEqual(fcntl(process.standardInput.fileDescriptor, F_GETNOSIGPIPE), 1)
        XCTAssertThrowsError(try process.standardInput.write(contentsOf: Data("request\n".utf8)))
    }
}
