import AppKit
import ImageIO
import SwiftUI

enum TypingMode: String, CaseIterable {
    case plain, meme, typingMeme, emoji
    var label: String {
        switch self { case .plain: return "기본"; case .meme: return "밈 모드"; case .typingMeme: return "타이핑 밈 모드"; case .emoji: return "이모지 모드" }
    }
    var symbol: String {
        switch self { case .plain: return "keyboard"; case .meme: return "photo.on.rectangle.angled"; case .typingMeme: return "keyboard.badge.ellipsis"; case .emoji: return "face.smiling" }
    }
}

enum TypingTextMode: String, CaseIterable {
    case word, continuous, field
    var label: String {
        switch self { case .word: return "단어 모드"; case .continuous: return "연속 모드"; case .field: return "입력창 모드" }
    }
    var symbol: String {
        switch self { case .word: return "textformat.abc"; case .continuous: return "text.alignleft"; case .field: return "rectangle.and.text.magnifyingglass" }
    }
}

enum MemeLevel: String, CaseIterable {
    case calm, typing, fast, chaos
    // These poses were checked visually; arbitrary timestamps often move both hands together.
    static let typingHands: [String: [Int]] = [
        "typing-cat-typing-00": [0, 6], "typing-cat-typing-01": [0, 1],
        "typing-dog-typing-07": [3, 4], "typing-dog-typing-09": [1, 4],
        "typing-typing-04": [2, 12], "typing-typing-12": [1, 4],
        "fast-kermit": [1, 2], "fast-jim": [2, 5],
        "fast-fast-typing-05": [3, 9], "fast-fast-typing-07": [0, 5],
        "fast-fast-typing-09": [0, 2], "fast-fast-typing-10": [0, 2],
        "fast-fast-typing-16": [0, 2], "fast-fast-typing-27": [0, 1],
        "fast-hacker-typing-08": [0, 5], "fast-hacker-typing-33": [0, 1],
        "fast-working-hard-05": [0, 3], "chaos-angry": [0, 14],
        "chaos-angry-typing-01": [0, 2], "chaos-angry-typing-04": [30, 45],
        "chaos-angry-typing-26": [0, 12], "chaos-panic-typing-01": [0, 8],
        "chaos-panic-typing-07": [0, 3], "chaos-panic-typing-10": [0, 3],
    ]
    var label: String {
        switch self { case .calm: return "생각 중"; case .typing: return "타이핑 중"; case .fast: return "폭풍 타이핑"; case .chaos: return "키보드 불타는 중" }
    }
    var files: [String] {
        switch self {
        case .calm: return [
            "calm", "calm-dog", "calm-bean",
            "calm-thinking-cat-05", "calm-thinking-cat-07", "calm-thinking-cat-09",
            "calm-confused-dog-00", "calm-confused-dog-03", "calm-confused-dog-05",
            "calm-confused-dog-10", "calm-capybara-chill-00", "calm-capybara-chill-05",
            "calm-capybara-chill-09", "calm-sloth-00", "calm-sloth-04",
            "calm-sloth-05", "calm-spongebob-thinking-01", "calm-spongebob-thinking-02",
            "calm-spongebob-thinking-05", "calm-homer-thinking-00", "calm-homer-thinking-07",
            "calm-squidward-coffee-00", "calm-squidward-coffee-07", "calm-confused-math-00",
            "calm-confused-math-03", "calm-thinking-monkey-00", "calm-thinking-monkey-03",
            "calm-thinking-monkey-07", "calm-waiting-meme-00", "calm-waiting-meme-05",
            "calm-waiting-meme-07", "calm-hmm-meme-07"
        ]
        case .typing: return [
            "typing", "typing-dog", "typing-monkey",
            "typing-cat-typing-00", "typing-cat-typing-01", "typing-cat-typing-07",
            "typing-cat-typing-10", "typing-dog-typing-03", "typing-dog-typing-06",
            "typing-dog-typing-07", "typing-dog-typing-09", "typing-dog-typing-11",
            "typing-dog-typing-13", "typing-bongo-cat-00", "typing-bongo-cat-03",
            "typing-bongo-cat-05", "typing-monkey-typing-01", "typing-monkey-typing-13",
            "typing-working-cute-00", "typing-working-cute-01", "typing-working-cute-02",
            "typing-working-cute-04", "typing-working-cute-07", "typing-working-cute-11",
            "typing-typing-04", "typing-typing-07", "typing-typing-12",
            "typing-duck-typing-00", "typing-duck-typing-06", "typing-hamster-typing-03",
            "typing-tom-jerry-typing-08", "typing-homer-typing-00"
        ]
        case .fast: return [
            "fast", "fast-kermit", "fast-jim",
            "fast-fast-typing-05", "fast-fast-typing-07", "fast-fast-typing-09",
            "fast-fast-typing-10", "fast-fast-typing-14", "fast-fast-typing-16",
            "fast-fast-typing-17", "fast-fast-typing-23", "fast-fast-typing-27",
            "fast-fast-typing-29", "fast-fast-typing-30", "fast-fast-typing-31",
            "fast-fast-typing-37", "fast-hacker-typing-02", "fast-hacker-typing-04",
            "fast-hacker-typing-05", "fast-hacker-typing-08", "fast-hacker-typing-14",
            "fast-hacker-typing-15", "fast-hacker-typing-17", "fast-hacker-typing-28",
            "fast-hacker-typing-29", "fast-hacker-typing-30", "fast-hacker-typing-32",
            "fast-hacker-typing-33", "fast-hacker-typing-38", "fast-hacker-typing-39",
            "fast-working-hard-05", "fast-working-hard-25"
        ]
        case .chaos: return [
            "chaos", "chaos-jim", "chaos-angry",
            "chaos-angry-typing-01", "chaos-angry-typing-04", "chaos-angry-typing-09",
            "chaos-angry-typing-12", "chaos-angry-typing-15", "chaos-angry-typing-18",
            "chaos-angry-typing-25", "chaos-angry-typing-26", "chaos-angry-typing-30",
            "chaos-keyboard-rage-00", "chaos-keyboard-rage-02", "chaos-keyboard-rage-04",
            "chaos-keyboard-rage-06", "chaos-keyboard-rage-15", "chaos-panic-typing-01",
            "chaos-panic-typing-06", "chaos-panic-typing-07", "chaos-panic-typing-10",
            "chaos-panic-typing-11", "chaos-panic-typing-24", "chaos-cat-fire-02",
            "chaos-cat-fire-09", "chaos-cat-fire-16", "chaos-chaos-meme-00",
            "chaos-chaos-meme-01", "chaos-chaos-meme-02", "chaos-chaos-meme-04",
            "chaos-chaos-meme-07", "chaos-this-is-fine-00"
        ]
        }
    }
    func url(at index: Int = 0) -> URL? {
        let file = files[index % files.count]
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.url(forResource: file, withExtension: "gif", subdirectory: "Memes")
        }
        return Bundle.module.url(forResource: file, withExtension: "gif", subdirectory: "Memes")
    }
}

