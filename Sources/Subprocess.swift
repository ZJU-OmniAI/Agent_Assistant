import Darwin
import Foundation

struct AssistantError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    var output: String { String(decoding: stdout, as: UTF8.self) }
    var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
}

/// A CLI process in its own process group, so stopping a request also stops
/// anything the CLI started. Output is read on background threads.
final class ChildProcess: @unchecked Sendable {
    let pid: pid_t
    private let input: Int32
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var status: Int32 = -1
    private var exited = false
    private(set) var exceeded = false
    private let maxOutput: Int
    private let onStdout: ((ChildProcess, Data) -> Void)?
    private let done = DispatchGroup()

    init(_ executable: String, _ arguments: [String], environment: [String: String], directory: String,
         maxOutput: Int = 4 << 20, onStdout: ((ChildProcess, Data) -> Void)? = nil) throws {
        self.maxOutput = maxOutput
        self.onStdout = onStdout
        var pipes: [[Int32]] = []
        for _ in 0..<3 {
            var ends: [Int32] = [0, 0]
            guard pipe(&ends) == 0 else {
                pipes.flatMap { $0 }.forEach { close($0) }
                throw AssistantError("无法创建进程管道。")
            }
            pipes.append(ends)
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, pipes[0][0], 0)
        posix_spawn_file_actions_adddup2(&actions, pipes[1][1], 1)
        posix_spawn_file_actions_adddup2(&actions, pipes[2][1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group; inherit only stdio; restore the SIGPIPE this app ignores.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var child: pid_t = 0
        let result = posix_spawn(&child, executable, &actions, &attributes, argv, envp)
        close(pipes[0][0]); close(pipes[1][1]); close(pipes[2][1])
        guard result == 0 else {
            close(pipes[0][1]); close(pipes[1][0]); close(pipes[2][0])
            throw AssistantError(result == ENOENT ? "未找到 CLI，请先安装并登录。" : "CLI 启动失败（错误 \(result)）。")
        }
        pid = child
        input = pipes[0][1]
        done.enter(); done.enter(); done.enter()
        let readers = DispatchQueue.global(qos: .userInitiated)
        readers.async { self.drain(pipes[1][0], isStdout: true); self.done.leave() }
        readers.async { self.drain(pipes[2][0], isStdout: false); self.done.leave() }
        readers.async {
            var raw: Int32 = 0
            while waitpid(child, &raw, 0) == -1 && errno == EINTR {}
            self.lock.lock()
            self.status = raw & 0x7f == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
            self.exited = true
            self.lock.unlock()
            // Reap anything the CLI left behind so its pipes reach end of file.
            kill(-child, SIGKILL)
            self.done.leave()
        }
    }

    private func drain(_ fd: Int32, isStdout: Bool) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            let chunk = Data(buffer[0..<count])
            lock.lock()
            var overflow = false
            if isStdout {
                if stdout.count + count > maxOutput { exceeded = true; overflow = true }
                else { stdout.append(chunk) }
            } else {
                stderr.append(chunk)
                if stderr.count > 8192 { stderr = stderr.suffix(8192) }
            }
            lock.unlock()
            if overflow { terminate() }
            else if isStdout { onStdout?(self, chunk) }
        }
        close(fd)
    }

    /// Writes everything, then closes standard input. Safe to call once.
    func finishInput(_ data: Data = Data()) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(input, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 { if errno == EINTR { continue } else { break } }
                offset += written
            }
        }
        close(input)
    }

    /// Writes one line without closing standard input.
    func send(_ line: String) {
        let data = Data((line + "\n").utf8)
        _ = data.withUnsafeBytes { Darwin.write(input, $0.baseAddress!, $0.count) }
    }

    func terminate() {
        lock.lock()
        let running = !exited
        lock.unlock()
        guard running else { return }
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [pid] in kill(-pid, SIGKILL) }
    }

    func wait() async -> ProcessResult {
        await withCheckedContinuation { continuation in
            done.notify(queue: .global()) {
                self.lock.lock()
                let result = ProcessResult(status: self.status, stdout: self.stdout, stderr: self.stderr)
                self.lock.unlock()
                continuation.resume(returning: result)
            }
        }
    }
}

enum Subprocess {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func run(_ executable: String, _ arguments: [String], input: Data = Data(), directory: String? = nil,
                    timeout: TimeInterval, maxOutput: Int = 2 << 20) async throws -> ProcessResult {
        let child = try ChildProcess(executable, arguments, environment: CLIEnvironment.current(),
                                     directory: directory ?? NSTemporaryDirectory(), maxOutput: maxOutput)
        DispatchQueue.global(qos: .userInitiated).async { child.finishInput(input) }
        let timedOut = Flag()
        let timer = DispatchWorkItem { timedOut.set(); child.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let result = await withTaskCancellationHandler { await child.wait() } onCancel: { child.terminate() }
        timer.cancel()
        try Task.checkCancellation()
        if timedOut.isSet { throw AssistantError("本机模型执行超过 \(Int(timeout)) 秒，已停止。") }
        if child.exceeded { throw AssistantError("模型输出超过上限。") }
        return result
    }

    static func temporaryDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }
}

