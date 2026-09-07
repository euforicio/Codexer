import Darwin
import Foundation

/// A subprocess launched as the leader of a dedicated process group.
///
/// The group remains addressable even if the root exits first, so cleanup can
/// reliably terminate background descendants that inherited the group.
final class GroupedSubprocess {
    let standardInput: FileHandle
    let standardOutput: FileHandle

    private let processID: pid_t
    private var waitStatus: Int32 = 0
    private var rootReaped = false

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) throws {
        var inputPipe: [Int32] = [0, 0]
        var outputPipe: [Int32] = [0, 0]
        guard pipe(&inputPipe) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard pipe(&outputPipe) == 0 else {
            close(inputPipe[0])
            close(inputPipe[1])
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        // A child can exit between a liveness check and a write. Report EPIPE
        // to the caller instead of letting SIGPIPE terminate the application.
        guard fcntl(inputPipe[1], F_SETNOSIGPIPE, 1) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            for descriptor in inputPipe + outputPipe {
                close(descriptor)
            }
            throw error
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        for descriptor in inputPipe + outputPipe {
            posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let command = [executableURL.path] + arguments
        let cArguments = command.map { strdup($0) }
        defer { cArguments.forEach { free($0) } }
        var argv = cArguments + [nil]
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
        let cEnvironment = environmentStrings.map { strdup($0) }
        defer { cEnvironment.forEach { free($0) } }
        var environmentPointer = cEnvironment + [nil]
        var spawnedProcessID: pid_t = 0
        let spawnResult = posix_spawn(
            &spawnedProcessID,
            executableURL.path,
            &actions,
            &attributes,
            &argv,
            &environmentPointer
        )
        close(inputPipe[0])
        close(outputPipe[1])
        guard spawnResult == 0 else {
            close(inputPipe[1])
            close(outputPipe[0])
            throw POSIXError(POSIXErrorCode(rawValue: spawnResult) ?? .EIO)
        }

        processID = spawnedProcessID
        standardInput = FileHandle(fileDescriptor: inputPipe[1], closeOnDealloc: true)
        standardOutput = FileHandle(fileDescriptor: outputPipe[0], closeOnDealloc: true)
    }

    var isRunning: Bool {
        guard !rootReaped else { return false }
        let result = waitpid(processID, &waitStatus, WNOHANG)
        if result == processID || (result == -1 && errno == ECHILD) {
            rootReaped = true
            return false
        }
        return result == 0
    }

    func terminateAndWait(gracePeriod: TimeInterval = 1) {
        try? standardInput.close()
        _ = kill(-processID, SIGTERM)
        let deadline = Date().addingTimeInterval(gracePeriod)
        while groupExists, Date() < deadline {
            _ = isRunning
            Thread.sleep(forTimeInterval: 0.01)
        }
        if groupExists {
            _ = kill(-processID, SIGKILL)
        }
        if !rootReaped {
            _ = waitpid(processID, &waitStatus, 0)
            rootReaped = true
        }
        try? standardOutput.close()
    }

    private var groupExists: Bool {
        if kill(-processID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}
