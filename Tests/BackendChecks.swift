import Foundation

func check(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    if !condition { print("FAIL (line \(line)): \(message())"); exit(1) }
}

func waitUntil(_ timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while await !condition() {
        guard Date() < deadline else { print("FAIL: timed out"); exit(1) }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

func lastCall(_ name: String, _ fixture: URL) -> [String: Any] {
    let text = (try? String(contentsOf: fixture.appendingPathComponent(name + ".log"), encoding: .utf8)) ?? ""
    let line = text.split(separator: "\n").last.map(String.init) ?? "{}"
    return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
}

@main
enum BackendChecks {
    @MainActor static func main() async throws {
        signal(SIGPIPE, SIG_IGN)
        let fixture = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIXTURE_DIR"]!)

        // Versions: a release outranks its pre-releases; numbers compare numerically.
        typealias V = CLIResolver.Version
        check(V("codex-cli 0.171.0-alpha.13.2")! < V("0.171.0")!, "pre-release order")
        check(V("1.2.9")! < V("1.2.10")! && V("2.0.0-beta.1")! < V("2.0.0-beta.2")!, "numeric order")
        check(V("no version") == nil, "unparsable version")
        check(CLIEnvironment.searchPath().contains { $0.hasSuffix("ChatGPT.app/Contents/Resources/codex-cli/bin") },
              "ChatGPT's bundled Codex CLI is searched")
        // An older codex comes first on PATH; the newest working copy must win.
        let codex = await CLIResolver.shared.resolve("codex")
        check(codex?.hasSuffix("/new/codex") == true, "newest codex resolved, got \(codex ?? "nil")")

        // Model catalog, including Codex pagination and Claude effort metadata.
        let started = Date()
        let catalog = await LocalCLI.modelCatalog(refresh: true)
        check(Date().timeIntervalSince(started) < 8, "catalog probe stops the CLI once answered")
        let claudeModels = catalog["claude"]?.models ?? []
        check(claudeModels.map(\.id) == ["sonnet", "haiku"], "claude models \(claudeModels.map(\.id)) \(catalog["claude"]?.error ?? "")")
        check(claudeModels[0].label == "Sonnet Fixture" && claudeModels[0].efforts == ["low", "high"], "claude efforts")
        check(claudeModels[1].efforts == [], "model without effort support")
        let codexModels = catalog["codex"]?.models ?? []
        check(codexModels.map(\.id) == ["gpt-fixture", "gpt-two"], "codex models \(codexModels.map(\.id)) \(catalog["codex"]?.error ?? "")")
        check(CatalogModel.effortLevels(provider: "codex", model: codexModels[0]) == ["default", "low", "high"], "codex efforts")
        check(CatalogModel.effortLevels(provider: "codex", model: codexModels[1]).count == 9, "fallback effort list")
        check(CatalogModel.accepts("custom/model:2.0") && !CatalogModel.accepts("not a model"), "model id rules")
        // Codex speed tiers: the valid one is kept and described in Chinese; the CLI default model is found.
        check(codexModels[0].serviceTiers == [ServiceTier(id: "priority", name: "Fast", description: "1.5x speed, increased usage")],
              "codex tiers \(codexModels[0].serviceTiers)")
        check(codexModels[0].serviceTiers[0].summary == "约 1.5 倍速度，额度消耗更多", codexModels[0].serviceTiers[0].summary)
        check(ServiceTier(id: "priority", name: "Fast", description: "2x speed").summary == "约 2 倍速度", "tier summary")
        check(codexModels[1].serviceTiers.isEmpty && claudeModels.allSatisfy { $0.serviceTiers.isEmpty }, "no tiers elsewhere")
        check(CatalogModel.serving("", in: codexModels)?.id == "gpt-fixture" && CatalogModel.serving("gpt-two", in: codexModels)?.id == "gpt-two",
              "default model lookup")

        // Connection status.
        let ready = try await LocalCLI(provider: "codex", model: "").checkConnection()
        check(ready.contains("99.0.0"), "codex status \(ready)")
        FileManager.default.createFile(atPath: fixture.appendingPathComponent("logged-out").path, contents: nil)
        do {
            _ = try await LocalCLI(provider: "claude", model: "").checkConnection()
            check(false, "expected login error")
        } catch { check(error.localizedDescription.contains("claude auth login"), error.localizedDescription) }
        try FileManager.default.removeItem(at: fixture.appendingPathComponent("logged-out"))

        // Generation through both CLIs, with model and effort flags.
        let source = "A distribution over actions.\n选中的多行原文。"
        let messages = Conversation(source: source).messages(asking: "翻译成简体中文。")
        let claude = LocalCLI(provider: "claude", model: "sonnet", effort: "high")
        check(try await claude.generate(messages) == "动作上的分布。", "claude reply")
        let claudeCall = lastCall("claude", fixture)
        let claudeArgs = claudeCall["args"] as? [String] ?? []
        check(claudeArgs.contains("--model") && claudeArgs.contains("sonnet") && claudeArgs.contains("--effort")
              && claudeArgs.contains("high") && claudeArgs.contains("--tools"), "claude args \(claudeArgs)")
        check((claudeCall["stdin"] as? String ?? "").contains("选中的多行原文"), "source text reaches the CLI")
        let codexCLI = LocalCLI(provider: "codex", model: "gpt-fixture", effort: "low")
        check(try await codexCLI.generate(messages) == "动作上的分布。", "codex reply read from -o file")
        let codexArgs = lastCall("codex", fixture)["args"] as? [String] ?? []
        check(codexArgs.contains("gpt-fixture") && codexArgs.contains("model_reasoning_effort=\"low\"")
              && codexArgs.contains("read-only"), "codex args \(codexArgs)")
        check(!codexArgs.joined(separator: " ").contains("service_tier"), "standard tier omits the flag")
        _ = try await LocalCLI(provider: "codex", model: "gpt-fixture", effort: "low", serviceTier: "priority").generate(messages)
        let fastArgs = lastCall("codex", fixture)["args"] as? [String] ?? []
        check(fastArgs.contains("service_tier=\"priority\""), "fast tier flag \(fastArgs)")
        do {
            _ = try await LocalCLI(provider: "claude", model: "", serviceTier: "priority").generate(messages)
            check(false, "claude has no service tier")
        } catch { check(error.localizedDescription.contains("不支持速度档位"), error.localizedDescription) }
        let plain = LocalCLI(provider: "claude", model: "")
        _ = try await plain.generate(messages)
        let plainArgs = lastCall("claude", fixture)["args"] as? [String] ?? []
        check(!plainArgs.contains("--model") && !plainArgs.contains("--effort"), "defaults omit flags")
        do {
            _ = try await LocalCLI(provider: "claude", model: "", effort: "ultra").generate(messages)
            check(false, "claude has no ultra effort")
        } catch { check(error.localizedDescription.contains("不支持推理强度"), error.localizedDescription) }

        // Errors are classified without forwarding the provider's text.
        let quota = Conversation(source: source).messages(asking: "触发额度")
        do { _ = try await claude.generate(quota); check(false, "expected quota error") }
        catch {
            check(error.localizedDescription.hasPrefix("本周模型额度已用尽") && error.localizedDescription.contains("重置时间：5pm（Asia/Shanghai）"),
                  error.localizedDescription)
        }
        do { _ = try await codexCLI.generate(quota); check(false, "expected quota error") }
        catch { check(error.localizedDescription.hasPrefix("模型使用额度已用尽"), error.localizedDescription) }

        // Conversation context keeps the source and the most recent turns.
        let longHistory = (1...12).map { Turn(question: "Q\($0)", answer: "A\($0)") }
        let trimmed = Conversation(source: source, turns: longHistory).messages(asking: "最新问题")
        check(trimmed.count == 2 + 2 * Conversation.contextTurns + 1 && trimmed[1].content == source, "context size")
        check(trimmed[2].content == "Q5" && trimmed.last?.content == "最新问题", "recent turns kept")

        // Preferences: per-provider model and per-model effort.
        let suite = "agent-assistant-checks-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        check(Preferences.backend(prefs).provider == "claude", "Claude Code is the default backend")
        prefs.set("claude", forKey: "provider")
        prefs.set("legacy-model", forKey: "model")
        Preferences.migrateModel(in: prefs)
        prefs.set("medium", forKey: Preferences.effortKey(provider: "claude", model: "legacy-model"))
        let configured = Preferences.backend(prefs)
        check(configured.model == "legacy-model" && configured.effort == "medium", "saved model and effort")
        prefs.set("codex", forKey: "provider")
        let switched = Preferences.backend(prefs)
        check(switched.model.isEmpty && switched.effort == "default" && switched.serviceTier.isEmpty, "switching backend keeps choices apart")
        prefs.set("priority", forKey: Preferences.serviceTierKey(provider: "codex", model: ""))
        check(Preferences.backend(prefs).serviceTier == "priority", "saved speed tier")
        prefs.set("priority", forKey: Preferences.serviceTierKey(provider: "claude", model: "legacy-model"))
        prefs.set("claude", forKey: "provider")
        check(Preferences.backend(prefs).serviceTier.isEmpty, "Claude Code ignores speed tiers")

        // Session: answer, failure and retry, stop, and switching models mid-conversation.
        UserDefaults.standard.setVolatileDomain(["provider": "claude", "model.claude": ""], forName: UserDefaults.argumentDomain)
        let session = Session(source: source)
        session.submit("请解释")
        try await waitUntil { session.pending == nil }
        check(session.failure == nil && session.conversation.turns.first?.answer == "解释成功", "session answer \(session.failure ?? "")")
        session.submit("请重试")
        try await waitUntil { session.pending == nil }
        check(session.failure != nil && session.conversation.turns.count == 1, "failure keeps history")
        session.retry()
        try await waitUntil { session.pending == nil }
        check(session.failure == nil && session.conversation.turns.last?.answer == "重试成功", "retry")

        session.submit("等待取消")
        try await waitUntil { FileManager.default.fileExists(atPath: fixture.appendingPathComponent("started").path) }
        let grandchild = pid_t(try String(contentsOf: fixture.appendingPathComponent("grandchild.pid"), encoding: .utf8))!
        session.stop()
        check(session.pending == nil && session.draft == "等待取消", "stop restores the draft")
        try await waitUntil(5) { kill(grandchild, 0) != 0 }

        UserDefaults.standard.setVolatileDomain(["provider": "codex", "model.codex": "gpt-fixture",
                                                Preferences.effortKey(provider: "codex", model: "gpt-fixture"): "high"],
                                               forName: UserDefaults.argumentDomain)
        session.submit("继续")
        try await waitUntil { session.pending == nil }
        check(session.conversation.turns.count == 3 && session.conversation.turns.last?.answer == "继续成功", "switch mid-conversation")
        let switchedCall = lastCall("codex", fixture)
        check((switchedCall["args"] as? [String] ?? []).contains("model_reasoning_effort=\"high\""), "new effort applied")
        check((switchedCall["stdin"] as? String ?? "").contains("解释成功"), "history carried across backends")

        // Response-time runs: three requests, saved per configuration.
        let latencySuite = "agent-assistant-latency-" + UUID().uuidString
        let latencyPrefs = UserDefaults(suiteName: latencySuite)!
        defer { latencyPrefs.removePersistentDomain(forName: latencySuite) }
        var updates = 0
        let run = try await LatencyRun.measure(backend: LocalCLI(provider: "claude", model: "sonnet", effort: "low"),
                                               label: "Sonnet Fixture") { partial in
            updates += 1
            LatencyRun.save(partial, in: latencyPrefs)
        }
        check(run.samples.count == 3 && run.successfulTimes.count == 3 && updates == 3 && run.median! > 0, "latency run")
        let latest = LatencyRun.latest(in: latencyPrefs)
        check(latest[LatencyRun.configurationKey(provider: "claude", model: "sonnet", effort: "low")]?.id == run.id, "latest by configuration")
        // Fast-tier runs are recorded apart from standard ones, and old records without a tier still load.
        let fastRun = try await LatencyRun.measure(backend: LocalCLI(provider: "codex", model: "gpt-fixture", effort: "low", serviceTier: "priority"),
                                                   label: "GPT Fixture") { LatencyRun.save($0, in: latencyPrefs) }
        let standardRun = try await LatencyRun.measure(backend: LocalCLI(provider: "codex", model: "gpt-fixture", effort: "low"),
                                                       label: "GPT Fixture") { LatencyRun.save($0, in: latencyPrefs) }
        let both = LatencyRun.latest(in: latencyPrefs)
        check(both[LatencyRun.configurationKey(provider: "codex", model: "gpt-fixture", effort: "low", serviceTier: "priority")]?.id == fastRun.id
              && both[LatencyRun.configurationKey(provider: "codex", model: "gpt-fixture", effort: "low")]?.id == standardRun.id
              && fastRun.serviceTier == "priority" && standardRun.serviceTier == nil, "tiers recorded apart")
        let legacy = #"[{"id":"\#(UUID().uuidString)","started":0,"provider":"codex","model":"m","label":"M","effort":"low","samples":[{"seconds":1}]}]"#
        latencyPrefs.set(Data(legacy.utf8), forKey: LatencyRun.historyKey)
        check(LatencyRun.history(in: latencyPrefs).first?.serviceTier == nil && LatencyRun.history(in: latencyPrefs).count == 1, "old records load")
        // Answers: Markdown blocks are laid out instead of showing raw symbols.
        let blocks = MarkdownBlock.parse("## 两个概念\n\n**Bootstrapping**：自举\n- 短时域\n  2) 子项\n> 注：一\n> 二\n---\n```\nV(s) ← r\n```\n| a | b |\n|---|---|\n#话题 不是标题")
        check(blocks == [.heading(level: 2, text: "两个概念"), .paragraph("**Bootstrapping**：自举"),
                         .bullet(indent: 0, marker: "•", text: "短时域"), .bullet(indent: 1, marker: "2.", text: "子项"),
                         .quote("注：一\n二"), .rule, .code("V(s) ← r"), .code("| a | b |\n|---|---|"),
                         .paragraph("#话题 不是标题")], "markdown blocks \(blocks)")
        check(MarkdownBlock.parse("```\n未闭合") == [.code("未闭合")], "unclosed fence")
        check(String(MarkdownText.inline("**粗** `x`").characters) == "粗 x", "inline markdown")
        print("All backend checks passed.")
    }
}
