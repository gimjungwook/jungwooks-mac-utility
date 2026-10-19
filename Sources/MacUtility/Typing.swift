import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Observes copies only. Never posts events, edits the focused app or records input.
final class TypingMonitor: NSObject {
    var onChange: ((TypingDisplay, Bool) -> Void)?
    var secureInput: () -> Bool = { IsSecureEventInputEnabled() }
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var classify: (String, Bool, @escaping ([MemeMatch]) -> Void) -> DispatchWorkItem? = { SemanticMemeMatcher.shared.classify($0, allowEmbedding: $1, completion: $2) }
    var readField: (Bool, @escaping (FocusedInput?) -> Void) -> DispatchWorkItem? = { FocusedInput.fetch(includeText: $0, $1) }
    var watchFocus: (() -> Bool)?
    private lazy var focusWatcher = FocusedInputWatcher { [weak self] in self?.focusChanged($0) }
    private var mode = TypingMode.plain
    private var textMode = TypingTextMode.word
    private var pace = TypingPace()
    private var memes = MemeRotation()
    private var lastActivity: TimeInterval?
    private var firstActivity: TimeInterval?
    private var memeSeed = ""
    private var selectedSeed = ""
    private var field: FocusedInput?
    private var fieldIsCurrent = false
    private var fieldWork: DispatchWorkItem?
    private var fieldPending = false
    private var fieldGeneration = 0
    private var nextFieldRead: TimeInterval = 0
    private var pendingKeys: [NSEvent] = []
    private var reaction: (level: MemeLevel, index: Int, match: MemeMatch?)?
    private var typingFrame = 0
    private var shownAt: TimeInterval?
    private var choices: [MemeMatch] = []
    private var remaining: [MemeMatch] = []
    private var poolTopic: String?
    private var previousFile: String?
    private var selectionPending = false
    private var selectionWork: DispatchWorkItem?
    private var generation = 0
    private var input = WordInput()
    private var shown = TypingDisplay()
    private var key = ""
    private var keyTimer: Timer?
    static let keyDuration: TimeInterval = TypingPace.idle
    static let memeInterval: TimeInterval = 3
    private var monitors: [Any] = []
    private var timer: Timer?
    private var twoSetKorean = false
    private var lastKeyEvent: (time: TimeInterval, type: NSEvent.EventType, code: UInt16, flags: NSEvent.ModifierFlags)?
    private var sessionActive = true
    private var ticks = 0

