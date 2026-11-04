import AppKit
import Foundation
import InputCore
import Metal
import QuartzCore

/// Receives keys and the left mouse only inside our own window. Every key is
/// swallowed (no text path yet); unmapped input is simply ignored.
@MainActor
final class GameView: NSView {
    var onAction: ((InputAction) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { nil }

    func show(_ image: CGImage, flipped: Bool) {
        layer?.transform = flipped ? CATransform3DMakeScale(1, -1, 1) : CATransform3DIdentity
        layer?.contents = image
    }

    /// Fast path: a Metal layer under the overlay; rotation/flip happen in the shader.
    private(set) var metalLayer: CAMetalLayer?
    func installMetal(device: MTLDevice, mode: PresentMode = .standard) {
        let metal = CAMetalLayer()
        metal.device = device; metal.pixelFormat = .bgra8Unorm; metal.framebufferOnly = true
        metal.maximumDrawableCount = mode.drawableCount
        metal.displaySyncEnabled = mode.displaySync
        metal.isOpaque = mode.opaque
        layer?.contents = nil
        layer?.insertSublayer(metal, at: 0)
        metalLayer = metal
        updateMetalSize()
    }
    private func updateMetalSize() {
        guard let metal = metalLayer else { return }
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        metal.frame = bounds; metal.contentsScale = scale
        metal.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        CATransaction.commit()
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateMetalSize() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateMetalSize() }

    private func point(_ event: NSEvent) -> HostPoint {
        let p = convert(event.locationInWindow, from: nil)
        return .init(x: Double(p.x), y: Double(p.y))
    }

    override func keyDown(with event: NSEvent) {
        // Command/Control chords belong to the menu, never to a binding.
        guard event.modifierFlags.isDisjoint(with: [.command, .control]) else { return }
        onAction?(.keyDown(event.keyCode, autorepeat: event.isARepeat))
    }
    override func keyUp(with event: NSEvent) { onAction?(.keyUp(event.keyCode)) }
    override func mouseDown(with event: NSEvent) { onAction?(.leftDown(point(event))) }
    override func mouseDragged(with event: NSEvent) { onAction?(.leftMove(point(event))) }
    override func mouseUp(with event: NSEvent) { onAction?(.leftUp(point(event))) }
}

/// The game area (left of the toolbar). Black; reports size changes so the
/// picture can be re-fitted and the input model rebuilt.
@MainActor
final class GameStage: NSView {
    var onLayout: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { nil }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        onLayout?()
    }
}

/// What the overlay shows, already in display-normalized space.
struct OverlayState: Equatable {
    var bindings: [SkillBinding] = []
    var stickCenter: NormalizedPoint?
    /// Stick reach in view points.
    var stickRadius = 0.0
    var stickSelected = false
    var pending: NormalizedPoint?
    var selected: Int?
    var editing = false
    var banner = ""
}

/// Transparent layer above the picture; never takes clicks.
@MainActor
final class OverlayView: NSView {
    var state = OverlayState() { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func drawText(_ text: String, in rect: NSRect, size: CGFloat, bold: Bool, center: Bool) {
        let style = NSMutableParagraphStyle()
        style.alignment = center ? .center : .left
        style.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor.white, .paragraphStyle: style,
        ]
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attributes)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = KeymapEditor.hitRadius * 0.6
        if let stick = state.stickCenter {
            let center = NSPoint(x: stick.x * bounds.width, y: stick.y * bounds.height)
            let reach = max(radius, state.stickRadius)
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2))
            ring.setLineDash([5, 4], count: 2, phase: 0)
            (state.stickSelected ? NSColor.systemOrange : NSColor.white).withAlphaComponent(0.8).setStroke()
            ring.lineWidth = 1.5; ring.stroke()
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            (state.stickSelected ? NSColor.systemOrange : (state.editing ? NSColor.systemPurple : NSColor.white))
                .withAlphaComponent(state.editing ? 0.65 : 0.28).setFill()
            dot.fill()
            drawText("WASD", in: NSRect(x: center.x - radius * 2, y: center.y - 7, width: radius * 4, height: 16),
                     size: 10, bold: true, center: true)
        }
        for (index, binding) in state.bindings.enumerated() {
            let center = NSPoint(x: binding.point.x * bounds.width, y: binding.point.y * bounds.height)
            let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                     width: radius * 2, height: radius * 2))
            let chosen = state.selected == index
            (chosen ? NSColor.systemOrange : (state.editing ? NSColor.systemBlue : NSColor.white))
                .withAlphaComponent(state.editing ? 0.65 : 0.28).setFill()
            circle.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke(); circle.lineWidth = 1.5; circle.stroke()
            drawText(binding.label, in: NSRect(x: center.x - radius, y: center.y - 7, width: radius * 2, height: 16),
                     size: 11, bold: true, center: true)
        }
        if let pending = state.pending {
            let center = NSPoint(x: pending.x * bounds.width, y: pending.y * bounds.height)
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                   width: radius * 2, height: radius * 2))
            ring.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.systemGreen.setStroke(); ring.lineWidth = 2; ring.stroke()
            drawText("?", in: NSRect(x: center.x - radius, y: center.y - 8, width: radius * 2, height: 18),
                     size: 14, bold: true, center: true)
        }
        guard !state.banner.isEmpty else { return }
        let box = NSRect(x: 6, y: bounds.height - 46, width: bounds.width - 12, height: 40)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        drawText(state.banner, in: box.insetBy(dx: 8, dy: 4), size: 11, bold: false, center: false)
    }
}

