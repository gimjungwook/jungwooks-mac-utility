import Foundation

enum MemeTopic: String, CaseIterable {
    case food, coffee, sleep, celebrate, sad, love, angry, confused, error, waiting, work, money, travel, cat, dog, relax
    case surprise, awkward, approve, reject, cheer, facepalm, smug, skeptical, scared, laugh, dance, hug
    case apology, thanks, hello, goodbye, shrug, secret, shopping, exercise, music, gaming, rain, cold

    // Short words and inflected Korean stems need explicit anchors; vectors handle longer paraphrases.
    var anchors: [String] {
        switch self {
        case .food: return ["배고", "허기", "점심", "저녁", "아침밥", "먹고", "먹자", "맛있", "피자", "치킨", "라면", "food", "hungry", "lunch", "dinner", "pizza"]
        case .coffee: return ["커피", "아아", "아메리카노", "카페인", "라떼", "coffee", "caffeine", "espresso", "latte"]
        case .sleep: return ["졸리", "졸려", "피곤", "지쳤", "지친", "잘자", "자고", "잠온", "잠이", "sleep", "sleepy", "tired", "exhausted"]
        case .celebrate: return ["퇴근", "끝났", "끝냈", "해냈", "축하", "성공", "완료", "신난", "신나", "congrats", "success", "hooray", "done"]
        case .sad: return ["슬프", "슬퍼", "우울", "눈물", "울고", "실망", "ㅠㅠ", "ㅜㅜ", "sad", "cry", "crying", "disappointed"]
        case .love: return ["사랑", "좋아해", "감동", "love", "lovely", "heart"]
        case .angry: return ["짜증", "화나", "화가", "열받", "분노", "빡치", "angry", "rage", "furious", "annoyed"]
        case .confused: return ["모르겠", "헷갈", "궁금", "고민", "무슨뜻", "뭔소리", "confused", "thinking", "wonder", "huh"]
        case .error: return ["버그", "오류", "에러", "고장", "먹통", "멘붕", "망했", "안되네", "안돼", "bug", "error", "broken", "crash", "panic"]
        case .waiting: return ["기다", "심심", "지루", "언제와", "아직도", "waiting", "wait", "bored", "boring"]
        case .work: return ["코딩", "공부", "개발", "회의", "문서", "일하", "집중", "coding", "study", "working", "meeting", "focus"]
        case .money: return ["월급", "돈", "지갑", "텅장", "비싸", "부자", "money", "payday", "salary", "broke", "expensive"]
        case .travel: return ["여행", "휴가", "비행기", "공항", "바다", "vacation", "travel", "flight", "beach", "holiday"]
        case .cat: return ["고양이", "냥이", "냥냥", "cat", "cats", "kitten"]
        case .dog: return ["강아지", "댕댕", "반려견", "멍멍", "dog", "dogs", "puppy"]
        case .relax: return ["쉬고", "휴식", "편안", "느긋", "여유", "힐링", "relax", "rest", "chill", "peaceful"]
        case .surprise: return ["놀랐", "놀라", "대박", "헐", "세상에", "surprised", "shocked", "wow", "mind blown"]
        case .awkward: return ["민망", "어색", "쑥스", "당황", "awkward", "embarrassed", "nervous laugh"]
        case .approve: return ["동의", "찬성", "인정", "좋네", "좋겠", "오케이", "굿", "approved", "agree", "yes", "okay", "thumbs up"]
        case .reject: return ["싫어", "싫다", "거절", "안할", "사양", "nope", "reject", "no thanks", "hard pass"]
        case .cheer: return ["힘내", "화이팅", "파이팅", "응원", "할수있", "cheering", "you can do it", "you got this"]
        case .facepalm: return ["한심", "어이없", "이마", "아이고", "facepalm", "oh no"]
        case .smug: return ["뿌듯", "자랑", "역시나", "자신만만", "smug", "proud", "nailed it"]
        case .skeptical: return ["의심", "수상", "진짜로", "설마", "skeptical", "side eye", "really"]
        case .scared: return ["무서", "두려", "겁나", "긴장", "scared", "terrified", "afraid", "nervous"]
        case .laugh: return ["웃겨", "웃기", "웃음", "ㅋㅋ", "ㅎㅎ", "laugh", "laughing", "lol", "lmao", "hilarious"]
        case .dance: return ["춤", "댄스", "덩실", "dance", "dancing"]
        case .hug: return ["안아", "포옹", "토닥", "hug", "hugs", "cuddle"]
        case .apology: return ["미안", "죄송", "사과드", "sorry", "apology", "my bad"]
        case .thanks: return ["고마", "감사", "덕분", "thanks", "thankyou", "thank you", "grateful"]
        case .hello: return ["안녕하", "반가", "하이", "hello", "greetings", "good morning"]
        case .goodbye: return ["잘가", "다음에봐", "바이바이", "goodbye", "bye", "see you later"]
        case .shrug: return ["글쎄", "어쩌라", "아무거나", "상관없", "shrug", "whatever", "idk", "i don't know"]
        case .secret: return ["비밀", "쉿", "몰래", "secret", "shh", "sneaky"]
        case .shopping: return ["쇼핑", "장바구니", "지름", "구매", "shopping", "retail", "take my money"]
        case .exercise: return ["운동", "헬스", "달리", "러닝", "workout", "exercise", "running", "gym"]
        case .music: return ["음악", "노래", "뮤직", "흥얼", "music", "singing", "song", "vibing"]
        case .gaming: return ["게임", "게이머", "플레이", "gaming", "gamer", "game over", "video game"]
        case .rain: return ["비온", "비가", "비오", "장마", "우산", "rain", "raining", "rainy"]
        case .cold: return ["춥", "추워", "겨울", "덜덜", "cold", "freezing", "winter"]
        }
    }

