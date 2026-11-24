import Foundation

struct PointerMotion {
    let speed: Double
    private var remainderX = 0.0
    private var remainderY = 0.0

    init(speed: Double) {
        self.speed = speed.isFinite ? min(2, max(0.4, speed)) : 1
    }

    mutating func scale(x: Int32, y: Int32) -> (x: Int32, y: Int32) {
        let scaledX = Double(min(5000, max(-5000, x))) * speed + remainderX
        let scaledY = Double(min(5000, max(-5000, y))) * speed + remainderY
        let wholeX = scaledX.rounded(.towardZero)
        let wholeY = scaledY.rounded(.towardZero)
        remainderX = scaledX - wholeX
        remainderY = scaledY - wholeY
        return (Int32(wholeX), Int32(wholeY))
    }
}

struct ScrollMotion {
    let smoothness: Double
    private var remainderX = 0.0
    private var remainderY = 0.0

    init(smoothness: Double) {
        self.smoothness = smoothness.isFinite ? min(3.0, max(0.2, smoothness)) : 1.0
    }

    mutating func scale(x: Double, y: Double, continuous: Bool) -> (x: Int32, y: Int32) {
        let clampedX = continuous ? min(4000.0, max(-4000.0, x)) : min(50.0, max(-50.0, x))
        let clampedY = continuous ? min(4000.0, max(-4000.0, y)) : min(50.0, max(-50.0, y))
        let factor = (continuous ? 2.2 : 120.0) * smoothness
        let scaledX = clampedX * factor + remainderX
        let scaledY = clampedY * factor + remainderY
        let wholeX = scaledX.rounded(.towardZero)
        let wholeY = scaledY.rounded(.towardZero)
        remainderX = scaledX - wholeX
        remainderY = scaledY - wholeY
        let outX = Int32(min(10000.0, max(-10000.0, wholeX)))
        let outY = Int32(min(10000.0, max(-10000.0, wholeY)))
        return (outX, outY)
    }
}

struct TopEdgePush {
    let threshold: Int32
    let maxStep: Int32
    let window: TimeInterval
    private var push: Int32 = 0
    private var lastPush: TimeInterval = -.infinity

    init(threshold: Int32 = -75, maxStep: Int32 = -45, window: TimeInterval = 0.25) {
        self.threshold = threshold
        self.maxStep = maxStep
        self.window = window
    }

    mutating func reset() {
        push = 0
        lastPush = -.infinity
    }

    mutating func advance(dx: Int32, dy: Int32, atTopEdge: Bool, now: TimeInterval) -> Bool {
        guard atTopEdge, dy < 0, abs(dx) <= -dy else {
            reset()
            return false
        }
        if now - lastPush > window {
            push = 0
        }
        lastPush = now
        push += max(maxStep, dy)
        guard push <= threshold else { return false }
        reset()
        return true
    }
}

enum ThreeFingerSwipeAction: String, CaseIterable {
    case desktops
    case switchApps
    case browserHistory
    case off
}

enum SwipeDirection: Equatable {
    case left
    case right
    case up
    case down
}

struct ThreeFingerSwipeDetector {
    private var anchor: (x: Double, y: Double)?
    private var triggeredInGesture = false
    private var lastTrigger: TimeInterval = -.infinity
    private var lastUpdate: TimeInterval = -.infinity

    mutating func reset() {
        anchor = nil
        triggeredInGesture = false
    }

    mutating func update(touchCount: Int, x: Double, y: Double, now: TimeInterval) -> SwipeDirection? {
        if now - lastUpdate > 0.25 {
            reset()
        }
        lastUpdate = now
        guard touchCount == 3 else {
            reset()
            return nil
        }
        guard let anchor else {
            self.anchor = (x, y)
            return nil
        }
        guard !triggeredInGesture, now - lastTrigger >= 0.35 else { return nil }
        let dx = x - anchor.x
        let dy = y - anchor.y
        if abs(dx) >= 0.11, abs(dx) > abs(dy) * 1.35 {
            triggeredInGesture = true
            lastTrigger = now
            return dx < 0 ? .left : .right
        }
        if dy >= 0.11, dy > abs(dx) * 1.35 {
            triggeredInGesture = true
            lastTrigger = now
            return .up
        }
        if dy <= -0.11, -dy > abs(dx) * 1.35 {
            triggeredInGesture = true
            lastTrigger = now
            return .down
        }
        return nil
    }
}

func swipeShortcutAction(direction: SwipeDirection, horizontalAction: ThreeFingerSwipeAction, upEnabled: Bool, downEnabled: Bool) -> String? {
    switch direction {
    case .up:
        return upEnabled ? "taskView" : nil
    case .down:
        return downEnabled ? "showDesktop" : nil
    case .left, .right:
        switch horizontalAction {
        case .off:
            return nil
        case .desktops:
            return direction == .left ? "desktopNext" : "desktopPrev"
        case .switchApps:
            return direction == .left ? "switchAppNext" : "switchAppPrev"
        case .browserHistory:
            return direction == .left ? "browserForward" : "browserBack"
        }
    }
}

