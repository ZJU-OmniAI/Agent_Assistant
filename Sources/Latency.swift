import Foundation

struct LatencySample: Codable {
    let seconds: Double
    let error: String?
}

struct LatencyRun: Codable, Identifiable {
    let id: UUID
    let started: Date
    let provider: String
    let model: String
    let label: String
    let effort: String
    var samples: [LatencySample]

    static let repetitions = 3
    static let source = "The library opens at nine."
    static let question = "翻译成简体中文。"
    static let historyKey = "translationLatency.v1"

    var successfulTimes: [Double] {
        samples.filter { $0.error == nil }.map(\.seconds).sorted()
    }

    var median: Double? {
        let times = successfulTimes
        guard !times.isEmpty else { return nil }
        return (times[(times.count - 1) / 2] + times[times.count / 2]) / 2
    }

    @MainActor static func measure(backend: LocalCLI, label: String, onSample: (Self) -> Void) async throws -> Self {
        let messages = Conversation(source: source).messages(asking: question)
        var run = Self(id: UUID(), started: Date(), provider: backend.provider, model: backend.model,
                       label: label, effort: backend.effort, samples: [])
        for _ in 0..<repetitions {
            try Task.checkCancellation()
            let start = ContinuousClock.now
            var failure: String?
            do { _ = try await backend.generate(messages) }
            catch {
                try Task.checkCancellation()
                failure = error.localizedDescription
            }
            let elapsed = start.duration(to: .now).components
            try Task.checkCancellation()
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            run.samples.append(LatencySample(seconds: seconds, error: failure))
            onSample(run)
            if failure != nil { break }
        }
        return run
    }

    /// The newest run of every provider/model/effort combination.
    static func latest(in defaults: UserDefaults = .standard) -> [String: Self] {
        var result: [String: Self] = [:]
        for run in history(in: defaults) {
            let key = configurationKey(provider: run.provider, model: run.model, effort: run.effort)
            if let existing = result[key], existing.started >= run.started { continue }
            result[key] = run
        }
        return result
    }

    static func configurationKey(provider: String, model: String, effort: String) -> String {
        [provider, model.trimmed.isEmpty ? "" : model.trimmed, effort].joined(separator: "|")
    }

    static func history(in defaults: UserDefaults = .standard) -> [Self] {
        guard let data = defaults.data(forKey: historyKey) else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }

    // Update the same row after each finished request, including partial runs.
    @discardableResult static func save(_ run: Self, in defaults: UserDefaults = .standard) -> [Self] {
        let candidates = [run] + history(in: defaults).filter { $0.id != run.id }
        // Keep recent repeats and the latest measurement of every distinct setting.
        var configurations = Set<[String]>()
        var rows = [Self]()
        for (index, candidate) in candidates.enumerated() {
            let key = [candidate.provider, candidate.model, candidate.effort]
            let firstForConfiguration = configurations.insert(key).inserted
            if index < 30 || firstForConfiguration { rows.append(candidate) }
        }
        if let data = try? JSONEncoder().encode(rows) { defaults.set(data, forKey: historyKey) }
        return rows
    }
}
