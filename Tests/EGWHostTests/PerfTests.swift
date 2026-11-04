import Testing
@testable import EGWHost

@Suite("Play performance sampling")
struct PerfTests {
    @Test func parsesPsOutput() {
        #expect(PerfSampler.parse("  187.4 2345678\n") == .init(cpuPercent: 187.4, rssBytes: 2_345_678 * 1024))
        #expect(PerfSampler.parse("0.0 12") == .init(cpuPercent: 0, rssBytes: 12 * 1024))
        for bad in ["", "abc 12", "12", "-1 5", "1 2 3", "nan 5"] { #expect(PerfSampler.parse(bad) == nil) }
    }

    @Test func summarizesSamples() {
        #expect(PerfSampler.summarize([]) == nil)
        let s = PerfSampler.summarize([.init(cpuPercent: 100, rssBytes: 10), .init(cpuPercent: 151, rssBytes: 30),
                                       .init(cpuPercent: 120, rssBytes: 20)])
        #expect(s == .init(samples: 3, cpuPercentAvg: 123.7, cpuPercentMax: 151, rssMaxBytes: 30))
        #expect(PerfSampler.percent(cpuSeconds: 30, wallSeconds: 120) == 25)
        #expect(PerfSampler.percent(cpuSeconds: 1, wallSeconds: 0) == 0)
    }

    @Test func launcherSummaryShowsPerformance() {
        let json = #"{"transportCompleted":true,"contactsHeldAtEnd":0,"touchRequests":3,"touchFailures":0,"keyRevoked":true,"summary":{"fps":29.51},"hostCpuPercent":34.6,"emulatorPerf":{"samples":4,"cpuPercentAvg":182.3,"cpuPercentMax":210,"rssMaxBytes":1}}"#
        let text = launcherSummary(json)
        #expect(text.contains("畫面 29.5 fps") && text.contains("遊戲視窗 CPU 35%") && text.contains("模擬器 CPU 平均 182%"))
        let old = #"{"transportCompleted":true,"contactsHeldAtEnd":0,"touchRequests":3,"touchFailures":0,"keyRevoked":true}"#
        #expect(!launcherSummary(old).contains("fps"))
    }
}