func swipeKeySequence(direction: SwipeDirection, horizontalAction: ThreeFingerSwipeAction, upEnabled: Bool, downEnabled: Bool = true) -> [Input] {
    let combo: [UInt16]
    switch direction {
    case .up:
        guard upEnabled else { return [] }
        combo = [0x15b, 0x0f] // Win + Tab
    case .down:
        guard downEnabled else { return [] }
        combo = [0x15b, 0x20] // Win + D
    case .left, .right:
        switch horizontalAction {
        case .off:
            return []
        case .desktops:
            combo = [0x1d, 0x15b, direction == .left ? 0x14d : 0x14b] // Ctrl + Win + Right / Left
        case .switchApps:
            combo = direction == .left ? [0x38, 0x0f] : [0x38, 0x2a, 0x0f] // Alt+Tab / Alt+Shift+Tab
        case .browserHistory:
            combo = [0x38, direction == .left ? 0x14d : 0x14b] // Alt + Right / Left
        }
    }
    return combo.map { Input(kind: "key", code: $0, down: true) } +
           combo.reversed().map { Input(kind: "key", code: $0, down: false) }
}

struct RemoteKeyboard {
    let commandIsControl: Bool
    let commandSpaceSwitchesLanguage: Bool
    private var held: [Int64: UInt16] = [:]
    private var physicalCommand: Set<Int64> = []
    private var suppressedCommand: [Int64: UInt16] = [:]
    private var languageSwitchActive = false

    private static let commandKeys: [Int64] = [55, 54]
    private static let otherModifiers: Set<Int64> = [56, 60, 58, 61, 59, 62]

    init(commandIsControl: Bool, commandSpaceSwitchesLanguage: Bool = true) {
        self.commandIsControl = commandIsControl
        self.commandSpaceSwitchesLanguage = commandSpaceSwitchesLanguage
    }

    private var otherModifierHeld: Bool {
        held.keys.contains { Self.otherModifiers.contains($0) }
    }

    mutating func events(for key: Int64, down: Bool, flagsChanged: Bool) -> [Input] {
        guard var code = scanCodes[key] else { return [] }
        if commandIsControl {
            if key == 55 { code = 0x1d }
            if key == 54 { code = 0x11d }
        }
        if key == 57 && flagsChanged {
            return [Input(kind: "key", code: code, down: true), Input(kind: "key", code: code)]
        }
        if flagsChanged && (key == 55 || key == 54) {
            if down {
                physicalCommand.insert(key)
            } else {
                physicalCommand.remove(key)
                if suppressedCommand.removeValue(forKey: key) != nil { return [] }
            }
        }
        if key == 49 && !flagsChanged {
            if down {
                if languageSwitchActive { return [] }
                if commandSpaceSwitchesLanguage, !physicalCommand.isEmpty, !otherModifierHeld, held[49] == nil {
                    languageSwitchActive = true
                    var releasedCmdUps: [Input] = []
                    for cmdKey in Self.commandKeys {
                        if let cmdCode = held.removeValue(forKey: cmdKey) {
                            suppressedCommand[cmdKey] = cmdCode
                            if !held.values.contains(cmdCode) {
                                releasedCmdUps.append(Input(kind: "key", code: cmdCode, down: false))
                            }
                        }
                    }
                    var sequence: [Input] = []
                    if commandIsControl {
                        sequence.append(contentsOf: releasedCmdUps)
                        sequence.append(Input(kind: "key", code: 0x2a, down: true))
                        sequence.append(Input(kind: "key", code: 0x38, down: true))
                    } else {
                        // Hold Shift before releasing Win so Windows does not open the Start menu.
                        sequence.append(Input(kind: "key", code: 0x2a, down: true))
                        sequence.append(contentsOf: releasedCmdUps)
                        sequence.append(Input(kind: "key", code: 0x38, down: true))
                    }
                    return sequence
                }
            } else if languageSwitchActive {
                languageSwitchActive = false
                return [Input(kind: "key", code: 0x38, down: false), Input(kind: "key", code: 0x2a, down: false)]
            }
        }
        var prefix: [Input] = []
        if down, !languageSwitchActive, !suppressedCommand.isEmpty, !(flagsChanged && (key == 55 || key == 54)) {
            for cmdKey in Self.commandKeys {
                if let cmdCode = suppressedCommand.removeValue(forKey: cmdKey) {
                    let alreadyHeld = held.values.contains(cmdCode)
                    held[cmdKey] = cmdCode
                    if !alreadyHeld {
                        prefix.append(Input(kind: "key", code: cmdCode, down: true))
                    }
                }
            }
        }
        if down {
            let alreadyHeld = held.values.contains(code)
            held[key] = code
            // Only ordinary key presses repeat. Multiple physical modifiers can share one scan code.
            if alreadyHeld && flagsChanged { return prefix }
        } else {
            guard held.removeValue(forKey: key) != nil, !held.values.contains(code) else { return prefix }
        }
        return prefix + [Input(kind: "key", code: code, down: down)]
    }
}