/// Apps opened from Finder start with launchd's minimal environment: no nvm or
/// Homebrew on PATH and no proxy from ~/.zshrc. Borrow exactly those from the
/// user's login shell, like a CLI started in Terminal would see them.
enum CLIEnvironment {
    static let proxyKeys = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"].flatMap { [$0, $0.lowercased()] }
    private static let appCLIDirectories = ["ChatGPT.app/Contents/Resources/codex-cli/bin",
                                            "Codex.app/Contents/Resources/codex-cli/bin", "Codex.app/Contents/Resources"]

    private static let shellLock = NSLock()
    private static var shellCache: [String: String]?

    /// Blocks on first use; call `prepare()` at launch to load it in the background.
    static var shell: [String: String] {
        shellLock.lock()
        defer { shellLock.unlock() }
        if let shellCache { return shellCache }
        let loaded = loadShell()
        shellCache = loaded
        return loaded
    }

    static func prepare() { DispatchQueue.global(qos: .utility).async { _ = shell } }

    private static func loadShell() -> [String: String] {
        let process = ProcessInfo.processInfo.environment
        if process["AGENT_ASSISTANT_SKIP_SHELL"] == "1" { return [:] }
        let path = process["SHELL"] ?? getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        let marker = "__AGENT_ASSISTANT_ENV__"
        guard let child = try? ChildProcess(path, ["-ilc", "printf '\(marker)'; command env -0"], environment: process,
                                            directory: NSHomeDirectory(), maxOutput: 1 << 20) else { return [:] }
        child.finishInput()
        let semaphore = DispatchSemaphore(value: 0)
        var result: ProcessResult?
        Task.detached { result = await child.wait(); semaphore.signal() }
        if semaphore.wait(timeout: .now() + 8) == .timedOut { child.terminate(); return [:] }
        guard let result, let range = result.stdout.range(of: Data(marker.utf8)) else { return [:] }
        var values: [String: String] = [:]
        for entry in result.stdout[range.upperBound...].split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "=") else { continue }
            values[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return values
    }

    static func current() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let shell = shell
        for key in proxyKeys { if let value = shell[key] { environment[key] = value } }
        environment["PATH"] = searchPath(shell: shell).joined(separator: ":")
        environment["NO_COLOR"] = "1"
        environment.removeValue(forKey: "CLAUDECODE")
        return environment
    }

    static func searchPath(shell: [String: String]? = nil) -> [String] {
        let home = NSHomeDirectory()
        var directories = ((shell ?? self.shell)["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        directories += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let nvm = "\(home)/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []
        directories += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }
        for root in ["/Applications", "\(home)/Applications"] {
            directories += appCLIDirectories.map { "\(root)/\($0)" }
        }
        var seen = Set<String>()
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Several copies of a CLI often coexist (npm, Homebrew, the native installer,
/// the Codex CLI inside ChatGPT.app) and the first on PATH is frequently stale,
/// which hides new models. Use the newest copy whose --version works.
actor CLIResolver {
    static let shared = CLIResolver()

    struct Version: Comparable {
        let parts: [Int]
        let pre: [String]

        init?(_ text: String) {
            guard let match = text.range(of: #"(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?"#, options: .regularExpression) else { return nil }
            let token = String(text[match])
            let pieces = token.split(separator: "-", maxSplits: 1)
            parts = pieces[0].split(separator: ".").compactMap { Int($0) }
            pre = pieces.count > 1 ? pieces[1].split(separator: ".").map(String.init) : []
        }

        static func < (a: Version, b: Version) -> Bool {
            if a.parts != b.parts { return a.parts.lexicographicallyPrecedes(b.parts) }
            if a.pre.isEmpty || b.pre.isEmpty { return !a.pre.isEmpty && b.pre.isEmpty }
            for (x, y) in zip(a.pre, b.pre) where x != y {
                switch (Int(x), Int(y)) {
                case let (m?, n?): return m < n
                case (.some, nil): return true
                case (nil, .some): return false
                default: return x < y
                }
            }
            return a.pre.count < b.pre.count
        }
    }

    private var versions: [String: (stamp: String, version: Version?, at: Date)] = [:]

    func resolve(_ provider: String) async -> String? {
        if let override = ProcessInfo.processInfo.environment["AGENT_ASSISTANT_\(provider.uppercased())_BIN"] {
            return override
        }
        var best: (path: String, version: Version?)?
        var seen = Set<String>()
        for directory in CLIEnvironment.searchPath() {
            let path = "\(directory)/\(provider)"
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), !isDirectory.boolValue,
                  seen.insert(real).inserted else { continue }
            let version = await version(of: path, real: real)
            if best == nil || (version != nil && (best!.version == nil || best!.version! < version!)) {
                best = (path, version)
            }
        }
        return best?.path
    }

    private func version(of path: String, real: String) async -> Version? {
        let info = try? FileManager.default.attributesOfItem(atPath: real)
        let stamp = "\((info?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(info?[.size] ?? 0)"
        if let cached = versions[real], cached.stamp == stamp, Date().timeIntervalSince(cached.at) < 600 {
            return cached.version
        }
        var version: Version?
        if let result = try? await Subprocess.run(path, ["--version"], timeout: 7, maxOutput: 4096), result.status == 0 {
            version = Version(result.output)
        }
        versions[real] = (stamp, version, Date())
        return version
    }
}
