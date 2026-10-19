import Foundation
import AppKit
import ApplicationServices
import SwiftUI

/// Fixed public sample phrases only, never reads the user's keys or changes settings.
func benchmarkMemes(anchorsOnly: Bool) -> Never {
    let start = ProcessInfo.processInfo.systemUptime
    let matcher = SemanticMemeMatcher()
    var matches = 0
    for _ in 0..<100 {
        if matcher.match("배고파")?.topic == "food" { matches += 1 }
        if matcher.match("퇴근")?.topic == "celebrate" { matches += 1 }
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    print("fixed queries: \(matches)/200, \(String(format: "%.2f", elapsed * 1000 / 200)) ms/query including index load, model calls=\(matcher.embeddedQueries)")
    if !anchorsOnly {
        for text in ["점심 뭐 먹지", "마침내 해냈다", "회사 끝났다", "화가 난다", "컴파일이 안되네", "안녕하세요", "일부 설정을 바꾸었다", "catastrophe", "my eyes are closing", "I cannot afford this"] {
            let t = ProcessInfo.processInfo.systemUptime
            let result = matcher.match(text)
            print("sample: \(text) -> \(result?.topic ?? "fallback") (\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - t) * 1000)) ms)")
        }
    }
    exit(matches == 200 ? 0 : 1)
}

/// Read-only check: pure logic plus live readings. Never changes system settings.
func selfTest() -> Never {
    var failed = 0
    func check(_ ok: Bool, _ what: String) { print(ok ? "ok    " : "FAIL  ", what); if !ok { failed += 1 } }
    check(parseSleepDisabled(" SleepDisabled\t\t1\n"), "pmset tab-separated 1 -> on")
    check(!parseSleepDisabled(" SleepDisabled\t\t0\n"), "pmset tab-separated 0 -> off")
    check(parseSleepDisabled(" SleepDisabled 1\n"), "pmset space-separated 1 -> on")
    check(!parseSleepDisabled(" sleep 0\n displaysleep 0\n"), "key absent -> off")
    check(autoOffReason(Reading(onBattery: true, percent: 15, thermalSerious: false)) != nil, "battery 15% -> off")
    check(autoOffReason(Reading(onBattery: true, percent: 16, thermalSerious: false)) == nil, "battery 16% -> keep")
    check(autoOffReason(Reading(onBattery: false, percent: 5, thermalSerious: false)) == nil, "charger at 5% -> keep")
    check(autoOffReason(Reading(onBattery: false, percent: 90, thermalSerious: true)) != nil, "thermal serious -> off")
    check(rootDomainBool("AppleClamshellState") != nil, "IORegistry exposes lid state")
    check(parseSleepDisabled(shell("/usr/bin/pmset", ["-g"]).out) == (rootDomainBool("SleepDisabled") ?? false), "pmset text and IORegistry agree on SleepDisabled now")

    check(shouldDimDisplay(on: true, lidClosed: true, external: false), "travel + closed lid + no external screen -> brightness zero")
    check(!shouldDimDisplay(on: false, lidClosed: true, external: false) && !shouldDimDisplay(on: true, lidClosed: false, external: false) && !shouldDimDisplay(on: true, lidClosed: true, external: true), "mode off, open lid or external screen -> restore brightness")
    check(parseBatteryPowerMode("Battery Power:\n powermode 2\nAC Power:\n powermode 0\n") == 2, "power mode parser selects battery, preserves high power for restoration")
    check(parseBatteryPowerMode("AC Power:\n powermode 1\n") == nil && parseBatteryPowerMode("Battery Power:\n powermode 9\n") == nil, "missing or unsupported battery power mode -> unknown")

    let suite = "MacUtility-selftest-" + UUID().uuidString
    let prefs = UserDefaults(suiteName: suite)!
    let power = LowPowerSession(defaults: prefs)
    var mode = 0, writes: [Int] = []
    power.readMode = { mode }
    power.writeMode = { mode = $0; writes.append($0); return nil }
    check(power.setEnabled(true, lidClosed: false) == nil && mode == 0 && writes.isEmpty, "travel with open lid -> no low power or unnecessary write")
    check(power.setEnabled(true, lidClosed: true) == nil && mode == 1, "travel + lid closes -> low power")
    check(power.setEnabled(true, lidClosed: true) == nil && writes == [1], "repeated closed lid keeps original snapshot without another write")
    check(power.setEnabled(true, lidClosed: false) == nil && mode == 0 && writes == [1, 0], "lid opens while travel stays on -> low power off")
    _ = power.setEnabled(true, lidClosed: true)
    check(power.setEnabled(false) == nil && mode == 0 && writes == [1, 0, 1, 0], "repeated close/open then travel off restores original power mode")
    writes = []; mode = 1
    check(power.setEnabled(true, lidClosed: false) == nil && mode == 0, "originally low power is disabled for open-lid work")
    _ = power.setEnabled(true, lidClosed: true)
    check(power.setEnabled(true, lidClosed: false) == nil && mode == 0 && writes == [0, 1, 0], "original low-power snapshot survives several lid transitions")
    let openRestarted = LowPowerSession(defaults: prefs)
    openRestarted.readMode = { mode }
    openRestarted.writeMode = { mode = $0; return nil }
    check(openRestarted.setEnabled(false) == nil && mode == 1, "restart after open-lid work restores original low power")
    mode = 2; _ = power.setEnabled(true, lidClosed: true)
    power.writeMode = { _ in "denied" }
    check(power.setEnabled(false) == "denied" && mode == 1, "failed restore retains snapshot")
    let restarted = LowPowerSession(defaults: prefs)
    restarted.readMode = { mode }
    restarted.writeMode = { mode = $0; return nil }
    check(restarted.setEnabled(false) == nil && mode == 2, "new instance restores saved high power after restart")
    mode = 0
    check(power.setEnabled(true, lidClosed: true) == "denied" && power.setEnabled(false) == nil && mode == 0, "denied close leaves original power mode unchanged")
    power.writeMode = { mode = $0; return nil }
    _ = power.setEnabled(true, lidClosed: true); mode = 2
    check(power.setEnabled(false) == nil && mode == 2, "newer manual power choice is preserved")
    check(power.setEnabled(true, lidClosed: false) == nil && mode == 2, "original high power stays available for open-lid work")
    _ = power.setEnabled(true, lidClosed: true)
    power.writeMode = { _ in "denied" }
    check(power.setEnabled(true, lidClosed: false) == "denied" && mode == 1, "failed open-lid change does not overwrite the last applied mode")
    check(restarted.setEnabled(false) == nil && mode == 2, "failed open-lid change still restores original mode after restart")
    power.writeMode = { mode = $0; return nil }
    _ = power.setEnabled(true, lidClosed: true)
    _ = power.setEnabled(true, lidClosed: false); mode = 0
    check(power.setEnabled(false) == nil && mode == 0, "manual choice after reopening is preserved when travel ends")
    prefs.set(2, forKey: "travelBatteryPowerMode"); mode = 1
    check(power.setEnabled(false) == nil && mode == 2, "v0.6 snapshot remains restorable after upgrade")

    let dim = TravelDisplay(defaults: prefs)
    var brightness: Float = 0.6, brightWrites: [Float] = []
    dim.readBrightness = { brightness }
    dim.writeBrightness = { brightness = $0; brightWrites.append($0); return true }
    let oldTag = traceTag; traceTag = "[test] "
    check(dim.dim(true) == nil && brightness == 0, "closed lid -> dim to zero without sleeping or locking")
    check(dim.dim(true) == nil && brightWrites == [0], "repeated closed-lid tick keeps original brightness snapshot")
    brightness = 0.3
    check(dim.dim(true) == nil && brightness == 0 && brightWrites == [0, 0], "automatic brightness change while closed -> dim again without replacing snapshot")
    dim.writeBrightness = { _ in false }
    check(dim.dim(false) != nil && brightness == 0, "failed brightness restore retains snapshot")
    let dimRestarted = TravelDisplay(defaults: prefs)
    dimRestarted.writeBrightness = { brightness = $0; return true }
    check(dimRestarted.dim(false) == nil && abs(brightness - 0.6) < 0.001, "new instance restores brightness after restart")
    traceTag = oldTag
    prefs.removePersistentDomain(forName: suite)
    check(builtinBrightness().map { $0.isFinite && (0...1).contains($0) } ?? false, "live built-in brightness is readable without changing it")

    var composing = WordComposer(), progress: [String] = []
    for jamo in "ㄱㅣㅇㅓㄱ" { composing.feed(String(jamo)); progress.append(composing.text) }
    check(progress == ["ㄱ", "기", "깅", "기어", "기억"], "current Korean word shows each composition step")
    var erased: [String] = []
    for _ in 0..<4 { composing.backspace(); erased.append(composing.text) }
    check(erased == ["기어", "기ㅇ", "기", ""], "backspace decomposes the active syllable then removes committed letters")
    for (keys, expected) in [("ㄱㅏㅅㅏ", "가사"), ("ㄱㅏㅂㅅㅣ", "갑시"), ("ㄱㅏㅂㅅㅇㅣ", "값이"),
                             ("ㄱㅗㅏㄴ", "관"), ("ㅇㅗㅐㄴ", "왠"), ("ㄷㅏㄹㄱㅇㅡㄹ", "닭을"),
                             ("ㅎㅏㄴㄱㅡㄹ", "한글"), ("ㄲㅏㄲㅏ", "까까"), ("ㅗㅏㄱ", "ㅘㄱ")] {
        composing.clear(); composing.feed(keys)
        check(composing.text == expected, "two-set vowels, finals and syllable boundaries: \(expected)")
    }
    composing.clear(); composing.feed("ㄱㅗㅏㄴ"); erased = []
    for _ in 0..<4 { composing.backspace(); erased.append(composing.text) }
    check(erased == ["과", "고", "ㄱ", ""], "compound vowel backspace follows individual two-set keys")
    var syllableFailures = 0
    for (l, initial) in WordComposer.initials.enumerated() {
        for (v, vowel) in WordComposer.vowels.enumerated() {
            for (t, final) in WordComposer.finals.enumerated() {
                let vPair = WordComposer.vowelPairs.first { $0.2 == vowel }
                let tPair = WordComposer.finalPairs.first { $0.2 == final }
                composing.clear()
                composing.feed(initial + (vPair.map { $0.0 + $0.1 } ?? vowel) + (tPair.map { $0.0 + $0.1 } ?? final))
                if composing.text != String(UnicodeScalar(0xAC00 + (l * 21 + v) * 28 + t)!) { syllableFailures += 1 }
            }
        }
    }
    check(syllableFailures == 0, "all 11,172 modern Hangul syllables compose from two-set jamo")
    var word = WordInput()
    for code: UInt16 in [15, 37, 2, 38, 15] { word.receive(code: code, characters: nil, flags: [], twoSetKorean: true) }
    check(word.text == "기억", "physical two-set keys form the current word")
    word.receive(code: 49, characters: " ", flags: [], twoSetKorean: true)
    check(word.text.isEmpty, "Space clears the current word immediately")
    word.receive(code: 15, characters: nil, flags: [], twoSetKorean: true)
    check(word.text == "ㄱ", "first key after Space starts a new word")
    word.receive(code: 51, characters: nil, flags: [], twoSetKorean: true)
    word.receive(code: 51, characters: nil, flags: [], twoSetKorean: true)
    check(word.text.isEmpty, "backspace never brings a previous word back")
    word.receive(code: 15, characters: "R", flags: .shift, twoSetKorean: true)
    word.receive(code: 40, characters: "k", flags: [], twoSetKorean: true)
    check(word.text == "까", "shifted two-set consonants retain their composition")
    word.clear(); word.receive(code: 0, characters: "Hello", flags: [], twoSetKorean: false)
    word.receive(code: 51, characters: nil, flags: [], twoSetKorean: false)
    check(word.text == "Hell", "English preserves case and supports Backspace")
    word.receive(code: 0, characters: " first second", flags: [], twoSetKorean: false)
    check(word.text == "second", "only the final current word survives a multi-character event")
    for code: UInt16 in [36, 48, 53, 117, 123, 126] {
        word.receive(code: 0, characters: "test", flags: [], twoSetKorean: false)
        word.receive(code: code, characters: nil, flags: [], twoSetKorean: false)
        check(word.text.isEmpty, "navigation and non-text keys clear the word: \(code)")
    }
    for flags: NSEvent.ModifierFlags in [.command, .control, .option, [.control, .option]] {
        word.receive(code: 0, characters: "test", flags: [], twoSetKorean: false)
        word.receive(code: 32, characters: "u", flags: flags, twoSetKorean: true)
        check(word.text.isEmpty, "shortcuts clear the word instead of appending to it")
    }
    word.receive(code: 122, characters: "\u{F704}", flags: [], twoSetKorean: false)
    check(word.text.isEmpty, "function key Unicode is not displayed as a word")
    composing.clear(); composing.feed(String(repeating: "a", count: 600) + "ㄱㅣ")
    check(composing.text.count == WordComposer.limit && composing.text.hasSuffix("기"), "word memory is bounded and retains the active syllable")
    var sentence = WordInput()
    for code: UInt16 in [15, 37, 2, 38, 15, 49, 15, 37, 2, 38, 15] {
        sentence.receive(code: code, characters: nil, flags: [], twoSetKorean: true, textMode: .continuous)
    }
    check(sentence.text == "기억 기억", "continuous mode commits Hangul at Space and composes the next word independently")
    sentence.receive(code: 51, characters: nil, flags: [], twoSetKorean: true, textMode: .continuous)
    check(sentence.text == "기억 기어", "continuous mode decomposes the current Korean syllable on Backspace")
    sentence.clear()
    sentence.receive(code: 0, characters: "Hello world", flags: [], twoSetKorean: false, textMode: .continuous)
    sentence.receive(code: 49, characters: " ", flags: [], twoSetKorean: false, textMode: .continuous)
    sentence.receive(code: 51, characters: nil, flags: [], twoSetKorean: false, textMode: .continuous)
    check(sentence.text == "Hello world", "continuous mode preserves and deletes spaces without losing earlier words")
    sentence.receive(code: 0, characters: String(repeating: " phrase", count: 100), flags: [], twoSetKorean: false, textMode: .continuous)
    check(sentence.text.count == WordComposer.limit && sentence.text.hasSuffix(" phrase"), "continuous input retains at most 256 recent characters")
    for code: UInt16 in [36, 48, 53, 123] {
        sentence.receive(code: code, characters: nil, flags: [], twoSetKorean: false, textMode: .continuous)
        check(sentence.text.isEmpty, "continuous text clears at an editing boundary: \(code)")
        sentence.receive(code: 0, characters: "Hello world", flags: [], twoSetKorean: false, textMode: .continuous)
    }
    check([49, 36, 48, 51, 53, 117, 123, 124, 125, 126].map { KeyLabel.key(code: UInt16($0), characters: nil, flags: []) } == ["␣", "↵", "⇥", "⌫", "⎋", "⌦", "←", "→", "↓", "↑"], "non-text keys have visible symbols without control characters")
    check(KeyLabel.key(code: 49, characters: " ", flags: [.command, .shift]) == "⇧⌘␣" && KeyLabel.key(code: 8, characters: "c", flags: .command) == "⌘C", "key badges include shortcut modifiers")
    check(KeyLabel.key(code: 0, characters: "a", flags: .shift) == nil && KeyLabel.key(code: 122, characters: nil, flags: []) == "F1", "letters remain words and function keys use readable labels")
    check(KeyLabel.modifier(code: 56, flags: .shift) == "⇧" && KeyLabel.modifier(code: 56, flags: []) == nil && KeyLabel.modifier(code: 58, flags: [.control, .option]) == "⌃⌥", "modifier presses are shown and releases do not create new badges")
    let typingElement = AXUIElementCreateApplication(100)
    let typing = TypingMonitor()
    typing.watchFocus = { true }
    typing.readField = { _, done in done(FocusedInput(element: typingElement, text: "")); return nil }
    var secure = false, visibleInput = TypingDisplay(), lastAnimated = true
    typing.secureInput = { secure }
    typing.classify = { _, _, done in done([]); return nil }
    typing.onChange = { visibleInput = $0; lastAnimated = $1 }
    func sampleKey(_ text: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [], repeated: Bool = false, timestamp: TimeInterval = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: timestamp, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: repeated, keyCode: code)!
    }
    typing.receive(sampleKey("hello"))
    check(visibleInput.word == "hello", "monitor publishes a current word without posting an event")
    typing.receive(sampleKey(" ", code: 49))
    check(visibleInput == TypingDisplay(key: "␣") && lastAnimated, "Space clears the word and shows a transient animated badge")
    RunLoop.main.run(until: Date().addingTimeInterval(TypingMonitor.keyDuration + 0.06))
    check(visibleInput.isEmpty && lastAnimated, "a lone non-text key expires automatically")
    typing.receive(sampleKey("he"))
    typing.receive(sampleKey("", code: 51))
    check(visibleInput == TypingDisplay(word: "h", key: "⌫"), "Backspace edits the word while showing its key")
    typing.receive(sampleKey("i"))
    check(visibleInput == TypingDisplay(word: "hi"), "new text removes the old key badge immediately")
    typing.receive(sampleKey("c", code: 8, flags: .command))
    check(visibleInput == TypingDisplay(word: "hi"), "copy shortcut neither displays a badge nor changes the current word")
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    typing.receive(sampleKey("c", code: 8, flags: .command))
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    check(visibleInput == TypingDisplay(word: "hi"), "repeated copy shortcuts cannot refresh the display")
    secure = true; typing.checkPrivacy()
    check(visibleInput.isEmpty && !lastAnimated, "Secure Input clears keys and words immediately even when events stop arriving")
    typing.receive(sampleKey("blocked"))
    check(visibleInput.isEmpty, "Secure Input ignores incoming characters")
    secure = false; typing.receive(sampleKey("new"))
    check(visibleInput.word == "new", "after Secure Input the old word cannot reappear")
    typing.clear()

    var pace = TypingPace()
    check(pace.level(at: 100) == nil, "idle typing has no meme or numeric stats")
    for (count, expected) in [(1, MemeLevel.calm), (4, .typing), (10, .fast), (16, .chaos)] {
        pace.clear()
        for index in 0..<count { pace.record(at: 100 + Double(index) / Double(count)) }
        check(pace.level(at: 101) == expected, "recent physical typing selects meme level \(expected.rawValue)")
    }
    check(pace.level(at: 105.8) == .chaos, "last meme is held for nearly five seconds after typing")
    check(pace.level(at: 106) == nil, "meme activity expires after five seconds")
    pace.record(at: 107)
    check(pace.level(at: 107) == .calm, "old bursts do not affect a new typing session")
    pace.record(at: 50)
    check(pace.level(at: 50) == .calm, "clock reset cannot keep a stale fast meme")
    check(WordEmoji.match("커피") == "☕️" && WordEmoji.match("커피를") == "☕️" && WordEmoji.match("Coffee!") == "☕️", "emoji matching supports Korean particles and English case and punctuation")
    check(WordEmoji.match("고양이") == "🐱" && WordEmoji.match("cat") == "🐱" && WordEmoji.match("코딩") == "💻", "known nouns select related emoji")
    check(WordEmoji.match("ㅋㅋㅋㅋ") == "😂" && WordEmoji.match("ㅠㅠ") == "🥲", "Korean chat reactions map locally")
    check(WordEmoji.match("catastrophe") == nil && WordEmoji.match("사과드립니다") == nil && WordEmoji.match("") == nil, "unknown words do not trigger misleading substring emoji")
    var rotation = MemeRotation()
    let firstMeme = rotation.index(for: .typing)
    check(rotation.index(for: .typing) == firstMeme, "timer ticks and keys keep the same meme playing")
    _ = rotation.index(for: nil)
    let secondMeme = rotation.index(for: .typing)
    check(secondMeme != firstMeme, "a new typing burst picks a different meme in the same speed stage")
    rotation.clear()
    check(![firstMeme, secondMeme].contains(rotation.index(for: .typing)), "privacy reset clears the selection while preserving the non-sensitive gallery order")
    var handRotation = MemeRotation()
    var handCycle: [String] = []
    for _ in 0..<MemeLevel.typingHands.count {
        let scene = handRotation.typingScene()
        handCycle.append(scene.level.files[scene.index]); handRotation.clear()
    }
    check(handCycle.count >= 24 && Set(handCycle) == Set(MemeLevel.typingHands.keys), "typing sessions use all 24 checked hand scenes across speed galleries before repeating")
    let nextHand = handRotation.typingScene()
    check(nextHand.level.files[nextHand.index] != handCycle.last, "hand-scene reshuffling avoids an immediate repeat")
    for level in MemeLevel.allCases {
        var gallery = MemeRotation()
        var cycle: [Int] = []
        for _ in level.files.indices {
            cycle.append(gallery.index(for: level))
            gallery.clear()
        }
        check(Set(cycle) == Set(level.files.indices), "every meme appears once before any repeat: \(level.rawValue)")
        let next = gallery.index(for: level)
        check(next != cycle.last, "reshuffling avoids an immediate repeat between gallery cycles: \(level.rawValue)")
        let other: MemeLevel = level == .calm ? .chaos : .calm
        _ = gallery.index(for: other)
        check(gallery.index(for: level) != next, "speed stages keep independent shuffled galleries: \(level.rawValue)")
    }
    let allMemeFiles = MemeLevel.allCases.flatMap(\.files)
    check(MemeLevel.allCases.allSatisfy { $0.files.count >= 32 } && Set(allMemeFiles).count == allMemeFiles.count, "four speed stages contain at least 128 distinct meme files")
    var now: TimeInterval = 100
    typing.clock = { now }
    typing.setMode(.meme)
    for index in 0..<16 { now = 100 + Double(index) * 0.06; typing.receive(sampleKey("a")) }
    typing.checkMeme(force: true)
    check(visibleInput.meme == .chaos && visibleInput.emoji == nil, "meme mode decorates the current word from typing pace")
    let locked = visibleInput
    for _ in 0..<14 { now += 0.2; typing.receive(sampleKey(" ", code: 49)); typing.receive(sampleKey("slow")) }
    check(visibleInput.meme == locked.meme && visibleInput.memeIndex == locked.memeIndex, "keys and Space do not replace a meme before three seconds")
    now += 0.21; typing.receive(sampleKey("a"))
    check(visibleInput.meme != locked.meme || visibleInput.memeIndex != locked.memeIndex, "continued input rotates the fallback GIF after three seconds")
    let rotated = visibleInput
    now += 3.1; typing.checkMeme()
    check(visibleInput.meme == rotated.meme && visibleInput.memeIndex == rotated.memeIndex, "a silent pause holds the last GIF instead of rotating on its own")
    now -= 3.1
    now += 4.9; typing.checkIdle()
    check(visibleInput.meme == rotated.meme, "the last meme survives almost five seconds of silence")
    now += 0.11; typing.checkIdle()
    check(visibleInput.isEmpty, "five seconds ends the whole typing burst")
    for _ in 0..<16 { now += 0.03; typing.receive(sampleKey("a")) }
    typing.checkMeme(force: true)
    check(visibleInput.meme == .chaos && visibleInput.memeIndex != locked.memeIndex, "a new burst selects another file from the same shuffled gallery")
    secure = true; typing.checkPrivacy()
    check(visibleInput.isEmpty && !lastAnimated, "Secure Input removes meme, word, key and timing state immediately")
    secure = false; now += 0.1; typing.receive(sampleKey("a"))
    for _ in 0..<40 { typing.receive(sampleKey("a", repeated: true)) }
    typing.checkMeme(force: true)
    check(visibleInput.meme == .calm, "holding a key does not inflate physical typing speed")
    typing.setMode(.emoji)
    check(visibleInput.isEmpty, "changing display modes clears the previous word and reaction")
    typing.receive(sampleKey("coffee"))
    check(visibleInput.emoji == "☕️" && visibleInput.meme == nil, "emoji mode uses only the current word")
    typing.receive(sampleKey(" ", code: 49))
    check(visibleInput.word.isEmpty && visibleInput.emoji == nil && visibleInput.key == "␣", "Space clears the emoji without retaining the previous word")
    typing.setMode(.plain); typing.receive(sampleKey("cat"))
    check(visibleInput.meme == nil && visibleInput.emoji == nil && visibleInput.word == "cat", "plain mode retains the original display")
    now += 4.9; typing.checkIdle()
    check(visibleInput.word == "cat", "word remains visible before the five-second deadline")
    now += 0.11; typing.checkIdle()
    check(visibleInput.isEmpty && lastAnimated, "five seconds without typing clears the word with a fade")
    typing.receive(sampleKey("new"))
    check(visibleInput.word == "new", "typing after idle starts a fresh word")
    typing.setTextMode(.continuous)
    typing.receive(sampleKey("hello")); typing.receive(sampleKey(" ", code: 49)); typing.receive(sampleKey("world"))
    check(visibleInput.word == "hello world" && visibleInput.textMode == .continuous, "monitor publishes a continuous sentence independently of effect mode")
    typing.setMode(.emoji)
    typing.receive(sampleKey("hello coffee"))
    check(visibleInput.word == "hello coffee" && visibleInput.emoji == "☕️", "continuous emoji mode follows the current final word")
    secure = true; typing.checkPrivacy()
    check(visibleInput.isEmpty && !lastAnimated, "privacy clearing removes the entire continuous sentence immediately")
    secure = false; typing.setTextMode(.word); typing.setMode(.meme)
    for code: UInt16 in [36, 48, 51, 53, 117, 123, 122] {
        typing.clear(); typing.receive(sampleKey("", code: code)); now += 0.46; typing.checkMeme()
        check(visibleInput.isEmpty, "navigation and control keys cannot start a typing session: \(code)")
    }
    typing.clear()
    typing.receive(sampleKey("c", code: 8, flags: .command)); now += 0.46; typing.checkMeme()
    check(visibleInput.isEmpty, "shortcuts cannot start a fallback meme")
    typing.clear()
    let shift = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
    typing.receive(shift); now += 0.46; typing.checkMeme()
    check(visibleInput.isEmpty, "a standalone modifier or input-source toggle cannot start a meme")

    var callbacks: [([MemeMatch]) -> Void] = [], seeds: [String] = [], embeddingAllowed: [Bool] = [], jobs: [DispatchWorkItem] = []
    typing.classify = { seed, allowEmbedding, callback in
        seeds.append(seed); embeddingAllowed.append(allowEmbedding); callbacks.append(callback)
        let job = DispatchWorkItem {}; jobs.append(job); return job
    }
    let food = MemeMatch(file: "meaning-food-00", label: "배고픔", topic: "food")
    let coffee = MemeMatch(file: "meaning-coffee-00", label: "커피", topic: "coffee")
    let coffee2 = MemeMatch(file: "meaning-coffee-01", label: "커피 한 잔", topic: "coffee")
    let coffee3 = MemeMatch(file: "meaning-coffee-02", label: "카페인", topic: "coffee")
    typing.clear(); typing.receive(sampleKey("hungry"))
    check(callbacks.isEmpty && visibleInput.meme == nil, "meme waits briefly to collect the first word")
    typing.receive(sampleKey(" ", code: 49))
    for _ in 0..<20 { now += 0.1; typing.receive(sampleKey("x")); typing.checkMeme() }
    check(seeds == ["hungry"] && callbacks.count == 1, "only one bounded semantic query runs while a selection is pending")
    callbacks[0]([food])
    typing.receive(sampleKey(" ", code: 49)); typing.receive(sampleKey("coffee")); now += 0.5; typing.checkMeme()
    check(visibleInput.memeMatch == food && callbacks.count == 1, "new words cannot replace a semantic GIF before the three-second deadline")
    now += 2.51; typing.receive(sampleKey(" ", code: 49))
    check(seeds == ["hungry", "coffee"] && embeddingAllowed == [true, false], "a new known subject refreshes the pool at three seconds without another model inference")
    callbacks[1]([coffee, coffee2, coffee3])
    var semanticCycle = [visibleInput.memeMatch!.file]
    for _ in 0..<2 {
        now += 3.01; typing.receive(sampleKey("x"))
        semanticCycle.append(visibleInput.memeMatch!.file)
    }
    check(Set(semanticCycle).count == 3 && callbacks.count == 2, "all semantic candidates appear once before repeating, without reclassifying at every rotation")
    now += 3.01; typing.receive(sampleKey("x"))
    check(visibleInput.memeMatch?.file != semanticCycle.last, "semantic shuffle avoids an immediate repeat between cycles")
    callbacks = []; seeds = []; embeddingAllowed = []; jobs = []
    typing.clear(); typing.receive(sampleKey("coffee")); typing.checkMeme(force: true)
    secure = true; typing.checkPrivacy(); callbacks[0]([coffee])
    check(jobs[0].isCancelled && visibleInput.isEmpty, "a delayed semantic answer cannot restore text or memes after Secure Input")
    secure = false; typing.receive(sampleKey("hungry")); typing.checkMeme(force: true)
    now += 5.1; callbacks[1]([food])
    check(visibleInput.isEmpty && jobs[1].isCancelled, "a delayed semantic answer cannot outlive the five-second burst")
    typing.receive(sampleKey("hungry")); typing.checkMeme(force: true)
    typing.clear(); typing.receive(sampleKey("coffee")); typing.checkMeme(force: true)
    callbacks[2]([food])
    check(visibleInput.meme == nil, "an old selection cannot overwrite a newer typing burst")
    callbacks[3]([coffee])
    check(visibleInput.memeMatch == coffee, "the current burst receives its own semantic match")
    typing.clear(); typing.receive(sampleKey("coffee")); typing.checkMeme(force: true); typing.setTextMode(.continuous); callbacks[4]([coffee])
    check(visibleInput.isEmpty && jobs[4].isCancelled, "changing text mode also cancels an outstanding semantic query")
    typing.receive(sampleKey("coffee")); typing.checkMeme(force: true); now -= 50; callbacks[5]([coffee])
    check(visibleInput.isEmpty, "a clock reset cannot restore a stale semantic result")
    typing.stop()

    let sessionTyping = TypingMonitor()
    sessionTyping.watchFocus = { true }
    sessionTyping.readField = { _, done in done(FocusedInput(element: typingElement, text: "")); return nil }
    var sessionTime: TimeInterval = 100, sessionDisplay = TypingDisplay(), sessionSecure = false, sessionQueries = 0, sessionAnimated = true
    sessionTyping.clock = { sessionTime }; sessionTyping.secureInput = { sessionSecure }
    sessionTyping.onChange = { sessionDisplay = $0; sessionAnimated = $1 }
    sessionTyping.classify = { _, _, _ in sessionQueries += 1; return nil }
    sessionTyping.setMode(.typingMeme)
    sessionTyping.receive(sampleKey("a"))
    check(sessionDisplay.meme != nil && sessionDisplay.memeMatch == nil && sessionDisplay.memeFrame == 1, "typing meme mode immediately selects one frame without semantic matching")
    let sessionMeme = sessionDisplay.memeIndex, sessionLevel = sessionDisplay.meme
    sessionTyping.receive(sampleKey(" ", code: 49))
    check(sessionDisplay.memeFrame == 0 && sessionDisplay.memeIndex == sessionMeme, "Space alternates the same typing meme to its other frame")
    sessionTyping.receive(sampleKey("b"))
    check(sessionDisplay.memeFrame == 1 && sessionDisplay.memeIndex == sessionMeme, "the next character taps the other hand without replacing the session GIF")
    sessionTyping.receive(sampleKey("a", repeated: true))
    check(sessionDisplay.memeFrame == 1, "holding a key does not autoplay or retrigger the two-frame animation")
    let copiedKey = sampleKey("x", timestamp: 500)
    sessionTyping.observe(copiedKey); sessionTyping.observe(copiedKey)
    check(sessionDisplay.memeFrame == 0, "a duplicated event copy advances the typing frame only once")
    sessionTyping.receive(shift)
    check(sessionDisplay.memeFrame == 0, "pressing a modifier leaves the typing frame unchanged")
    let shiftRelease = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
    sessionTyping.receive(shiftRelease)
    check(sessionDisplay.memeFrame == 0, "releasing a modifier never advances the typing frame")
    var sessionHeld = true
    for index in 0..<15 {
        sessionTime += 1
        sessionTyping.receive(sampleKey(index % 2 == 0 ? " " : "배고파", code: index % 2 == 0 ? 49 : 0))
        sessionTyping.checkMeme()
        sessionHeld = sessionHeld && sessionDisplay.meme == sessionLevel && sessionDisplay.memeIndex == sessionMeme
    }
    check(sessionHeld && sessionQueries == 0, "words, Space and elapsed three-second intervals keep one typing meme for the whole session without model calls")
    let heldFrame = sessionDisplay.memeFrame
    sessionTime += 4.99; sessionTyping.checkIdle()
    sessionTyping.checkMeme()
    check(sessionDisplay.meme == sessionLevel && sessionDisplay.memeIndex == sessionMeme && sessionDisplay.memeFrame == heldFrame, "a short pause holds the last frame without autoplay")
    sessionTime += 0.02; sessionTyping.checkIdle()
    check(sessionDisplay.isEmpty && sessionAnimated, "five seconds without input ends the typing meme session with a fade")
    sessionTyping.receive(sampleKey("", code: 36))
    check(sessionDisplay.isEmpty, "Enter alone cannot reopen a finished session")
    sessionTyping.receive(sampleKey("next"))
    check(sessionDisplay.meme != nil && (sessionDisplay.meme != sessionLevel || sessionDisplay.memeIndex != sessionMeme), "the next typed session picks a different GIF")
    sessionTyping.receive(sampleKey("", code: 36))
    check(sessionDisplay.isEmpty && sessionAnimated, "Enter finishes a word session using the animated collapse path")
    sessionTyping.receive(sampleKey("again"))
    sessionSecure = true; sessionTyping.checkPrivacy()
    check(sessionDisplay.isEmpty && !sessionAnimated, "typing meme mode clears immediately for Secure Input")
    sessionTyping.receive(sampleKey("blocked")); sessionTyping.checkMeme()
    check(sessionDisplay.isEmpty && sessionQueries == 0, "secure input cannot start a typing GIF or semantic query")
    sessionSecure = false; sessionTyping.receive(sampleKey("new")); sessionTyping.setMode(.plain)
    check(sessionDisplay.isEmpty, "leaving typing meme mode clears its session")
    check(TypingMode(rawValue: "typingMeme") == .typingMeme && TypingMode.allCases.map(\.label).contains("타이핑 밈 모드"), "mode menu and persisted value include the separate typing meme mode")
    sessionTyping.stop()

    let observedTyping = TypingMonitor()
    observedTyping.watchFocus = { true }
    observedTyping.readField = { _, done in done(FocusedInput(element: typingElement, text: "")); return nil }
    var observedDisplay = TypingDisplay()
    observedTyping.secureInput = { false }
    observedTyping.onChange = { display, _ in observedDisplay = display }
    for (index, jamo) in Array("ㅌㅏㅇㅣㅍㅣㅇㅎㅏㅁㅕㄴ").enumerated() {
        let event = sampleKey(String(jamo), timestamp: Double(index + 1))
        observedTyping.observe(event); observedTyping.observe(event)
    }
    check(observedDisplay.word == "타이핑하면", "duplicate copies of a physical Korean key are composed only once")
    observedTyping.observe(sampleKey("a", repeated: true, timestamp: 20))
    observedTyping.observe(sampleKey("a", repeated: true, timestamp: 21))
    check(observedDisplay.word == "타이핑하면aa", "distinct repeated key events remain separate input")
    observedTyping.stop()

    let gated = TypingMonitor()
    var gateTime: TimeInterval = 100, gatedDisplay = TypingDisplay(), focusReads = 0
    var editableFocus: FocusedInput?
    var requestedBodies: [Bool] = []
    gated.clock = { gateTime }; gated.secureInput = { false }
    gated.onChange = { display, _ in gatedDisplay = display }
    gated.watchFocus = { true }
    gated.readField = { body, done in
        focusReads += 1; requestedBodies.append(body); done(editableFocus); return nil
    }
    gated.setMode(.typingMeme)
    for _ in 0..<30 { gated.receive(sampleKey(" ", code: 49, repeated: true)) }
    check(gatedDisplay.isEmpty && focusReads == 1, "holding Space on a non-editor never opens the island and focus reads stay bounded")
    gateTime += 0.3
    gated.receive(sampleKey("c", code: 8, flags: .command))
    gated.receive(sampleKey("v", code: 9, flags: .command)); gated.receive(shift)
    check(gatedDisplay.isEmpty && focusReads == 1, "copy, paste and modifiers cannot trigger a display or even a focus read")
    editableFocus = FocusedInput(element: typingElement, text: "")
    gated.receive(sampleKey("입력"))
    check(gatedDisplay.word == "입력" && gatedDisplay.meme != nil && requestedBodies == [false, false], "the first real text key waits for editable focus without reading existing field contents")
    let editingDisplay = gatedDisplay
    gated.receive(sampleKey("c", code: 8, flags: .command)); gated.receive(sampleKey("v", code: 9, flags: .command))
    check(gatedDisplay == editingDisplay, "copy and paste preserve an active GIF, phase and text without shortcut badges")
    let readsDuringTyping = focusReads
    for _ in 0..<40 {
        gateTime += 0.1
        gated.receive(sampleKey("a")); gated.checkField()
    }
    check(focusReads == readsDuringTyping, "word typing and timer ticks never poll an already validated focus")
    let ongoingTyping = gatedDisplay
    gated.focusChanged(typingElement)
    check(gatedDisplay == ongoingTyping && focusReads == readsDuringTyping, "a duplicate focus notification preserves the word, GIF and hand frame without an AX read")
    let programmaticField = AXUIElementCreateApplication(103)
    gated.focusChanged(programmaticField)
    check(gatedDisplay.isEmpty && focusReads == readsDuringTyping, "a programmatic focus change clears cached input immediately without polling")
    editableFocus = FocusedInput(element: programmaticField, text: "")
    gated.setTextMode(.continuous); gated.receive(sampleKey("new"))
    let continuousReads = focusReads
    for _ in 0..<40 {
        gateTime += 0.1
        gated.receive(sampleKey("a")); gated.checkField()
    }
    check(gatedDisplay.word.hasPrefix("new") && focusReads == continuousReads, "continuous typing also caches focus without repeated AX queries")
    gated.clear(); gated.watchFocus = { false }
    gated.receive(sampleKey("blocked"))
    check(gatedDisplay.isEmpty && focusReads == continuousReads, "unsupported focus notifications fail closed before reading or showing an input")
    gated.watchFocus = { true }; gated.setTextMode(.word)
    var focusReply: ((FocusedInput?) -> Void)?
    gated.clear(); gated.readField = { _, done in focusReply = done; return DispatchWorkItem {} }
    gated.receive(sampleKey("stale")); gated.clear(); focusReply?(editableFocus)
    check(gatedDisplay.isEmpty, "a delayed focus validation cannot replay a buffered key after the app or field changes")
    gated.receive(sampleKey("old")); gated.focusChanged(programmaticField); focusReply?(editableFocus)
    check(gatedDisplay.isEmpty, "a focus notification invalidates an in-flight first-key read")
    gated.receive(sampleKey("quick")); gated.receive(sampleKey("", code: 36)); focusReply?(editableFocus)
    check(gatedDisplay.isEmpty, "Enter cancels a first key still waiting for focus validation instead of reopening the finished input")
    gated.stop()

    let imeTyping = TypingMonitor()
    var imeDisplay = TypingDisplay(), imeChanges = 0
    imeTyping.secureInput = { false }
    imeTyping.watchFocus = { true }
    imeTyping.readField = { _, done in done(FocusedInput(element: typingElement, text: "")); return nil }
    imeTyping.onChange = { display, _ in imeDisplay = display; imeChanges += 1 }
    imeTyping.setMode(.typingMeme); imeTyping.setInputSource(korean: true)
    imeTyping.receive(sampleKey("r", code: 15)); imeTyping.receive(sampleKey("l", code: 37))
    let beforeSourceSwitch = imeDisplay, changesBeforeSwitch = imeChanges
    imeTyping.focusChanged(typingElement)
    imeTyping.setInputSource(korean: false)
    let caps = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .capsLock, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 57)!
    imeTyping.receive(caps); imeTyping.receive(sampleKey(" ", code: 49, flags: .control))
    check(imeDisplay == beforeSourceSwitch && imeChanges == changesBeforeSwitch, "Korean/English notification, Caps Lock and Control-Space neither collapse nor change the session GIF or frame")
    imeTyping.receive(sampleKey("a"))
    check(imeDisplay.word == "기a" && imeDisplay.meme == beforeSourceSwitch.meme && imeDisplay.memeIndex == beforeSourceSwitch.memeIndex, "switching to English commits the Korean syllable and preserves the selected GIF")
    imeTyping.setInputSource(korean: true); imeTyping.receive(sampleKey("r", code: 15))
    imeTyping.setInputSource(korean: true); imeTyping.receive(sampleKey("l", code: 37))
    check(imeDisplay.word == "기a기", "duplicate source notifications do not split an in-progress Korean syllable")
    imeTyping.stop()

    // AX fixtures never inspect the user's real focused application or clipboard.
    let fieldElement = AXUIElementCreateApplication(101), otherField = AXUIElementCreateApplication(102)
    var attributes: [String: CFTypeRef] = [kAXRoleAttribute: kAXTextAreaRole as CFString,
        kAXSubroleAttribute: kAXUnknownSubrole as CFString, kAXValueAttribute: "  붙여 넣은 글\n중간 수정 🙂  " as CFString]
    var valueReads = 0
    let copyField: (AXUIElement, String) -> CFTypeRef? = { _, name in
        if name == kAXValueAttribute { valueReads += 1 }
        return attributes[name]
    }
    let acceptedField = FocusedInput.read(fieldElement, copy: copyField, canEdit: { _ in true })
    check(acceptedField?.text == "  붙여 넣은 글\n중간 수정 🙂  ", "field reader preserves whitespace, line breaks and emoji exactly")
    valueReads = 0
    check(FocusedInput.read(fieldElement, includeText: false, copy: copyField, canEdit: { _ in true })?.text == "" && valueReads == 0, "word-mode eligibility reads metadata only, without inspecting the existing input value")
    for role in [kAXTextFieldRole, kAXComboBoxRole] {
        attributes[kAXRoleAttribute] = role as CFString
        check(FocusedInput.read(fieldElement, copy: copyField, canEdit: { _ in true }) != nil, "editable text role accepted: \(role)")
    }
    attributes[kAXSubroleAttribute] = kAXSecureTextFieldSubrole as CFString; valueReads = 0
    check(FocusedInput.read(fieldElement, copy: copyField, canEdit: { _ in true }) == nil && valueReads == 0, "password field is rejected before its value is read")
    attributes[kAXSubroleAttribute] = kAXUnknownSubrole as CFString
    attributes[kAXRoleAttribute] = kAXStaticTextRole as CFString; valueReads = 0
    check(FocusedInput.read(fieldElement, copy: copyField, canEdit: { _ in true }) == nil && valueReads == 0, "static document text is never read as an input")
    attributes[kAXRoleAttribute] = kAXTextAreaRole as CFString
    check(FocusedInput.read(fieldElement, copy: copyField, canEdit: { _ in false }) == nil && valueReads == 0, "read-only editor is rejected before reading its body")
    attributes[kAXEnabledAttribute] = kCFBooleanFalse
    check(FocusedInput.read(fieldElement, copy: copyField, canEdit: { _ in true }) == nil, "disabled input is excluded")
    attributes.removeValue(forKey: kAXEnabledAttribute)
    attributes[kAXNumberOfCharactersAttribute] = NSNumber(value: FocusedInput.limit + 1); valueReads = 0
    check(FocusedInput.read(fieldElement, copy: copyField, canEdit: { _ in true }) == nil && valueReads == 0, "oversize editor is refused without fetching its value")
    attributes.removeValue(forKey: kAXNumberOfCharactersAttribute)
    attributes[kAXValueAttribute] = String(repeating: "🙂", count: FocusedInput.limit / 2 + 1) as CFString
    check(FocusedInput.read(fieldElement, copy: copyField, canEdit: { _ in true }) == nil, "fallback size check counts UTF-16 units without truncating emoji")
    attributes[kAXValueAttribute] = String(repeating: "가", count: FocusedInput.limit) as CFString
    check(FocusedInput.read(fieldElement, copy: copyField, canEdit: { _ in true })?.text.count == FocusedInput.limit, "complete long input is retained at the supported limit")
    attributes[kAXValueAttribute] = NSNumber(value: 42)
    check(FocusedInput.read(fieldElement, copy: copyField, canEdit: { _ in true }) == nil, "non-string AX value cannot become displayed input")

    let mirror = TypingMonitor()
    var fieldTime: TimeInterval = 100, mirrored = TypingDisplay(), mirrorAnimated = true, fieldSecure = false, reads = 0
    var snapshot: FocusedInput? = FocusedInput(element: fieldElement, text: "이미 써 둔 글\ncoffee")
    mirror.clock = { fieldTime }; mirror.secureInput = { fieldSecure }
    mirror.onChange = { mirrored = $0; mirrorAnimated = $1 }
    mirror.watchFocus = { true }
    mirror.readField = { _, done in reads += 1; done(snapshot); return nil }
    mirror.checkField()
    check(reads == 0, "word and continuous modes never read a field")
    mirror.setTextMode(.field); mirror.checkField()
    check(mirrored.isEmpty, "focusing pre-existing input alone does not open the island before editing")
    mirror.checkField(); fieldTime += 0.24; mirror.checkField()
    check(reads == 1, "field reads are bounded to at most four per second")
    snapshot = FocusedInput(element: fieldElement, text: "붙여넣은 문장\n중간을 바꿨어요 🙂")
    fieldTime += 0.02; mirror.checkField()
    check(mirrored.word == snapshot?.text, "paste and middle edits replace the mirror with the complete actual value")
    mirror.receive(sampleKey("wrong reconstructed text"))
    check(mirrored.word == snapshot?.text, "field mode never appends reconstructed key text")
    mirror.receive(sampleKey("v", code: 9, flags: .command))
    check(mirrored.key.isEmpty && mirrored.word == snapshot?.text, "paste shortcut never shows a command badge or destroys the mirrored field")
    fieldTime += 4.9; mirror.checkField(); mirror.receive(sampleKey("", code: 123))
    check(mirrored.word == snapshot?.text && mirrored.key.isEmpty, "unchanged polling and navigation preserve input without a badge or a new deadline")
    fieldTime += 0.11; mirror.checkIdle(); fieldTime += 0.26; mirror.checkField()
    check(mirrored.isEmpty && mirrorAnimated, "five-second fade does not reappear from unchanged polling")
    mirror.receive(sampleKey("", code: 123))
    mirror.receive(sampleKey("c", code: 8, flags: .command)); mirror.receive(shift)
    check(mirrored.isEmpty, "navigation, copying and modifiers cannot revive an unchanged hidden input")
    snapshot = FocusedInput(element: fieldElement, text: "실제로 바뀐 문장\n수정한 글")
    fieldTime += 0.26; mirror.checkField()
    check(mirrored.word == snapshot?.text, "a real field-content change restores its complete current text after idle")
    fieldTime += 4.9; snapshot = FocusedInput(element: fieldElement, text: "한 번 더 수정한 글"); mirror.checkField()
    fieldTime += 0.11; mirror.checkIdle()
    check(mirrored.word == "한 번 더 수정한 글", "a real text change restarts the five-second deadline")
    mirror.receive(sampleKey("\n", code: 36))
    check(mirrored.word == snapshot?.text && mirrored.key == "↵", "Enter waits for the actual field value and does not discard a multiline input")
    snapshot = FocusedInput(element: fieldElement, text: ""); fieldTime += 0.26; mirror.checkField()
    check(mirrored.isEmpty && mirrorAnimated, "Enter submission that empties the actual field uses the smooth collapse path")
    snapshot = FocusedInput(element: fieldElement, text: "다시 입력"); fieldTime += 0.26; mirror.checkField()
    mirror.receive(sampleKey("", code: 48))
    check(mirrored.isEmpty && !mirrorAnimated, "Tab clears the old field before focus can move to a password")
    fieldTime += 0.26; mirror.checkField()
    check(mirrored.isEmpty, "Tab or Escape cannot rediscover unchanged contents as fresh activity")
    snapshot = FocusedInput(element: otherField, text: "다른 입력창")
    fieldTime += 0.26; mirror.checkField()
    check(mirrored.isEmpty, "focus change removes previous input without opening prefilled text")
    snapshot = FocusedInput(element: otherField, text: "다른 입력창 수정")
    fieldTime += 0.26; mirror.checkField()
    check(mirrored.word == snapshot?.text, "editing the new field mirrors its complete actual contents")
    snapshot = nil; fieldTime += 0.26; mirror.checkField()
    check(mirrored.isEmpty && !mirrorAnimated, "unsupported or inaccessible focused input immediately removes the previous mirror")
    snapshot = FocusedInput(element: fieldElement, text: ""); fieldTime += 0.26; mirror.checkField()
    check(mirrored.isEmpty, "empty input removes both text and reaction")
    snapshot = FocusedInput(element: fieldElement, text: "coffee"); fieldTime += 0.26; mirror.checkField()
    fieldSecure = true; mirror.checkPrivacy()
    check(mirrored.isEmpty && !mirrorAnimated, "Secure Input clears field text without a fade")
    let readsBeforeSecure = reads; fieldTime += 0.26; mirror.checkField()
    check(reads == readsBeforeSecure, "Secure Input prevents even an attempted field read")
    fieldSecure = false
    var fieldCallbacks: [(FocusedInput?) -> Void] = [], fieldJobs: [DispatchWorkItem] = []
    mirror.readField = { _, done in
        fieldCallbacks.append(done); let job = DispatchWorkItem {}; fieldJobs.append(job); return job
    }
    mirror.checkField(); mirror.setTextMode(.continuous); fieldCallbacks[0](snapshot)
    check(mirrored.isEmpty && fieldJobs[0].isCancelled, "delayed field read cannot revive input after a mode change")
    mirror.setTextMode(.field); fieldTime += 0.26; mirror.checkField()
    mirror.clear(); fieldCallbacks[1](snapshot)
    check(mirrored.isEmpty && fieldJobs[1].isCancelled, "app or focus privacy reset invalidates an in-flight field read")

    var fieldSeeds: [String] = [], fieldAnswers: [([MemeMatch]) -> Void] = [], fieldEmbeddings: [Bool] = []
    mirror.readField = { _, done in done(snapshot); return nil }
    mirror.classify = { seed, embed, done in fieldSeeds.append(seed); fieldEmbeddings.append(embed); fieldAnswers.append(done); return nil }
    mirror.setMode(.meme)
    snapshot = FocusedInput(element: fieldElement, text: "coffee " + String(repeating: "이전에 쓴 문장 ", count: 80))
    fieldTime += 0.26; mirror.receive(sampleKey("coffee")); mirror.checkMeme(force: true)
    check(fieldSeeds == [snapshot!.text] && mirrored.word.count > WordComposer.limit, "field display and meme query include contents beyond the old 256 and 160 character limits")
    fieldAnswers[0]([coffee, coffee2, coffee3])
    let oldFieldMeme = mirrored.memeMatch
    snapshot = FocusedInput(element: fieldElement, text: "눈이 감기고 침대에 눕고 싶다")
    fieldTime += 0.5; mirror.checkField(); mirror.checkMeme()
    check(fieldSeeds.count == 1 && mirrored.memeMatch == oldFieldMeme, "field edits retain the minimum three-second GIF interval")
    fieldTime += 2.51; mirror.checkMeme()
    check(fieldSeeds.count == 2 && fieldSeeds.last == snapshot?.text && fieldEmbeddings == [true, true], "changed actual field can refresh semantic meaning at the next three-second boundary")
    snapshot = FocusedInput(element: otherField, text: "배고파")
    fieldTime += 0.26; mirror.checkField(); fieldAnswers[1]([coffee])
    check(mirrored.isEmpty, "late answer from another focused field cannot restore its text or meme")
    snapshot = FocusedInput(element: otherField, text: "배고파!")
    fieldTime += 0.26; mirror.checkField()
    mirror.checkMeme(force: true); fieldAnswers[2]([food]); let queryCount = fieldSeeds.count
    let unchangedMeme = mirrored.memeMatch
    fieldTime += 3.01; mirror.receive(sampleKey("", code: 123)); mirror.checkMeme()
    check(fieldSeeds.count == queryCount && mirrored.memeMatch == unchangedMeme, "navigation without a content change does not refresh or rotate the field meme")
    mirror.clear(); fieldTime += 0.26; mirror.receive(sampleKey("typed")); mirror.checkMeme(force: true)
    fieldSecure = true; mirror.checkPrivacy(); fieldAnswers.last?([food])
    check(mirrored.isEmpty, "privacy reset rejects a delayed semantic result for a mirrored field")
    fieldSecure = false; mirror.setMode(.typingMeme)
    snapshot = FocusedInput(element: fieldElement, text: "처음 쓴 문장")
    fieldTime += 0.26; mirror.receive(sampleKey("typed")); mirror.checkMeme()
    let typingFieldMeme = mirrored.memeIndex, typingFieldLevel = mirrored.meme, typingFieldQueries = fieldSeeds.count
    let typingFieldFrame = mirrored.memeFrame
    mirror.receive(sampleKey("a"))
    check(mirrored.memeFrame != typingFieldFrame, "input-field mode also advances the typing frame on an observed key")
    let afterFieldKey = mirrored.memeFrame
    for index in 1...6 {
        fieldTime += 1
        snapshot = FocusedInput(element: fieldElement, text: "바뀐 문장 \(index)")
        mirror.checkField(); mirror.checkMeme()
    }
    check(mirrored.word == snapshot?.text && mirrored.meme == typingFieldLevel && mirrored.memeIndex == typingFieldMeme && fieldSeeds.count == typingFieldQueries, "input-field edits mirror the text while retaining one typing GIF without semantic queries")
    check(mirrored.memeFrame == afterFieldKey, "AX content changes and polling never advance the typing animation without keys")
    fieldTime += 5.01; mirror.checkIdle(); mirror.checkField(); mirror.checkMeme()
    check(mirrored.isEmpty, "unchanged mirrored text cannot revive an idle typing meme session")
    mirror.stop()
    let longContext = "커피 " + String(repeating: "보통의 문장 ", count: 400)
    let sampledContext = SemanticMemeMatcher.embeddingText(longContext)
    check(sampledContext.count <= 770 && sampledContext.hasPrefix("커피 ") && sampledContext.hasSuffix(String(longContext.suffix(256))), "long semantic inference samples start, middle and end with a bounded cost")
    check(SemanticMemeMatcher().candidates(longContext, allowEmbedding: false).first?.topic == "coffee", "topic selection can find relevant content at the start of a long field")
    check(TypingTextMode.allCases.map(\.label) == ["단어 모드", "연속 모드", "입력창 모드"] && TypingTextMode(rawValue: "field") == .field, "mode menu and persisted value include the actual-field option")

    for level in MemeLevel.allCases {
      for variant in level.files.indices {
        let url = level.url(at: variant)
        let bitmap = url.flatMap { try? Data(contentsOf: $0) }.flatMap { NSBitmapImageRep(data: $0) }
        // Static GIFs may omit frameCount; successful decoding is enough for the calm image.
        let frames = bitmap?.value(forProperty: .frameCount) as? Int ?? 1
        check(url?.isFileURL == true && bitmap != nil && (level == .calm ? frames >= 1 : frames > 1), "local meme resource decodes with expected animation: \(level.files[variant])")
        if Bundle.main.bundleURL.pathExtension == "app" {
            check(url?.path.hasPrefix(Bundle.main.bundlePath + "/") == true, "installed meme loads from app resources, without source checkout")
        }
      }
    }
    let catalog = SemanticMemeMatcher.loadIndex()
    check((catalog?.entries.count ?? 0) >= 1000 && catalog?.isValid() == true, "over a thousand tagged memes have validated precomputed Korean and English vectors")
    check(Set(catalog?.anchors.keys.map { $0 } ?? []) == Set(MemeTopic.allCases.map(\.rawValue)), "short-word query vectors cover every authored reaction topic")
    let known = [("배고파", "food"), ("커피", "coffee"), ("졸려", "sleep"), ("퇴근", "celebrate"),
                 ("ㅠㅠ", "sad"), ("고마워", "thanks"), ("열받아", "angry"), ("헷갈린다", "confused"),
                 ("버그", "error"), ("기다린다", "waiting"), ("코딩", "work"), ("월급", "money"),
                 ("휴가", "travel"), ("고양이", "cat"), ("멍멍", "dog"), ("쉬고싶다", "relax"),
                 ("hungry", "food"), ("coffee", "coffee"), ("sleepy", "sleep"), ("done", "celebrate"),
                 ("crying", "sad"), ("thanks", "thanks"), ("angry", "angry"), ("confused", "confused"),
                 ("error", "error"), ("waiting", "waiting"), ("working", "work"), ("payday", "money"),
                 ("vacation", "travel"), ("kitten", "cat"), ("puppy", "dog"), ("relax", "relax"),
                 ("놀랐어", "surprise"), ("민망하다", "awkward"), ("동의해", "approve"), ("싫어", "reject"),
                 ("힘내", "cheer"), ("어이없다", "facepalm"), ("뿌듯하다", "smug"), ("수상하다", "skeptical"),
                 ("무서워", "scared"), ("ㅋㅋㅋ", "laugh"), ("춤추자", "dance"), ("안아줘", "hug"),
                 ("미안해", "apology"), ("안녕하세요", "hello"), ("잘가", "goodbye"), ("글쎄", "shrug"),
                 ("비밀이야", "secret"), ("쇼핑하자", "shopping"), ("운동하자", "exercise"), ("노래", "music"),
                 ("게임하자", "gaming"), ("비가온다", "rain"), ("추워", "cold"),
                 ("shocked", "surprise"), ("awkward", "awkward"), ("yes", "approve"), ("nope", "reject"),
                 ("you got this", "cheer"), ("facepalm", "facepalm"), ("proud", "smug"), ("side eye", "skeptical"),
                 ("scared", "scared"), ("lol", "laugh"), ("dancing", "dance"), ("hug", "hug"),
                 ("sorry", "apology"), ("hello", "hello"), ("bye", "goodbye"), ("whatever", "shrug"),
                 ("secret", "secret"), ("shopping", "shopping"), ("workout", "exercise"), ("music", "music"),
                 ("gaming", "gaming"), ("raining", "rain"), ("freezing", "cold")]
    let matcher = SemanticMemeMatcher()
    for (text, topic) in known {
        check(matcher.match(text)?.topic == topic, "nearest local meme vector matches the authored reaction: \(text)")
    }
    check(matcher.embeddedQueries == 0, "known short words search vectors without loading an embedding model")
    for topic in MemeTopic.allCases {
        let choices = matcher.candidates(topic.anchors[0], allowEmbedding: false)
        check(choices.count >= 3 && choices.allSatisfy { $0.topic == topic.rawValue }, "every recognized subject offers several distinct GIFs instead of pinning one: \(topic.rawValue)")
    }
    check(MemeTopic.keyword(in: "catastrophe") == nil && MemeTopic.keyword(in: "sometimes") == nil && MemeTopic.keyword(in: "coffee2") == nil && MemeTopic.keyword(in: "cat_id") == nil && MemeTopic.keyword(in: "coffee then hungry") == .food, "short aliases respect English word boundaries and prefer the latest subject")
    check(matcher.candidates("coffee").count >= 12, "a known subject offers many nearby GIFs for rotation")
    let general = matcher.generalCandidates()
    check(general.count >= 900 && general.allSatisfy { $0.topic != "work" }, "unknown words and non-letter keys can use over nine hundred varied reactions")
    let beforeRotationQueries = matcher.embeddedQueries
    check(matcher.candidates("some new unrecognized sentence", allowEmbedding: false).isEmpty && matcher.embeddedQueries == beforeRotationQueries, "timed rotation cannot invoke the free-text model")
    for (text, topic) in [("눈이 감기고 침대에 눕고 싶다", "sleep"), ("답이 도착할 때까지 아무것도 못하고 있다", "waiting"), ("I cannot afford this", "money")] {
        check(matcher.match(text)?.topic == topic, "unseen phrasing can select a local semantic vector: \(topic)")
    }
    check(matcher.match("일부 설정을 바꾸었다") == nil && matcher.match("see you next week") == nil && matcher.match("xyqz") == nil, "uncertain or very short free text uses the general-gallery fallback")
    if let entries = catalog?.entries {
        let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
        let resources = Set((try? FileManager.default.contentsOfDirectory(atPath: bundle.bundleURL.path + (Bundle.main.bundleURL.pathExtension == "app" ? "/Contents/Resources/Memes" : "/Memes")))?.filter { $0.hasSuffix(".gif") }.map { String($0.dropLast(4)) } ?? [])
        check(resources == Set(entries.map(\.file)), "every bundled GIF appears exactly once in the semantic catalog")
        for entry in entries where !allMemeFiles.contains(entry.file) {
          autoreleasepool {
            let match = MemeMatch(file: entry.file, label: entry.label, topic: entry.topic)
            let bitmap = match.url.flatMap { try? Data(contentsOf: $0) }.flatMap { NSBitmapImageRep(data: $0) }
            check(bitmap != nil, "new non-keyboard reaction resource decodes: \(entry.file)")
            if Bundle.main.bundleURL.pathExtension == "app" { check(match.url?.path.hasPrefix(Bundle.main.bundlePath + "/") == true, "semantic GIF loads from installed app resources") }
          }
        }
        var broken = catalog!
        broken.entries[0].vectors["ko"] = Data([0])
        check(!broken.isValid(), "truncated vectors cannot enter the runtime index")
        broken = catalog!; broken.entries[0].file = "../outside"
        check(!broken.isValid(), "catalog file names cannot escape the bundled meme directory")
    }

    let f = CGRect(x: 0, y: 0, width: 1500, height: 900)
    check(targetRect(.leftThird, in: f) == CGRect(x: 0, y: 0, width: 500, height: 900), "U left third")
    check(targetRect(.centerThird, in: f) == CGRect(x: 500, y: 0, width: 500, height: 900), "I center third")
    check(targetRect(.rightThird, in: f) == CGRect(x: 1000, y: 0, width: 500, height: 900), "O right third")
    check(targetRect(.leftHalf, in: f) == CGRect(x: 0, y: 0, width: 750, height: 900), "J left half")
    check(targetRect(.rightHalf, in: f) == CGRect(x: 750, y: 0, width: 750, height: 900), "L right half")
    check(targetRect(.centerHalf, in: f) == CGRect(x: 375, y: 0, width: 750, height: 900), "K center half = middle two of four columns")
    let g = CGRect(x: 100, y: 32, width: 1000, height: 800)
    let t = [LayoutAction.leftThird, .centerThird, .rightThird].map { targetRect($0, in: g) }
    check(t[0].minX == g.minX && t[0].maxX == t[1].minX && t[1].maxX == t[2].minX && t[2].maxX == g.maxX, "thirds tile exactly on width 1000")
    check(LayoutAction.allCases.map { $0.label } == ["U", "I", "O", "J", "L", "K"], "key labels in order")
    check(toAX(CGRect(x: 0, y: 0, width: 1728, height: 1085), primaryHeight: 1117) == CGRect(x: 0, y: 32, width: 1728, height: 1085), "Cocoa -> AX y flip")

    // the island
    let scr = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let isl = IslandLayout(screen: scr, notch: CGSize(width: 185, height: 32))
    let o = isl.openSize
    check(isl.closedSize == CGSize(width: 185, height: 32), "closed island is exactly the notch, so nothing shows beside it")
    check(isl.contentSize(open: false, showingInput: false) == isl.closedSize && isl.contentSize(open: true, showingInput: false) == isl.openSize, "empty input keeps existing closed and open island sizes")
    check(isl.contentSize(open: false, showingInput: true) == CGSize(width: 340, height: 68), "typing adds one line below the physical notch")
    check(isl.contentSize(open: true, showingInput: true).height == isl.openSize.height + IslandLayout.wordHeight && isl.window(showingInput: true).maxY == scr.maxY, "typing and controls fit together while the top stays on the notch")
    let continuous = TypingDisplay(word: "이 문장을 이어 보여줍니다", meme: .typing, textMode: .continuous)
    check(continuous.textHeight == 76 && isl.window(showingInput: true, inputHeight: continuous.textHeight).height == 176, "continuous text and controls no longer reserve space for the corner meme")
    let fieldDisplay = TypingDisplay(word: "첫 줄\n둘째 줄", meme: .typing, textMode: .field)
    check(fieldDisplay.textHeight == 132 && isl.window(showingInput: true, inputHeight: fieldDisplay.textHeight).height == 232, "scrollable input keeps its full text area without a central meme")
    let squareSize = IslandLayout.memeImageSize(for: CGSize(width: 400, height: 400))
    let portraitSize = IslandLayout.memeImageSize(for: CGSize(width: 100, height: 400))
    let wideSize = IslandLayout.memeImageSize(for: CGSize(width: 800, height: 200))
    check(squareSize == CGSize(width: 190, height: 190), "square images shrink the panel width instead of adding sidebars")
    check(portraitSize == CGSize(width: 47.5, height: 190) && wideSize == CGSize(width: 292, height: 73), "portrait and wide images retain their full aspect ratio inside the maximum bounds")
    for size in [CGSize.zero, CGSize(width: -1, height: 5), CGSize(width: CGFloat.infinity, height: 5), CGSize(width: 5, height: CGFloat.nan)] {
        check(IslandLayout.memeImageSize(for: size) == CGSize(width: 292, height: 190), "invalid image metadata has a finite layout fallback")
    }
    let corner = IslandLayout.memeWindow(in: scr, imageSize: squareSize)
    check(corner == CGRect(x: 0, y: 911, width: 206, height: 206), "fitted meme is flush with the screen's physical top-left edge")
    let rightCorner = IslandLayout.memeWindow(in: scr, imageSize: squareSize, onRight: true)
    check(rightCorner.maxX == scr.maxX && rightCorner.maxY == scr.maxY && rightCorner.size == corner.size, "right placement stays flush and preserves the fitted image size")
    for size in [squareSize, portraitSize, wideSize] {
        for right in [false, true] {
            let frame = IslandLayout.memeWindow(in: scr, imageSize: size, onRight: right)
            check(frame.width - size.width == 16 && frame.height - size.height == 16 && frame.maxY == scr.maxY, "both corners reserve exactly 8pt for every aspect ratio")
        }
    }
    check(scr.contains(corner) && !corner.intersects(isl.window(showingInput: true, inputHeight: fieldDisplay.textHeight)), "bezel meme and centered input have separate non-overlapping frames")
    let leftScreen = CGRect(x: -1920, y: -400, width: 1900, height: 1040)
    check(IslandLayout.memeWindow(in: leftScreen, imageSize: wideSize).minX == -1920 && IslandLayout.memeWindow(in: leftScreen, imageSize: wideSize).maxY == 640, "fitted bezel connection follows another screen's physical origin")
    let leftMouse = CGPoint(x: 1, y: scr.maxY - 1), rightMouse = CGPoint(x: scr.maxX - 1, y: scr.maxY - 1)
    check(!MemePosition.left.onRight(current: true, mouse: leftMouse, screen: scr, imageSize: squareSize)
          && MemePosition.right.onRight(current: false, mouse: rightMouse, screen: scr, imageSize: squareSize), "fixed placement ignores pointer proximity")
    func autoSide(_ current: Bool, _ mouse: CGPoint?, _ screen: CGRect = scr, _ size: CGSize = squareSize) -> Bool {
        MemePosition.automatic.onRight(current: current, mouse: mouse, screen: screen, imageSize: size)
    }
    check(autoSide(false, leftMouse) && !autoSide(true, rightMouse), "automatic placement escapes either occupied corner")
    check(autoSide(true, leftMouse) && autoSide(true, CGPoint(x: scr.midX, y: scr.midY)) && autoSide(true, nil), "automatic placement stays on its new side without bouncing back")
    check(autoSide(false, CGPoint(x: corner.maxX + 16, y: corner.minY - 16)), "automatic placement starts avoiding before the pointer reaches the image")
    check(!autoSide(false, CGPoint(x: corner.maxX + 40, y: corner.midY)), "automatic proximity follows the fitted bounds rather than all of the screen")
    check(!autoSide(false, CGPoint(x: -1, y: scr.maxY - 1)), "a pointer on a neighbouring display cannot move this display's meme")
    check(autoSide(false, CGPoint(x: -1919, y: 639), leftScreen, wideSize), "automatic avoidance supports negative screen origins")
    check(!autoSide(false, CGPoint(x: 100, y: 200), CGRect(x: 0, y: 0, width: 300, height: 300), wideSize), "overlapping avoidance zones never oscillate on a small display")
    check(isl.window == CGRect(x: 864 - o.width / 2, y: 1117 - o.height, width: o.width, height: o.height), "window is top-centred and flush with the screen top")
    check(isl.hotspot.contains(CGPoint(x: 864, y: 1117)), "hotspot reaches the very top row of the screen")
    check(!isl.hotspot.contains(CGPoint(x: 864 + 100, y: 1110)), "hotspot is the notch only: menu bar icons beside it stay untouched")
    let flat = IslandLayout(screen: CGRect(x: 1728, y: 37, width: 1920, height: 1080), notch: nil)
    check(flat.window.midX == 1728 + 960 && flat.window.maxY == 1117, "no notch: centred on the top edge of that screen")
    let hot = isl.hotspot, win = isl.window
    check(islandMove(open: false, pinned: false, mouse: CGPoint(x: 864, y: 1116), hotspot: hot, island: win) == .open, "closed + pointer on the notch -> open")
    check(islandMove(open: false, pinned: false, mouse: CGPoint(x: 300, y: 1116), hotspot: hot, island: win) == .hold, "closed + pointer elsewhere -> nothing")
    check(islandMove(open: true, pinned: false, mouse: CGPoint(x: 864, y: 1117 - o.height / 2), hotspot: hot, island: win) == .hold, "open + pointer inside -> stay open")
    check(islandMove(open: true, pinned: false, mouse: CGPoint(x: 864, y: 700), hotspot: hot, island: win) == .close, "open + pointer left -> close")
    check(islandMove(open: true, pinned: true, mouse: CGPoint(x: 864, y: 700), hotspot: hot, island: win) == .hold, "pinned open stays open")

    let sample = "fans=2\nfan0 actual=3985.7 min=1499 max=5348 target=4000 mode=1\nfan1 actual=4006.5 min=1499 max=5776 target=4000 mode=1\n"
    let fans = parseFanStatus(sample)
    check(fans.count == 2 && fans[1].max == 5776, "parse fan status")
    check(!fanNeedsReapply(.rpm4000, fans), "4000 held -> no reapply")
    check(fanNeedsReapply(.rpm4000, [FanInfo(actual: 1500, min: 1499, max: 5348, target: 0, mode: 0)]), "system took control back -> reapply")
    check(!fanNeedsReapply(.auto, []), "auto -> never reapply")
    check(!fanNeedsReapply(.max, [FanInfo(actual: 5300, min: 1499, max: 5348, target: 5348, mode: 1)]), "max held -> no reapply")
    check(FanMode.allCases.map { $0.rawValue } == ["auto", "4000", "max"], "helper arguments")
    let icons = FanMode.allCases.map { $0.symbol } + TypingMode.allCases.map { $0.symbol } + [Icon.mode, Icon.quit, Icon.permission]
    let missing = icons.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
    check(missing.isEmpty && Set(icons).count == icons.count, "island icons exist on this macOS and differ from each other (missing: \(missing))")
    _ = NSApplication.shared
    let menuModel = Model(); menuModel.readOnly = true; menuModel.typingMode = .typingMeme; menuModel.typingTextMode = .word; menuModel.memePosition = .left
    let menuIsland = Island(model: menuModel)
    let picker = TypingModeButton.Coordinator(m: menuModel, s: menuIsland.state)
    let modeMenu = picker.menu()
    check(modeMenu.minimumWidth >= 240 && modeMenu.size.width >= 240, "mode menu has a readable native minimum width independent of its icon")
    check(modeMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == TypingMode.allCases.map(\.label) + TypingTextMode.allCases.map(\.label) + ["밈 위치"] + MemePosition.allCases.map(\.label), "native menu includes full effect, text and position labels")
    check(modeMenu.items.filter { $0.state == .on }.map(\.title) == ["타이핑 밈 모드", "단어 모드", "왼쪽 위"], "native menu checks each independent choice")
    picker.effect(modeMenu.items.first { $0.title == "밈 모드" }!)
    picker.text(modeMenu.items.first { $0.title == "입력창 모드" }!)
    check(menuModel.typingMode == .meme && menuModel.typingTextMode == .field, "native menu actions select both kinds of mode")
    menuIsland.state.layout = isl
    let positionedInput = TypingDisplay(word: "같은 글", meme: .typing, memeIndex: 3, memeFrame: 1)
    menuIsland.showInput(positionedInput, animated: false)
    let positionBeforeTest = UserDefaults.standard.string(forKey: "memePosition")
    picker.position(modeMenu.items.first { $0.title == "오른쪽 위" }!)
    check(menuModel.memePosition == .right && menuIsland.state.memeOnRight && menuIsland.memePanel.frame.maxX == scr.maxX, "menu selection immediately moves the live island using the published new value")
    check(menuIsland.state.input == positionedInput && menuIsland.state.memeReveal == 1, "moving position preserves the current word, GIF, hand frame and reveal")
    picker.position(modeMenu.items.first { $0.title == "자동 · 마우스 피하기" }!)
    menuIsland.placeMeme(.automatic, mouse: rightMouse)
    check(!menuIsland.state.memeOnRight && menuIsland.state.input == positionedInput, "automatic placement moves the same displayed meme back to the left")
    check(UserDefaults.standard.string(forKey: "memePosition") == positionBeforeTest, "read-only position checks never change the user's saved setting")
    check(!menuIsland.panel.canBecomeKey && !menuIsland.panel.canBecomeMain && !menuIsland.memePanel.canBecomeKey, "island panels cannot take typing focus")
    menuIsland.setOpen(true); menuIsland.state.choosingMode = true; menuIsland.setOpen(false)
    check(menuIsland.state.open, "hover and peek timers cannot close the island while its mode menu is open")
    menuIsland.state.choosingMode = false; menuIsland.setOpen(false)
    check(!menuIsland.state.open, "island can close normally after the mode menu finishes")
    menuIsland.memePanel.close(); menuIsland.panel.close()

    for level in MemeLevel.allCases {
      for variant in level.files.indices where level == .typing || MemeLevel.typingHands[level.files[variant]] != nil {
        let view = FittingMemeImageView()
        MemeView(level: level, variant: variant, frame: 0, animate: true).update(view)
        let first = view.image
        let frames = view.keyFrames
        if let indices = MemeLevel.typingHands[level.files[variant]],
           let bitmap = level.url(at: variant).flatMap({ try? Data(contentsOf: $0) }).flatMap({ NSBitmapImageRep(data: $0) }) {
            let count = bitmap.value(forProperty: .frameCount) as? Int ?? 1
            check(indices.count == 2 && indices[0] != indices[1] && indices.allSatisfy { (0..<count).contains($0) }, "curated hand poses reference valid, separate original frames")
        }
        MemeView(level: level, variant: variant, frame: 1, animate: true).update(view)
        check(frames.count == 2 && frames.first?.tiffRepresentation != frames.last?.tiffRepresentation && !view.animates,
              "typing meme has two distinct static frames: \(level.files[variant])")
        check(view.image === frames.last && view.keyFrames.first === first,
              "keystrokes reuse the decoded pair instead of loading the GIF again")
        MemeView(level: level, variant: variant, frame: 0, animate: true).update(view)
        check(view.image === first, "the next keystroke returns to the exact first frame")
        MemeView(level: level, variant: variant, animate: true).update(view)
        check(view.animates && view.keyFrames.isEmpty, "ordinary meme playback still uses the original animated GIF")
        MemeView.dismantleNSView(view, coordinator: ())
        check(view.image == nil && view.keyFrames.isEmpty && !view.animates, "removing the meme releases both cached frames")
    }
    }

    let b = battery()
    print("live: sleepDisabled=\(sleepDisabled()) battery=\(b.percent)% onBattery=\(b.onBattery) lidClosed=\(lidClosed()) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) screenLocked=\(screenLocked())")
    print("live: displays=\(onlineDisplays().count) external=\(hasExternalDisplay()) builtinAsleep=\(String(describing: builtinAsleep()))")
    print("live: batteryPowerMode=\(String(describing: batteryPowerMode())) brightness=\(String(describing: builtinBrightness()))")
    print("live: sudoSetupDone=\(setupDone()) accessibilityTrusted=\(AXIsProcessTrusted()) loginItem=\(loginEnabled()) fanHelperInstalled=\(FileManager.default.isExecutableFile(atPath: fanHelper))")
    print("live: screens=\(NSScreen.screens.count) notch=\(String(describing: NSScreen.screens.compactMap { $0.notchSize }.first))")
    exit(failed == 0 ? 0 : 1)
}

