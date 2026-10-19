import SwiftUI
import Combine
import Network

final class Model: ObservableObject {
    @Published var on = false
    @Published var message = ""
    @Published var fan: FanMode = .auto
    @Published var trusted = false
    @Published var hotkeyNote = ""
    @Published var conflictNote = ""
    @Published var typingMode = TypingMode(rawValue: UserDefaults.standard.string(forKey: "typingMode") ?? "") ?? .meme
    @Published var typingTextMode = TypingTextMode(rawValue: UserDefaults.standard.string(forKey: "typingTextMode") ?? "") ?? .word
    @Published var memePosition = MemePosition(rawValue: UserDefaults.standard.string(forKey: "memePosition") ?? "") ?? .left
    // Only the log and the smoke test read these; the island shows none of them, so they do not redraw it every second.
    var lid = false
    var net = "확인 중"
    var fanText = "-"
    /// Test runs (--smoke, --layout-test) only read: they must never change power, fan or lock state.
    var readOnly = false
    private var ticks = 0
    private var sealed = false
    private var rectangleRunning = false
    private var lastFanApply = Date.distantPast
    private let monitor = NWPathMonitor()
    private let wantKey = "wantOn"
    private let fanKey = "fanWant"
    private let lowPower = LowPowerSession()
    private let display = TravelDisplay()

    func setTypingMode(_ mode: TypingMode) {
        typingMode = mode
        if !readOnly { UserDefaults.standard.set(mode.rawValue, forKey: "typingMode") }
    }

    func setTypingTextMode(_ mode: TypingTextMode) {
        typingTextMode = mode
        if !readOnly { UserDefaults.standard.set(mode.rawValue, forKey: "typingTextMode") }
    }

