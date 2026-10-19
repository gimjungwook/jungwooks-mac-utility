import Foundation
import CryptoKit

/// Run when the GIF catalog changes, not at app startup or on each key.
@main struct BuildMemeIndex {
    struct Source: Decodable {
        struct Anchor: Decodable { var id: String; var ko: String; var en: String }
        struct Entry: Decodable {
            var file: String; var topic: String; var label: String; var tags: [String]
            var ko: String; var en: String; var koMeaning: String; var enMeaning: String; var sha256: String
        }
        var anchors: [Anchor]
        var entries: [Entry]
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
        let source = try JSONDecoder().decode(Source.self, from: Data(contentsOf: root.appendingPathComponent("meme-catalog.json")))
        let resources = root.appendingPathComponent("Sources/MacUtility/Memes")
        let files = try Set(FileManager.default.contentsOfDirectory(atPath: resources.path).filter { $0.hasSuffix(".gif") }.map { String($0.dropLast(4)) })
        guard files == Set(source.entries.map(\.file)), files.count == source.entries.count else { fatalError("GIF catalog mismatch") }
        for entry in source.entries {
            let data = try Data(contentsOf: resources.appendingPathComponent(entry.file + ".gif"))
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == entry.sha256 else { fatalError("GIF changed: " + entry.file) }
        }
        var index = MemeIndex(schema: 1, models: [:], anchors: [:], entries: source.entries.map {
            .init(file: $0.file, topic: $0.topic, label: $0.label, tags: $0.tags, vectors: [:])
        })
        for language in ["ko", "en"] {
            guard let encoder = MemeVectorizer(language: language) else { fatalError("Local model unavailable: " + language) }
            index.models[language] = encoder.model
            var fixedVectors: [String: [Float]] = [:]
            func vector(_ text: String) -> [Float] {
                if let cached = fixedVectors[text] { return cached }
                guard let result = encoder.vector(text) else { fatalError("Could not embed fixed catalog text") }
                fixedVectors[text] = result
                return result
            }
            func packed(_ text: String) -> Data {
                vector(text).withUnsafeBufferPointer { Data(buffer: $0) }
            }
            for anchor in source.anchors { index.anchors[anchor.id, default: [:]][language] = packed(language == "ko" ? anchor.ko : anchor.en) }
            for i in source.entries.indices {
                let entry = source.entries[i]
                let caption = (language == "ko" ? entry.ko : entry.en) + ". " + entry.tags.prefix(6).joined(separator: ", ")
                let meaning = vector(language == "ko" ? entry.koMeaning : entry.enMeaning)
                let scene = vector(caption)
                // Intent outweighs incidental objects, e.g. a hungry cat is about hunger before cats.
                let combined = zip(meaning, scene).map { 0.85 * $0 + 0.15 * $1 }
                let norm = sqrt(combined.reduce(Float(0)) { $0 + $1 * $1 })
                let vector = combined.map { $0 / norm }
                index.entries[i].vectors[language] = vector.withUnsafeBufferPointer { Data(buffer: $0) }
            }
            encoder.unload()
            print("indexed \(source.entries.count) GIFs: \(language), \(encoder.model.dimension) dimensions")
        }
        guard index.isValid() else { fatalError("Invalid generated index") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: resources.appendingPathComponent("semantic-index.json"), options: .atomic)
        print("semantic-index.json: \(data.count) bytes")
    }
}
