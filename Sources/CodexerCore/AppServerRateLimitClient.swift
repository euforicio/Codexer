import Foundation

public final class AppServerRateLimitClient: @unchecked Sendable {
    private let executableOverride: URL?
    private let appValidator: any CodexAppValidating
    private let timeoutSeconds: TimeInterval
    private let maximumResponseBytes: Int
    private let clientVersion: String

    public init(
        codexExecutable: URL? = nil,
        appValidator: any CodexAppValidating = OfficialCodexAppValidator(),
        timeoutSeconds: TimeInterval = 8,
        maximumResponseBytes: Int = 1_048_576,
        clientVersion: String? = nil
    ) {
        executableOverride = codexExecutable
        self.appValidator = appValidator
        self.timeoutSeconds = timeoutSeconds
        self.maximumResponseBytes = maximumResponseBytes
        self.clientVersion = clientVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.1.1"
    }

    public func fetchRateLimits(for profile: CodexProfile, codexAppURL: URL) -> ProfileRateLimits {
        fetchRateLimits(codexHomeURL: profile.codexHomePath, codexAppURL: codexAppURL)
    }

    public func fetchRateLimits(codexHomeURL: URL, codexAppURL: URL) -> ProfileRateLimits {
        if executableOverride == nil {
            do {
                try appValidator.validateCodexApp(at: codexAppURL)
            } catch {
                return ProfileRateLimits(
                    errorMessage: (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                )
            }
        }
        let codexExecutable = executableOverride
            ?? codexAppURL.appendingPathComponent("Contents/Resources/codex")
        guard FileManager.default.isExecutableFile(atPath: codexExecutable.path) else {
            return ProfileRateLimits(errorMessage: "Codex app-server executable was not found at \(codexExecutable.path).")
        }

        let environment = Self.launchEnvironment(
            codexHomeURL: codexHomeURL,
            codexExecutable: codexExecutable,
            inherited: ProcessInfo.processInfo.environment
        )

        let initializeCompletion = DispatchSemaphore(value: 0)
        let completion = DispatchSemaphore(value: 0)
        let pipeFinished = DispatchSemaphore(value: 0)
        let responseState = ResponseState(maximumBytes: maximumResponseBytes)

        do {
            let process = try GroupedSubprocess(
                executableURL: codexExecutable,
                arguments: ["app-server", "--listen", "stdio://"],
                environment: environment
            )
            process.standardOutput.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    pipeFinished.signal()
                    return
                }
                responseState.consume(data)
                if responseState.hasInitializeResponse || responseState.errorMessage != nil {
                    initializeCompletion.signal()
                }
                if responseState.responseData != nil || responseState.errorMessage != nil {
                    completion.signal()
                }
            }
            defer {
                process.standardOutput.readabilityHandler = nil
                process.terminateAndWait()
            }

            try writeInitializeRequest(to: process.standardInput)
            let initializeWait = waitForCompletion(initializeCompletion, process: process)
            if let errorMessage = responseState.errorMessage {
                return ProfileRateLimits(errorMessage: errorMessage)
            }
            if Task.isCancelled {
                return ProfileRateLimits(errorMessage: "Usage-limit refresh was cancelled.")
            }
            guard responseState.hasInitializeResponse else {
                if initializeWait == .timedOut {
                    return ProfileRateLimits(errorMessage: "Timed out reading Codex usage limits.")
                }
                return ProfileRateLimits(errorMessage: "Codex app-server exited before returning usage limits.")
            }

            try writeRateLimitRequest(to: process.standardInput)

            let waitResult = waitForCompletion(completion, process: process)
            if !process.isRunning,
               responseState.responseData == nil,
               responseState.errorMessage == nil
            {
                // Process termination can race the readability callback that
                // delivers the final response. Give that bounded callback a
                // chance to consume EOF before deciding the response is absent.
                _ = pipeFinished.wait(timeout: .now() + 0.1)
            }
            if let responseData = responseState.responseData {
                return try RateLimitParser.parseResponse(responseData)
            }
            if let errorMessage = responseState.errorMessage {
                return ProfileRateLimits(errorMessage: errorMessage)
            }
            if Task.isCancelled {
                return ProfileRateLimits(errorMessage: "Usage-limit refresh was cancelled.")
            }
            guard waitResult == .success else {
                return ProfileRateLimits(errorMessage: "Timed out reading Codex usage limits.")
            }
            return ProfileRateLimits(errorMessage: "Codex app-server exited before returning usage limits.")
        } catch {
            return ProfileRateLimits(errorMessage: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    static func launchEnvironment(
        codexHomeURL: URL,
        codexExecutable: URL,
        inherited: [String: String]
    ) -> [String: String] {
        var environment = DesktopLaunchEnvironment.sanitized(inherited)
        // Native account limits must use this home's login. Custom-provider
        // credentials and endpoints are handled by CodexRateLimitClient instead.
        for key in [
            "OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL",
            "OPENAI_ORG_ID", "OPENAI_ORGANIZATION", "OPENAI_PROJECT_ID",
            "CODEX_APP_SERVER_CHATGPT_BASE_URL", "CODEX_APP_SERVER_OPENAI_BASE_URL",
            "CODEX_APP_SERVER_LOGIN_ISSUER", "CODEX_API_BASE_URL", "CODEX_API_ENDPOINT"
        ] {
            environment.removeValue(forKey: key)
        }
        environment["CODEX_HOME"] = codexHomeURL.path
        environment["CODEX_CLI_PATH"] = codexExecutable.path
        return environment
    }

    private func waitForCompletion(
        _ completion: DispatchSemaphore,
        process: GroupedSubprocess
    ) -> DispatchTimeoutResult {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !Task.isCancelled, Date() < deadline {
            if completion.wait(timeout: .now() + 0.1) == .success {
                return .success
            }
            if !process.isRunning {
                return .success
            }
        }
        return .timedOut
    }

    private func writeInitializeRequest(to fileHandle: FileHandle) throws {
        let initialize: [String: Any] = [
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "AgentDock",
                    "version": clientVersion
                ],
                "capabilities": [
                    "experimentalApi": true
                ]
            ]
        ]
        var data = try JSONSerialization.data(withJSONObject: initialize)
        data.append(0x0A)
        try fileHandle.write(contentsOf: data)
    }