/// Owns the window, the input model, the keymap editor and the single
/// in-flight touch sender. The window follows the frame geometry: a new
/// picture size, stream rotation or view rotation stops the mapping, waits
/// for every contact to be released, then resizes and rebuilds the model.
@MainActor
final class GameWindowHost: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSMenuDelegate {
    private(set) var closed = false
    private(set) var statusNote = "waiting-for-first-frame"
    private(set) var touchRequests = 0
    private(set) var touchFailures = 0
    private(set) var framesShown = 0
    private(set) var keyEvents = 0
    private(set) var keysConsumed = 0
    private(set) var mouseEvents = 0
    private(set) var keymapSaves = 0
    private(set) var keymapSaveFailures = 0
    private(set) var geometryChanges = 0
    private(set) var maxHeldContacts = 0
    private(set) var lastStreamRotation = 0
    /// Stored keymap: panel-normalized points, screen-direction stick roles.
    private(set) var profile: MappingProfile
    private(set) var viewTurns: Int
    private let flipFrames: Bool
    private let streamMap: StreamRotationMap
    private let clock: @Sendable () -> Int64
    private let sendTouch: @Sendable (ContactRequest) async -> DispatchOutcome
    private let saveKeymap: (MappingProfile) throws -> Void
    private var window: NSWindow?
    private var view: GameView?
    private var overlay: OverlayView?
    private var model: GameInputModel?
    private var geometry: GameGeometry?
    private var pendingGeometry: GameGeometry?
    private var lastPicture: (width: Int, height: Int, rotation: Int)?
    private var inFlight: Task<Void, Never>?
    private var editor: KeymapEditor?
    private var exitingEdit = false
    private var hint = ""
    /// View points per displayed Guest pixel; kept across rotation, changed by resizing.
    private var scale = 0.5
    private var resizing = false
    private var pendingRebuild = false
    /// Official Emulator process, for text mode. nil disables the menu action.
    var officialPID: Int32?
    private(set) var textModeSwitches = 0
    private(set) var resizes = 0
    /// In-window typing: guest clipboard + Ctrl+V. nil disables ⌘T.
    var sendText: (@Sendable (String) async -> Bool)?
    private var textField: NSTextField?
    private var textSending = false
    private(set) var textSends = 0
    private(set) var textFailures = 0
    var typing: Bool { textField != nil }
    /// Android system buttons (back/home/recents/volume). nil hides them.
    var sendAndroidKey: (@Sendable (AndroidKey) async -> Bool)?
    private(set) var androidKeys = 0
    private(set) var screenshots = 0
    private var stage: GameStage?
    private var lastShown: CGImage?
    private var pendingProfile: MappingProfile?
    private var toolbarButtons: [NSButton] = []
    /// Fast path (MMAP + Metal). nil = gRPC pixels + CGImage layer.
    var fastRenderer: MetalFrameRenderer?
    var presentMode: PresentMode = .nosync3
    /// Fast path with a no-vsync mode: frames are drawn when they arrive.
    var drawsOnArrival: Bool { fastRenderer != nil && presentMode.drawsOnArrival }
    var fastMapping: FrameMapping?
    private var lastMapped: (width: Int, height: Int)?
    private(set) var fastDrawFailures = 0
    /// Receive → display handoff (never blocks the receiver) and stage timings.
    nonisolated let mailbox = FrameMailbox()
    nonisolated let stages = StageStats()
    private var displayLink: CADisplayLink?
    /// Waiting for a Metal drawable happens here, never on the main thread.
    private let renderQueue = DispatchQueue(label: "egw.render", qos: .userInteractive)
    private var renderBusy = false