/// Off-screen fixtures only; never starts the model or listens to the user's keys.
func renderIslandTest(_ directory: String) -> Never {
    let destination = URL(fileURLWithPath: directory, isDirectory: true)
    do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
    catch { print("FAIL  cannot create render directory"); exit(1) }
    let model = Model(); model.trusted = true; model.readOnly = true; model.memePosition = .left
    func snapshot(_ island: Island, _ name: String, meme: Bool = false) {
        guard let view = (meme ? island.memePanel : island.panel).contentView else { print("FAIL  render view"); exit(1) }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("FAIL  render bitmap"); exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { print("FAIL  render PNG"); exit(1) }
        do { try png.write(to: destination.appendingPathComponent(name + ".png")) }
        catch { print("FAIL  save render"); exit(1) }
    }
    var fixtures = [("idle", false, TypingDisplay()), ("word", false, TypingDisplay(word: "기억")),
                    ("word-controls", true, TypingDisplay(word: "기억")),
                    ("long-word", false, TypingDisplay(word: String(repeating: "아주긴단어", count: 10))),
                    ("space", false, TypingDisplay(key: "␣")),
                    ("word-backspace", true, TypingDisplay(word: "기어", key: "⌫")),
                    ("space-controls", true, TypingDisplay(key: "␣")),
                    ("emoji-coffee", true, TypingDisplay(word: "커피", emoji: "☕️")),
                    ("emoji-cat", false, TypingDisplay(word: "고양이", emoji: "🐱")),
                    ("meme-calm", false, TypingDisplay(word: "기억", meme: .calm)),
                    ("meme-typing", true, TypingDisplay(word: "타이핑", meme: .typing)),
                    ("typing-frame-0", false, TypingDisplay(word: "첫 키", meme: .typing, memeIndex: 3, memeFrame: 0)),
                    ("typing-frame-1", false, TypingDisplay(word: "다음 키", meme: .typing, memeIndex: 3, memeFrame: 1)),
                    ("typing-peter-0", false, TypingDisplay(word: "왼손", meme: .typing, memeIndex: 24, memeFrame: 0)),
                    ("typing-peter-1", false, TypingDisplay(word: "오른손", meme: .typing, memeIndex: 24, memeFrame: 1)),
                    ("typing-jim-0", false, TypingDisplay(word: "첫 키", meme: .fast, memeIndex: 2, memeFrame: 0)),
                    ("typing-jim-1", false, TypingDisplay(word: "다음 키", meme: .fast, memeIndex: 2, memeFrame: 1)),
                    ("right-square", false, TypingDisplay(word: "오른쪽 위", meme: .typing, memeIndex: 3, memeFrame: 0)),
                    ("right-wide", false, TypingDisplay(word: "넓은 밈", meme: .fast, memeIndex: 1)),
                    ("right-portrait", false, TypingDisplay(word: "세로 밈", meme: .chaos, memeIndex: 2)),
                    ("meme-fast", false, TypingDisplay(word: "폭풍타이핑", key: "⌫", meme: .fast)),
                    ("meme-chaos", true, TypingDisplay(word: "키보드불타는중", meme: .chaos)),
                    ("meme-long", true, TypingDisplay(word: String(repeating: "긴단어", count: 40), key: "⌫", meme: .fast)),
                    ("meme-space", false, TypingDisplay(key: "␣", meme: .chaos)),
                    ("meme-wide", true, TypingDisplay(word: "폭풍 타이핑", meme: .fast, memeIndex: 1)),
                    ("meme-portrait", true, TypingDisplay(word: "집중", meme: .chaos, memeIndex: 2)),
                    ("continuous", false, TypingDisplay(word: "지금 쓰는 문장을 Space에서도 계속 이어 보여줍니다", textMode: .continuous)),
                    ("continuous-long", true, TypingDisplay(word: String(repeating: "이전 문장도 이어 쓰다가 ", count: 14) + "지금 마지막에 쓰는 말", key: "␣", textMode: .continuous)),
                    ("continuous-emoji", true, TypingDisplay(word: "커피 한 잔 마시면서 일하는 중", emoji: "☕️", textMode: .continuous)),
                    ("semantic-food", true, TypingDisplay(word: "배고파", meme: .calm, memeMatch: MemeMatch(file: "meaning-food-00", label: "배고픈 루피", topic: "food"))),
                    ("semantic-coffee", false, TypingDisplay(word: "커피", meme: .calm, memeMatch: MemeMatch(file: "meaning-coffee-01", label: "커피 마시는 백설공주", topic: "coffee"))),
                    ("continuous-meme", true, TypingDisplay(word: "드디어 오늘 할 일을 전부 끝냈다 이제 퇴근이다", key: "␣", meme: .typing, memeMatch: MemeMatch(file: "meaning-celebrate-00", label: "신나는 춤", topic: "celebrate"), textMode: .continuous)),
                    ("field", false, TypingDisplay(word: "  이미 써 둔 첫 줄\n중간을 수정한 둘째 줄 🙂\n붙여넣기도 그대로", textMode: .field)),
                    ("field-long", true, TypingDisplay(word: (1...30).map { "\($0)번째 줄: 이 입력창의 내용을 그대로 보여줍니다." }.joined(separator: "\n"), textMode: .field)),
                    ("field-meme", true, TypingDisplay(word: "커피 한 잔 하자.\n이미 써 둔 문장과 새 문장 모두 보여요.", meme: .calm, memeMatch: MemeMatch(file: "meaning-coffee-01", label: "커피 마시는 백설공주", topic: "coffee"), textMode: .field))]
    for (topic, word) in [("surprise", "깜짝 놀랐어"), ("cheer", "힘내 할 수 있어"), ("shopping", "장바구니가 또 가득해졌다")] {
        if let entry = SemanticMemeMatcher.loadIndex()?.entries.first(where: { $0.topic == topic && $0.file.hasPrefix("reaction-") }) {
            fixtures.append(("expanded-" + topic, true, TypingDisplay(word: word, meme: .calm, memeMatch: MemeMatch(file: entry.file, label: entry.label, topic: entry.topic), textMode: .continuous)))
        }
    }
    for (name, open, display) in fixtures {
        model.setMemePosition(name.hasPrefix("right-") ? .right : .left)
        let island = Island(model: model)
        // Static fixtures have no visible-window animation clock. Test fades separately below.
        let host = NSHostingView(rootView: IslandView(m: model, s: island.state).transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        })
        host.sizingOptions = []
        island.panel.contentView = host
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.typingMode = display.meme != nil ? .meme : display.emoji != nil ? .emoji : .plain
            island.state.layout = IslandLayout(screen: CGRect(x: 0, y: 0, width: 1728, height: 1117), notch: CGSize(width: 185, height: 32))
            island.state.open = open
            island.showInput(display, animated: false)
        }
        island.panel.setFrame(island.state.layout.window(showingInput: !display.isEmpty, inputHeight: display.textHeight), display: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        snapshot(island, name)
        if display.meme != nil { snapshot(island, name + "-corner", meme: true) }
        guard island.memePanel.ignoresMouseEvents, !island.memePanel.isVisible,
              island.memePanel.collectionBehavior.contains([.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]) else { print("FAIL  corner intercepts clicks, moves with desktops or escapes off-screen testing"); exit(1) }
        island.memePanel.close()
        island.panel.close()
    }
    // These transitions stay off screen and never listen to or inject real key events.
    model.setMemePosition(.left)
    let island = Island(model: model)
    island.state.layout = IslandLayout(screen: CGRect(x: 0, y: 0, width: 1728, height: 1117), notch: CGSize(width: 185, height: 32))
    island.showInput(TypingDisplay(word: "기억"), animated: false)
    island.showInput(TypingDisplay())
    guard !island.state.showingInput, island.state.input.word == "기억", island.panel.frame.height == 136 else { print("FAIL  outgoing line clipped before fade"); exit(1) }
    island.showInput(TypingDisplay(), animated: false)
    guard island.state.input.isEmpty, island.panel.frame.height == 100 else { print("FAIL  privacy clear retained outgoing text"); exit(1) }
    island.showInput(TypingDisplay(word: "커피", meme: .chaos), animated: false)
    guard island.panel.frame.height == 136 else { print("FAIL  meme still expands the centered island"); exit(1) }
    island.showInput(TypingDisplay(word: "문장을 계속 이어 쓰는 중", meme: .typing, textMode: .continuous), animated: false)
    guard island.panel.frame.height == 176 else { print("FAIL  continuous text still reserves centered meme space"); exit(1) }
    island.showInput(TypingDisplay(), animated: false)
    guard island.state.input.isEmpty, island.state.memeReveal == 0, island.panel.frame.height == 100 else { print("FAIL  privacy clear retained reaction or bezel reveal"); exit(1) }
    island.showInput(TypingDisplay(word: "커피", meme: .typing), animated: false)
    guard island.state.memeReveal == 1 else { print("FAIL  meme did not expand"); exit(1) }
    let handDisplay = TypingDisplay(word: "키", meme: .typing, memeIndex: 3, memeFrame: 0)
    island.showInput(handDisplay, animated: false)
    let handFrame = island.memePanel.frame, handSize = island.state.memeSize
    var nextHand = handDisplay; nextHand.memeFrame = 1
    island.showInput(nextHand, animated: false)
    guard island.memePanel.frame == handFrame, island.state.memeSize == handSize,
          abs(handFrame.width - handSize.width - 16) < 1,
          abs(handFrame.height - handSize.height - 16) < 1 else { print("FAIL  hand alternation changed the fitted panel or its padding"); exit(1) }
    model.setMemePosition(.right)
    guard island.state.memeOnRight, island.memePanel.frame.maxX == 1728, island.state.input == nextHand,
          island.state.memeSize == handSize else { print("FAIL  right selection changed the GIF or did not update immediately"); exit(1) }
    model.setMemePosition(.automatic)
    island.placeMeme(.automatic, mouse: CGPoint(x: 1727, y: 1116))
    guard !island.state.memeOnRight, island.memePanel.frame.minX == 0 else { print("FAIL  auto did not avoid the right pointer"); exit(1) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05)); snapshot(island, "auto-left", meme: true)
    island.placeMeme(.automatic, mouse: CGPoint(x: 1, y: 1116))
    guard island.state.memeOnRight, island.memePanel.frame.maxX == 1728,
          island.state.input == nextHand, island.state.memeSize == handSize else { print("FAIL  auto reset or resized the typing meme"); exit(1) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05)); snapshot(island, "auto-right", meme: true)
    island.placeMeme(.automatic, mouse: CGPoint(x: 864, y: 500))
    guard island.state.memeOnRight else { print("FAIL  auto bounced back after the pointer left"); exit(1) }
    model.setMemePosition(.left)
    var noAnimation = Transaction(); noAnimation.disablesAnimations = true
    for (name, reveal) in [("bezel-closed", CGFloat(0)), ("bezel-mid", CGFloat(0.5)), ("bezel-open", CGFloat(1))] {
        withTransaction(noAnimation) { island.state.memeReveal = reveal }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        snapshot(island, name, meme: true)
    }
    island.showInput(TypingDisplay())
    guard !island.state.showingInput, island.state.memeReveal == 0, island.state.input.meme != nil else { print("FAIL  corner image lost before retracting"); exit(1) }
    RunLoop.main.run(until: Date().addingTimeInterval(Island.inputAnimationDuration + 0.12))
    guard island.state.input.meme == nil, island.state.memeReveal == 0, !island.memePanel.isVisible else { print("FAIL  corner reaction retained after retracting"); exit(1) }
    island.showInput(TypingDisplay(key: "␣"))
    RunLoop.main.run(until: Date().addingTimeInterval(Island.inputAnimationDuration + 0.12))
    island.showInput(TypingDisplay())
    island.showInput(TypingDisplay(word: "새"))
    RunLoop.main.run(until: Date().addingTimeInterval(Island.inputAnimationDuration + 0.12))
    guard island.state.showingInput, island.state.input.word == "새", island.panel.frame.maxY == 1117 else { print("FAIL  interrupted fade lost the new input"); exit(1) }
    island.showInput(TypingDisplay())
    RunLoop.main.run(until: Date().addingTimeInterval(Island.inputAnimationDuration + 0.12))
    guard island.state.input.isEmpty, island.panel.frame.height == 100 else { print("FAIL  fade did not finish"); exit(1) }
    island.showInput(TypingDisplay(key: "␣"))
    RunLoop.main.run(until: Date().addingTimeInterval(0.08)); snapshot(island, "appear-mid")
    RunLoop.main.run(until: Date().addingTimeInterval(0.25)); snapshot(island, "appear-end")
    island.showInput(TypingDisplay())
    RunLoop.main.run(until: Date().addingTimeInterval(0.08)); snapshot(island, "disappear-mid")
    RunLoop.main.run(until: Date().addingTimeInterval(0.25)); snapshot(island, "disappear-end")
    island.panel.close()
    print("ok    \(fixtures.count) off-screen fixtures, fade completion/interruption and immediate privacy clearing")
    exit(0)
}

