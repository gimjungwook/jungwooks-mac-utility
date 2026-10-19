import AppKit

struct TypingDisplay: Equatable {
    var word = ""
    var key = ""
    var meme: MemeLevel?
    var memeIndex = 0
    var memeMatch: MemeMatch?
    var memeFrame: Int?
    var emoji: String?
    var textMode = TypingTextMode.word
    var isEmpty: Bool { word.isEmpty && key.isEmpty && meme == nil && emoji == nil }
    var textHeight: CGFloat { textMode == .field ? 132 : textMode == .continuous ? 76 : IslandLayout.wordHeight }
}

enum KeyLabel {
    private static let special: [UInt16: String] = [
        36: "↵", 48: "⇥", 49: "␣", 51: "⌫", 53: "⎋", 71: "⌧", 76: "⌤",
        115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> String {
        [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .compactMap { (flag: NSEvent.ModifierFlags, label: String) in flags.contains(flag) ? label : nil }.joined()
    }

    static func key(code: UInt16, characters: String?, flags: NSEvent.ModifierFlags) -> String? {
        let prefix = modifiers(flags)
        if let label = special[code] { return prefix + label }
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              let character = characters?.first,
              character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) else { return nil }
        return prefix + String(character).uppercased()
    }

    static func modifier(code: UInt16, flags: NSEvent.ModifierFlags) -> String? {
        if code == 57 { return "⇪" }
        let flag: NSEvent.ModifierFlags
        switch code {
        case 54, 55: flag = .command
        case 56, 60: flag = .shift
        case 58, 61: flag = .option
        case 59, 62: flag = .control
        case 63: return flags.contains(.function) ? "fn" : nil
        default: return nil
        }
        return flags.contains(flag) ? modifiers(flags) : nil
    }
}

/// A bounded word or current line in memory; never a document or persisted history.
struct WordComposer {
    static let limit = 256
    static let initials = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ").map(String.init)
    static let vowels = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ").map(String.init)
    static let finals = [""] + Array("ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ").map(String.init)
    static let vowelPairs = [("ㅗ", "ㅏ", "ㅘ"), ("ㅗ", "ㅐ", "ㅙ"), ("ㅗ", "ㅣ", "ㅚ"),
                             ("ㅜ", "ㅓ", "ㅝ"), ("ㅜ", "ㅔ", "ㅞ"), ("ㅜ", "ㅣ", "ㅟ"), ("ㅡ", "ㅣ", "ㅢ")]
    static let finalPairs = [("ㄱ", "ㅅ", "ㄳ"), ("ㄴ", "ㅈ", "ㄵ"), ("ㄴ", "ㅎ", "ㄶ"),
                             ("ㄹ", "ㄱ", "ㄺ"), ("ㄹ", "ㅁ", "ㄻ"), ("ㄹ", "ㅂ", "ㄼ"),
                             ("ㄹ", "ㅅ", "ㄽ"), ("ㄹ", "ㅌ", "ㄾ"), ("ㄹ", "ㅍ", "ㄿ"),
                             ("ㄹ", "ㅎ", "ㅀ"), ("ㅂ", "ㅅ", "ㅄ")]
    private var completed = ""
    private var initial = "", vowel = "", final = ""

    private var syllable: String {
        if initial.isEmpty { return vowel }
        if vowel.isEmpty { return initial }
        guard let l = Self.initials.firstIndex(of: initial), let v = Self.vowels.firstIndex(of: vowel),
              let t = Self.finals.firstIndex(of: final), let scalar = UnicodeScalar(0xAC00 + (l * 21 + v) * 28 + t) else { return "" }
        return String(scalar)
    }

    var text: String { completed + syllable }

    mutating func clear() { completed = ""; initial = ""; vowel = ""; final = "" }

    mutating func commit() {
        completed += syllable
        initial = ""; vowel = ""; final = ""
    }

    mutating func feed(_ value: String, preserveSpaces: Bool = false) {
        for character in value {
            let jamo = String(character)
            if character.isWhitespace {
                if preserveSpaces { commit(); completed += " " } else { clear() }
            } else if Self.initials.contains(jamo) {
                if !initial.isEmpty, !vowel.isEmpty, Self.finals.contains(jamo), final.isEmpty {
                    final = jamo
                } else if !initial.isEmpty, !vowel.isEmpty,
                          let pair = Self.finalPairs.first(where: { $0.0 == final && $0.1 == jamo }) {
                    final = pair.2
                } else { commit(); initial = jamo }
            } else if Self.vowels.contains(jamo) {
                if vowel.isEmpty { vowel = jamo }
                else if !final.isEmpty {
                    let pair = Self.finalPairs.first(where: { $0.2 == final })
                    let nextInitial = pair?.1 ?? final
                    final = pair?.0 ?? ""
                    commit()
                    initial = nextInitial; vowel = jamo
                } else if let pair = Self.vowelPairs.first(where: { $0.0 == vowel && $0.1 == jamo }) {
                    vowel = pair.2
                } else { commit(); vowel = jamo }
            } else { commit(); completed += jamo }
            let room = Self.limit - (syllable.isEmpty ? 0 : 1)
            if completed.count > room { completed = String(completed.suffix(room)) }
        }
    }

    mutating func backspace() {
        if !final.isEmpty { final = Self.finalPairs.first(where: { $0.2 == final })?.0 ?? "" }
        else if !vowel.isEmpty { vowel = Self.vowelPairs.first(where: { $0.2 == vowel })?.0 ?? "" }
        else if !initial.isEmpty { initial = "" }
        else if !completed.isEmpty { completed.removeLast() }
    }
}

struct WordInput {
    private var composer = WordComposer()
    var text: String { composer.text }
    mutating func clear() { composer.clear() }
    mutating func commit() { composer.commit() }

    private static let letters: [UInt16: String] = [
        0: "ㅁ", 1: "ㄴ", 2: "ㅇ", 3: "ㄹ", 4: "ㅗ", 5: "ㅎ", 6: "ㅋ", 7: "ㅌ", 8: "ㅊ", 9: "ㅍ",
        11: "ㅠ", 12: "ㅂ", 13: "ㅈ", 14: "ㄷ", 15: "ㄱ", 16: "ㅛ", 17: "ㅅ", 31: "ㅐ", 32: "ㅕ",
        34: "ㅑ", 35: "ㅔ", 37: "ㅣ", 38: "ㅓ", 40: "ㅏ", 45: "ㅜ", 46: "ㅡ",
    ]
    private static let shifted: [UInt16: String] = [12: "ㅃ", 13: "ㅉ", 14: "ㄸ", 15: "ㄲ", 17: "ㅆ", 31: "ㅒ", 35: "ㅖ"]
    private static let boundaries: Set<UInt16> = [36, 48, 49, 53, 71, 76, 115, 116, 117, 119, 121, 123, 124, 125, 126]

    mutating func receive(code: UInt16, characters: String?, flags: NSEvent.ModifierFlags, twoSetKorean: Bool, textMode: TypingTextMode = .word) {
        if !flags.intersection([.command, .control, .option]).isEmpty { clear(); return }
        if code == 49 {
            if textMode == .continuous { composer.feed(" ", preserveSpaces: true) } else { clear() }
            return
        }
        if Self.boundaries.contains(code) { clear(); return }
        if code == 51 { composer.backspace(); return }
        if twoSetKorean, let jamo = Self.letters[code] {
            composer.feed(flags.contains(.shift) ? Self.shifted[code] ?? jamo : jamo)
            return
        }
        guard let characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) else { clear(); return }
        composer.feed(characters, preserveSpaces: textMode == .continuous)
    }
}
