import Foundation

/// One `claude -p` in stream-json mode that answers a single request.
///
/// It can be started before the question exists, and the answer is read from the result event
/// instead of waiting for the CLI to exit (~0.8 s). Closing its input ends it: the CLI exits by
/// itself within about a second, which also happens if Agent Assistant quits or crashes.
final class ClaudeProcess: @unchecked Sendable {
    enum Outcome {
        case result(Data)
        case exited(ProcessResult)
    }

    let key: String
    private let workdir: URL
    private let lock = NSLock()
    private var child: ChildProcess?
    private var buffer = Data()
    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Error>?
    private var inputClosed = false
    private var hasExited = false

    var pid: pid_t { lock.lock(); defer { lock.unlock() }; return child?.pid ?? 0 }
    var exited: Bool { lock.lock(); defer { lock.unlock() }; return hasExited }

    private init(key: String, workdir: URL) {
        self.key = key
        self.workdir = workdir
    }

    static func start(_ bin: String, _ arguments: [String], key: String) throws -> ClaudeProcess {
        let workdir = try Subprocess.temporaryDirectory("agent-assistant-")
        let process = ClaudeProcess(key: key, workdir: workdir)
        let child: ChildProcess
        do {
            child = try ChildProcess(bin, arguments, environment: CLIEnvironment.current(), directory: workdir.path,
                                     retainOutput: false) { [weak process] _, chunk in process?.receive(chunk) }
        } catch {
            try? FileManager.default.removeItem(at: workdir)
            throw error
        }
        process.attach(child)
        Task.detached {
            let result = await child.wait()
            process.finished(result)
        }
        return process
    }

    /// Sends the question and closes input, then waits for the result event.
    func answer(_ prompt: String, timeout: TimeInterval) async throws -> Outcome {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": prompt]]
        closeInput(try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8))
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(AssistantError("本机模型执行超过 \(Int(timeout)) 秒，已停止。")))
            self?.stop()
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    /// Ends an unused process: closing input lets the CLI exit; stop it if it lingers.
    func dismiss() {
        closeInput(Data())
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.exited == false { self?.stop() }
        }
    }

    /// Stops the CLI and everything it started.
    func stop() {
        lock.lock(); let process = child; lock.unlock()
        process?.terminate()
    }

    private func attach(_ process: ChildProcess) {
        lock.lock(); child = process; lock.unlock()
    }

    private func closeInput(_ data: Data) {
        lock.lock()
        guard !inputClosed, let process = child else { lock.unlock(); return }
        inputClosed = true
        lock.unlock()
        // A long question may exceed the pipe buffer; never block the caller on it.
        DispatchQueue.global(qos: .userInitiated).async { process.finishInput(data) }
    }

    private func receive(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var lines: [Data] = []
        while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(Data(buffer[buffer.startIndex..<end]))
            buffer.removeSubrange(buffer.startIndex...end)
        }
        lock.unlock()
        for line in lines {
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  event["type"] as? String == "result" else { continue }
            finish(.success(.result(line)))
        }
    }

    private func finished(_ result: ProcessResult) {
        lock.lock(); hasExited = true; lock.unlock()
        try? FileManager.default.removeItem(at: workdir)
        finish(.success(.exited(result)))
    }

    private func finish(_ value: Result<Outcome, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        if case .success(let settled) = value { outcome = settled }
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: value)
    }
}

/// Starts Claude Code just before it is needed, and only then.
///
/// A Claude Code process takes ~0.5 s to start and uses ~230 MB, so none is kept running.
/// One is started when the user shows intent (the Translate/Ask strip appears, or they type
/// a follow-up) and answers the next request. An unused one ends after `lifetime` seconds,
/// when the chat panel closes, or when the model or effort changes.
actor ClaudeWarmup {
    static let shared = ClaudeWarmup()

    /// Set `AGENT_ASSISTANT_CLAUDE_WARMUP=0` to start Claude Code only when a request is sent.
    nonisolated(unsafe) static var enabled = ProcessInfo.processInfo.environment["AGENT_ASSISTANT_CLAUDE_WARMUP"] != "0"
    nonisolated(unsafe) static var lifetime: TimeInterval = 30

    private var spare: ClaudeProcess?
    private var deadline = Date()
    private var expiry: Task<Void, Never>?

    var spareProcessID: pid_t? { spare.map(\.pid) }

    static func key(_ cli: LocalCLI) -> String { [cli.model.trimmed, cli.effort].joined(separator: "|") }

    /// Starts a process for these settings, or keeps the matching one for another `lifetime`.
    func prepare(_ cli: LocalCLI) async {
        guard Self.enabled, cli.provider == "claude" else { return }
        if let spare, spare.key == Self.key(cli), !spare.exited {
            extend()
            return
        }
        discard()
        guard let bin = await CLIResolver.shared.resolve("claude"),
              let process = try? ClaudeProcess.start(bin, cli.arguments(workdir: "", output: ""), key: Self.key(cli)) else { return }
        if spare != nil {
            // Another call prepared one while the CLI path was being looked up.
            process.dismiss()
        } else {
            spare = process
        }
        extend()
    }

    /// The prepared process, if it matches these settings; otherwise it is ended.
    func take(_ cli: LocalCLI) -> ClaudeProcess? {
        guard let spare else { return nil }
        self.spare = nil
        expiry?.cancel()
        if spare.key == Self.key(cli), !spare.exited { return spare }
        spare.dismiss()
        return nil
    }

    func discard() {
        spare?.dismiss()
        spare = nil
        expiry?.cancel()
    }

    private func extend() {
        deadline = Date().addingTimeInterval(Self.lifetime)
        expiry?.cancel()
        expiry = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.lifetime * 1e9))
            guard !Task.isCancelled else { return }
            self.expire()
        }
    }

    private func expire() {
        if Date() >= deadline.addingTimeInterval(-0.05) { discard() }
    }
}
