import Foundation
import CoreGraphics

/// "pmset -g" prints "SleepDisabled<TAB><TAB>1"; the line is absent until the flag was set once.
/// An earlier shell check matched spaces only and always read 0, so accept both separators.
func parseSleepDisabled(_ output: String) -> Bool {
    for line in output.split(separator: "\n") {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if parts.count >= 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
    }
    return false
}

struct Reading {
    var onBattery: Bool
    var percent: Int
    var thermalSerious: Bool
}

/// Why the mode must switch off now, or nil to keep it on.
func autoOffReason(_ r: Reading, floor: Int = 15) -> String? {
    if r.thermalSerious { return "발열로 꺼짐" }
    if r.onBattery && r.percent <= floor { return "배터리 \(floor)% 이하라 꺼짐" }
    return nil
}

func shouldDimDisplay(on: Bool, lidClosed: Bool, external: Bool) -> Bool { on && lidClosed && !external }

/// Read only the battery profile; AC can have a different power mode.
func parseBatteryPowerMode(_ output: String) -> Int? {
    var battery = false
    for line in output.split(separator: "\n") {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(":") { battery = text == "Battery Power:"; continue }
        let fields = text.split(whereSeparator: { $0.isWhitespace })
        if battery, fields.count == 2, fields[0] == "powermode", let mode = Int(fields[1]), (0...2).contains(mode) { return mode }
    }
    return nil
}

/// Window layout keys: Control+Option + U I O J L K (all on the right hand).
enum LayoutAction: UInt32, CaseIterable {
    case leftThird = 1, centerThird, rightThird, leftHalf, rightHalf, centerHalf

    var keyCode: UInt32 {
        switch self {
        case .leftThird: return 32     // U
        case .centerThird: return 34   // I
        case .rightThird: return 31    // O
        case .leftHalf: return 38      // J
        case .rightHalf: return 37     // L
        case .centerHalf: return 40    // K
        }
    }
    var label: String { ["U", "I", "O", "J", "L", "K"][Int(rawValue) - 1] }
}

/// Left and right edge of the target inside a visible frame. Edges are rounded once so neighbouring thirds tile exactly.
private func edges(_ a: LayoutAction, _ f: CGRect) -> (CGFloat, CGFloat) {
    func e(_ frac: CGFloat) -> CGFloat { (f.minX + f.width * frac).rounded() }
    switch a {
    case .leftThird: return (f.minX, e(1.0 / 3))
    case .centerThird: return (e(1.0 / 3), e(2.0 / 3))
    case .rightThird: return (e(2.0 / 3), f.maxX)
    case .leftHalf: return (f.minX, e(0.5))
    case .rightHalf: return (e(0.5), f.maxX)
    case .centerHalf: return (e(0.25), e(0.75))   // the middle two of four columns
    }
}

func targetRect(_ a: LayoutAction, in f: CGRect) -> CGRect {
    let (l, r) = edges(a, f)
    return CGRect(x: l, y: f.minY, width: r - l, height: f.height)
}

/// Cocoa rect (origin bottom-left) -> Accessibility space (origin top-left of the primary screen).
func toAX(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}

/// Fan choices. The raw value is the argument of the root helper.
enum FanMode: String, CaseIterable {
    case auto
    case rpm4000 = "4000"
    case max

    var label: String {
        switch self {
        case .auto: return "자동"
        case .rpm4000: return "4000"
        case .max: return "최대"
        }
    }

    /// Island icon: a fan marked "auto", then a gauge at about 70% (4000 of ~5500 rpm) and at 100%.
    var symbol: String {
        switch self {
        case .auto: return "fan.badge.automatic"
        case .rpm4000: return "gauge.with.dots.needle.67percent"
        case .max: return "gauge.with.dots.needle.100percent"
        }
    }
}

/// The other SF Symbols the island uses. The self-test checks that every icon exists on this macOS.
enum Icon {
    static let mode = "laptopcomputer"
    static let quit = "power"
    static let permission = "hand.raised.fill"
}

struct FanInfo {
    var actual: Float
    var min: Float
    var max: Float
    var target: Float
    var mode: Int
}

/// Parses the helper's lines: "fan0 actual=3985.7 min=1499 max=5348 target=4000 mode=1".
func parseFanStatus(_ s: String) -> [FanInfo] {
    s.split(separator: "\n").compactMap { line in
        guard line.hasPrefix("fan") else { return nil }
        var kv: [String: Float] = [:]
        for part in line.split(separator: " ").dropFirst() {
            let p = part.split(separator: "=")
            if p.count == 2, let v = Float(p[1]) { kv[String(p[0])] = v }
        }
        guard let a = kv["actual"], let mn = kv["min"], let mx = kv["max"], let t = kv["target"], let m = kv["mode"] else { return nil }
        return FanInfo(actual: a, min: mn, max: mx, target: t, mode: Int(m))
    }
}

