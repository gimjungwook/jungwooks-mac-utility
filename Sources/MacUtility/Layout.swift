import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Global hotkeys, Control+Option + U I O J L K. Carbon hotkeys need no permission; moving windows needs Accessibility.
final class HotKeys {
    static var onAction: ((LayoutAction) -> Void)?
    static var onPanel: (() -> Void)?
    static let panelID: UInt32 = 100
    private var refs: [EventHotKeyRef] = []

    /// Returns the labels of keys that could not be registered (usually taken by another app).
    func register() -> [String] {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if id.id == HotKeys.panelID { DispatchQueue.main.async { HotKeys.onPanel?() } }
            else if let a = LayoutAction(rawValue: id.id) { DispatchQueue.main.async { HotKeys.onAction?(a) } }
            return noErr
        }, 1, &spec, nil, nil)
        var failed: [String] = []
        for a in LayoutAction.allCases {
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(a.keyCode, UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4D555449, id: a.rawValue), GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref) } else { failed.append(a.label) }
        }
        var panelRef: EventHotKeyRef?
        let ps = RegisterEventHotKey(35, UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4D555449, id: HotKeys.panelID), GetApplicationEventTarget(), 0, &panelRef)   // P
        if ps == noErr, let panelRef { refs.append(panelRef) } else { failed.append("P") }
        return failed
    }
}

func requestAccessibility() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
}

private func axFrame(_ w: AXUIElement) -> CGRect? {
    var p: CFTypeRef?, s: CFTypeRef?
    guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
          AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success,
          let pv = p, let sv = s else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &pt)
    AXValueGetValue(sv as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

private func setAX(_ w: AXUIElement, origin: CGPoint) {
    var o = origin
    if let v = AXValueCreate(.cgPoint, &o) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
}

private func setAX(_ w: AXUIElement, size: CGSize) {
    var s = size
    if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
}

/// Moves one window onto the layout and checks the result. Returns an error text, or nil.
func place(_ win: AXUIElement, _ a: LayoutAction) -> String? {
    guard let cur = axFrame(win) else { return "창 배치: 창 위치를 못 읽음" }
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    let center = CGPoint(x: cur.midX, y: primaryH - cur.midY)
    guard let vf = (NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main)?.visibleFrame else { return "창 배치: 화면 없음" }
    let t = targetRect(a, in: toAX(vf, primaryHeight: primaryH))
    // size, position, size again: some windows clamp the first size change
    setAX(win, size: t.size); setAX(win, origin: t.origin); setAX(win, size: t.size)
    guard let after = axFrame(win), abs(after.width - t.width) < 3, abs(after.minX - t.minX) < 3 else { return "창 배치: 이 창은 크기를 바꿀 수 없음" }
    return nil
}

/// Hotkey entry point: the focused window of the frontmost app.
func applyLayout(_ a: LayoutAction) -> String? {
    guard AXIsProcessTrusted() else { return "창 배치: 손쉬운 사용 권한 필요" }
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return "창 배치: 앞 앱 없음" }
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &ref) == .success, let w = ref else { return "창 배치: 창 없음" }
    return place(w as! AXUIElement, a)
}

/// Moves a small test window of this process through all six layouts via the real Accessibility path.
/// The expected frame is computed from NSScreen in AppKit space, independent of the Accessibility conversion used by place().
func layoutTest() -> Int {
    let panel = NSPanel(contentRect: NSRect(x: 300, y: 300, width: 420, height: 320), styleMask: [.titled, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.title = "MacUtility layout test"
    panel.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &ref) == .success,
          let wins = ref as? [AXUIElement], let win = wins.first else {
        print("FAIL  cannot read the test window through Accessibility")
        return 1
    }
    var failed = 0
    for a in LayoutAction.allCases {
        if let err = place(win, a) { print("FAIL  \(a.label): \(err)"); failed += 1; continue }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let got = panel.frame
        let c = CGPoint(x: got.midX, y: got.midY)
        guard let vf = (NSScreen.screens.first { $0.frame.contains(c) } ?? NSScreen.main)?.visibleFrame else { failed += 1; continue }
        let want = targetRect(a, in: vf)
        let ok = abs(got.minX - want.minX) < 3 && abs(got.minY - want.minY) < 3 && abs(got.width - want.width) < 3 && abs(got.height - want.height) < 3
        print(ok ? "ok    " : "FAIL  ", "\(a.label): got x=\(Int(got.minX)) y=\(Int(got.minY)) w=\(Int(got.width)) h=\(Int(got.height)) | want x=\(Int(want.minX)) y=\(Int(want.minY)) w=\(Int(want.width)) h=\(Int(want.height)) | screen \(Int(vf.width))x\(Int(vf.height))")
        if !ok { failed += 1 }
    }
    panel.close()
    return failed
}

