// Logic tests for the Mac app. Built by scripts/test-mac.sh together with
// mac/Protocol.swift and mac/InputProcessing.swift; needs only the Command Line Tools.
import CoreGraphics
import Foundation

var failures = 0
var checks = 0

func test(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print(failures == before ? "ok    \(name)" : "FAIL  \(name)")
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String = "", line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("      line \(line): \(message)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", line: Int = #line) {
    expect(actual == expected, "\(message) got \(actual), want \(expected)", line: line)
}

extension Input: Equatable {
    public static func == (a: Input, b: Input) -> Bool {
        a.kind == b.kind && a.x == b.x && a.y == b.y && a.code == b.code && a.down == b.down
    }
}

func key(_ code: UInt16, _ down: Bool) -> Input { Input(kind: "key", code: code, down: down) }

// MARK: - Pointer motion

test("pointer speed is clamped to 0.4...2") {
    expectEqual(PointerMotion(speed: 0.1).speed, 0.4)
    expectEqual(PointerMotion(speed: 5).speed, 2)
    expectEqual(PointerMotion(speed: .nan).speed, 1)
    expectEqual(PointerMotion(speed: .infinity).speed, 1)
}

test("fractional speed carries the remainder instead of losing it") {
    var motion = PointerMotion(speed: 1.5)
    let steps = (0..<4).map { _ in motion.scale(x: 1, y: -1) }
    expectEqual(steps.map(\.x), [1, 2, 1, 2])
    expectEqual(steps.map(\.y), [-1, -2, -1, -2])
}

test("slow speed still moves after enough small deltas") {
    var motion = PointerMotion(speed: 0.4)
    let total = (0..<10).reduce(Int32(0)) { sum, _ in sum + motion.scale(x: 1, y: 0).x }
    expectEqual(total, 4)
}

test("huge deltas are clamped before scaling") {
    var motion = PointerMotion(speed: 2)
    let moved = motion.scale(x: .max, y: .min)
    expectEqual(moved.x, 10000)
    expectEqual(moved.y, -10000)
}

// MARK: - Keyboard

test("ordinary key press and release") {
    var keyboard = RemoteKeyboard(commandIsControl: true)
    expectEqual(keyboard.events(for: 0, down: true, flagsChanged: false), [key(0x1e, true)])
    expectEqual(keyboard.events(for: 0, down: false, flagsChanged: false), [key(0x1e, false)])
}

test("auto-repeat sends repeated key-downs") {
    var keyboard = RemoteKeyboard(commandIsControl: true)
    _ = keyboard.events(for: 0, down: true, flagsChanged: false)
    expectEqual(keyboard.events(for: 0, down: true, flagsChanged: false), [key(0x1e, true)])
}

test("release without press is dropped") {
    var keyboard = RemoteKeyboard(commandIsControl: true)
    expectEqual(keyboard.events(for: 0, down: false, flagsChanged: false), [])
}

test("unmapped Mac keys produce nothing") {
    var keyboard = RemoteKeyboard(commandIsControl: true)
    expectEqual(keyboard.events(for: 63, down: true, flagsChanged: true), [], "fn")
    expectEqual(keyboard.events(for: 160, down: true, flagsChanged: false), [], "mission control")
}

test("Command maps to Ctrl by default and to Win when disabled") {
    var asControl = RemoteKeyboard(commandIsControl: true)
    expectEqual(asControl.events(for: 55, down: true, flagsChanged: true), [key(0x1d, true)], "left cmd")
    expectEqual(asControl.events(for: 54, down: true, flagsChanged: true), [key(0x11d, true)], "right cmd")
    var asWindows = RemoteKeyboard(commandIsControl: false)
    expectEqual(asWindows.events(for: 55, down: true, flagsChanged: true), [key(0x15b, true)], "left cmd")
    expectEqual(asWindows.events(for: 54, down: true, flagsChanged: true), [key(0x15c, true)], "right cmd")
}

test("Option maps to Alt") {
    var keyboard = RemoteKeyboard(commandIsControl: true)
    expectEqual(keyboard.events(for: 58, down: true, flagsChanged: true), [key(0x38, true)])
    expectEqual(keyboard.events(for: 61, down: true, flagsChanged: true), [key(0x138, true)])
}

test("Cmd and Control sharing Ctrl keep it held until both are up") {
    var keyboard = RemoteKeyboard(commandIsControl: true)
    expectEqual(keyboard.events(for: 59, down: true, flagsChanged: true), [key(0x1d, true)])
    expectEqual(keyboard.events(for: 55, down: true, flagsChanged: true), [], "second Ctrl source")
    expectEqual(keyboard.events(for: 59, down: false, flagsChanged: true), [], "Ctrl still held by Cmd")
    expectEqual(keyboard.events(for: 55, down: false, flagsChanged: true), [key(0x1d, false)])
}

test("Caps Lock toggles with a press and release pair") {
    var keyboard = RemoteKeyboard(commandIsControl: true)
    expectEqual(keyboard.events(for: 57, down: true, flagsChanged: true), [key(0x3a, true), key(0x3a, false)])
    expectEqual(keyboard.events(for: 57, down: false, flagsChanged: true), [key(0x3a, true), key(0x3a, false)])
}

test("every scan code is accepted by the receiver") {
    // Mirrors event.valid() in windows/main.go.
    for (mac, code) in scanCodes {
        expect(code > 0 && code <= 0x17f && code != 0x100, "Mac key \(mac) -> \(String(code, radix: 16))")
    }
    for mac in modifierMasks.keys {
        expect(scanCodes[mac] != nil, "modifier \(mac) has no scan code")
    }
}

// MARK: - Wire format

test("Input encodes the fields the receiver decodes") {
    let data = try! JSONEncoder().encode(Input(kind: "key", code: 30, down: true))
    let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    expectEqual(Set(object.keys), ["kind", "x", "y", "code", "down"])
    expectEqual(object["kind"] as? String, "key")
    expectEqual(object["code"] as? Int, 30)
    expectEqual(object["down"] as? Bool, true)
}

test("entry position spans 0...65535 across the display") {
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    expectEqual(entryPosition(x: 0, in: display), 0)
    expectEqual(entryPosition(x: 756, in: display), 32767)
    expectEqual(entryPosition(x: 1512, in: display), 65535)
}

test("entry position is relative to the display origin") {
    let display = CGRect(x: -1512, y: 0, width: 1512, height: 982)
    expectEqual(entryPosition(x: -1512, in: display), 0)
    expectEqual(entryPosition(x: -756, in: display), 32767)
}

test("entry position never leaves the range the receiver accepts") {
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    expectEqual(entryPosition(x: -40, in: display), 0)
    expectEqual(entryPosition(x: 1600, in: display), 65535)
    expectEqual(entryPosition(x: .nan, in: display), 32768)
    expectEqual(entryPosition(x: 10, in: .zero), 32768)
}

test("power code matches the receiver's powerToken derivation") {
    // Same vector as TestPowerTokenDerivation in windows/pairing_test.go, cross-checked with openssl.
    expectEqual(powerCode(accessCode: "00112233445566778899aabbccddeeff"),
                "f8bcdd75a07ae2b7135b348261a0321d6b6aba4fc8b067b54928507d65f317b8")
}

// MARK: - Pairing code

test("pairing code from the receiver window parses") {
    let code = PairingCode("ABCD-EF01-2345-6789-042137")
    expectEqual(code?.prefix, "abcdef0123456789")
    expectEqual(code?.pin, "042137")
}

test("pairing code tolerates pasted whitespace") {
    expectEqual(PairingCode("  abcd ef01\t2345-6789 - 042137\n")?.pin, "042137")
}

test("malformed pairing codes are rejected") {
    expect(PairingCode("") == nil, "empty")
    expect(PairingCode("ABCD-EF01-2345-6789-04213") == nil, "short pin")
    expect(PairingCode("ABCD-EF01-2345-6789-0421377") == nil, "long pin")
    expect(PairingCode("GHIJ-EF01-2345-6789-042137") == nil, "non-hex prefix")
    expect(PairingCode("ABCD-EF01-2345-6789-04213a") == nil, "non-digit pin")
    expect(PairingCode("АБВГ-EF01-2345-6789-042137") == nil, "cyrillic")
}

// MARK: - Wake-on-LAN

test("MAC address accepts common notations") {
    for text in ["a8:5e:45:01:02:03", "A8-5E-45-01-02-03", "a85e45010203", " A8:5E:45:01:02:03 "] {
        expectEqual(WakeTarget(mac: text, broadcast: "192.168.1.255")?.mac, "a8:5e:45:01:02:03", text)
    }
}

test("invalid wake targets are rejected") {
    expect(WakeTarget(mac: "01:00:5e:00:00:01", broadcast: "192.168.1.255") == nil, "multicast MAC")
    expect(WakeTarget(mac: "00:00:00:00:00:00", broadcast: "192.168.1.255") == nil, "zero MAC")
    expect(WakeTarget(mac: "a8:5e:45:01:02", broadcast: "192.168.1.255") == nil, "five bytes")
    expect(WakeTarget(mac: "g8:5e:45:01:02:03", broadcast: "192.168.1.255") == nil, "non-hex")
    expect(WakeTarget(mac: "a8:5e:45:01:02:03", broadcast: "0.0.0.0") == nil, "zero broadcast")
    expect(WakeTarget(mac: "a8:5e:45:01:02:03", broadcast: "192.168.1") == nil, "short broadcast")
    expect(WakeTarget(mac: "a8:5e:45:01:02:03", broadcast: "fe80::1") == nil, "IPv6 broadcast")
}

test("magic packet is 6 x FF then the MAC 16 times") {
    let target = WakeTarget(mac: "a8:5e:45:01:02:03", broadcast: "192.168.1.255")!
    let packet = [UInt8](target.packet)
    expectEqual(packet.count, 102)
    expectEqual(Array(packet[0..<6]), [UInt8](repeating: 0xff, count: 6))
    for repeatIndex in 0..<16 {
        let start = 6 + repeatIndex * 6
        expectEqual(Array(packet[start..<start + 6]), [0xa8, 0x5e, 0x45, 0x01, 0x02, 0x03])
    }
}

// MARK: - Updates

test("release versions compare numerically") {
    expect(ReleaseVersion("0.10.0")! > ReleaseVersion("0.9.9")!)
    expect(ReleaseVersion("v1.0")! == ReleaseVersion("1.0.0")!)
    expect(ReleaseVersion("0.8.2")! < ReleaseVersion("0.8.3")!)
    expect(!(ReleaseVersion("0.8.2")! < ReleaseVersion("0.8.2")!))
    expectEqual(ReleaseVersion("v0.9.0")!.description, "0.9")
    expect(ReleaseVersion("") == nil)
    expect(ReleaseVersion("1.x") == nil)
    expect(ReleaseVersion("1..2") == nil)
    expect(ReleaseVersion("-1") == nil)
    expect(ReleaseVersion("1.2.3-beta") == nil)
}

test("release JSON yields the Mac archive") {
    let json = """
    {"tag_name":"v0.9.0","body":"Новое","html_url":"https://github.com/o/prilo/releases/tag/v0.9.0","draft":false,"prerelease":false,
     "assets":[{"name":"PriloReceiver.exe","browser_download_url":"https://github.com/o/prilo/releases/download/v0.9.0/PriloReceiver.exe"},
               {"name":"Prilo-Mac.zip","browser_download_url":"https://github.com/o/prilo/releases/download/v0.9.0/Prilo-Mac.zip"}]}
    """
    let info = ReleaseInfo.parse(Data(json.utf8))
    expectEqual(info?.version.description, "0.9")
    expectEqual(info?.notes, "Новое")
    expectEqual(info?.download.lastPathComponent, "Prilo-Mac.zip")
}

test("release JSON without archive, prerelease or https is ignored") {
    let noAsset = #"{"tag_name":"v1","html_url":"https://x/y","assets":[]}"#
    let pre = #"{"tag_name":"v1","html_url":"https://x/y","prerelease":true,"assets":[{"name":"Prilo-Mac.zip","browser_download_url":"https://x/z"}]}"#
    let plain = #"{"tag_name":"v1","html_url":"https://x/y","assets":[{"name":"Prilo-Mac.zip","browser_download_url":"http://x/z"}]}"#
    expect(ReleaseInfo.parse(Data(noAsset.utf8)) == nil)
    expect(ReleaseInfo.parse(Data(pre.utf8)) == nil)
    expect(ReleaseInfo.parse(Data(plain.utf8)) == nil)
    expect(ReleaseInfo.parse(Data("not json".utf8)) == nil)
}

print("\n\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
