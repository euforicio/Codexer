import Darwin
import Foundation

public final class AdvisoryFileLock: @unchecked Sendable {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    public static func acquire(
        at lockURL: URL,
        timeout: Duration = .seconds(10)
    ) async throws -> AdvisoryFileLock {
        let fileDescriptor = try openLockFile(at: lockURL)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while flock(fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else {
                let code = errno
                close(fileDescriptor)
                throw ProfileOperationLockError.couldNotLock(code)
            }
            guard clock.now < deadline else {
                close(fileDescriptor)
                throw ProfileOperationLockError.timedOut
            }
            do {
                try await clock.sleep(for: .milliseconds(50))
            } catch {
                close(fileDescriptor)
                throw error
            }
        }
        return AdvisoryFileLock(fileDescriptor: fileDescriptor)
    }

    public static func acquireSynchronously(
        at lockURL: URL,
        timeout: Duration = .seconds(10)
    ) throws -> AdvisoryFileLock {
        let fileDescriptor = try openLockFile(at: lockURL)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while flock(fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else {
                let code = errno
                close(fileDescriptor)
                throw ProfileOperationLockError.couldNotLock(code)
            }
            guard !Task.isCancelled else {
                close(fileDescriptor)
                throw CancellationError()
            }
            guard clock.now < deadline else {
                close(fileDescriptor)
                throw ProfileOperationLockError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        if Task.isCancelled {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
            throw CancellationError()
        }
        return AdvisoryFileLock(fileDescriptor: fileDescriptor)
    }

    private static func openLockFile(at lockURL: URL) throws -> Int32 {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fileDescriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard fileDescriptor >= 0 else {
            throw ProfileOperationLockError.couldNotOpen(errno)
        }
        var status = Darwin.stat()
        guard Darwin.fstat(fileDescriptor, &status) == 0 else {
            let code = errno
            Darwin.close(fileDescriptor)
            throw ProfileOperationLockError.couldNotOpen(code)
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1
        else {
            Darwin.close(fileDescriptor)
            throw ProfileOperationLockError.couldNotOpen(EINVAL)
        }
        return fileDescriptor
    }
}

public final class ProfileOperationLock: @unchecked Sendable {
    private let fileLock: AdvisoryFileLock

    private init(fileLock: AdvisoryFileLock) {
        self.fileLock = fileLock
    }

    public static func lockFileURL(for profileDirectory: URL) -> URL {
        let canonicalDirectory = profileDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return canonicalDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(".codexer-locks", isDirectory: true)
            .appendingPathComponent("\(canonicalDirectory.lastPathComponent).lock")
    }

    public static func acquire(
        for profileDirectory: URL,
        timeout: Duration = .seconds(10)
    ) async throws -> ProfileOperationLock {
        ProfileOperationLock(
            fileLock: try await AdvisoryFileLock.acquire(
                at: lockFileURL(for: profileDirectory),
                timeout: timeout
            )
        )
    }

    public static func acquireSynchronously(
        for profileDirectory: URL,
        timeout: Duration = .seconds(10)
    ) throws -> ProfileOperationLock {
        ProfileOperationLock(
            fileLock: try AdvisoryFileLock.acquireSynchronously(
                at: lockFileURL(for: profileDirectory),
                timeout: timeout
            )
        )
    }
}

public enum ProfileOperationLockError: Error, LocalizedError, Equatable {
    case couldNotOpen(Int32)
    case couldNotLock(Int32)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case let .couldNotOpen(code):
            "AgentDock could not open the profile operation lock (errno \(code))."
        case let .couldNotLock(code):
            "AgentDock could not acquire the profile operation lock (errno \(code))."
        case .timedOut:
            "Another operation on this profile did not finish in time."
        }
    }
}
