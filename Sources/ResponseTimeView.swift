import SwiftUI

/// Latest response times as a model × effort grid. Clicking a cell selects that combination.
struct ResponseTimeView: View {
    let catalog: [String: ProviderCatalog]
    @AppStorage(LatencyRun.historyKey) private var history = Data()
    @AppStorage("provider") private var provider = "claude"
    @State private var shown: String?
    @State private var task: Task<Void, Never>?
    @State private var status = ""
    @State private var chosen = 0
    @State private var tierShown: String?

    private struct Row: Identifiable {
        let id: String // model ID, "" for the CLI default
        let label: String
    }

    private var current: String { shown ?? provider }

    /// The Codex speed tier whose results are shown: the saved choice until the user flips the switch.
    private var currentTier: String {
        guard current == "codex" else { return "" }
        if let tierShown { return tierShown }
        let model = UserDefaults.standard.string(forKey: Preferences.modelKey(for: current)) ?? ""
        return Preferences.serviceTier(provider: current, model: model)
    }

    /// The faster tier Codex offers (normally "priority"), from the catalog or earlier results.
    private func offeredTier(_ latest: [String: LatencyRun]) -> ServiceTier? {
        if let tier = (catalog["codex"]?.models ?? []).lazy.compactMap({ $0.serviceTiers.first }).first { return tier }
        return latest.values.first { $0.provider == "codex" && $0.serviceTier != nil }
            .map { ServiceTier(id: $0.serviceTier!, name: "Fast", description: "") }
    }

