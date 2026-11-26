import Foundation

/// Keeps one `codex app-server` running with a conversation already started and warmed up.
///
/// `codex exec` repeats the same work for every request: it fetches the model list, syncs
/// plugins, opens and warms a connection, and shuts down after answering. Of the ~5.7 s a
/// short translation took, the model itself needed under 2 s. Here that work happens once,
/// and the next conversation is prepared while the user is still selecting text.
///
/// Anything that goes wrong before Codex accepts the question throws `Unavailable`, and the
/// caller falls back to `codex exec`. Model errors such as an exhausted quota are reported as usual.
actor CodexServer {
    static let shared = CodexServer()

    /// Set `AGENT_ASSISTANT_CODEX_SERVER=0` to always use `codex exec`.
    nonisolated(unsafe) static var enabled = ProcessInfo.processInfo.environment["AGENT_ASSISTANT_CODEX_SERVER"] != "0"
    nonisolated(unsafe) static var idleTimeout: TimeInterval = 900
    /// A prepared conversation older than this is replaced; its connection may have gone stale.
    static let spareLifetime: TimeInterval = 600
    /// After a failed start, use `codex exec` for a while instead of retrying every request.
    static let retryAfterFailure: TimeInterval = 300

    /// Features a text-only assistant never uses; each adds startup work, tools or child processes.
    /// Written as `-c features.x=false`: CLIs that do not know a name ignore it, while
    /// `--disable x` would refuse to start.
    static let unusedFeatures = ["plugins", "remote_plugin", "apps", "browser_use", "browser_use_external", "computer_use",
                                 "in_app_browser", "image_generation", "code_mode_host", "goals", "sleep_tool", "tool_suggest",
                                 "unified_exec", "shell_tool", "shell_snapshot", "view_image", "hooks", "multi_agent",
                                 "skill_search", "workspace_dependencies"]

    struct Unavailable: Error { let reason: String }

    private struct Spare {
        let thread: String
        let model: String
        let tier: String
        let created: Date
        let workdir: URL
        let link: Link
    }

    private var link: Link?
    private var connecting: Task<Link, Error>?
    private var spare: Spare?
    private var preparation: Task<Void, Never>?
    private var failedAt: Date?
    private var lastUse = Date()
    private var idleTask: Task<Void, Never>?

    var isRunning: Bool { link.map { !$0.closed } ?? false }
    var spareThreadID: String? { spare?.thread }

    // MARK: Requests

    /// Prepares a warmed-up conversation for the current settings. Cheap when one is ready.
    func prepare(_ cli: LocalCLI) async {
        guard Self.enabled, cli.provider == "codex" else { return }
        touch()
        // One preparation at a time; a second caller waits for it and reuses the result.
        if let preparation { await preparation.value }
        if let spare, matches(spare, cli), !spare.link.closed { return }
        let task = Task { await self.makeSpare(cli) }
        preparation = task
        await task.value
        if preparation == task { preparation = nil }
    }

    private func makeSpare(_ cli: LocalCLI) async {
        do {
            let link = try await connect()
            let fresh = try await startThread(link, cli)
            if let old = spare { discard(old) }
            spare = fresh
        } catch {}
    }

    func generate(prompt: String, cli: LocalCLI) async throws -> String {
        guard Self.enabled else { throw Unavailable(reason: "disabled") }
        touch()
        // A click right after selecting text: the conversation is already being set up.
        if let preparation { await preparation.value }
        defer {
            touch()
            Task { await self.prepare(cli) }
        }
        let link = try await connect()
        let thread: Spare
        if let spare, matches(spare, cli), spare.link === link, !link.closed {
            thread = spare
            self.spare = nil
        } else {
            thread = try await startThread(link, cli)
        }
        defer { discard(thread) }

        let turn = Turn()
        link.listen(thread.thread) { method, params in turn.handle(method, params) }
        defer { link.unlisten(thread.thread) }
        var params: [String: Any] = ["threadId": thread.thread, "input": [["type": "text", "text": prompt]],
                                     "serviceTierForTurn": cli.serviceTier.isEmpty ? "default" : cli.serviceTier]
        if !cli.model.trimmed.isEmpty { params["model"] = cli.model.trimmed }
        if cli.effort != "default" { params["effort"] = cli.effort }
        // Rejected before the turn began, e.g. by an older CLI: `codex exec` reports it properly.
        let started: [String: Any]
        do { started = try await link.request("turn/start", params) }
        catch { throw Unavailable(reason: "turn/start: \(error)") }
        let turnID = (started["turn"] as? [String: Any])?["id"] as? String
        let threadID = thread.thread

        return try await withTaskCancellationHandler {
            switch try await turn.result(timeout: LocalCLI.generationTimeout) {
            case .answer(let text): return text
            case .failed(let message, let code): throw AssistantError(cli.failure(Self.result(message, code: code)))
            }
        } onCancel: {
            if let turnID { link.post("turn/interrupt", ["threadId": threadID, "turnId": turnID]) }
            turn.cancel()
        }
    }

    /// Stops the server. The next request starts a new one, even right after a failed start.
    func shutdown() {
        failedAt = nil
        if let spare { discard(spare) }
        spare = nil
        link?.close()
        link = nil
        connecting?.cancel()
        connecting = nil
        idleTask?.cancel()
    }

    // MARK: Internals

    private func matches(_ spare: Spare, _ cli: LocalCLI) -> Bool {
        spare.model == cli.model.trimmed && spare.tier == cli.serviceTier
            && Date().timeIntervalSince(spare.created) < Self.spareLifetime
    }

    private func touch() {
        lastUse = Date()
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.idleTimeout * 1e9))
            guard !Task.isCancelled else { return }
            self.shutdownIfIdle()
        }
    }

    private func shutdownIfIdle() {
        if Date().timeIntervalSince(lastUse) >= Self.idleTimeout * 0.99 { shutdown() }
    }

    private func discard(_ spare: Spare) {
        spare.link.post("thread/unsubscribe", ["threadId": spare.thread])
        try? FileManager.default.removeItem(at: spare.workdir)
    }

    private func connect() async throws -> Link {
        if let link, !link.closed { return link }
        link = nil
        if let spare { discard(spare); self.spare = nil }
        if let failedAt, Date().timeIntervalSince(failedAt) < Self.retryAfterFailure {
            throw Unavailable(reason: "recent start failure")
        }
        if let connecting { return try await connecting.value }
        let task = Task { () throws -> Link in
            guard let bin = await CLIResolver.shared.resolve("codex") else { throw Unavailable(reason: "no codex") }
            return try await Link.start(bin)
        }
        connecting = task
        defer { connecting = nil }
        do {
            let started = try await task.value
            link = started
            failedAt = nil
            return started
        } catch {
            failedAt = Date()
            throw (error as? Unavailable) ?? Unavailable(reason: "\(error)")
        }
    }

    private func startThread(_ link: Link, _ cli: LocalCLI) async throws -> Spare {
        let workdir: URL
        do { workdir = try Subprocess.temporaryDirectory("agent-assistant-codex-") }
        catch { throw Unavailable(reason: "workdir") }
        var params: [String: Any] = ["ephemeral": true, "cwd": workdir.path, "approvalPolicy": "never",
                                     "sandbox": "read-only", "config": link.threadConfig]
        if !cli.model.trimmed.isEmpty { params["model"] = cli.model.trimmed }
        if !cli.serviceTier.isEmpty { params["serviceTier"] = cli.serviceTier }
        do {
            let result = try await link.request("thread/start", params)
            guard let id = (result["thread"] as? [String: Any])?["id"] as? String else { throw Unavailable(reason: "no thread id") }
            return Spare(thread: id, model: cli.model.trimmed, tier: cli.serviceTier, created: Date(), workdir: workdir, link: link)
        } catch {
            try? FileManager.default.removeItem(at: workdir)
            throw (error as? Unavailable) ?? Unavailable(reason: "thread/start: \(error)")
        }
    }

    /// Shapes a turn error like a `codex exec` event so the usual classification applies.
    static func result(_ message: String, code: String?) -> ProcessResult {
        let event: [String: Any] = ["type": "turn.failed", "error": ["message": message]]
        let line = (try? JSONSerialization.data(withJSONObject: event)) ?? Data()
        // "usageLimitExceeded" → "usage_limit_exceeded", which the classifier recognises.
        let snake = (code ?? "").replacingOccurrences(of: "([a-z])([A-Z])", with: "$1_$2", options: .regularExpression).lowercased()
        return ProcessResult(status: 1, stdout: line, stderr: Data(snake.utf8))
    }

    // MARK: Turn

    /// Collects one turn's answer from notifications, which may arrive before anyone waits.
    private final class Turn: @unchecked Sendable {
        enum Outcome { case answer(String), failed(String, String?) }
        private let lock = NSLock()
        private var text = ""
        private var error: (String, String?)?
        private var outcome: Result<Outcome, Error>?
        private var continuation: CheckedContinuation<Outcome, Error>?

        func handle(_ method: String, _ params: [String: Any]) {
            switch method {
            case "item/completed":
                let item = params["item"] as? [String: Any]
                if item?["type"] as? String == "agentMessage", let value = item?["text"] as? String, !value.trimmed.isEmpty {
                    lock.lock(); text = value; lock.unlock()
                }
            case "error":
                guard params["willRetry"] as? Bool != true, let detail = params["error"] as? [String: Any] else { return }
                lock.lock(); error = (detail["message"] as? String ?? "", Self.code(detail)); lock.unlock()
            case "turn/completed":
                let turn = params["turn"] as? [String: Any]
                switch turn?["status"] as? String {
                case "completed":
                    lock.lock(); let answer = text.trimmed; lock.unlock()
                    finish(answer.isEmpty ? .failure(AssistantError("模型没有返回内容。")) : .success(.answer(answer)))
                case "interrupted":
                    finish(.failure(CancellationError()))
                default:
                    let detail = turn?["error"] as? [String: Any]
                    lock.lock(); let earlier = error; lock.unlock()
                    finish(.success(.failed(detail?["message"] as? String ?? earlier?.0 ?? "",
                                            detail.flatMap(Self.code) ?? earlier?.1)))
                }
            case Link.closedMethod:
                finish(.failure(AssistantError("Codex 后台服务意外退出，请重试。")))
            default:
                break
            }
        }

        private static func code(_ detail: [String: Any]) -> String? {
            let info = detail["codexErrorInfo"]
            return info as? String ?? (info as? [String: Any])?.keys.first
        }

        func cancel() { finish(.failure(CancellationError())) }

        private func finish(_ value: Result<Outcome, Error>) {
            lock.lock()
            guard outcome == nil else { lock.unlock(); return }
            outcome = value
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(with: value)
        }

        func result(timeout: TimeInterval) async throws -> Outcome {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(AssistantError("本机模型执行超过 \(Int(timeout)) 秒，已停止。")))
            }
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let outcome { lock.unlock(); continuation.resume(with: outcome); return }
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