/// Shuffled galleries contain file indices only, never typed text or timings.
struct MemeRotation {
    private var level: MemeLevel?
    private var remaining: [String: [Int]] = [:]
    private var previous: [String: Int] = [:]
    private var selected = 0

    mutating func index(for level: MemeLevel?) -> Int {
        guard let level else { self.level = nil; selected = 0; return 0 }
        if self.level != level {
            selected = take(key: level.rawValue, count: level.files.count)
            self.level = level
        }
        return selected
    }

    mutating func typingScene() -> (level: MemeLevel, index: Int) {
        let variants = MemeLevel.allCases.flatMap { level in
            level.files.indices.filter { MemeLevel.typingHands[level.files[$0]] != nil }.map { (level: level, index: $0) }
        }
        return variants[take(key: "hands", count: variants.count)]
    }

    private mutating func take(key: String, count: Int) -> Int {
        var bag = remaining[key] ?? []
        if bag.isEmpty {
            bag = Array(0..<count).shuffled()
            if bag.count > 1, bag.last == previous[key] { bag.swapAt(0, bag.count - 1) }
        }
        let chosen = bag.removeLast()
        remaining[key] = bag
        previous[key] = chosen
        return chosen
    }

    // Gallery order contains no input; keep it across privacy clears to avoid repeating the first few GIFs.
    mutating func clear() { level = nil; selected = 0 }
}

