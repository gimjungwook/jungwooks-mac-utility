import SwiftUI
import Combine

extension NSScreen {
    var displayID: CGDirectDisplayID { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }

    /// Size of the camera notch; nil on a screen without one.
    var notchSize: CGSize? {
        guard safeAreaInsets.top > 0, let l = auxiliaryTopLeftArea, let r = auxiliaryTopRightArea else { return nil }
        return CGSize(width: frame.width - l.width - r.width, height: safeAreaInsets.top)
    }
}

final class IslandState: ObservableObject {
    @Published var open = false
    @Published var input = TypingDisplay()
    @Published var showingInput = false
    @Published var memeReveal: CGFloat = 0
    @Published var memeSize = CGSize.zero
    @Published var memeOnRight = false
    @Published var layout = IslandLayout(screen: .zero, notch: nil)
    var choosingMode = false
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// Lets the window sit flush with the top edge of the screen, over the menu bar and the notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Owns the island window and decides when it opens: the pointer on the notch, Control+Option+P, or a short peek.
final class Island {
    let state = IslandState()
    let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let memePanel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let model: Model
    private var pinned = false
    private var pending: Timer?
    private var inputHide: Timer?
    static let inputAnimationDuration: TimeInterval = 0.32
    private var monitors: [Any] = []
    private var memePositionChange: AnyCancellable?

    init(model: Model) {
        self.model = model
        for window in [panel, memePanel] {
            window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.hidesOnDeactivate = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.ignoresMouseEvents = true
        }
        let host = NSHostingView(rootView: IslandView(m: model, s: state))
        host.sizingOptions = []
        panel.contentView = host
        let memeHost = NSHostingView(rootView: CornerMemeView(s: state))
        memeHost.sizingOptions = []
        memePanel.contentView = memeHost
        memePositionChange = model.$memePosition.sink { [weak self] in self?.placeMeme($0) }
    }

    func start() {
        reposition()
        panel.orderFrontRegardless()
        // Moves over other apps' windows reach the global monitor; moves over the open island reach the local one.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in self?.pointerMoved() }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] e in self?.pointerMoved(); return e }) { monitors.append(l) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.reposition() }
    }

    /// The island sits on the built-in display (the one with the notch), or on the main display when that one is off.
    func reposition() {
        let all = NSScreen.screens
        guard let s = all.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) ?? NSScreen.main ?? all.first else { return }
        state.layout = IslandLayout(screen: s.frame, notch: s.notchSize)
        panel.setFrame(state.layout.window(showingInput: !state.input.isEmpty, inputHeight: state.input.textHeight), display: true)
        placeMeme(model.memePosition)
    }

    func placeMeme(_ position: MemePosition, mouse: CGPoint? = nil) {
        let right = position.onRight(current: state.memeOnRight, mouse: mouse,
                                     screen: state.layout.screen, imageSize: state.memeSize)
        let frame = IslandLayout.memeWindow(in: state.layout.screen, imageSize: state.memeSize, onRight: right)
        guard right != state.memeOnRight || frame != memePanel.frame else { return }
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { state.memeOnRight = right }
        memePanel.setFrame(frame, display: true)
    }

    func showInput(_ display: TypingDisplay, animated: Bool = true) {
        guard display != state.input || state.showingInput != !display.isEmpty || inputHide != nil else { return }
        inputHide?.invalidate(); inputHide = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        if let level = display.meme,
           display.meme != state.input.meme || display.memeIndex != state.input.memeIndex || display.memeMatch != state.input.memeMatch {
            // Read image metadata only when the asset changes, never for each keystroke.
            withTransaction(transaction) {
                state.memeSize = MemeView.imageSize(at: display.memeMatch?.url ?? level.url(at: display.memeIndex))
            }
            placeMeme(model.memePosition, mouse: model.readOnly ? nil : NSEvent.mouseLocation)
        }
        if !animated {
            withTransaction(transaction) {
                state.input = display; state.showingInput = !display.isEmpty
                state.memeReveal = display.meme == nil ? 0 : 1
            }
            panel.setFrame(state.layout.window(showingInput: !display.isEmpty, inputHeight: display.textHeight), display: true)
        } else if !display.isEmpty {
            if state.input.isEmpty || state.input.textHeight != display.textHeight {
                panel.setFrame(state.layout.window(showingInput: true, inputHeight: display.textHeight), display: true)
            }
            withTransaction(transaction) { state.input = display }
            if display.meme != nil, state.memeReveal == 0, panel.isVisible {
                // Lay out the closed mask before the first GIF arrives after the text.
                memePanel.orderFrontRegardless()
                memePanel.contentView?.layoutSubtreeIfNeeded()
            }
            withAnimation(.easeOut(duration: Self.inputAnimationDuration)) { state.showingInput = true }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { state.memeReveal = display.meme == nil ? 0 : 1 }
        } else {
            withAnimation(.easeInOut(duration: Self.inputAnimationDuration)) { state.showingInput = false; state.memeReveal = 0 }
            // Keep the outgoing line and window alive until the fade finishes; privacy clears skip this.
            let t = Timer(timeInterval: Self.inputAnimationDuration + 0.04, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.inputHide = nil
                withTransaction(transaction) { self.state.input = TypingDisplay() }
                self.memePanel.orderOut(nil)
                self.panel.setFrame(self.state.layout.window(showingInput: false), display: true)
            }
            inputHide = t
            RunLoop.main.add(t, forMode: .common)
        }
        if !display.isEmpty, display.meme != nil, panel.isVisible { memePanel.orderFrontRegardless() }
        else if !display.isEmpty || !animated { memePanel.orderOut(nil) }
    }