/// JSON-RPC over the standard input and output of one `codex app-server` process.
final class Link: @unchecked Sendable {
    static let closedMethod = "agent-assistant/closed"
    struct RemoteError: Error { let message: String }

    private let lock = NSLock()
    private var child: ChildProcess?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var listeners: [String: (String, [String: Any]) -> Void] = [:]
    private var isClosed = false
    private let workdir: URL
    /// Per-conversation overrides: the user's MCP servers stay off.
    private(set) var threadConfig: [String: Any] = [:]

    var closed: Bool { lock.lock(); defer { lock.unlock() }; return isClosed }

    private init(workdir: URL) { self.workdir = workdir }

    static func start(_ bin: String) async throws -> Link {
        let workdir = try Subprocess.temporaryDirectory("agent-assistant-codex-server-")
        let link = Link(workdir: workdir)
        // The user's config still supplies login, default model and effort; its notify program
        // (run after every answer) and project docs are switched off.
        var arguments = ["app-server", "-c", #"approval_policy="never""#, "-c", #"web_search="disabled""#,
                         "-c", "project_doc_max_bytes=0", "-c", "notify=[]"]
        for feature in CodexServer.unusedFeatures { arguments += ["-c", "features.\(feature)=false"] }
        do {
            let child = try ChildProcess(bin, arguments, environment: CLIEnvironment.current(), directory: workdir.path,
                                         retainOutput: false) { [weak link] _, chunk in link?.receive(chunk) }
            link.attach(child)
            Task.detached { [weak link] in
                _ = await child.wait()
                link?.close()
            }
            _ = try await link.request("initialize", ["clientInfo": ["name": "agent-assistant", "version": "1.0"]], timeout: 20)
            link.post("initialized", nil)
            let config = try await link.request("config/read", [:], timeout: 20)
            let servers = ((config["config"] as? [String: Any])?["mcp_servers"] as? [String: Any])?.keys.sorted() ?? []
            link.threadConfig = servers.isEmpty ? [:] : ["mcp_servers": Dictionary(uniqueKeysWithValues: servers.map { ($0, ["enabled": false]) })]
            return link
        } catch {
            link.close()
            throw CodexServer.Unavailable(reason: "start: \(error)")
        }
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !isClosed else {
                lock.unlock()
                continuation.resume(throwing: CodexServer.Unavailable(reason: "closed"))
                return
            }
            let id = nextID
            nextID += 1
            pending[id] = continuation
            lock.unlock()
            write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(id, .failure(CodexServer.Unavailable(reason: "\(method) timed out")))
            }
        }
    }

    /// A notification, or a request whose answer nobody waits for.
    func post(_ method: String, _ params: [String: Any]?) {
        if method == "initialized" {
            write(["jsonrpc": "2.0", "method": method])
            return
        }
        lock.lock()
        let id = nextID
        nextID += 1
        lock.unlock()
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params ?? [:]])
    }

    private func attach(_ process: ChildProcess) {
        lock.lock(); child = process; lock.unlock()
    }

    func listen(_ thread: String, _ handler: @escaping (String, [String: Any]) -> Void) {
        lock.lock(); listeners[thread] = handler; lock.unlock()
    }

    func unlisten(_ thread: String) {
        lock.lock(); listeners[thread] = nil; lock.unlock()
    }

    func close() {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        let waiting = pending
        pending = [:]
        let handlers = Array(listeners.values)
        listeners = [:]
        let process = child
        lock.unlock()
        process?.terminate()
        try? FileManager.default.removeItem(at: workdir)
        waiting.values.forEach { $0.resume(throwing: CodexServer.Unavailable(reason: "closed")) }
        handlers.forEach { $0(Self.closedMethod, [:]) }
    }

    private func write(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        lock.lock(); let process = isClosed ? nil : child; lock.unlock()
        process?.send(String(decoding: data, as: UTF8.self))
    }

    private func resolve(_ id: Int, _ value: Result<[String: Any], Error>) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(with: value)
    }

    private func receive(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var lines: [Data] = []
        while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(buffer[buffer.startIndex..<end])
            buffer.removeSubrange(buffer.startIndex...end)
        }
        lock.unlock()
        for line in lines {
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let method = message["method"] as? String
            if let id = message["id"] as? Int, method == nil {
                if let error = message["error"] as? [String: Any] {
                    resolve(id, .failure(RemoteError(message: error["message"] as? String ?? "")))
                } else {
                    resolve(id, .success(message["result"] as? [String: Any] ?? [:]))
                }
            } else if let method, let id = message["id"] {
                // A request from Codex, such as an approval. Nothing here may run tools, so decline.
                write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "not supported by Agent Assistant: \(method)"]])
            } else if let method {
                let params = message["params"] as? [String: Any] ?? [:]
                guard let thread = params["threadId"] as? String else { continue }
                lock.lock(); let handler = listeners[thread]; lock.unlock()
                handler?(method, params)
            }
        }
    }
}
