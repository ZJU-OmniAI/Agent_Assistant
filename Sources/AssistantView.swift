import AppKit
import SwiftUI

enum Preferences {
    static func modelKey(for provider: String) -> String { "model.\(provider)" }
    static func effortKey(provider: String, model: String) -> String {
        "effort.\(provider).\(model.isEmpty ? "default" : model)"
    }
    static func serviceTierKey(provider: String, model: String) -> String {
        "serviceTier.\(provider).\(model.isEmpty ? "default" : model)"
    }
    /// The saved Codex speed tier for a model; Claude Code has none.
    static func serviceTier(provider: String, model: String, in defaults: UserDefaults = .standard) -> String {
        provider == "codex" ? defaults.string(forKey: serviceTierKey(provider: provider, model: model)) ?? "" : ""
    }

    static func migrateModel(in defaults: UserDefaults = .standard) {
        guard let legacy = defaults.string(forKey: "model") else { return }
        let key = modelKey(for: defaults.string(forKey: "provider") ?? "codex")
        if defaults.object(forKey: key) == nil {
            defaults.set(legacy.trimmed == "default" ? "" : legacy.trimmed, forKey: key)
        }
        defaults.removeObject(forKey: "model")
    }

    static func backend(_ defaults: UserDefaults = .standard) -> LocalCLI {
        let saved = defaults.string(forKey: "provider") ?? "claude"
        let provider = LocalCLI.providers.contains(saved) ? saved : "claude"
        let model = defaults.string(forKey: modelKey(for: provider)) ?? ""
        let effort = defaults.string(forKey: effortKey(provider: provider, model: model)) ?? "default"
        return LocalCLI(provider: provider, model: model, effort: effort,
                        serviceTier: serviceTier(provider: provider, model: model, in: defaults))
    }

    static var translationPrompt: String {
        let language = UserDefaults.standard.string(forKey: "language") ?? "简体中文"
        return "翻译成\(language)。"
    }
}

@MainActor
final class Session: ObservableObject {
    @Published private(set) var conversation: Conversation
    @Published private(set) var pending: String?
    @Published private(set) var failure: String?
    @Published var draft = ""
    var failedQuestion: String? { failure == nil ? nil : retryQuestion }
    private var task: Task<Void, Never>?
    private var revision = 0
    private var retryQuestion: String?

    init(source: String) { conversation = Conversation(source: source) }

    func submit(_ question: String) {
        let question = question.trimmed
        guard !question.isEmpty, pending == nil else { return }
        failure = nil
        draft = ""
        pending = question
        retryQuestion = question
        let current = revision
        let messages = conversation.messages(asking: question)
        task = Task {
            do {
                let answer = try await Preferences.backend().generate(messages)
                guard revision == current else { return }
                conversation.turns.append(Turn(question: question, answer: answer))
                retryQuestion = nil
            } catch {
                guard revision == current else { return }
                failure = error.localizedDescription
            }
            pending = nil
            task = nil
        }
    }

    func retry() {
        if let retryQuestion { submit(retryQuestion) }
    }

    func stop() {
        revision &+= 1
        task?.cancel()
        task = nil
        if let pending { draft = pending }
        pending = nil
    }
}

struct AssistantView: View {
    @ObservedObject var session: Session
    let settings: () -> Void
    @State private var expanded = false
    @FocusState private var composing: Bool

    @ViewBuilder private var sourceHeader: some View {
        // A long original stays independently scrollable when expanded.
        if expanded {
            ScrollView { sourceLine }
                .frame(maxHeight: 150)
                .background(Color(nsColor: .controlBackgroundColor))
        } else {
            sourceLine.background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private var sourceLine: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.quote").foregroundStyle(.secondary).accessibilityLabel("选中的原文")
            Text(session.conversation.source).lineLimit(expanded ? nil : 2).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                .buttonStyle(.borderless).help(expanded ? "收起原文" : "展开原文").accessibilityLabel("展开或收起原文")
        }.font(.callout).padding(14)
    }