    func setOpen(_ open: Bool) {
        guard open || !state.choosingMode else { return }
        guard open != state.open else { return }
        state.open = open
        panel.ignoresMouseEvents = !open
        trace("island \(open ? "open" : "closed")")
    }

    /// Control+Option+P: pin it open, or close it again.
    func toggle() {
        pending?.invalidate(); pending = nil
        pinned = !(state.open && pinned)
        setOpen(pinned)
    }

    /// Opens for a few seconds (launch, new message), then closes unless the pointer is on it or it is pinned.
    func peek(_ seconds: TimeInterval) {
        setOpen(true)
        after(seconds) { [weak self] in
            guard let s = self, !s.pinned, s.pointerAway() else { return }
            s.setOpen(false)
        }
    }

    private func after(_ seconds: TimeInterval, _ run: @escaping () -> Void) {
        pending?.invalidate()
        pending = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.pending = nil
            run()
        }
    }

    private func pointerAway() -> Bool {
        islandMove(open: true, pinned: false, mouse: NSEvent.mouseLocation, hotspot: .zero, island: panel.frame) == .close
    }

    private func pointerMoved() {
        if model.memePosition == .automatic, memePanel.isVisible, state.showingInput, state.input.meme != nil {
            placeMeme(model.memePosition, mouse: NSEvent.mouseLocation)
        }
        switch islandMove(open: state.open, pinned: pinned, mouse: NSEvent.mouseLocation, hotspot: state.layout.hotspot, island: panel.frame) {
        case .open: if pending == nil { after(0.12) { [weak self] in self?.setOpen(true) } }
        case .close: if pending == nil { after(0.4) { [weak self] in self?.setOpen(false) } }
        case .hold: pending?.invalidate(); pending = nil
        }
    }
}

struct CornerMemeView: View {
    @ObservedObject var s: IslandState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var alignment: Alignment { s.memeOnRight ? .topTrailing : .topLeading }
    private var anchor: UnitPoint { s.memeOnRight ? .topTrailing : .topLeading }
    private func curve(_ radius: CGFloat) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomLeadingRadius: s.memeOnRight ? radius : 0,
                               bottomTrailingRadius: s.memeOnRight ? 0 : radius)
    }

    var body: some View {
        ZStack(alignment: alignment) {
            if let level = s.input.meme {
                MemeView(level: level, variant: s.input.memeIndex, match: s.input.memeMatch,
                         frame: s.input.memeFrame.map { reduceMotion ? 0 : $0 }, animate: s.showingInput && !reduceMotion)
                    .frame(width: s.memeSize.width, height: s.memeSize.height)
                    // Inset the panel's 24pt curve by the 8pt padding.
                    .clipShape(curve(16))
            }
        }
        .frame(width: s.memeSize.width, height: s.memeSize.height, alignment: alignment)
        .padding(8)
        .background(Color.black)
        .mask(alignment: alignment) {
            curve(24).scaleEffect(s.memeReveal, anchor: anchor)
        }
        .transaction { if reduceMotion { $0.animation = nil } }
    }
}

/// A switch that reads at a glance on black: green when on (the system switch follows the accent colour, which can be grey).
struct IslandSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? Color.green : Color.white.opacity(0.2))
                .frame(width: 48, height: 28)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) { Circle().fill(Color.white).frame(width: 24, height: 24).padding(2) }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
        }
        .buttonStyle(.plain)
    }
}

struct IslandView: View {
    @ObservedObject var m: Model
    @ObservedObject var s: IslandState

    private let spring = Animation.spring(response: 0.4, dampingFraction: 0.82)
    /// One fixed-height notice line, so a long message can never push the buttons out of the island.
    private var notice: String { [m.conflictNote, m.hotkeyNote, m.message].first { !$0.isEmpty } ?? "" }