/// Two seconds of timings only. No characters, sentences, rate history or persistence.
struct TypingPace {
    private var strokes: [TimeInterval] = []
    private static let window: TimeInterval = 2
    static let idle: TimeInterval = 5

    mutating func clear() { strokes.removeAll() }

    private mutating func prune(at now: TimeInterval) {
        if let last = strokes.last, last > now { clear() }
        strokes.removeAll { now - $0 > Self.window }
    }

    mutating func record(at now: TimeInterval) {
        prune(at: now)
        strokes.append(now)
        if strokes.count > 80 { strokes.removeFirst(strokes.count - 80) }
    }

    mutating func level(at now: TimeInterval) -> MemeLevel? {
        if let last = strokes.last, last > now { clear() }
        guard let last = strokes.last, now - last < Self.idle else { return nil }
        // Hold the last typing reaction while the user watches it; prune on the next physical key.
        let perSecond = Double(strokes.count) / Self.window
        if perSecond >= 8 { return .chaos }
        if perSecond >= 5 { return .fast }
        if perSecond >= 2 { return .typing }
        return .calm
    }
}

enum WordEmoji {
    private static let groups: [(String, [String])] = [
        ("☕️", ["커피", "아메리카노", "아아", "라떼", "카페", "coffee", "latte", "espresso", "cafe"]),
        ("🐱", ["고양이", "냥이", "냥", "cat", "cats", "kitten"]),
        ("🐶", ["강아지", "댕댕이", "멍멍", "dog", "dogs", "puppy"]),
        ("🦦", ["수달", "otter"]), ("🐻", ["곰", "bear"]),
        ("🍕", ["피자", "pizza"]), ("🍗", ["치킨", "chicken"]), ("🍔", ["햄버거", "버거", "burger"]),
        ("🍜", ["라면", "라멘", "국수", "ramen", "noodles"]), ("🍣", ["초밥", "스시", "sushi"]),
        ("🍰", ["케이크", "케익", "cake"]), ("🍞", ["빵", "토스트", "bread", "toast"]),
        ("🍚", ["밥", "점심", "저녁", "아침", "식사", "배고파", "배고프다", "lunch", "dinner", "breakfast", "hungry"]),
        ("🍎", ["사과", "apple"]), ("🍌", ["바나나", "banana"]), ("🍓", ["딸기", "strawberry"]),
        ("🍺", ["맥주", "beer"]), ("🍷", ["와인", "wine"]), ("💧", ["물", "목말라", "water"]),
        ("❤️", ["사랑", "사랑해", "사랑해요", "하트", "love", "heart"]),
        ("😂", ["웃겨", "웃기다", "재밌다", "재밌어", "lol", "lmao", "haha"]),
        ("🥲", ["슬퍼", "슬프다", "눈물", "울어", "sad", "cry"]),
        ("😴", ["졸려", "졸리다", "피곤", "피곤해", "피곤하다", "잠", "잘자", "sleep", "sleepy", "tired"]),
        ("🔥", ["불", "대박", "쩐다", "미쳤다", "fire", "lit"]),
        ("🎉", ["축하", "축하해", "축하해요", "성공", "완료", "congrats", "success", "done"]),
        ("🙏", ["감사", "감사합니다", "고마워", "고마워요", "기도", "thanks", "thankyou", "pray"]),
        ("😡", ["화나", "화난다", "짜증", "짜증나", "angry", "rage"]),
        ("☀️", ["해", "햇빛", "맑음", "sun", "sunny"]), ("🌧️", ["비", "장마", "rain", "rainy"]),
        ("❄️", ["눈", "추워", "춥다", "겨울", "snow", "cold", "winter"]),
        ("🌊", ["바다", "해변", "여름", "sea", "beach", "summer"]),
        ("🌙", ["달", "밤", "moon", "night"]), ("🌸", ["꽃", "벚꽃", "봄", "flower", "spring"]),
        ("💻", ["코딩", "개발", "맥북", "컴퓨터", "노트북", "code", "coding", "macbook", "computer", "laptop"]),
        ("🐛", ["버그", "오류", "에러", "bug", "error"]), ("🚀", ["배포", "출시", "로켓", "deploy", "launch", "rocket"]),
        ("📚", ["공부", "책", "독서", "학교", "study", "book", "school"]),
        ("📝", ["회의", "메모", "문서", "글쓰기", "meeting", "note", "document", "writing"]),
        ("🎵", ["음악", "노래", "뮤직", "music", "song"]), ("🎮", ["게임", "game", "gaming"]),
        ("📷", ["사진", "카메라", "photo", "camera"]), ("🖼️", ["이미지", "그림", "image", "picture"]),
        ("✈️", ["여행", "비행기", "휴가", "travel", "flight", "vacation"]),
        ("🏃", ["운동", "달리기", "러닝", "run", "running", "workout"]), ("🚗", ["자동차", "운전", "car", "drive"]),
        ("🏠", ["집", "퇴근", "home"]), ("💰", ["돈", "월급", "money", "payday"]),
    ]
    private static let endings: Set<String> = ["은", "는", "이", "가", "을", "를", "의", "에", "에서", "와", "과", "도", "만", "로", "으로", "랑", "이랑", "하고", "까지", "부터", "처럼", "보다", "입니다", "이에요", "예요", "야", "다"]