    func start() {
        guard timer == nil else { return }
        updateInputSource()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(updateInputSource), name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(clear), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionEnded), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionStarted), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        syncPermission()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.checkPrivacy()
            self.checkIdle()
            self.checkField()
            self.checkMeme()
            self.ticks += 1
            if self.ticks % 10 == 0 { self.syncPermission() }
            if self.mode == .meme, self.ticks % 2 == 0 { self.publish() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        removeMonitors()
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        clear()
    }

    func setMode(_ mode: TypingMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        clear()
    }

    func setTextMode(_ mode: TypingTextMode) {
        guard mode != textMode else { return }
        textMode = mode
        focusWatcher.stop()
        clear()
    }

    private func syncPermission() {
        guard AXIsProcessTrusted() else { removeMonitors(); clear(); return }
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        guard let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.observe(e) }) else { return }
        monitors.append(g)
        // The island has no text entry; its own menu keys must never enter the word composer.
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] e in self?.receive(e); return e }) { monitors.append(l) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        focusWatcher.stop()
    }

    @objc private func appChanged() { focusWatcher.stop(); clear() }

    func focusChanged(_ element: AXUIElement) {
        if let field, CFEqual(field.element, element) { return }
        clear()
    }

    @objc private func updateInputSource() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { setInputSource(korean: false); return }
        let identifier = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        setInputSource(korean: identifier.lowercased().contains("2set"))
    }

    func setInputSource(korean: Bool) {
        guard korean != twoSetKorean else { return }
        // Commit the current syllable without ending the typing session or changing its GIF.
        input.commit()
        twoSetKorean = korean
    }

    @objc private func sessionEnded() { sessionActive = false; clear() }
    @objc private func sessionStarted() { sessionActive = true; clear() }

    func checkPrivacy() {
        // Secure Input suppresses events, so clear even if no further key event reaches us.
        if secureInput() || !sessionActive { clear() }
    }

    func checkIdle() {
        if let lastActivity, clock() < lastActivity || clock() - lastActivity >= TypingPace.idle {
            reset(animated: true, keepField: textMode == .field)
        }
    }

    func checkField() {
        guard textMode == .field || !pendingKeys.isEmpty else { return }
        guard !secureInput(), sessionActive else { clear(); return }
        guard !fieldPending, clock() >= nextFieldRead else { return }
        if textMode != .field {
            let following: Bool
            if let watchFocus { following = watchFocus() }
            else if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid() {
                following = focusWatcher.watch(pid)
            } else { following = false }
            guard following else {
                clear(); nextFieldRead = clock() + 0.25
                return
            }
        }
        nextFieldRead = clock() + 0.25
        fieldPending = true
        let request = fieldGeneration
        fieldWork = readField(textMode == .field) { [weak self] snapshot in
            guard let self, self.fieldGeneration == request else { return }
            self.fieldPending = false; self.fieldWork = nil
            guard !self.secureInput(), self.sessionActive else { self.clear(); return }
            guard let snapshot else {
                self.clear()
                self.nextFieldRead = self.clock() + 0.25
                return
            }
            let events = self.pendingKeys
            self.pendingKeys.removeAll()
            let sameField = self.field.map { CFEqual($0.element, snapshot.element) } ?? false
            let changed = !sameField || self.field?.text != snapshot.text
            if !sameField { self.reset(animated: false) }
            self.field = snapshot
            self.fieldIsCurrent = true
            self.nextFieldRead = self.clock() + 0.25
            // Word modes only retain the editable element, never the field's existing contents.
            if self.textMode != .field {
                events.forEach(self.receive)
                return
            }
            // Focusing prefilled text alone is not typing; wait for an edit or an observed text key.
            if !sameField, events.isEmpty { return }
            guard changed else { events.forEach(self.receive); return }
            // Edits invalidate an outstanding answer, while the displayed GIF keeps its three-second cadence.
            self.generation &+= 1
            self.selectionWork?.cancel(); self.selectionWork = nil; self.selectionPending = false
            self.lastActivity = self.clock()
            if self.firstActivity == nil { self.firstActivity = self.lastActivity }
            self.memeSeed = snapshot.text
            if snapshot.text.isEmpty { self.reset(animated: true, keepField: true) }
            else { self.publish() }
            events.forEach(self.receive)
        }
    }

    func checkMeme(force: Bool = false) {
        guard mode == .meme || mode == .typingMeme, !selectionPending,
              let firstActivity, let lastActivity else { return }
        guard !secureInput(), sessionActive else { clear(); return }
        let now = clock()
        guard now - lastActivity < TypingPace.idle else { checkIdle(); return }
        if mode == .typingMeme {
            guard reaction == nil else { return }
            let scene = memes.typingScene()
            reaction = (scene.level, scene.index, nil)
            publish()
            return
        }
        if let shownAt {
            guard now - shownAt >= Self.memeInterval, lastActivity > shownAt else { return }
            if textMode == .field {
                guard memeSeed != selectedSeed else { advanceMeme(); return }
            } else {
                // Rotation reuses IDs; a new known subject can refresh the pool without loading a model.
                guard let topic = MemeTopic.keyword(in: memeSeed), topic.rawValue != poolTopic else { advanceMeme(); return }
            }
        } else {
            guard force || now - lastActivity >= 0.45 || now - firstActivity >= 1.2 else { return }
        }
        let allowEmbedding = shownAt == nil || textMode == .field
        let seed = textMode == .field ? memeSeed : String(memeSeed.suffix(160))
        selectionPending = true
        let request = generation
        let finish: ([MemeMatch]) -> Void = { [weak self] matches in
            guard let self, self.generation == request, self.mode == .meme else { return }
            guard !self.secureInput(), self.sessionActive else { self.clear(); return }
            guard let last = self.lastActivity, self.clock() >= last,
                  self.clock() - last < TypingPace.idle else { self.checkIdle(); return }
            self.selectionWork = nil
            self.selectionPending = false
            self.choices = matches
            self.remaining = []
            self.selectedSeed = seed
            self.poolTopic = Set(matches.map(\.topic)).count == 1 ? matches.first?.topic : nil
            self.advanceMeme()
        }
        selectionWork = classify(seed, allowEmbedding, finish)
    }

    private func advanceMeme() {
        if remaining.isEmpty {
            remaining = choices.shuffled()
            if remaining.count > 1, remaining.last?.file == previousFile { remaining.swapAt(0, remaining.count - 1) }
        }
        let match = remaining.popLast()
        if let match { previousFile = match.file }
        let level = pace.level(at: clock()) ?? .calm
        memes.clear()
        reaction = (level, memes.index(for: level), match)
        shownAt = clock()
        publish()
    }

    func observe(_ event: NSEvent) {
        if event.type == .keyDown || event.type == .flagsChanged {
            if event.timestamp > 0, let last = lastKeyEvent,
               last.time == event.timestamp, last.type == event.type,
               last.code == event.keyCode, last.flags == event.modifierFlags { return }
            lastKeyEvent = (event.timestamp, event.type, event.keyCode, event.modifierFlags)
        }
        receive(event)
    }

    func receive(_ event: NSEvent) {
        guard !secureInput(), sessionActive else { clear(); return }
        checkIdle()
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            reset(animated: false, keepField: textMode == .field)
            return
        }
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty else { return }
        if [48, 53].contains(event.keyCode) {
            reset(animated: false, keepField: textMode == .field)
            return
        }
        if [36, 76].contains(event.keyCode) {
            guard lastActivity != nil || !pendingKeys.isEmpty else { return }
            if textMode == .field, fieldIsCurrent {
                // A multiline Enter is an edit; a submitted/emptied value collapses in checkField.
                flash(KeyLabel.key(code: event.keyCode, characters: nil, flags: event.modifierFlags) ?? "")
                publish()
            } else { reset(animated: true, keepField: true) }
            return
        }
        let characters = event.characters
        let printable = characters.map { !$0.isEmpty && $0.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        } } ?? false
        let editing = [UInt16(49), 51, 117].contains(event.keyCode)
        guard printable || editing else { return }
        if [51, 117].contains(event.keyCode), lastActivity == nil { return }
        // First keys wait for a bounded asynchronous focus read; cached valid focus keeps tapping responsive.
        guard fieldIsCurrent else {
            if pendingKeys.count < 32 { pendingKeys.append(event) }
            checkField()
            return
        }
        if mode == .typingMeme, !event.isARepeat { typingFrame = 1 - typingFrame }
        if textMode == .field {
            guard lastActivity != nil else { return }
            flash(KeyLabel.key(code: event.keyCode, characters: event.charactersIgnoringModifiers, flags: event.modifierFlags) ?? "")
            publish()
            return
        }
        lastActivity = clock()
        if firstActivity == nil { firstActivity = lastActivity }
        if mode == .meme, !event.isARepeat, event.keyCode != 51,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) {
            pace.record(at: clock())
        }
        let before = input.text
        input.receive(code: event.keyCode, characters: characters, flags: event.modifierFlags, twoSetKorean: twoSetKorean, textMode: textMode)
        if mode == .meme {
            memeSeed = String((input.text.isEmpty ? before : input.text).suffix(160))
        }
        flash(KeyLabel.key(code: event.keyCode, characters: event.charactersIgnoringModifiers, flags: event.modifierFlags) ?? "")
        if event.keyCode == 49 { checkMeme(force: true) }
        else { checkMeme() }
        publish()
    }

    @objc func clear() { reset(animated: false) }

    private func reset(animated: Bool, keepField: Bool = false) {
        input.clear()
        if !keepField { field = nil }
        fieldIsCurrent = false
        if !keepField { nextFieldRead = 0 }
        pendingKeys.removeAll()
        fieldGeneration &+= 1
        fieldWork?.cancel(); fieldWork = nil; fieldPending = false
        pace.clear()
        lastActivity = nil
        firstActivity = nil
        memeSeed = ""
        selectedSeed = ""
        reaction = nil
        typingFrame = 0
        shownAt = nil
        choices = []; remaining = []; poolTopic = nil
        selectionPending = false
        generation &+= 1
        selectionWork?.cancel(); selectionWork = nil
        if animated { _ = memes.index(for: nil) } else { memes.clear() }
        flash("")
        publish(animated: animated)
    }

    private func flash(_ label: String) {
        keyTimer?.invalidate(); keyTimer = nil
        key = label
        guard !label.isEmpty else { return }
        let t = Timer(timeInterval: Self.keyDuration, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.keyTimer = nil
            guard !self.secureInput(), self.sessionActive else { self.clear(); return }
            self.key = ""
            self.publish()
        }
        keyTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func publish(animated: Bool = true) {
        let word = textMode == .field ? (lastActivity == nil ? "" : field?.text ?? "") : input.text
        let emojiWord = word.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        let display = TypingDisplay(word: word, key: key, meme: reaction?.level, memeIndex: reaction?.index ?? 0,
                                   memeMatch: reaction?.match, memeFrame: mode == .typingMeme && reaction != nil ? typingFrame : nil,
                                   emoji: mode == .emoji ? WordEmoji.match(emojiWord) : nil, textMode: textMode)
        // An immediate privacy clear must also cancel an in-flight visual fade.
        guard shown != display || !animated else { return }
        shown = display
        onChange?(shown, animated)
    }
}
