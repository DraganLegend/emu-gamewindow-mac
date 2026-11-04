import Foundation
import InputCore

/// launcher decisions, kept pure so they are testable without AppKit.
/// The launcher never kills processes, deletes locks or uses ADB; starting the
/// Runtime goes through `scripts/egw start` so CLI and GUI share one path.
struct LauncherModel: Equatable {
    var state: RuntimeDiscovery.State = .stopped
    var starting = false
    var playing = false
    var stopping = false
    /// level; starting the Runtime below the stop line is refused (egw start checks too).
    var space: SpacePolicy.Level = .ok

    /// Packaged apps carry `EGWRole = launcher` (App/Info.plist); the bundle ID is configurable.
    static let role = "launcher"
    static let minutesChoices = [30, 60, 120, 180, 240]
    static let rotateChoices = [0, 90, 180, 270]

    var canStart: Bool { state == .stopped && !starting && !playing && !stopping && space != .stop }
    var canPlay: Bool { state == .running && !starting && !playing && !stopping && space != .stop }
    /// The game window holds a trusted key; close it before shutting Android down.
    var canStop: Bool { state == .running && !starting && !playing && !stopping }
    /// Quitting the launcher while its game window runs would orphan the drain report.
    var canQuit: Bool { !playing && !starting && !stopping }

    var statusText: String {
        if starting { return "啟動中…（最多約 3 分鐘）" }
        if stopping { return "關機中…（請在模擬器畫面點「關機」，或等候結束）" }
        switch state {
        case .stopped: return "已停止"
        case .starting: return "啟動中（等待 Emulator 就緒）"
        case .running: return playing ? "執行中・遊戲視窗開啟" : "執行中（按「開始遊玩」查看畫面）"
        case .lost: return "失聯：程序已不存在，請人工確認"
        case .ambiguous: return "不明確：找到多個實例，請人工確認"
        }
    }

    static func startArguments(script: String, audio: Bool, officialWindow: Bool = false) -> [String] {
        [script, "start"] + (audio ? ["--audio"] : []) + (officialWindow ? ["--window"] : [])
    }

    /// The launcher confirms in its own dialog, so `--yes`.
    static func stopArguments(script: String, host: Bool) -> [String] {
        [script, "stop", "--yes", host ? "--host" : "--android"]
    }

    static func playArguments(minutes: Int, rotate: Int, fastPath: Bool = false) -> [String]? {
        guard minutesChoices.contains(minutes), rotateChoices.contains(rotate) else { return nil }
        return ["game-view", "--auto", "--usb-off-confirmed", "--game-in-use",
                "--seconds", String(minutes * 60), "--rotate", String(rotate)] + (fastPath ? ["--fast-path"] : [])
    }

    static func keymapText(_ profile: MappingProfile?) -> String {
        guard let profile else { return "按鍵設定：無法讀取（檔案權限或格式不符）" }
        let keys = profile.bindings.map(\.label).joined(separator: " ")
        let stick = profile.joystick == nil ? "" : "＋WASD 搖桿"
        return profile.bindings.isEmpty && profile.joystick == nil
            ? "按鍵設定：尚未設定（遊戲視窗中按 ⌘E）"
            : "按鍵設定：\(keys)\(stick)"
    }

    /// One-line summary of a game-view report; never echoes raw error text.
    static func summary(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "上次遊玩：沒有可讀的報告"
        }
        let ok = object["transportCompleted"] as? Bool == true
        let held = object["contactsHeldAtEnd"] as? Int ?? -1
        let touches = object["touchRequests"] as? Int ?? 0
        let failures = object["touchFailures"] as? Int ?? 0
        let revoked = object["keyRevoked"] as? Bool == true
        let error = (object["error"] as? String).map { $0.unicodeScalars.allSatisfy { $0.isASCII } ? $0 : "?" }
        let head = ok ? "上次遊玩：正常結束" : "上次遊玩：未正常結束（\(error.map { String($0.prefix(40)) } ?? "原因不明")）"
        return head + "｜觸控 \(touches)、失敗 \(failures)、殘留觸點 \(held)、金鑰撤銷 \(revoked ? "是" : "否")" + performanceLine(object)
    }

    /// "\n畫面 29.5 fps｜遊戲視窗 CPU 35%｜模擬器 CPU 平均 180%" from the report, when present.
    static func performanceLine(_ object: [String: Any]) -> String {
        var parts: [String] = []
        if let fps = (object["summary"] as? [String: Any])?["fps"] as? Double { parts.append(String(format: "畫面 %.1f fps", fps)) }
        if let host = object["hostCpuPercent"] as? Double, host > 0 { parts.append(String(format: "遊戲視窗 CPU %.0f%%", host)) }
        if let emu = (object["emulatorPerf"] as? [String: Any])?["cpuPercentAvg"] as? Double {
            parts.append(String(format: "模擬器 CPU 平均 %.0f%%", emu))
        }
        return parts.isEmpty ? "" : "\n" + parts.joined(separator: "｜")
    }

    static let stopInstructions = """
    請先確認遊戲已存檔並退出、遊戲視窗已關閉。

    快速關機（預設）：對模擬器送一次結束請求（SIGTERM），最多等 60 秒；不會強制終止。
    Android 關機：送出電源鍵，需在官方模擬器視窗點「關機」，只適用於啟動時勾選「顯示官方模擬器視窗」。此映像長按電源鍵會叫出 Google 助理。

    快速關機失敗時：有官方視窗就從視窗關閉；沒有的話，打開「活動監視器」選 qemu-system 程序 →「結束」（不要選強制結束）。
    """
}