    var body: some View {
        let l = s.layout
        let size = l.contentSize(open: s.open, showingInput: s.showingInput, inputHeight: s.input.textHeight)
        let radius: CGFloat = s.open || s.showingInput ? 26 : 12
        VStack(spacing: 0) {
            Color.clear.frame(height: l.notchH)   // the row level with the notch stays empty
            inputLine
                .frame(height: s.showingInput ? s.input.textHeight : 0)
                .opacity(s.showingInput ? 1 : 0)
                .offset(y: s.showingInput ? 0 : -4)
                .clipped()
            if s.open { controls }
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
        .background(UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius).fill(Color.black))
        .opacity(s.open || s.showingInput || l.notch != nil ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(spring, value: s.open)
        .environment(\.colorScheme, .dark)
    }

    private var inputLine: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                if !s.input.word.isEmpty {
                    if s.input.textMode == .field {
                        ScrollView(.vertical) {
                            Text(s.input.word)
                                .font(.system(size: 17, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityLabel("입력창 내용")
                    } else {
                        Text(s.input.word)
                            .font(.system(size: s.input.textMode == .continuous ? 17 : 20, weight: .medium))
                            .lineLimit(s.input.textMode == .continuous ? 3 : 1)
                            .truncationMode(.head)
                    }
                }
                if !s.input.key.isEmpty {
                    Text(s.input.key)
                        .font(.system(size: 17, weight: .medium))
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.14)))
                }
                if let emoji = s.input.emoji {
                    Text(emoji).font(.system(size: 26)).fixedSize()
                }
            }
            .frame(height: s.input.textHeight)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(s.input.textMode == .field && s.open)
        .transaction { $0.animation = nil } // Edit glyphs immediately; animate the line's appearance, not every character.
    }

    private var controls: some View {
        VStack(spacing: 6) {
            // Left and right groups share the spare width, so the fan icons sit exactly in the middle.
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: Icon.mode).foregroundStyle(m.on ? Color.green : Color.secondary).accessibilityHidden(true)
                    Toggle("이동 모드", isOn: Binding(get: { m.on }, set: { m.set($0) }))
                        .toggleStyle(IslandSwitch())
                        .labelsHidden()
                }
                .help("이동 모드: 덮개를 닫아도 계속 실행")
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 2) {
                    ForEach(FanMode.allCases, id: \.self) { f in
                        IconButton(symbol: f.symbol, name: "팬 \(f.label)", tint: m.fan == f ? .cyan : .secondary, selected: m.fan == f) { m.setFan(f) }
                    }
                }
                HStack(spacing: 0) {
                    TypingModeButton(m: m, s: s).frame(width: 34, height: 30)
                    if !m.trusted { IconButton(symbol: Icon.permission, name: "창 배치·단어 표시 권한 켜기", tint: .orange) { requestAccessibility() } }
                    IconButton(symbol: Icon.quit, name: "종료") { NSApp.terminate(nil) }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text(notice)
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help(notice)
                .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .frame(height: IslandLayout.controlsHeight, alignment: .top)
        .transition(.opacity)
    }
}

struct TypingModeButton: NSViewRepresentable {
    let m: Model
    let s: IslandState

    func makeCoordinator() -> Coordinator { Coordinator(m: m, s: s) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.refusesFirstResponder = true
        button.setAccessibilityLabel("입력 표시 모드")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.image = NSImage(systemSymbolName: m.typingMode.symbol, accessibilityDescription: m.typingMode.label)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        button.contentTintColor = m.typingMode == .plain ? .secondaryLabelColor : .systemCyan
        button.toolTip = "\(m.typingMode.label) · \(m.typingTextMode.label) · 밈 위치: \(m.memePosition.label)"
        button.setAccessibilityValue(button.toolTip)
    }

    final class Coordinator: NSObject {
        let m: Model
        let s: IslandState
        init(m: Model, s: IslandState) { self.m = m; self.s = s }

        func menu() -> NSMenu {
            let menu = NSMenu()
            menu.minimumWidth = 240
            menu.autoenablesItems = false
            for mode in TypingMode.allCases {
                let item = NSMenuItem(title: mode.label, action: #selector(effect(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = mode.rawValue
                item.state = m.typingMode == mode ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            for mode in TypingTextMode.allCases {
                let item = NSMenuItem(title: mode.label, action: #selector(text(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = mode.rawValue
                item.state = m.typingTextMode == mode ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let heading = NSMenuItem(title: "밈 위치", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            for choice in MemePosition.allCases {
                let item = NSMenuItem(title: choice.label, action: #selector(position(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = choice.rawValue
                item.state = m.memePosition == choice ? .on : .off
                menu.addItem(item)
            }
            return menu
        }

        @objc func open(_ button: NSButton) {
            s.choosingMode = true
            defer { s.choosingMode = false }
            menu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        }

        @objc func effect(_ item: NSMenuItem) {
            if let value = item.representedObject as? String, let mode = TypingMode(rawValue: value) { m.setTypingMode(mode) }
        }

        @objc func text(_ item: NSMenuItem) {
            if let value = item.representedObject as? String, let mode = TypingTextMode(rawValue: value) { m.setTypingTextMode(mode) }
        }

        @objc func position(_ item: NSMenuItem) {
            if let value = item.representedObject as? String, let position = MemePosition(rawValue: value) { m.setMemePosition(position) }
        }
    }
}

/// A bare icon button. The name is both the tooltip and the accessibility label.
struct IconButton: View {
    let symbol: String
    let name: String
    var tint: Color = .secondary
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(selected ? 0.16 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .help(name)
    }
}
