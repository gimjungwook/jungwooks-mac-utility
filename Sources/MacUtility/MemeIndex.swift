import Foundation
import NaturalLanguage

/// Fixed, normalized Float32 vectors. No user text is stored in this catalog.
struct MemeIndex: Codable {
    struct Model: Codable, Equatable {
        var identifier: String
        var revision: Int
        var dimension: Int
    }
    struct Entry: Codable {
        var file: String
        var topic: String
        var label: String
        var tags: [String]
        var vectors: [String: Data]
    }
    var schema: Int
    var models: [String: Model]
    var anchors: [String: [String: Data]]
    var entries: [Entry]

    static func values(_ data: Data, dimension: Int) -> [Float]? {
        guard data.count == dimension * MemoryLayout<Float>.size else { return nil }
        let values = data.withUnsafeBytes { bytes in
            (0..<dimension).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        let norm = values.reduce(Float(0)) { $0 + $1 * $1 }
        return values.allSatisfy(\.isFinite) && abs(norm - 1) < 0.01 ? values : nil
    }

    func isValid() -> Bool {
        guard schema == 1, !entries.isEmpty, Set(entries.map(\.file)).count == entries.count,
              Set(models.keys) == ["ko", "en"], models.values.allSatisfy({ (1...2048).contains($0.dimension) }) else { return false }
        func valid(_ vectors: [String: Data]) -> Bool {
            models.allSatisfy { language, model in
                vectors[language].flatMap { Self.values($0, dimension: model.dimension) } != nil
            }
        }
        return entries.allSatisfy {
            !$0.file.isEmpty && $0.file.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }
                && !$0.label.isEmpty && !$0.tags.isEmpty && valid($0.vectors)
        } && anchors.values.allSatisfy(valid)
    }

    static func similarity(_ query: [Float], _ data: Data) -> Float {
        guard data.count == query.count * 4 else { return -1 }
        return data.withUnsafeBytes { bytes in
            var sum: Float = 0
            for i in query.indices { sum += query[i] * bytes.loadUnaligned(fromByteOffset: i * 4, as: Float.self) }
            return sum
        }
    }
}

/// The authoring tool and runtime use exactly the same model and pooling.
final class MemeVectorizer {
    let language: String
    let model: MemeIndex.Model
    private let contextual: NLContextualEmbedding?

    init?(language: String) {
        self.language = language
        guard language == "ko" || language == "en" else { return nil }
        if let embedding = NLContextualEmbedding(language: language == "ko" ? .korean : .english), embedding.hasAvailableAssets {
            contextual = embedding
            model = .init(identifier: embedding.modelIdentifier, revision: embedding.revision, dimension: embedding.dimension)
        } else { return nil }
    }

    func vector(_ text: String) -> [Float]? {
        var sum: [Double]
        if let contextual, let result = try? contextual.embeddingResult(for: text, language: language == "ko" ? .korean : .english) {
            sum = .init(repeating: 0, count: model.dimension)
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                for i in vector.indices { sum[i] += vector[i] }
                return true
            }
        } else { return nil }
        let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        guard sum.count == model.dimension, norm.isFinite, norm > 0 else { return nil }
        return sum.map { Float($0 / norm) }
    }

    func unload() { contextual?.unload() }
    deinit { unload() }
}
