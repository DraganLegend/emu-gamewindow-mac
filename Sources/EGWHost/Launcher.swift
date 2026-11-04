import AppKit
import Darwin
import Foundation
import InputCore

/// a small launcher window shown when the app opens with no arguments.
/// Start goes through `scripts/egw start`; play runs this same executable as a
/// separate `game-view --auto` process so its tested drain/revoke path is unchanged.
@MainActor
final class Launcher: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static var retained: Launcher?
    private var model = LauncherModel()
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 330),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    private let status = NSTextField(labelWithString: "")
    private let keymap = NSTextField(labelWithString: "")
    private let spaceLine = NSTextField(labelWithString: "")
    private let last = NSTextField(wrappingLabelWithString: "")
    private let output = NSTextField(wrappingLabelWithString: "")
    private let audio = NSButton(checkboxWithTitle: "啟動時開啟聲音", target: nil, action: nil)
    private let officialWindow = NSButton(checkboxWithTitle: "顯示官方模擬器視窗（除錯用）", target: nil, action: nil)
    private let fastPath = NSButton(checkboxWithTitle: "高效能畫面（共享記憶體＋Metal）", target: nil, action: nil)
    private let minutes = NSPopUpButton()
    private let rotate = NSPopUpButton()
    private let startButton = NSButton(title: "啟動 Runtime", target: nil, action: nil)
    private let playButton = NSButton(title: "開始遊玩", target: nil, action: nil)
    private let stopButton = NSButton(title: "關機…", target: nil, action: nil)
    private var timer: Timer?
    private var game: Process?

    static var project: String { RuntimeDiscovery.project }
    static var egwScript: String { project + "/scripts/egw" }
    static var reports: String { project + "/.runtime/state" }

    static func show() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let launcher = Launcher()
        retained = launcher
        app.delegate = launcher
        launcher.build()
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    // MARK: Layout

    private func build() {
        let menu = NSMenu(), item = NSMenuItem(), sub = NSMenu()
        sub.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = sub; menu.addItem(item); NSApp.mainMenu = menu

        status.font = .boldSystemFont(ofSize: 14)
        for label in [keymap, spaceLine, last, output] { label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor }
        minutes.addItems(withTitles: LauncherModel.minutesChoices.map { "\($0) 分鐘" })
        minutes.selectItem(at: LauncherModel.minutesChoices.firstIndex(of: 120) ?? 0)
        rotate.addItems(withTitles: LauncherModel.rotateChoices.map { "畫面旋轉 \($0)°" })
        let savedRotate = UserDefaults.standard.integer(forKey: "rotate")
        rotate.selectItem(at: LauncherModel.rotateChoices.firstIndex(of: savedRotate) ?? 0)
        audio.state = UserDefaults.standard.bool(forKey: "audio") ? .on : .off
        officialWindow.state = UserDefaults.standard.bool(forKey: "officialWindow") ? .on : .off
        officialWindow.target = self; officialWindow.action = #selector(remember)
        // Default on; an explicit off is remembered.
        fastPath.state = (UserDefaults.standard.object(forKey: "fastPath") as? Bool ?? true) ? .on : .off
        fastPath.target = self; fastPath.action = #selector(remember)
        for (button, action) in [(startButton, #selector(start)), (playButton, #selector(play)), (stopButton, #selector(stopHelp))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        audio.target = self; audio.action = #selector(remember)
        rotate.target = self; rotate.action = #selector(remember)

        let buttons = NSStackView(views: [startButton, playButton, stopButton])
        let options = NSStackView(views: [minutes, rotate])
        let stack = NSStackView(views: [status, keymap, spaceLine, audio, officialWindow, fastPath, options, buttons, last, output])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            last.widthAnchor.constraint(equalToConstant: 420), output.widthAnchor.constraint(equalToConstant: 420),
        ])
        window.contentView = content
        window.title = HostPaths.config.appName
        window.delegate = self
        window.center(); window.makeKeyAndOrderFront(nil)
        last.stringValue = Self.latestReportSummary()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func render() {
        status.stringValue = "Runtime：" + model.statusText
        startButton.isEnabled = model.canStart
        playButton.isEnabled = model.canPlay
        stopButton.isEnabled = model.canStop
        keymap.stringValue = LauncherModel.keymapText(try? GameKeymapStore.load())
    }

    private func refresh() {
        Task {
            let (finding, policy) = await Task.detached { (RuntimeDiscovery.find(), SpacePolicy.current()) }.value
            self.model.state = finding.state
            self.model.space = policy.level
            self.spaceLine.stringValue = policy.summary + (policy.level == .ok ? "" : "（請執行 egw space／egw clean）")
            self.spaceLine.textColor = policy.level == .ok ? .secondaryLabelColor : policy.level == .warn ? .systemOrange : .systemRed
            self.render()
        }
    }

    @objc private func remember() {
        UserDefaults.standard.set(LauncherModel.rotateChoices[max(0, rotate.indexOfSelectedItem)], forKey: "rotate")
        UserDefaults.standard.set(audio.state == .on, forKey: "audio")
        UserDefaults.standard.set(officialWindow.state == .on, forKey: "officialWindow")
        UserDefaults.standard.set(fastPath.state == .on, forKey: "fastPath")
    }

    // MARK: Actions

    @objc private func start() {
        guard model.canStart else { return }
        model.starting = true; render()
        output.stringValue = "執行 egw start…"
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = LauncherModel.startArguments(script: Self.egwScript, audio: audio.state == .on,
                                                           officialWindow: officialWindow.state == .on)
        process.standardOutput = pipe; process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { finished in
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let code = finished.terminationStatus
            Task { @MainActor in
                self.model.starting = false
                let tail = text.split(separator: "\n").suffix(4).joined(separator: "\n")
                self.output.stringValue = (code == 0 ? "啟動已送出：\n" : "啟動未完成（exit \(code)）：\n") + tail
                self.refresh()
            }
        }
        do { try process.run() } catch {
            model.starting = false; output.stringValue = "無法執行 scripts/egw"; render()
        }
    }

    @objc private func play() {
        guard model.canPlay, let executable = Bundle.main.executableURL,
              let args = LauncherModel.playArguments(
                  minutes: LauncherModel.minutesChoices[max(0, minutes.indexOfSelectedItem)],
                  rotate: LauncherModel.rotateChoices[max(0, rotate.indexOfSelectedItem)],
                  fastPath: fastPath.state == .on) else { return }
        let alert = NSAlert()
        alert.messageText = "開始遊玩前確認"
        alert.informativeText = "1. Android 的 USB 偵錯目前是關閉的。\n2. 這次是遊戲用途（可在視窗中開啟或操作遊戲）。\n\n兩項都屬實才按「確認」。"
        alert.addButton(withTitle: "確認"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let stamp = Self.stamp()
        guard let report = Self.privateFile(Self.reports + "/play-\(stamp).json"),
              let errors = Self.privateFile(Self.reports + "/play-\(stamp).stderr.txt") else {
            output.stringValue = "無法建立報告檔"; return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.standardOutput = report; process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let path = Self.reports + "/play-\(stamp).json"
        process.terminationHandler = { _ in
            Task { @MainActor in
                try? report.close(); try? errors.close()
                self.game = nil; self.model.playing = false
                self.showLauncher()
                self.last.stringValue = LauncherModel.summary((try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data())
                self.output.stringValue = "報告：\(path)"
                self.refresh()
            }
        }
        do {
            try process.run()
            game = process; model.playing = true
            output.stringValue = "遊戲視窗開啟中…"
            hideLauncher()
        } catch { output.stringValue = "無法開啟遊戲視窗" }
        render()
    }

    /// One window at a time: while the game window (its own process, same app
    /// bundle) is open, the launcher leaves the screen and the Dock.
    private func hideLauncher() {
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    private func showLauncher() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func stopHelp() {
        guard model.canStop else { return }
        let alert = NSAlert()
        alert.messageText = "關閉 Runtime"
        alert.informativeText = LauncherModel.stopInstructions
        alert.addButton(withTitle: "快速關機"); alert.addButton(withTitle: "Android 關機"); alert.addButton(withTitle: "取消")
        let choice = alert.runModal()
        guard choice != .alertThirdButtonReturn else { return }
        let host = choice == .alertFirstButtonReturn
        model.stopping = true; render()
        output.stringValue = host ? "送出結束請求，最多等 60 秒…" : "已送出電源鍵：請在模擬器畫面點「關機」（最多等 120 秒）"
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = LauncherModel.stopArguments(script: Self.egwScript, host: host)
        process.standardOutput = pipe; process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { finished in
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let code = finished.terminationStatus
            Task { @MainActor in
                self.model.stopping = false
                let tail = text.split(separator: "\n").suffix(3).joined(separator: "\n")
                self.output.stringValue = (code == 0 ? "已關機：\n" : "關機未完成（exit \(code)）：\n") + tail
                self.refresh()
            }
        }
        do { try process.run() } catch { model.stopping = false; output.stringValue = "無法執行 scripts/egw"; render() }
    }

    // MARK: Lifecycle

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.canQuit else {
            let alert = NSAlert()
            alert.messageText = model.playing ? "遊戲視窗仍在執行" : model.stopping ? "Runtime 正在關機" : "Runtime 仍在啟動"
            alert.informativeText = model.playing ? "請先在遊戲視窗按 ⌘Q，等它釋放觸點後再結束 Launcher。" : "請等啟動流程結束。"
            alert.runModal()
            return .terminateCancel
        }
        timer?.invalidate()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { model.canQuit }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !model.canQuit { _ = applicationShouldTerminate(NSApp); return false }
        return true
    }

    // MARK: Files

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// New owner-only file, never an existing path or a link.
    private static func privateFile(_ path: String) -> FileHandle? {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
    }

    static func latestReportSummary() -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: reports)) ?? []
        guard let latest = names.filter({ $0.hasPrefix("play-") && $0.hasSuffix(".json") }).sorted().last,
              let data = FileManager.default.contents(atPath: reports + "/" + latest) else { return "上次遊玩：無紀錄" }
        return LauncherModel.summary(data)
    }
}