    static func match(_ word: String) -> String? {
        let value = word.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        guard !value.isEmpty else { return nil }
        if value.count >= 2, value.allSatisfy({ "ㅋㅎ".contains($0) }) { return "😂" }
        if value.count >= 2, value.allSatisfy({ "ㅠㅜ".contains($0) }) { return "🥲" }
        for (emoji, words) in groups {
            if words.contains(value) { return emoji }
            for key in words where key.unicodeScalars.allSatisfy({ (0xAC00...0xD7A3).contains($0.value) }) && value.hasPrefix(key) {
                if endings.contains(String(value.dropFirst(key.count))) { return emoji }
            }
        }
        return nil
    }
}

final class FittingMemeImageView: NSImageView {
    var keyFrames: [NSImage] = []
    // The source GIF's intrinsic size must not overflow SwiftUI's proposed image box.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}

struct MemeView: NSViewRepresentable {
    let level: MemeLevel
    var variant = 0
    var match: MemeMatch?
    var frame: Int?
    let animate: Bool

    static func imageSize(at url: URL?) -> CGSize {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return IslandLayout.memeImageSize(for: .zero)
        }
        return IslandLayout.memeImageSize(for: CGSize(width: width.doubleValue, height: height.doubleValue))
    }

    func makeNSView(context: Context) -> FittingMemeImageView {
        let view = FittingMemeImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.setAccessibilityElement(true)
        return view
    }

    func updateNSView(_ view: FittingMemeImageView, context: Context) {
        update(view)
    }

    func update(_ view: FittingMemeImageView) {
        let file = match?.file ?? level.files[variant % level.files.count]
        let id = NSUserInterfaceItemIdentifier(file + (frame == nil ? ":gif" : ":keys"))
        if view.identifier != id {
            view.animates = false
            view.keyFrames = []
            let url = match?.url ?? level.url(at: variant)
            if frame != nil, let data = url.flatMap({ try? Data(contentsOf: $0) }),
               let bitmap = NSBitmapImageRep(data: data) {
                let count = bitmap.value(forProperty: .frameCount) as? Int ?? 1
                for index in MemeLevel.typingHands[file] ?? [0, count * 3 / 4] {
                    bitmap.setProperty(.currentFrame, withValue: index)
                    if let image = bitmap.cgImage { view.keyFrames.append(NSImage(cgImage: image, size: .zero)) }
                }
            }
            view.image = view.keyFrames.first ?? url.flatMap { NSImage(contentsOf: $0) }
            view.identifier = id
            view.setAccessibilityLabel("밈: \(match?.label ?? level.label)")
        }
        if let frame, view.keyFrames.count == 2 { view.image = view.keyFrames[frame % 2] }
        view.animates = frame == nil && animate && (match != nil || level != .calm)
    }

    static func dismantleNSView(_ view: FittingMemeImageView, coordinator: ()) {
        view.animates = false
        view.image = nil
        view.keyFrames = []
    }
}