    func setMemePosition(_ position: MemePosition) {
        memePosition = position
        if !readOnly { UserDefaults.standard.set(position.rawValue, forKey: "memePosition") }
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] p in
            // isExpensive is true on an iPhone Personal Hotspot (or a metered network)
            let t = p.status != .satisfied ? "끊김"
                : p.isExpensive ? "핫스팟"
                : p.usesInterfaceType(.wifi) ? "Wi-Fi"
                : p.usesInterfaceType(.wiredEthernet) ? "유선" : "연결됨"
            DispatchQueue.main.async { self?.net = t }
        }
        monitor.start(queue: .global())
        on = sleepDisabled()
        trusted = AXIsProcessTrusted()
        // Always starts at login: the mode is no use after a reboot unless the app runs.
        if !readOnly, !loginEnabled() {
            let err = enableLogin()
            trace("login item: enabled=\(loginEnabled()) \(err ?? "")")
            if let err { message = err }
        }
        if !setupDone() {
            message = "처음 한 번: setup-sudoers.sh 실행 필요"
        } else if !readOnly {
            if UserDefaults.standard.bool(forKey: wantKey), !on, autoOffReason(reading()) == nil { set(true) }
            if let raw = UserDefaults.standard.string(forKey: fanKey), let m = FanMode(rawValue: raw), m != .auto { setFan(m, remember: false) }
        }
        if !readOnly { syncTravelMode() }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        tick()
        refreshSlow()
    }

    private func reading() -> Reading {
        let b = battery()
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        return Reading(onBattery: b.onBattery, percent: b.percent, thermalSerious: hot)
    }

    func tick() {
        ticks += 1
        let r = reading(), closed = lidClosed(), wasClosed = lid
        lid = closed
        if closed != wasClosed { trace(closed ? "lid closed" : "lid opened") }
        if ticks % 5 == 0 { refreshSlow() }
        if ticks % 30 == 0 { heartbeat(r) }
        // "Sealed" = lid closed and no external display: the Mac is going into a bag. Covers closing the lid, and also
        // unplugging the monitor while the lid is already closed (clamshell desk use -> leaving).
        let external = hasExternalDisplay()
        let sealedNow = closed && !external
        defer { sealed = sealedNow }
        guard !readOnly else { return }
        if let error = display.dim(shouldDimDisplay(on: on, lidClosed: closed, external: external)) { message = error }
        if closed != wasClosed { syncTravelMode() }
        guard on else { return }
        if sealedNow && !sealed { trace("travel lid closed: brightness=\(String(describing: builtinBrightness())) locked=\(screenLocked()); no lock or display-sleep request") }
        if closed && !wasClosed && !sealedNow { trace("lid closed with an external display: left as is") }
        if let why = autoOffReason(r) {
            set(false, remember: false)
            message = why
            trace("auto-off: \(why)")
        }
    }

    /// Readings that need a process spawn run every 5 s.
    private func refreshSlow() {
        let wasOn = on
        on = sleepDisabled()
        if !readOnly, on != wasOn { syncTravelMode() }
        trusted = AXIsProcessTrusted()
        let fans = fanStatus()
        fanText = fans.isEmpty ? "도우미 없음" : "\(Int(fans.map { $0.actual }.reduce(0, +) / Float(fans.count))) rpm"
        if !readOnly, fanNeedsReapply(fan, fans), Date().timeIntervalSince(lastFanApply) > 15 {
            setFan(fan, remember: false)
            trace("fan re-applied")
        }
        // Another app registering the same keys is not reported by the system, so look for Rectangle by name.
        let rect = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.knollsoft.Rectangle" }
        if rect != rectangleRunning { rectangleRunning = rect; trace("Rectangle running=\(rect)") }
        conflictNote = rect ? "Rectangle 실행 중: 창 배치 키가 겹칩니다" : ""
    }

    private func heartbeat(_ r: Reading) {
        let io = rootDomainBool("SleepDisabled").map { $0 ? "1" : "0" } ?? "-"
        let disp = builtinAsleep().map { $0 ? "asleep" : "awake" } ?? "n/a"
        trace("hb on=\(on) iokit=\(io) lid=\(lid ? 1 : 0) \(r.onBattery ? "Battery" : "AC") \(r.percent)% net=\(net) builtin=\(disp) ext=\(hasExternalDisplay() ? 1 : 0) locked=\(screenLocked()) brightness=\(String(describing: builtinBrightness())) batteryPowerMode=\(String(describing: batteryPowerMode())) fan=\(fanText)")
    }

    func set(_ want: Bool, remember: Bool = true) {
        let restoreError = !want ? stopTravelMode() : nil
        let sleepError = setSleepDisabled(want)
        message = sleepError ?? restoreError ?? ""
        on = sleepDisabled()
        if remember && sleepError == nil && on == want { UserDefaults.standard.set(want, forKey: wantKey) }
        syncTravelMode()
        trace("set \(want) -> on=\(on) \(message)")
    }

    func setFan(_ m: FanMode, remember: Bool = true) {
        lastFanApply = Date()
        if let err = applyFan(m) {
            message = err
            trace("fan \(m.rawValue) failed: \(err)")
            return
        }
        fan = m
        if remember { UserDefaults.standard.set(m.rawValue, forKey: fanKey) }
        trace("fan \(m.rawValue) ok")
    }

    private func syncTravelMode() {
        let closed = lidClosed()
        let errors = [display.holdAwake(on), lowPower.setEnabled(on, lidClosed: closed)].compactMap { $0 }
        if !errors.isEmpty { message = errors.joined(separator: " · ") }
        trace("travel on=\(on) lid=\(closed ? 1 : 0) batteryPowerMode=\(String(describing: batteryPowerMode())) \(errors.joined(separator: "; "))")
    }

    @discardableResult
    func stopTravelMode() -> String? {
        let errors = [display.dim(false), display.holdAwake(false), lowPower.setEnabled(false)].compactMap { $0 }
        if !errors.isEmpty { message = errors.joined(separator: " · "); trace("travel restore: \(message)") }
        return errors.isEmpty ? nil : errors.joined(separator: " · ")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    let keys = HotKeys()
    let typing = TypingMonitor()
    var island: Island!
    var hotkeyFailed: [String] = []
    var smokePNG: String?
    var layoutTestMode = false
    var testMode: Bool { smokePNG != nil || layoutTestMode }
    var signals: [DispatchSourceSignal] = []
    var peekOnMessage: AnyCancellable?
    var typingModeChange: AnyCancellable?
    var typingTextModeChange: AnyCancellable?
    var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if testMode { traceTag = "[test] " }
        model.readOnly = testMode
        // Without this, App Nap delays the 1 s timer while nothing is on screen or the lid is closed.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "lid watch")
        island = Island(model: model)
        // SIGTERM quits cleanly. SIGUSR1 does what Control+Option+P does (kill -USR1 <pid>): a way to open the island
        // without the keyboard, which is also how the running app is tested.
        func onSignal(_ sig: Int32, _ act: @escaping () -> Void) {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler(handler: act)
            s.resume()
            signals.append(s)
        }
        onSignal(SIGTERM) { NSApp.terminate(nil) }
        onSignal(SIGUSR1) { [weak self] in self?.island.toggle() }
        HotKeys.onAction = { [weak self] a in
            if let err = applyLayout(a) { self?.model.message = err; trace("layout \(a.label): \(err)") } else { trace("layout \(a.label): ok") }
        }
        HotKeys.onPanel = { [weak self] in self?.island.toggle() }
        hotkeyFailed = keys.register()
        if !hotkeyFailed.isEmpty {
            model.hotkeyNote = "키 \(hotkeyFailed.joined(separator: " ")) 등록 실패: 다른 앱이 사용 중"
            trace("hotkeys not registered: \(hotkeyFailed.joined(separator: " "))")
        }
        model.start()
        if !testMode {
            typing.onChange = { [weak self] display, animated in self?.island.showInput(display, animated: animated) }
            typingModeChange = model.$typingMode.sink { [weak self] in self?.typing.setMode($0) }
            typingTextModeChange = model.$typingTextMode.sink { [weak self] in self?.typing.setTextMode($0) }
            typing.start()
        }
        // The layout test drives the first window of this process, so the island stays out of its way.
        if !layoutTestMode {
            island.start()
            // A new message (auto-off, display result, error) opens the island for a few seconds.
            peekOnMessage = model.$message.dropFirst().filter { !$0.isEmpty }.sink { [weak self] _ in self?.island.peek(5) }
            island.peek(4)   // shows where it is
        }
        trace("started trusted=\(AXIsProcessTrusted()) setupDone=\(setupDone()) login=\(loginEnabled()) external=\(hasExternalDisplay()) hotkeysFailed=\(hotkeyFailed.joined(separator: ","))")
        if let png = smokePNG { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.smoke(png) } }
        if layoutTestMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let bad = layoutTest()
                print(bad == 0 ? "layout test: all 6 passed" : "layout test: \(bad) failed")
                exit(bad == 0 ? 0 : 1)
            }
        }
    }

    /// Opening the app again (Finder, Spotlight, "open") shows the island for a moment.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        trace("reopen")
        island.peek(5)
        return false
    }

    func applicationWillTerminate(_ n: Notification) {
        guard !testMode else { return }
        typing.stop()
        model.stopTravelMode()
        // shortcut: a crash or SIGKILL leaves these on; add a launchd watchdog if that ever happens.
        if model.on { _ = setSleepDisabled(false) }
        if model.fan != .auto { _ = applyFan(.auto) }
        trace("quit")
    }

    /// Writes the island's content view to a PNG. Returns the box around everything it draws (points, y down), nil if it draws nothing.
    private func render(_ path: String) -> CGRect? {
        guard let v = island.panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        let k = CGFloat(rep.pixelsWide) / v.bounds.width
        var box = CGRect.null
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                box = box.union(CGRect(x: CGFloat(x) / k, y: CGFloat(y) / k, width: 1 / k, height: 1 / k))
            }
        }
        return box.isNull ? nil : box
    }

    private func smoke(_ path: String) {
        _ = render(path)
        let l = island.state.layout
        print("smoke ok: open=\(island.state.open) window=\(island.panel.frame) level=\(island.panel.level.rawValue) visible=\(island.panel.isVisible) notch=\(String(describing: l.notch)) on=\(model.on) net=\(model.net) trusted=\(model.trusted) hotkeysFailed=\(hotkeyFailed) external=\(hasExternalDisplay()) rectangleNote=\(model.conflictNote) msg=\(model.message)")
        // The closed island must stay inside the notch: anything drawn beside it stays put while a three-finger swipe slides the desktop away.
        island.setOpen(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let drawn = self.render(path + ".closed.png")
            let w = self.island.panel.contentView?.bounds.width ?? 0
            let notch = CGRect(x: (w - l.notchW) / 2, y: 0, width: l.notchW, height: l.notchH).insetBy(dx: -1, dy: -1)
            let inside = drawn.map { notch.contains($0) } ?? true
            print("\(inside ? "ok  " : "FAIL") closed island draws only inside the notch: drawn=\(String(describing: drawn)) notch=\(notch)")
            exit(inside ? 0 : 1)
        }
    }
}