/// True when a manual fan mode is wanted but the system took control back (it does after sleep/wake) or the target drifted.
func fanNeedsReapply(_ want: FanMode, _ fans: [FanInfo]) -> Bool {
    guard want != .auto, !fans.isEmpty else { return false }
    return fans.contains { $0.mode != 1 || abs($0.target - (want == .max ? $0.max : 4000)) > 50 }
}

/// The island: a black shape that grows out of the camera notch, or out of the top edge on a screen without one.
/// Rects use Cocoa screen coordinates (origin bottom-left), like NSScreen.frame.
struct IslandLayout {
    var screen: CGRect
    /// Size of the notch; nil on a screen without one.
    var notch: CGSize?

    /// Open: the notch row, then a fixed strip of controls. A taller notch makes the island taller, so nothing is clipped.
    static let openWidth: CGFloat = 340
    static let controlsHeight: CGFloat = 68
    static let wordHeight: CGFloat = 36
    static let memeImageWidth: CGFloat = openWidth - 48
    static let memeImageHeight: CGFloat = 190

    var notchW: CGFloat { notch?.width ?? 170 }
    var notchH: CGFloat { notch?.height ?? 30 }
    var openSize: CGSize { CGSize(width: Self.openWidth, height: notchH + Self.controlsHeight) }

    /// Closed: exactly the notch, so nothing shows outside it. Anything left beside the notch stays put while a three-finger swipe slides the desktop away.
    var closedSize: CGSize { CGSize(width: notchW, height: notchH) }

    /// The window is as big as the open island, flush with the top edge of the screen and centred on it.
    var window: CGRect { window(showingInput: false) }

    func contentSize(open: Bool, showingInput: Bool, inputHeight: CGFloat = Self.wordHeight) -> CGSize {
        CGSize(width: open || showingInput ? Self.openWidth : notchW,
               height: notchH + (open ? Self.controlsHeight : 0) + (showingInput ? inputHeight : 0))
    }

    func window(showingInput: Bool, inputHeight: CGFloat = Self.wordHeight) -> CGRect {
        let o = contentSize(open: true, showingInput: showingInput, inputHeight: inputHeight)
        return CGRect(x: screen.midX - o.width / 2, y: screen.maxY - o.height, width: o.width, height: o.height)
    }

    static func memeImageSize(for size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return CGSize(width: memeImageWidth, height: memeImageHeight)
        }
        let scale = min(memeImageWidth / size.width, memeImageHeight / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    static func memeWindow(in screenFrame: CGRect, imageSize: CGSize, onRight: Bool = false) -> CGRect {
        let size = CGSize(width: imageSize.width + 16, height: imageSize.height + 16)
        return CGRect(x: onRight ? screenFrame.maxX - size.width : screenFrame.minX,
                      y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Where the pointer opens a closed island: on the notch, up to a few points past the top row of the screen.
    var hotspot: CGRect {
        let c = closedSize
        return CGRect(x: screen.midX - c.width / 2, y: screen.maxY - c.height, width: c.width, height: c.height + 6)
    }
}

enum MemePosition: String, CaseIterable {
    case left, right, automatic

    var label: String {
        switch self {
        case .left: return "왼쪽 위"
        case .right: return "오른쪽 위"
        case .automatic: return "자동 · 마우스 피하기"
        }
    }

    func onRight(current: Bool, mouse: CGPoint?, screen: CGRect, imageSize: CGSize) -> Bool {
        switch self {
        case .left: return false
        case .right: return true
        case .automatic:
            guard let mouse, screen.contains(mouse) else { return current }
            let occupied = IslandLayout.memeWindow(in: screen, imageSize: imageSize, onRight: current).insetBy(dx: -32, dy: -32)
            let other = IslandLayout.memeWindow(in: screen, imageSize: imageSize, onRight: !current).insetBy(dx: -32, dy: -32)
            // Stay on the new side until approached again; overlapping corners must not oscillate.
            return occupied.contains(mouse) && !other.contains(mouse) ? !current : current
        }
    }
}

enum IslandMove { case open, close, hold }

/// What the pointer asks of the island. Closed: open when it is on the island. Open: close when it has left, unless pinned.
func islandMove(open: Bool, pinned: Bool, mouse: CGPoint, hotspot: CGRect, island: CGRect) -> IslandMove {
    if !open { return hotspot.contains(mouse) ? .open : .hold }
    if pinned || island.insetBy(dx: -12, dy: -12).contains(mouse) { return .hold }
    return .close
}