    private func writeRateLimitRequest(to fileHandle: FileHandle) throws {
        let initialized = """
        {"method":"initialized","params":{}}

        """
        let readRateLimits = """
        {"id":2,"method":"account/rateLimits/read"}

        """
        try fileHandle.write(contentsOf: Data(initialized.utf8))
        try fileHandle.write(contentsOf: Data(readRateLimits.utf8))
    }

}

private final class ResponseState: @unchecked Sendable {
    private struct Envelope: Decodable {
        var id: Int?
    }

    private let lock = NSLock()
    private let maximumBytes: Int
    private var buffer = Data()
    private var readOffset = 0
    private var storedResponse: Data?
    private var storedError: String?
    private var receivedInitializeResponse = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    var responseData: Data? {
        lock.withLock { storedResponse }
    }

    var errorMessage: String? {
        lock.withLock { storedError }
    }

    var hasInitializeResponse: Bool {
        lock.withLock { receivedInitializeResponse }
    }

    func consume(_ data: Data) {
        lock.withLock {
            guard storedResponse == nil, storedError == nil else { return }
            guard !data.isEmpty else { return }
            guard buffer.count - readOffset + data.count <= maximumBytes else {
                storedError = "Codex app-server response exceeded \(maximumBytes) bytes."
                return
            }

            buffer.append(data)
            while
                readOffset < buffer.endIndex,
                let newline = buffer[readOffset...].firstIndex(of: 0x0A)
            {
                let line = Data(buffer[readOffset..<newline])
                readOffset = buffer.index(after: newline)
                guard !line.isEmpty,
                      let envelope = try? JSONDecoder().decode(Envelope.self, from: line)
                else {
                    continue
                }
                if envelope.id == 1 {
                    receivedInitializeResponse = true
                } else if envelope.id == 2 {
                    storedResponse = line
                }
            }
            compactBufferIfNeeded()
        }
    }

    private func compactBufferIfNeeded() {
        guard readOffset >= 64 * 1_024, readOffset >= buffer.count / 2 else {
            return
        }
        buffer.removeSubrange(..<readOffset)
        readOffset = 0
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