    private func questionLine(_ text: String) -> some View {
        Text(text)
            .textSelection(.enabled)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var chat: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if session.conversation.turns.isEmpty && session.pending == nil && session.failure == nil {
                        HStack(spacing: 10) {
                            Button("翻译原文") { session.submit(Preferences.translationPrompt) }
                            Button("解释这段话") { session.submit("用通俗的语言解释这段原文。") }
                        }
                    }
                    ForEach(session.conversation.turns) { turn in
                        questionLine(turn.question).id(turn.id)
                        MarkdownText(turn.answer).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            let board = NSPasteboard.general
                            board.clearContents()
                            board.setString(turn.answer, forType: .string)
                        } label: { Label("复制回答", systemImage: "doc.on.doc") }
                        .buttonStyle(.borderless).font(.caption)
                    }
                    if let question = session.pending {
                        questionLine(question)
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("等待模型回复…").foregroundStyle(.secondary)
                            Spacer()
                            Button("停止") { session.stop() }
                        }
                    }
                    if let error = session.failure {
                        if let question = session.failedQuestion { questionLine(question) }
                        VStack(alignment: .leading, spacing: 8) {
                            Label("请求失败", systemImage: "exclamationmark.circle")
                            Text(error).font(.callout).textSelection(.enabled)
                            HStack {
                                Button("重试") { session.retry() }
                                Button("模型设置", action: settings)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.pending) { value in
                if value == nil, session.failure == nil, let last = session.conversation.turns.last {
                    reader.scrollTo(last.id, anchor: .top)
                } else {
                    reader.scrollTo("end", anchor: .bottom)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sourceHeader
            Divider()
            chat
            Divider()
            HStack(alignment: .bottom, spacing: 12) {
                Button(action: settings) {
                    Label("模型", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderless).help("选择翻译和对话使用的模型")
                TextField("围绕所选文字提问…", text: $session.draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...4).focused($composing)
                    .onSubmit { session.submit(session.draft) }
                Button { session.submit(session.draft) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(session.draft.trimmed.isEmpty || session.pending != nil).buttonStyle(.borderless)
                    .help("发送").accessibilityLabel("发送问题")
            }.padding(14)
        }
        .frame(minWidth: 340, minHeight: 275)
        .onAppear { composing = true }
    }
}

/// The block structure of a model answer. Models often reply in Markdown; showing the
/// raw `##` and `**` reads badly, so headings, lists, quotes, code and rules are laid out
/// here and inline styles go through Foundation's Markdown parser.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(indent: Int, marker: String, text: String)
    case quote(String)
    case code(String)
    case rule

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var fence: [String]?
        var table: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            if !table.isEmpty { blocks.append(.code(table.joined(separator: "\n"))) }
            paragraph = []
            table = []
        }
        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let lines = fence {
                if line.hasPrefix("```") { blocks.append(.code(lines.joined(separator: "\n"))); fence = nil }
                else { fence = lines + [raw] }
                continue
            }
            if line.hasPrefix("```") { flush(); fence = []; continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("|") {
                if !paragraph.isEmpty { flush() }
                table.append(line)
                continue
            }
            if !table.isEmpty { flush() }
            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                flush()
                blocks.append(.heading(level: hashes, text: line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)))
                continue
            }
            let marks = line.filter { $0 != " " }
            if marks.count >= 3, let first = marks.first, "-*_".contains(first), marks.allSatisfy({ $0 == first }) {
                flush()
                blocks.append(.rule)
                continue
            }
            if line.hasPrefix(">") {
                flush()
                let text = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if case .quote(let previous)? = blocks.last { blocks[blocks.count - 1] = .quote(previous + "\n" + text) }
                else { blocks.append(.quote(text)) }
                continue
            }
            if let item = listItem(line) {
                flush()
                let leading = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                blocks.append(.bullet(indent: min(leading / 2, 3), marker: item.marker, text: item.text))
                continue
            }
            paragraph.append(line)
        }
        if let lines = fence { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func listItem(_ line: String) -> (marker: String, text: String)? {
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            return ("•", line.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let dot = rest.first, dot == "." || dot == ")", rest.dropFirst().first == " " else { return nil }
        return (digits + ".", rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }
}

struct MarkdownText: View {
    let blocks: [MarkdownBlock]

    init(_ text: String) { blocks = MarkdownBlock.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in view(for: block) }
        }
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text)).font(level <= 2 ? .headline : .subheadline.weight(.semibold)).padding(.top, 2)
        case .paragraph(let text):
            Text(Self.inline(text)).lineSpacing(3)
        case .bullet(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary)
                Text(Self.inline(text)).lineSpacing(3)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let text):
            Text(Self.inline(text)).foregroundStyle(.secondary).lineSpacing(3).padding(.leading, 10)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(.quaternary).frame(width: 3) }
        case .code(let text):
            ScrollView(.horizontal) {
                Text(text).font(.system(.callout, design: .monospaced)).padding(8)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        }
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