    static func keyword(in text: String) -> MemeTopic? {
        let value = text.precomposedStringWithCanonicalMapping.lowercased()
        var latest: (String.Index, MemeTopic)?
        for topic in allCases {
            for anchor in topic.anchors {
                guard let range = value.range(of: anchor, options: .backwards) else { continue }
                if anchor.unicodeScalars.allSatisfy({ $0.isASCII }) {
                    if range.lowerBound > value.startIndex {
                        let before = value[value.index(before: range.lowerBound)]
                        if before.isLetter || before.isNumber || before == "_" { continue }
                    }
                    if range.upperBound < value.endIndex {
                        let after = value[range.upperBound]
                        if after.isLetter || after.isNumber || after == "_" { continue }
                    }
                }
                if latest == nil || range.lowerBound > latest!.0 { latest = (range.lowerBound, topic) }
            }
        }
        return latest?.1
    }

}

struct MemeMatch: Equatable {
    var file: String
    var label: String
    var topic: String

    var url: URL? {
        let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
        return bundle.url(forResource: file, withExtension: "gif", subdirectory: "Memes")
    }
}

/// Brute-force cosine search is tiny at this scale: one 512-float query against the fixed catalog.
/// Query text and vectors leave scope immediately; the monitor keeps only catalog IDs for rotation.
final class SemanticMemeMatcher {
    static let shared = SemanticMemeMatcher()
    private let queue = DispatchQueue(label: "MacUtility.semantic", qos: .utility)
    private lazy var index = Self.loadIndex()
    private var previousFile: String?
    private(set) var embeddedQueries = 0

    static func loadIndex() -> MemeIndex? {
        let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
        guard let url = bundle.url(forResource: "semantic-index", withExtension: "json", subdirectory: "Memes"),
              let data = try? Data(contentsOf: url), let index = try? JSONDecoder().decode(MemeIndex.self, from: data), index.isValid() else { return nil }
        return index
    }

    func classify(_ text: String, allowEmbedding: Bool, completion: @escaping ([MemeMatch]) -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem {
            let matches = self.candidates(text, allowEmbedding: allowEmbedding)
            let choices = matches.isEmpty ? self.generalCandidates() : matches
            DispatchQueue.main.async { completion(choices) }
        }
        queue.async(execute: work)
        return work
    }

    func match(_ text: String) -> MemeMatch? {
        let choices = candidates(text)
        let match = choices.filter { $0.file != previousFile }.randomElement() ?? choices.first
        previousFile = match?.file
        return match
    }

    func generalCandidates() -> [MemeMatch] {
        (index?.entries ?? []).filter { $0.topic != "work" }.map { MemeMatch(file: $0.file, label: $0.label, topic: $0.topic) }
    }

    static func embeddingText(_ text: String) -> String {
        guard text.count > 768 else { return text }
        // Bound inference cost while retaining context from the start, middle and end of a long input.
        let middle = text.index(text.startIndex, offsetBy: text.count / 2 - 128)
        return String(text.prefix(256)) + "\n" + String(text[middle...].prefix(256)) + "\n" + String(text.suffix(256))
    }

    func candidates(_ text: String, allowEmbedding: Bool = true) -> [MemeMatch] {
        let text = text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let index else { return [] }
        let language = text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } ? "ko" : "en"
        guard let model = index.models[language] else { return [] }
        let anchor = MemeTopic.keyword(in: text)
        let query: [Float]
        if let anchor, let packed = index.anchors[anchor.rawValue]?[language], let vector = MemeIndex.values(packed, dimension: model.dimension) {
            // Known short synonyms reuse an authored query vector: no model loading or inference.
            query = vector
        } else {
            guard allowEmbedding, text.count >= 6, let encoder = MemeVectorizer(language: language) else { return [] }
            defer { encoder.unload() }
            guard encoder.model == model, let vector = encoder.vector(Self.embeddingText(text)) else { return [] }
            embeddedQueries += 1
            query = vector
        }
        let ranked = index.entries.compactMap { entry -> (entry: MemeIndex.Entry, score: Float)? in
            if let anchor, entry.topic != anchor.rawValue { return nil }
            guard let vector = entry.vectors[language] else { return nil }
            return (entry, MemeIndex.similarity(query, vector))
        }.sorted { $0.score > $1.score }
        guard let top = ranked.first else { return [] }
        let other = ranked.first { $0.entry.topic != top.entry.topic }?.score ?? -1
        // Weak or ambiguous free text uses the general reaction gallery.
        guard top.score >= (anchor != nil ? 0.65 : language == "ko" ? 0.74 : 0.84),
              anchor != nil || top.score - other >= (language == "ko" ? 0.035 : 0.025) else { return [] }
        let sameTopic = ranked.filter { $0.entry.topic == top.entry.topic }
        // Keep several runners-up so a uniquely close match cannot pin one GIF forever.
        let count = max(3, sameTopic.prefix { $0.score >= top.score - 0.04 }.count)
        return sameTopic.prefix(min(48, count)).map {
            MemeMatch(file: $0.entry.file, label: $0.entry.label, topic: $0.entry.topic)
        }
    }
}
