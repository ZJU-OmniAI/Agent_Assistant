import ApplicationServices
import SwiftUI

struct SettingsView: View {
    let updateMonitor: () -> Void
    let useClipboard: (Bool) -> Void
    @AppStorage("settingsTab") private var tab = "selection"
    @State private var catalog: [String: ProviderCatalog] = [:]
    @State private var loadingCatalog = false
    @State private var refresh = 0

    var body: some View {
        TabView(selection: $tab) {
            SelectionSettings(updateMonitor: updateMonitor, useClipboard: useClipboard)
                .tabItem { Label("划词", systemImage: "text.cursor") }.tag("selection")
            ModelSettings(catalog: catalog, loading: loadingCatalog) { refresh += 1 }
                .tabItem { Label("模型", systemImage: "cpu") }.tag("model")
            ResponseTimeView(catalog: catalog)
                .tabItem { Label("响应时间", systemImage: "stopwatch") }.tag("latency")
        }
        .padding(.top, 8)
        .task(id: refresh) {
            loadingCatalog = true
            catalog = await LocalCLI.modelCatalog(refresh: refresh > 0)
            loadingCatalog = false
        }
    }
}

private struct SelectionSettings: View {
    let updateMonitor: () -> Void
    let useClipboard: (Bool) -> Void
    @AppStorage("automaticSelection") private var automatic = true
    @AppStorage("copyFallback") private var copyFallback = true
    @AppStorage("language") private var language = "简体中文"
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section {
                Toggle("在鼠标附近显示「翻译 / 提问」", isOn: $automatic)
                    .onChange(of: automatic) { _ in updateMonitor() }
                HStack {
                    Label(trusted ? "已允许辅助功能" : "自动划词需要辅助功能权限",
                          systemImage: trusted ? "checkmark.circle" : "hand.raised")
                    Spacer()
                    if !trusted { Button("前往授权", action: requestAccess) }
                }
                if !trusted {
                    Text("若系统设置里的开关看起来已经打开，那是旧版本留下的失效授权，或页面没有刷新。先按 ⌘Q 退出系统设置，再点「前往授权」并打开开关，无需重启。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("读不到选区时用 ⌘C 取词（取完立即恢复剪贴板）", isOn: $copyFallback)
                Text("Chrome 自带的 PDF 阅读器、刚打开的网页、飞书等应用不向系统提供选区，需要这一项。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("译文语言", selection: $language) {
                    ForEach(["简体中文", "繁體中文", "English", "日本語", "한국어", "Français", "Deutsch", "Español"], id: \.self) { Text($0) }
                }
            } header: {
                Text("划词翻译与问答")
            } footer: {
                Text("在网页或 PDF 中拖选、双击文字，松开鼠标后点「翻译」或「提问」。")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("剪贴板入口") {
                HStack {
                    Button("翻译剪贴板文字") { useClipboard(true) }
                    Button("用剪贴板文字提问…") { useClipboard(false) }
                }
                Text("先选中文字并按 ⌘C，再点上面的按钮。此方式无需辅助功能权限。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshTrust()
        }
        // The grant usually happens in System Settings while this window stays open.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if !trusted { refreshTrust() }
        }
    }

    private func refreshTrust() {
        let now = AXIsProcessTrusted()
        if now != trusted { trusted = now }
        updateMonitor()
    }

    private func requestAccess() {
        // A grant made for an earlier, differently signed build stays visible as "on"
        // but no longer matches. Clear it once per build so the switch shows the real
        // state; clearing on every click could undo a grant made a moment ago.
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if UserDefaults.standard.string(forKey: "accessResetBuild") != build, let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.set(build, forKey: "accessResetBuild")
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", id]
            try? reset.run()
            reset.waitUntilExit()
        }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct ModelSettings: View {
    let catalog: [String: ProviderCatalog]
    let loading: Bool
    let refresh: () -> Void
    @AppStorage("provider") private var provider = "claude"
    @State private var testing = false
    @State private var status = ""
    @State private var probe: Task<Void, Never>?

    var body: some View {
        Form {
            Section("模型") {
                Picker("本机 CLI", selection: $provider) {
                    Text("Claude Code").tag("claude")
                    Text("Codex").tag("codex")
                }
                ModelPicker(provider: provider, models: catalog[provider]?.models ?? []).id(provider)
                HStack {
                    Button("刷新模型列表", action: refresh).disabled(loading)
                    if loading {
                        ProgressView().controlSize(.small)
                        Text("读取中…").font(.caption)
                    }
                }
                if let error = catalog[provider]?.error {
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section("连接") {
                Text("直接调用这台 Mac 上已登录的 Claude Code 或 Codex，沿用它们的登录和额度，不需要另外启动服务。找到多份时使用版本最新的一份。")
                    .font(.callout)
                HStack {
                    Button("检测 \(LocalCLI.displayName(provider))", action: test).disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    Text(status).font(.caption).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: provider) { _ in cancelTest() }
        .onDisappear { cancelTest() }
    }

    private func cancelTest() {
        probe?.cancel()
        testing = false
        status = ""
    }

    private func test() {
        testing = true
        status = ""
        let backend = Preferences.backend()
        probe = Task { @MainActor in
            let result: String
            do { result = try await backend.checkConnection() }
            catch { result = error.localizedDescription }
            guard !Task.isCancelled else { return }
            status = result
            testing = false
        }
    }
}

private struct ModelPicker: View {
    let provider: String
    let models: [CatalogModel]
    @AppStorage private var model: String
    @State private var editing = false
    @State private var draft = ""

    init(provider: String, models: [CatalogModel]) {
        self.provider = provider
        self.models = models
        _model = AppStorage(wrappedValue: "", Preferences.modelKey(for: provider))
    }

    var body: some View {
        Picker("使用模型", selection: $model) {
            Text("CLI 默认模型").tag("")
            ForEach(models) { item in
                Text(item.label.isEmpty ? item.id : item.label).tag(item.id)
            }
            if !model.isEmpty && !models.contains(where: { $0.id == model }) {
                Text(model).tag(model)
            }
        }
        .onChange(of: model) { _ in editing = false }
        EffortPicker(provider: provider, model: model, catalogModel: models.first { $0.id == model },
                     tiers: models.isEmpty ? nil : CatalogModel.serving(model, in: models)?.serviceTiers ?? [])
            .id(model)
        if editing {
            HStack {
                TextField("模型 ID", text: $draft).onSubmit { apply() }
                Button("应用", action: apply).disabled(!CatalogModel.accepts(draft.trimmed))
                Button("取消") { editing = false }
            }
            if !draft.isEmpty && !CatalogModel.accepts(draft.trimmed) {
                Text("请输入最长 160 个字符的模型 ID，以英文字母或数字开头，可包含 . _ : / -。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Button("输入自定义模型 ID…") {
                draft = model
                editing = true
            }
        }
    }

    private func apply() {
        let id = draft.trimmed
        guard CatalogModel.accepts(id) else { return }
        model = id == "default" ? "" : id
        editing = false
    }
}

private struct EffortPicker: View {
    @AppStorage private var effort: String
    @AppStorage(LatencyRun.historyKey) private var history = Data()
    @AppStorage("settingsTab") private var tab = "model"
    @AppStorage private var tier: String
    let provider: String
    let model: String
    let levels: [String]
    /// Speed tiers the model offers; nil while the catalog is unknown.
    let tiers: [ServiceTier]?

    init(provider: String, model: String, catalogModel: CatalogModel?, tiers: [ServiceTier]?) {
        self.provider = provider
        self.model = model
        _effort = AppStorage(wrappedValue: "default", Preferences.effortKey(provider: provider, model: model))
        _tier = AppStorage(wrappedValue: "", Preferences.serviceTierKey(provider: provider, model: model))
        levels = CatalogModel.effortLevels(provider: provider, model: catalogModel)
        self.tiers = provider == "codex" ? tiers : []
    }

    var body: some View {
        Picker("推理强度（effort）", selection: $effort) {
            ForEach(levels, id: \.self) { level in
                Text(level == "default" ? "CLI 默认" : level).tag(level)
            }
        }
        .disabled(levels.count == 1)
        .onAppear(perform: reconcile)
        .onChange(of: levels) { _ in reconcile() }
        .onChange(of: tiers) { _ in reconcile() }
        if let offered = tiers?.first {
            Toggle(isOn: Binding(get: { tier == offered.id }, set: { tier = $0 ? offered.id : "" })) {
                Text("快速模式（\(offered.name)）")
                Text("\(offered.summary)。只加快模型输出，命令行工具启动的几秒不变，所以回答越长越明显。")
            }
        }
        HStack(spacing: 6) {
            Image(systemName: "stopwatch").foregroundStyle(.secondary)
            Text(summary).font(.callout)
            Spacer()
            Button("查看全部") { tab = "latency" }.buttonStyle(.link)
        }
    }

    private var summary: String {
        _ = history // Re-render when a test saves new results.
        let key = LatencyRun.configurationKey(provider: provider, model: model, effort: effort, serviceTier: tier)
        guard let run = LatencyRun.latest()[key] else {
            return tier.isEmpty ? "响应时间：这个组合还没测过" : "响应时间：这个组合的快速模式还没测过"
        }
        if let median = run.median {
            let failures = run.samples.count - run.successfulTimes.count
            return String(format: "响应时间：%.2f 秒", median) + "（\(run.samples.count) 次中位数"
                + (failures > 0 ? "，\(failures) 次失败" : "") + (tier.isEmpty ? "" : "，快速模式") + "）"
        }
        return "响应时间：上次测试失败（\(run.samples.last?.error ?? "未知错误")）"
    }

    private func reconcile() {
        if !levels.contains(effort) { effort = "default" }
        // Drop a saved tier the model no longer offers, but only once the catalog is known.
        if !tier.isEmpty, let tiers, !tiers.contains(where: { $0.id == tier }) { tier = "" }
    }
}