    init(profile: MappingProfile, flipFrames: Bool, viewTurns: Int = 0, streamMap: StreamRotationMap = .cw,
         clock: @escaping @Sendable () -> Int64 = HostMonotonicClock.milliseconds,
         saveKeymap: @escaping (MappingProfile) throws -> Void = { try GameKeymapStore.save($0) },
         sendTouch: @escaping @Sendable (ContactRequest) async -> DispatchOutcome) {
        self.profile = profile; self.flipFrames = flipFrames; self.viewTurns = ((viewTurns % 4) + 4) % 4
        self.streamMap = streamMap; self.clock = clock
        self.saveKeymap = saveKeymap; self.sendTouch = sendTouch
        super.init()
    }

    var editing: Bool { editor != nil }

    func installMenu() {
        let main = NSMenu(), app = NSMenuItem(), menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = target ?? self
        }
        add("Edit Keymap", #selector(toggleEdit(_:)), "e")
        add("Place Joystick (WASD) Here", #selector(placeJoystick(_:)), "j")
        add("Joystick Larger", #selector(joystickLarger(_:)), "]")
        add("Joystick Smaller", #selector(joystickSmaller(_:)), "[")
        add("Rotate View 90°", #selector(rotateView(_:)), "r")
        add("Type Text (Chinese OK)", #selector(openTextInput(_:)), "t")
        add("Screenshot", #selector(screenshot(_:)), "s")
        let full = menu.addItem(withTitle: "Full Screen", action: #selector(toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]; full.target = self
        menu.addItem(.separator())
        add("Save Keymap As…", #selector(saveKeymapAs(_:)), "")
        let load = menu.addItem(withTitle: "Load Keymap", action: nil, keyEquivalent: "")
        let loadMenu = NSMenu(); loadMenu.delegate = self; load.submenu = loadMenu
        menu.addItem(.separator())
        let official = menu.addItem(withTitle: "Official Emulator Window", action: #selector(textMode(_:)), keyEquivalent: "T")
        official.keyEquivalentModifierMask = [.command, .shift]; official.target = self
        menu.addItem(.separator())
        // Close drains contacts first; Quit goes through the app delegate, which closes the window.
        menu.addItem(withTitle: "Close Game Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add("Quit", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        app.submenu = menu; main.addItem(app); NSApp.mainMenu = main
    }

    // MARK: Frames and geometry

    /// Window creation and layout changes for a new frame; false if the frame is unusable.
    private func noteFrame(width: Int, height: Int, rotation: Int) -> Bool {
        guard !closed else { return false }
        lastPicture = (width, height, rotation); lastStreamRotation = rotation
        if window == nil {
            guard let g = GameGeometry(pictureWidth: width, pictureHeight: height, streamRotation: rotation,
                                       streamMap: streamMap, viewTurns: viewTurns) else {
                statusNote = "invalid-frame-geometry"; return false
            }
            createWindow(g)
        } else if let g = GameGeometry(pictureWidth: width, pictureHeight: height, streamRotation: rotation,
                                       streamMap: streamMap, viewTurns: viewTurns),
                  g != (pendingGeometry ?? geometry) {
            requestGeometry(g)
        }
        return true
    }

    /// Once per screen refresh: input upkeep, then the newest frame (if any).
    @objc func displayTick(_ link: CADisplayLink) {
        tick()
        drawLatest()
    }

    /// Takes the newest frame and shows it. While a Metal frame is still being
    /// drawn the mailbox keeps the newest one for the next refresh (or, when
    /// drawing on arrival, until that draw finishes).
    func drawLatest() {
        guard !closed, !(fastRenderer != nil && renderBusy), let frame = mailbox.take() else { return }
        let picked = CACurrentMediaTime()
        stages.wait((picked - frame.arrival) * 1000)
        guard noteFrame(width: frame.width, height: frame.height, rotation: frame.rotation) else { return }
        if window != nil, displayLink == nil, let view { startDisplayLink(view) }
        // Until a pending change is applied, keep showing frames in the old layout.
        let turns = geometry?.viewTurns ?? viewTurns
        switch frame.payload {
        case .image(let image):
            guard let shown = FrameRenderer.rotated(image, clockwise: turns) else { return }
            view?.show(shown, flipped: flipFrames)
            lastShown = shown
            framesShown += 1
        case .mapped:
            drawMapped(frame, turns: turns, picked: picked)
        }
    }

    private struct LayerBox: @unchecked Sendable { let layer: CAMetalLayer }

    private func drawMapped(_ frame: FrameMailbox.Frame, turns: Int, picked: CFTimeInterval) {
        guard let renderer = fastRenderer, let layer = view?.metalLayer else { return }
        renderBusy = true
        let box = LayerBox(layer: layer), stages = self.stages, flip = flipFrames
        let width = frame.width, height = frame.height
        renderQueue.async { [weak self] in
            var ok = false
            if let drawable = box.layer.nextDrawable() {
                drawable.addPresentedHandler { shown in
                    if shown.presentedTime > 0 { stages.present((shown.presentedTime - picked) * 1000) }
                }
                ok = renderer.render(width: width, height: height, turns: turns, flip: flip,
                                     into: drawable.texture, drawable: drawable) != nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.renderDone(ok, width: width, height: height) }
            }
        }
    }

    private func renderDone(_ ok: Bool, width: Int, height: Int) {
        renderBusy = false
        if ok { lastMapped = (width, height); framesShown += 1 } else { fastDrawFailures += 1 }
        // A frame that arrived while this one was drawing goes out now, not at the next tick.
        if drawsOnArrival { drawLatest() }
    }

    private func startDisplayLink(_ view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(displayTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func viewSize(_ g: GameGeometry) -> NSSize {
        // Picture size in points; starts at half size (1280x720 -> 640x360).
        NSSize(width: Double(g.displayWidth) * scale, height: Double(g.displayHeight) * scale)
    }

    private func createWindow(_ g: GameGeometry) {
        let size = viewSize(g)
        let content = NSSize(width: size.width + GameLayout.toolbarWidth, height: size.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: content),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.collectionBehavior.insert(.fullScreenPrimary)
        let root = NSView(frame: NSRect(origin: .zero, size: content))
        let stage = GameStage(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        stage.autoresizingMask = [.width, .height]
        let toolbar = makeToolbar(height: size.height)
        toolbar.frame = NSRect(x: size.width, y: 0, width: GameLayout.toolbarWidth, height: size.height)
        toolbar.autoresizingMask = [.minXMargin, .height]
        root.addSubview(stage); root.addSubview(toolbar)
        let view = GameView(frame: NSRect(origin: .zero, size: size))
        let overlay = OverlayView(frame: NSRect(origin: .zero, size: size))
        overlay.autoresizingMask = [.width, .height]
        view.addSubview(overlay); stage.addSubview(view)
        if let renderer = fastRenderer { view.installMetal(device: renderer.device, mode: presentMode) }
        window.contentView = root; window.delegate = self
        window.title = HostPaths.config.appName; window.isReleasedWhenClosed = false
        window.center(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
        self.window = window; self.view = view; self.overlay = overlay; self.stage = stage
        stage.onLayout = { [weak self] in self?.layoutPicture() }
        view.onAction = { [weak self] action in self?.route(action) }
        FileHandle.standardError.write(Data("gv:window-created\n".utf8))
        apply(g)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Stop the mapping now; `tick` applies the layout once nothing is held or in flight.
    private func requestGeometry(_ g: GameGeometry) {
        // Editor coordinates belong to the old layout: drop the unsaved edit.
        if editing { editor = nil; exitingEdit = false }
        pendingGeometry = g
        if var model { model.setFocused(false, at: clock()); self.model = model; drain() }
        hint = "畫面方向或大小改變，重新配置中…"; refreshOverlay()
    }

    private func apply(_ g: GameGeometry) {
        pendingGeometry = nil
        if geometry != nil { geometryChanges += 1 }
        geometry = g
        let size = viewSize(g)
        if let window {
            window.contentMinSize = NSSize(width: Double(g.displayWidth) * 0.25 + GameLayout.toolbarWidth,
                                           height: max(Double(g.displayHeight) * 0.25, 420))
            let content = NSSize(width: size.width + GameLayout.toolbarWidth, height: size.height)
            if !window.styleMask.contains(.fullScreen), window.contentView?.bounds.size != content {
                let top = window.frame.maxY
                window.setContentSize(content)
                window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
            }
        }
        layoutPicture(rebuild: false)
        hint = ""
        rebuildModel()
    }

    private func rebuildModel() {
        guard let geometry, let window, let size = view?.bounds.size, size.width > 0, size.height > 0 else { return }
        do {
            var rebuilt = try GameInputModel(profile: profile, geometry: geometry,
                                             viewWidth: Double(size.width), viewHeight: Double(size.height))
            rebuilt.setFocused(window.isKeyWindow && !editing && !typing, at: clock())
            model = rebuilt
            statusNote = "mapping-ready"
            window.title = HostPaths.config.appName + (geometry.totalTurns == 0 ? "" : "（旋轉 \(geometry.totalTurns * 90)°）")
        } catch {
            model = nil; statusNote = "model-init-failed"; window.title = HostPaths.config.appName + "（輸入停用）"
            hint = "輸入初始化失敗"
        }
        refreshOverlay()
    }

    @objc func rotateView(_ sender: Any?) {
        guard !editing, !closed, let picture = lastPicture else { return }
        viewTurns = (viewTurns + 1) % 4
        if let g = GameGeometry(pictureWidth: picture.width, pictureHeight: picture.height,
                                streamRotation: picture.rotation, streamMap: streamMap, viewTurns: viewTurns) {
            requestGeometry(g)
        }
    }

    // MARK: Overlay

    private func refreshOverlay() {
        var state = OverlayState()
        let size = view?.bounds.size ?? .zero
        func stickRadius(_ stick: JoystickBinding) -> Double {
            guard let g = geometry, g.displayWidth > 0 else { return 0 }
            let pixels = stick.radius * Double(min(g.panelWidth, g.panelHeight))
            return pixels * Double(size.width) / Double(g.displayWidth)
        }
        if let editor {
            state.bindings = editor.bindings; state.pending = editor.pending
            state.selected = editor.selected; state.editing = true
            if let stick = editor.joystick {
                state.stickCenter = stick.center; state.stickRadius = stickRadius(stick)
                state.stickSelected = editor.joystickSelected
            }
            if !hint.isEmpty { state.banner = hint }
            else if editor.pending != nil { state.banner = "已選位置：按要綁的鍵；或 ⌘J 放 WASD 搖桿（Esc 取消）" }
            else if editor.joystickSelected { state.banner = "已選中搖桿：Delete 移除、⌘[ ⌘] 調整範圍、Esc 取消" }
            else if let index = editor.selected {
                state.banner = "已選中 [\(editor.bindings[index].label)]：按新鍵更換、Delete 移除、Esc 取消"
            } else {
                state.banner = "編輯模式：點畫面選位置再按鍵；點圓點可改鍵或移除；⌘E 儲存並離開"
            }
        } else {
            if let g = geometry, let shown = try? g.displayProfile(profile) {
                state.bindings = shown.bindings
                if let stick = shown.joystick { state.stickCenter = stick.center; state.stickRadius = stickRadius(stick) }
            }
            state.banner = !hint.isEmpty ? hint
                : "遊玩中（\(profile.bindings.count) 鍵\(profile.joystick == nil ? "" : "＋搖桿")）｜⌘E 編輯｜⌘R 旋轉｜⌘T 打字（中文可）"
        }
        overlay?.state = state
    }

    // MARK: Input routing

    private func route(_ action: InputAction) {
        guard !closed, pendingGeometry == nil, !resizing, !pendingRebuild, !typing else { return }
        if editing { handleEdit(action); return }
        guard var model else { return }
        let disposition = model.send(action, at: clock()); self.model = model
        maxHeldContacts = max(maxHeldContacts, model.heldContacts)
        switch action {
        case .keyDown, .keyUp:
            keyEvents += 1
            if disposition == .consume { keysConsumed += 1 }
        default: mouseEvents += 1
        }
        drain()
    }

    private func handleEdit(_ action: InputAction) {
        guard var editor else { return }
        hint = ""
        switch action {
        case .leftDown(let point): editor.click(x: point.x, y: point.y)
        case .leftMove(let point): editor.drag(x: point.x, y: point.y)
        case .keyDown(let code, let autorepeat) where !autorepeat:
            switch editor.key(code) {
            case .exit: self.editor = editor; endEdit(); return
            case .rejected(.duplicate): hint = "此鍵已被使用（搖桿占用 W A S D），請換一個鍵"
            case .rejected(.full): hint = "最多只能綁 \(MappingProfile.maximumBindings) 個鍵"
            case .rejected(.reserved): hint = "這個鍵不能綁定，請換一個鍵"
            default: break
            }
        default: break
        }
        self.editor = editor
        refreshOverlay()
    }

    // MARK: Keymap editing

    @objc func toggleEdit(_ sender: Any?) {
        if editing { endEdit() } else { beginEdit() }
    }

    @objc func placeJoystick(_ sender: Any?) {
        guard var editor else { return }
        hint = editor.placeJoystick() == .rejected(.duplicate) ? "W A S D 已綁成技能鍵，請先移除再放搖桿" : ""
        self.editor = editor; refreshOverlay()
    }
    @objc func joystickLarger(_ sender: Any?) { resizeStick(0.02) }
    @objc func joystickSmaller(_ sender: Any?) { resizeStick(-0.02) }
    private func resizeStick(_ delta: Double) {
        guard var editor else { return }
        _ = editor.resizeJoystick(by: delta); self.editor = editor; refreshOverlay()
    }

    private func beginEdit() {
        guard window != nil, !closed, !typing, model != nil, pendingGeometry == nil, let geometry,
              let shown = try? geometry.displayProfile(profile) else { return }
        // Stop the mapping first; contacts it holds are released through cleanup requests.
        if var model { model.setFocused(false, at: clock()); self.model = model; drain() }
        editor = KeymapEditor(bindings: shown.bindings, joystick: shown.joystick,
                              viewWidth: Double(view?.bounds.width ?? 0),
                              viewHeight: Double(view?.bounds.height ?? 0))
        exitingEdit = false; hint = ""
        window?.title = HostPaths.config.appName + "（編輯按鍵）"
        refreshOverlay()
    }

    private func endEdit() {
        guard editing else { return }
        exitingEdit = true
    }

    /// Runs once nothing is in flight: save, rebuild the model on the new keymap, re-arm.
    private func finishEdit() {
        guard let editor, let geometry else { return }
        exitingEdit = false
        hint = ""
        do {
            let updated = try geometry.storedProfile(fromDisplay: editor.profile())
            try saveKeymap(updated)
            profile = updated; keymapSaves += 1
        } catch {
            keymapSaveFailures += 1; hint = "儲存失敗，按鍵設定未變更"
        }
        self.editor = nil
        rebuildModel()
    }

    // MARK: Sending

    /// Called every loop turn: applies a pending layout or edit exit once idle,
    /// re-arms after refocus, then keeps at most one sender in flight.
    func tick() {
        let idle = inFlight == nil && (model?.quiescent ?? true)
        if let pending = pendingGeometry, idle { apply(pending) }
        else if pendingRebuild, !resizing, idle { pendingRebuild = false; hint = ""; rebuildModel() }
        if exitingEdit, idle { finishEdit() }
        if let next = pendingProfile, idle, !editing {
            pendingProfile = nil
            do { try saveKeymap(next); profile = next; keymapSaves += 1; hint = "已載入按鍵設定" }
            catch { keymapSaveFailures += 1; hint = "載入失敗，按鍵設定未變更" }
            rebuildModel()
        }
        guard var model, !editing, pendingGeometry == nil else { drain(); return }
        model.tick(at: clock()); self.model = model
        drain()
    }

    private func drain() {
        guard inFlight == nil, var model, let request = model.nextRequest(at: clock()) else { return }
        self.model = model
        touchRequests += 1
        let send = sendTouch
        inFlight = Task { @MainActor [weak self] in
            let outcome = await send(request)
            guard let self else { return }
            if outcome != .acknowledged { self.touchFailures += 1 }
            if var model = self.model {
                model.complete(sequence: request.sequence, outcome: outcome); self.model = model
                if model.faulted {
                    self.statusNote = "input-fault"; self.window?.title = HostPaths.config.appName + "（輸入錯誤）"
                    self.hint = "輸入發生錯誤，已停止；請關閉視窗"; self.refreshOverlay()
                }
            }
            self.inFlight = nil
            self.drain()
        }
    }

    /// Stops the mapping and reports whether every contact is released.
    func beginShutdown() {
        editor = nil; exitingEdit = false; pendingGeometry = nil
        textField?.removeFromSuperview(); textField = nil
        guard var model else { return }
        model.setFocused(false, at: clock()); self.model = model
        drain()
    }

    var drained: Bool { inFlight == nil && (model?.quiescent ?? true) }
    var heldContacts: Int { model?.heldContacts ?? 0 }

    // MARK: Resizing and text mode

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // The editor works in fixed view coordinates; finish editing first.
        editing || pendingGeometry != nil ? sender.frame.size : frameSize
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        resizing = true
        if var model { model.setFocused(false, at: clock()); self.model = model; drain() }
        hint = "調整大小中，放開後恢復操作"; refreshOverlay()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        resizing = false
        guard let geometry, let width = view?.bounds.width, width > 0 else { return }
        scale = Double(width) / Double(geometry.displayWidth)
        resizes += 1
        // The model's view size is rebuilt only once every contact is released.
        pendingRebuild = true
    }

    /// Chinese text cannot go through sendKey (ASCII only), so hand the
    /// keyboard to the official window. Our window loses key status, which
    /// already stops the mapping and releases contacts; clicking back re-arms.
    @objc func textMode(_ sender: Any?) {
        guard !closed, let pid = officialPID,
              let official = NSRunningApplication(processIdentifier: pid) else {
            hint = "找不到官方模擬器視窗（預設隱藏；啟動時加 --window 才有）"; refreshOverlay(); return
        }
        textModeSwitches += 1
        official.activate()
    }

    // MARK: In-window typing

    /// Stops the mapping (releasing contacts) and shows a native text field, so
    /// the macOS input method works. Tap the game's chat box in Android first.
    @objc func openTextInput(_ sender: Any?) {
        guard !closed, !typing, !editing, pendingGeometry == nil, sendText != nil,
              let window, let view else { return }
        if var model { model.setFocused(false, at: clock()); self.model = model; drain() }
        let height: CGFloat = 28
        let field = NSTextField(frame: NSRect(x: 8, y: 8, width: view.bounds.width - 16, height: height))
        field.autoresizingMask = [.width]
        field.placeholderString = "輸入文字，Enter 送出、Esc 取消（先在遊戲裡點開聊天框）"
        field.delegate = self; field.target = self; field.action = #selector(submitText(_:))
        field.font = .systemFont(ofSize: 14)
        view.addSubview(field)
        textField = field
        window.makeFirstResponder(field)
        hint = "打字模式：映射已暫停"; refreshOverlay()
    }

    @objc private func submitText(_ sender: NSTextField) {
        guard !textSending, let sendText else { return }
        guard let text = TextSender.validated(sender.stringValue) else {
            hint = "請輸入 1～\(TextSender.maximumCharacters) 字（單行）"; refreshOverlay(); return
        }
        textSending = true; sender.isEnabled = false
        Task { @MainActor in
            let ok = await sendText(text)
            self.textSending = false
            if ok { self.textSends += 1; self.closeTextInput(hint: "") }
            else {
                self.textFailures += 1; sender.isEnabled = true
                self.hint = "送出失敗（未重試）；確認遊戲聊天框已點開"; self.refreshOverlay()
            }
        }
    }

    private func closeTextInput(hint newHint: String) {
        textField?.removeFromSuperview(); textField = nil
        if let window, let view { window.makeFirstResponder(view) }
        hint = newHint
        if var model { model.setFocused(window?.isKeyWindow ?? false, at: clock()); self.model = model }
        refreshOverlay()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), !textSending else { return false }
        closeTextInput(hint: ""); return true
    }

    // MARK: Picture fit, toolbar and window chrome

    /// Fits the picture into the game area. A real size change stops the
    /// mapping now; the model is rebuilt once contacts are released.
    private func layoutPicture(rebuild: Bool = true) {
        guard let stage, let view, let geometry = pendingGeometry ?? geometry else { return }
        let frame = GameLayout.fit(displayWidth: geometry.displayWidth, displayHeight: geometry.displayHeight,
                                   in: stage.bounds.size)
        guard frame.width > 0, frame != view.frame else { return }
        view.frame = frame
        guard rebuild, model != nil else { return }
        if var model { model.setFocused(false, at: clock()); self.model = model; drain() }
        pendingRebuild = true
    }

    private func makeToolbar(height: CGFloat) -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: GameLayout.toolbarWidth, height: height))
        let stack = NSStackView(frame: bar.bounds)
        stack.orientation = .vertical; stack.spacing = 6; stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        stack.autoresizingMask = [.width, .height]
        func button(_ symbol: String, _ tip: String, _ action: Selector, tag: Int = 0) -> NSButton {
            let b: NSButton
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
                b = NSButton(image: image, target: self, action: action)
            } else { b = NSButton(title: String(tip.prefix(2)), target: self, action: action) }
            b.isBordered = false; b.toolTip = tip; b.tag = tag
            b.symbolConfiguration = .init(pointSize: 17, weight: .regular)
            b.widthAnchor.constraint(equalToConstant: 40).isActive = true
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            toolbarButtons.append(b)
            return b
        }
        var top: [NSView] = [
            button("keyboard", "按鍵設定（⌘E）", #selector(toggleEdit(_:))),
            button("character.cursor.ibeam", "打字，中文可（⌘T）", #selector(openTextInput(_:))),
            button("camera", "截圖並複製（⌘S）", #selector(screenshot(_:))),
            button("rotate.right", "旋轉畫面（⌘R）", #selector(rotateView(_:))),
            button("arrow.up.left.and.arrow.down.right", "全螢幕（⌃⌘F）", #selector(toggleFullScreen(_:))),
        ]
        if sendAndroidKey != nil {
            let symbols: [AndroidKey: String] = [.volumeUp: "speaker.wave.3", .volumeDown: "speaker.wave.1",
                                                 .back: "arrow.uturn.backward", .home: "house", .recents: "square.on.square"]
            for key in [AndroidKey.volumeUp, .volumeDown, .back, .home, .recents] {
                top.append(button(symbols[key]!, key.label, #selector(androidKey(_:)),
                                  tag: AndroidKey.allCases.firstIndex(of: key)!))
            }
        }
        stack.setViews(top, in: .top)
        stack.setViews([button("xmark.circle", "結束遊玩（⌘Q）", #selector(endPlay(_:)))], in: .bottom)
        bar.addSubview(stack)
        return bar
    }

    private func busyHint() -> Bool {
        if editing { hint = "編輯按鍵中：先按 ⌘E 儲存並離開"; refreshOverlay(); return true }
        if typing { hint = "打字中：Enter 送出或 Esc 取消"; refreshOverlay(); return true }
        return false
    }

    /// The picture as shown: the last CGImage, or (fast path) a copy of the mapped frame.
    private func currentPicture() -> CGImage? {
        if let lastShown { return lastShown }
        guard let mapping = fastMapping, let size = lastMapped,
              let data = mapping.copyFrame(width: size.width, height: size.height),
              let image = FrameRenderer.image(rgba: data, width: size.width, height: size.height) else { return nil }
        return FrameRenderer.rotated(image, clockwise: geometry?.viewTurns ?? viewTurns)
    }

    @objc func screenshot(_ sender: Any?) {
        guard !closed, let image = currentPicture() else { return }
        guard let path = GameScreenshot.save(image) else { hint = "截圖存檔失敗"; refreshOverlay(); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
        screenshots += 1
        hint = "已截圖並複製：\(URL(fileURLWithPath: path).lastPathComponent)"; refreshOverlay()
    }

    @objc func toggleFullScreen(_ sender: Any?) {
        guard !closed, pendingGeometry == nil, !busyHint() else { return }
        window?.toggleFullScreen(nil)
    }

    @objc func androidKey(_ sender: NSButton) {
        guard !closed, !busyHint(), let send = sendAndroidKey,
              AndroidKey.allCases.indices.contains(sender.tag) else { return }
        let key = AndroidKey.allCases[sender.tag]
        Task { @MainActor in
            if await send(key) { self.androidKeys += 1 }
            else { self.hint = "\(key.label)送出失敗（未重試）"; self.refreshOverlay() }
        }
    }

    @objc func endPlay(_ sender: Any?) { closeWindow() }

    private func pauseForWindowChange() {
        resizing = true
        if var model { model.setFocused(false, at: clock()); self.model = model; drain() }
    }
    func windowWillEnterFullScreen(_ notification: Notification) { pauseForWindowChange() }
    func windowWillExitFullScreen(_ notification: Notification) { pauseForWindowChange() }
    func windowDidEnterFullScreen(_ notification: Notification) { resizing = false; pendingRebuild = true }
    func windowDidExitFullScreen(_ notification: Notification) { resizing = false; pendingRebuild = true }

    // MARK: Keymap profiles

    @objc func saveKeymapAs(_ sender: Any?) {
        guard !closed, !busyHint() else { return }
        let alert = NSAlert()
        alert.messageText = "另存按鍵設定"
        alert.informativeText = "輸入名稱（1～32 字，不含 / \\ :）。同名會覆蓋。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "儲存"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let name = GameKeymapStore.validProfileName(field.stringValue) else {
            hint = "名稱不符合規則"; refreshOverlay(); return
        }
        do { try GameKeymapStore.saveProfile(profile, name: name); hint = "已另存為「\(name)」" }
        catch { hint = "另存失敗" }
        refreshOverlay()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let names = GameKeymapStore.profileNames()
        if names.isEmpty { menu.addItem(withTitle: "（尚無另存的設定）", action: nil, keyEquivalent: "").isEnabled = false }
        for name in names {
            let item = menu.addItem(withTitle: name, action: #selector(loadKeymap(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = name
        }
    }

    /// Loading replaces the active keymap once every contact is released.
    @objc func loadKeymap(_ sender: NSMenuItem) {
        guard !closed, !busyHint(), let name = sender.representedObject as? String else { return }
        do {
            let next = try GameKeymapStore.loadProfile(name: name)
            if var model { model.setFocused(false, at: clock()); self.model = model; drain() }
            pendingProfile = next; hint = "載入「\(name)」中…"
        } catch { hint = "讀取「\(name)」失敗" }
        refreshOverlay()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !editing, pendingGeometry == nil, !resizing, !pendingRebuild, !typing, var model else { return }
        model.setFocused(true, at: clock()); self.model = model
    }
    func windowDidResignKey(_ notification: Notification) {
        guard var model else { return }
        model.setFocused(false, at: clock()); self.model = model
        drain()
    }
    func windowWillClose(_ notification: Notification) {
        closed = true
        displayLink?.invalidate(); displayLink = nil
    }

    /// Quit / Dock / signal path: closing the window ends the pump, which drains first.
    func closeWindow() {
        guard let window, !closed else { closed = true; return }
        window.close()
    }
}