    var body: some View {
        let latest = decode()
        let offered = current == "codex" ? offeredTier(latest) : nil
        let tier = offered == nil ? "" : currentTier
        let runs = latest.values.filter { $0.provider == current && ($0.serviceTier ?? "") == tier }
        let rows = rows(for: runs)
        let columns = (["default"] + (LocalCLI.efforts[current] ?? [])).filter { level in runs.contains { $0.effort == level } }
        let medians = runs.compactMap { $0.successfulTimes.count == $0.samples.count ? $0.median : nil }
        let fastest = medians.min() ?? 0, slowest = medians.max() ?? 0

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("后端", selection: Binding(get: { current }, set: { shown = $0 })) {
                    Text("Claude Code").tag("claude")
                    Text("Codex").tag("codex")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                if let offered {
                    Picker("速度", selection: Binding(get: { tier }, set: { tierShown = $0 })) {
                        Text("标准").tag("")
                        Text("快速").tag(offered.id)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                    .help("快速模式（\(offered.name)）的结果单独记录")
                }
                Spacer()
                if task != nil {
                    ProgressView().controlSize(.small)
                    Button("停止") { task?.cancel() }
                }
                Button("测试当前组合（3 次）", action: start).disabled(task != nil)
            }
            Text("每格是把同一句英文译成简体中文、连续 3 次的中位耗时（秒）：像实际使用一样，划词后约 1 秒点「翻译」，从点击算到收到完整译文。2026-11-27 之前测的格子是旧方式（每次重新启动 CLI），偏慢。点格子即可改用该模型和推理强度。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }

            if rows.isEmpty {
                Spacer()
                Text(tier.isEmpty ? "还没有 \(LocalCLI.displayName(current)) 的测试结果。在「模型」页选好模型和推理强度后，点右上角「测试当前组合」。"
                     : "还没有快速模式的测试结果。在「模型」页打开快速模式后，点右上角「测试当前组合」。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(.vertical) {
                    Grid(alignment: .center, horizontalSpacing: 3, verticalSpacing: 3) {
                        GridRow {
                            Text("模型").font(.caption.weight(.semibold)).frame(width: 150, alignment: .leading)
                            ForEach(columns, id: \.self) { level in
                                Text(level == "default" ? "CLI 默认" : level)
                                    .font(.caption.weight(.semibold)).frame(width: 64)
                            }
                        }
                        Divider().gridCellColumns(columns.count + 1)
                        ForEach(rows) { row in
                            GridRow {
                                Text(row.label).lineLimit(1).truncationMode(.middle)
                                    .frame(width: 150, alignment: .leading).help(row.id.isEmpty ? "CLI 默认模型" : row.id)
                                ForEach(columns, id: \.self) { level in
                                    cell(latest[LatencyRun.configurationKey(provider: current, model: row.id, effort: level, serviceTier: tier)],
                                         model: row.id, effort: level, tier: tier, fastest: fastest, slowest: slowest)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 160, maxHeight: .infinity)
                .monospacedDigit()
                summary(runs: runs)
            }
        }
        .padding(16)
        .onDisappear { task?.cancel() }
    }

    private func decode() -> [String: LatencyRun] {
        _ = (history, chosen) // Re-render when a test saves results or a cell is chosen.
        return LatencyRun.latest()
    }

    private func rows(for runs: [LatencyRun]) -> [Row] {
        var labels: [String: String] = [:]
        for run in runs.sorted(by: { $0.started < $1.started }) { labels[run.model] = run.label }
        let order = (catalog[current]?.models ?? []).map(\.id)
        return labels.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return a.isEmpty } // CLI default first
            let x = order.firstIndex(of: a) ?? Int.max, y = order.firstIndex(of: b) ?? Int.max
            return x != y ? x < y : (labels[a] ?? a).localizedStandardCompare(labels[b] ?? b) == .orderedAscending
        }.map { id in
            Row(id: id, label: catalog[current]?.models?.first { $0.id == id }?.label ?? labels[id] ?? id)
        }
    }

    @ViewBuilder
    private func cell(_ run: LatencyRun?, model: String, effort: String, tier: String, fastest: Double, slowest: Double) -> some View {
        let selected = provider == current
            && (UserDefaults.standard.string(forKey: Preferences.modelKey(for: current)) ?? "") == model
            && (UserDefaults.standard.string(forKey: Preferences.effortKey(provider: current, model: model)) ?? "default") == effort
            && Preferences.serviceTier(provider: current, model: model) == tier
        let failures = run.map { $0.samples.count - $0.successfulTimes.count } ?? 0
        let text: String = {
            guard let run else { return "—" }
            if let median = run.median { return String(format: failures > 0 ? "%.2f*" : "%.2f", median) }
            return (run.samples.last?.error ?? "").contains("额度") ? "额度" : "失败"
        }()
        let fill: Color = {
            guard let run else { return .clear }
            guard let median = run.median else { return .orange.opacity(0.16) }
            let position = slowest > fastest ? (median - fastest) / (slowest - fastest) : 0
            return .green.opacity(0.08 + 0.32 * (1 - min(max(position, 0), 1)))
        }()
        Button {
            choose(model: model, effort: effort, tier: tier)
        } label: {
            Text(text)
                .font(.callout)
                .foregroundStyle(run?.median == nil && run != nil ? Color.orange : Color.primary)
                .frame(width: 64, height: 24)
                .background(fill, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip(run, effort: effort))
    }

    private func tooltip(_ run: LatencyRun?, effort: String) -> String {
        guard let run else { return "还没测过。点一下改用这个组合，再点「测试当前组合」。" }
        let date = run.started.formatted(date: .abbreviated, time: .shortened)
        let times = run.successfulTimes
        var lines = ["\(run.label) · \(effort == "default" ? "CLI 默认" : effort)" + (run.serviceTier == nil ? "" : " · 快速模式")]
        if let first = times.first, let last = times.last, let median = run.median {
            lines.append(String(format: "中位 %.2f 秒，最快 %.2f，最慢 %.2f", median, first, last))
        }
        lines.append("成功 \(times.count)/\(run.samples.count) 次 · 测于 \(date)")
        if let error = run.samples.last?.error { lines.append(error) }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func summary(runs: [LatencyRun]) -> some View {
        let complete = runs.filter { $0.median != nil && $0.successfulTimes.count == $0.samples.count }
        let best = complete.min { $0.median! < $1.median! }
        HStack(spacing: 14) {
            Text("共 \(runs.count) 组，\(complete.count) 组全部成功")
            if let best, let median = best.median {
                Text("最快：\(best.label) · \(best.effort == "default" ? "CLI 默认" : best.effort) · \(String(format: "%.2f", median)) 秒")
            }
            Spacer()
            Text("绿色越深越快　* 有失败　蓝框为当前使用").foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func choose(model: String, effort: String, tier: String) {
        let defaults = UserDefaults.standard
        defaults.set(current, forKey: "provider")
        defaults.set(model, forKey: Preferences.modelKey(for: current))
        defaults.set(effort, forKey: Preferences.effortKey(provider: current, model: model))
        if current == "codex" { defaults.set(tier, forKey: Preferences.serviceTierKey(provider: current, model: model)) }
        provider = current
        chosen += 1
    }

    @MainActor private func start() {
        guard task == nil else { return }
        let backend = Preferences.backend()
        shown = backend.provider
        tierShown = backend.provider == "codex" ? backend.serviceTier : nil
        let id = backend.model
        let label = catalog[backend.provider]?.models?.first { $0.id == id }?.label
            ?? (id.isEmpty ? "\(backend.displayName) 默认模型" : id)
        let configuration = "\(label) · \(backend.effort == "default" ? "CLI 默认" : backend.effort)"
            + (backend.serviceTier.isEmpty ? "" : " · 快速模式")
        status = "\(configuration) · 正在测试 1/\(LatencyRun.repetitions)"
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let result = try await LatencyRun.measure(backend: backend, label: label) { partial in
                    LatencyRun.save(partial)
                    if partial.samples.count < LatencyRun.repetitions {
                        status = "\(configuration) · 正在测试 \(partial.samples.count + 1)/\(LatencyRun.repetitions)"
                    }
                }
                if let error = result.samples.last?.error {
                    status = "\(configuration) · 测试失败：\(error)"
                } else {
                    status = "\(configuration) · 已完成 \(result.samples.count) 次，中位 \(String(format: "%.2f", result.median ?? 0)) 秒"
                }
            } catch is CancellationError {
                status = "\(configuration) · 已停止，已完成的请求已记入表格。"
            } catch { status = error.localizedDescription }
        }
    }
}
