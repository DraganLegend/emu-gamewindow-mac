import InputCore

/// Input for the self-owned game window. Events come from our own NSView, so
/// there is no tap, window matching or permission state: the reducer's target
/// context reduces to "this window is key". Pure and synchronous; the caller
/// confines it to one actor and owns the single in-flight sender.
///
/// The reducer works in panel-normalized space (its display rect is the unit
/// square); this model turns view points into that space through the frame
/// geometry, so view rotation never reaches the core.
struct GameInputModel {
    private(set) var reducer: InputReducer
    private(set) var focused = false
    let geometry: GameGeometry
    let viewWidth: Double
    let viewHeight: Double
    private var sequence: UInt64 = 0
    private let generation: UInt64 = 1
    private let sessionGeneration: UInt64

    init(profile: MappingProfile, geometry: GameGeometry, viewWidth: Double, viewHeight: Double,
         sessionGeneration: UInt64 = 1, limits: ContactLimits = .game) throws {
        guard viewWidth.isFinite, viewHeight.isFinite, viewWidth > 0, viewHeight > 0 else {
            throw InputCoreError.invalidGeometry
        }
        let unit = HostRect(x: 0, y: 0, width: 1, height: 1)
        let calibration = try InputCalibration(generation: 1, width: geometry.panelWidth, height: geometry.panelHeight,
                                               rotation: 0, displayRect: unit, interactionRect: unit)
        // `profile` is the stored keymap; stick roles turn with the view.
        reducer = try InputReducer(profile: geometry.coreProfile(profile), calibration: calibration,
                                   sessionGeneration: sessionGeneration, limits: limits)
        self.geometry = geometry; self.viewWidth = viewWidth; self.viewHeight = viewHeight
        self.sessionGeneration = sessionGeneration
    }

    /// Unrotated convenience used by tests and a rotation-0 stream.
    init(profile: MappingProfile, width: Int, height: Int, viewWidth: Double, viewHeight: Double,
         sessionGeneration: UInt64 = 1, limits: ContactLimits = .game) throws {
        guard let geometry = GameGeometry(pictureWidth: width, pictureHeight: height, streamRotation: 0,
                                          streamMap: .cw, viewTurns: 0) else { throw InputCoreError.invalidGeometry }
        try self.init(profile: profile, geometry: geometry, viewWidth: viewWidth, viewHeight: viewHeight,
                      sessionGeneration: sessionGeneration, limits: limits)
    }

    private var context: InputContext {
        .init(targetVerified: true, focused: focused, calibrationGeneration: generation,
              sessionGeneration: sessionGeneration, permissionAvailable: true, systemShortcutActive: false)
    }

    /// View point (top-left origin, points) -> panel-normalized host point.
    func panelPoint(_ point: HostPoint) -> HostPoint {
        let (x, y) = geometry.panel(fromDisplay: point.x / viewWidth, point.y / viewHeight)
        return .init(x: x, y: y)
    }

    private func mapped(_ action: InputAction) -> InputAction {
        switch action {
        case .leftDown(let p): return .leftDown(panelPoint(p))
        case .leftMove(let p): return .leftMove(panelPoint(p))
        case .leftUp(let p): return .leftUp(panelPoint(p))
        default: return action
        }
    }

    @discardableResult
    mutating func send(_ action: InputAction, at ms: Int64) -> EventDisposition {
        sequence += 1
        return reducer.handle(.init(sequence: sequence, milliseconds: ms, action: mapped(action)),
                              context: context).disposition
    }

    /// Losing key status stops the mapping; the reducer then drains its own
    /// contacts through cleanup requests. Regaining it re-arms on `tick`.
    mutating func setFocused(_ value: Bool, at ms: Int64) {
        guard value != focused else { return }
        focused = value
        send(value ? .tick : .cancel, at: ms)
        guard !value else { return }
        // A non-key window gets no key/mouse-up, so anything still "pressed"
        // is treated as released; otherwise the reducer would stay draining.
        for source in Array(reducer.captured) {
            switch source {
            case .key(let code): send(.keyUp(code), at: ms)
            case .left: send(.leftUp(HostPoint(x: 0, y: 0)), at: ms)
            case .right: send(.rightUp, at: ms)
            case .joystick: break // Never captured; its keys are `.key`.
            }
        }
    }

    mutating func tick(at ms: Int64) {
        if focused && reducer.state == .disabled { send(.enable(PhysicalSnapshot()), at: ms) }
        else { send(.tick, at: ms) }
    }

    mutating func nextRequest(at ms: Int64) -> ContactRequest? { reducer.nextRequest(at: ms, context: context) }
    @discardableResult
    mutating func complete(sequence: UInt64, outcome: DispatchOutcome) -> Bool {
        reducer.complete(sequence: sequence, outcome: outcome, context: context)
    }

    var state: MappingState { reducer.state }
    var heldContacts: Int { reducer.contacts.count }
    var quiescent: Bool {
        reducer.dispatcher.isQuiescent && reducer.contacts.isEmpty && reducer.captured.isEmpty
    }
    var faulted: Bool { reducer.state == .faulted }
}
