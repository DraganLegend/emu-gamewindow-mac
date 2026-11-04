import Foundation

/// Read-only resource sampling during play.
/// The Emulator is sampled with `ps` (its own PID from discovery); nothing is
/// signalled or changed. `%cpu` can exceed 100 on several cores.
enum PerfSampler {
    struct Sample: Equatable, Sendable {
        let cpuPercent: Double
        let rssBytes: UInt64
    }

    struct Summary: Encodable, Equatable, Sendable {
        let samples: Int
        let cpuPercentAvg: Double
        let cpuPercentMax: Double
        let rssMaxBytes: UInt64
    }

    /// `ps -o %cpu=,rss=` output, e.g. "  187.4 2345678" (rss in KiB).
    static func parse(_ text: String) -> Sample? {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard parts.count == 2, let cpu = Double(parts[0]), cpu.isFinite, cpu >= 0,
              let kib = UInt64(parts[1]), kib <= UInt64.max / 1024 else { return nil }
        return .init(cpuPercent: cpu, rssBytes: kib * 1024)
    }

    static func sample(pid: Int32) -> Sample? {
        guard pid > 1, let text = try? StatusSession.inspect("/bin/ps", ["-o", "%cpu=,rss=", "-p", String(pid)]) else { return nil }
        return parse(text)
    }

    static func summarize(_ samples: [Sample]) -> Summary? {
        guard !samples.isEmpty else { return nil }
        let avg = samples.map(\.cpuPercent).reduce(0, +) / Double(samples.count)
        return .init(samples: samples.count, cpuPercentAvg: (avg * 10).rounded() / 10,
                     cpuPercentMax: samples.map(\.cpuPercent).max() ?? 0,
                     rssMaxBytes: samples.map(\.rssBytes).max() ?? 0)
    }

    /// This process: CPU% over the wall time of the session.
    static func percent(cpuSeconds: Double, wallSeconds: Double) -> Double {
        guard wallSeconds > 0, cpuSeconds.isFinite, cpuSeconds >= 0 else { return 0 }
        return (cpuSeconds / wallSeconds * 1000).rounded() / 10
    }
}

actor PerfLog {
    private(set) var samples: [PerfSampler.Sample] = []
    private(set) var thermal: [String] = []
    func add(_ sample: PerfSampler.Sample) { samples.append(sample) }
    func addThermal(_ label: String) { thermal.append(label) }
}
