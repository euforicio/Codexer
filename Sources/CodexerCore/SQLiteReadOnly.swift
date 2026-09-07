import Darwin
import Foundation

enum SQLiteReadOnly {
    static func databaseArgument(for database: URL, under root: URL? = nil) throws -> String {
        // `sqlite3 -nofollow` rejects symlinked path components on macOS. Resolve
        // only the parent, retain the final name, then validate the final files.
        let originalParent = database.deletingLastPathComponent()
        guard let resolvedParent = Darwin.realpath(originalParent.path, nil) else {
            throw SQLiteReadOnlyError.unsafeDatabase(database.path)
        }
        defer { Darwin.free(resolvedParent) }
        let parent = URL(fileURLWithPath: String(cString: resolvedParent), isDirectory: true)
        let canonicalDatabase = parent.appendingPathComponent(database.lastPathComponent)
        if let root {
            let rootPath = root.standardizedFileURL.path + "/"
            let databasePath = database.standardizedFileURL.path
            guard databasePath.hasPrefix(rootPath),
                  let resolvedRoot = Darwin.realpath(root.path, nil)
            else { throw SQLiteReadOnlyError.unsafeDatabase(database.path) }
            defer { Darwin.free(resolvedRoot) }
            let expected = URL(fileURLWithPath: String(cString: resolvedRoot), isDirectory: true)
                .appendingPathComponent(String(databasePath.dropFirst(rootPath.count)))
            guard expected.path == canonicalDatabase.path else {
                throw SQLiteReadOnlyError.unsafeDatabase(database.path)
            }
        }
        let wal = URL(fileURLWithPath: canonicalDatabase.path + "-wal")
        let sharedMemory = URL(fileURLWithPath: canonicalDatabase.path + "-shm")
        _ = try validateRegularFile(canonicalDatabase, required: true)
        let hasWAL = try validateRegularFile(wal, required: false)
        let hasSharedMemory = try validateRegularFile(sharedMemory, required: false)
        guard !hasWAL, !hasSharedMemory else {
            return canonicalDatabase.path
        }
        return canonicalDatabase.absoluteString + "?immutable=1"
    }

    private static func validateRegularFile(_ url: URL, required: Bool) throws -> Bool {
        var status = Darwin.stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            if !required, errno == ENOENT { return false }
            throw SQLiteReadOnlyError.unsafeDatabase(url.path)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw SQLiteReadOnlyError.unsafeDatabase(url.path)
        }
        return true
    }
}

enum SQLiteReadOnlyError: Error, LocalizedError, Equatable {
    case unsafeDatabase(String)

    var errorDescription: String? {
        switch self {
        case let .unsafeDatabase(path):
            "The database or one of its sidecars is not a safe regular file: \(path)"
        }
    }
}
