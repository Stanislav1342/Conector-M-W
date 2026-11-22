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

struct RemoteKeyboard {
    let commandIsControl: Bool
    private var held: [Int64: UInt16] = [:]

    init(commandIsControl: Bool) { self.commandIsControl = commandIsControl }

    mutating func events(for key: Int64, down: Bool, flagsChanged: Bool) -> [Input] {
        guard var code = scanCodes[key] else { return [] }
        if commandIsControl {
            if key == 55 { code = 0x1d }
            if key == 54 { code = 0x11d }
        }
        if key == 57 && flagsChanged {
            return [Input(kind: "key", code: code, down: true), Input(kind: "key", code: code)]
        }
        if down {
            let alreadyHeld = held.values.contains(code)
            held[key] = code
            // Only ordinary key presses repeat. Multiple physical modifiers can share one scan code.
            if alreadyHeld && flagsChanged { return [] }
        } else {
            guard held.removeValue(forKey: key) != nil, !held.values.contains(code) else { return [] }
        }
        return [Input(kind: "key", code: code, down: down)]
    }
}
