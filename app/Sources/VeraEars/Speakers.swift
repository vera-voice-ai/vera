import CSherpa
import Foundation

/// CAM++ (3D-Speaker) from the box: one voice vector per phrase. Tells voices apart; it does not know names —
/// those come from the voice book the owner fills in.
public final class SpeakerEmbedder {
    private let handle: UnsafeMutableRawPointer

    public init(runtime: EarsRuntime) throws {
        try SherpaLibrary.load(runtime)
        let model = runtime.root.appending(path: "models/speaker/campplus.onnx")
        guard FileManager.default.fileExists(atPath: model.path), let h = vera_speaker_create(model.path, 2) else {
            throw EarsError.model("CAM++")
        }
        handle = h
    }
    deinit { vera_speaker_destroy(handle) }

    /// nil for audio too short to say anything (under ~0.8 s).
    public func embed(_ samples: [Float]) -> [Float]? {
        guard samples.count >= 12_800 else { return nil }
        let dim = Int(vera_speaker_dim(handle))
        guard let v = samples.withUnsafeBufferPointer({ vera_speaker_embed(handle, $0.baseAddress, Int32($0.count), 16_000) }) else { return nil }
        defer { vera_sherpa_free_floats(v) }
        return Array(UnsafeBufferPointer(start: v, count: dim))
    }
}

/// Whose voices Vera knows: a few phrase vectors per person, in Vera's data (`voices.json`), never sent anywhere.
public struct VoiceBook: Codable, Sendable, Equatable {
    public struct Person: Codable, Sendable, Equatable {
        public var name: String
        public var owner: Bool
        public var templates: [[Float]]
        public init(name: String, owner: Bool, templates: [[Float]] = []) { self.name = name; self.owner = owner; self.templates = templates }
    }
    public var people: [Person] = []
    /// Measured in Vera 2 on the «Голоса» corpus for this model.
    public static let minCosine = 0.55
    public static let maxTemplates = 8

    public init(people: [Person] = []) { self.people = people }

    public static func load(_ url: URL) -> VoiceBook {
        (try? JSONDecoder().decode(VoiceBook.self, from: Data(contentsOf: url))) ?? VoiceBook()
    }
    public func save(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// The best match and its cosine; the person is nil below the threshold.
    public func identify(_ v: [Float]) -> (person: Person?, cosine: Double)? {
        var best: (Person, Double)?
        for p in people {
            for t in p.templates {
                guard let c = Self.cosine(v, t) else { continue }
                if best == nil || c > best!.1 { best = (p, c) }
            }
        }
        guard let best else { return nil }
        return (best.1 >= Self.minCosine ? best.0 : nil, best.1)
    }

    public mutating func add(_ v: [Float], to name: String, owner: Bool) {
        if let i = people.firstIndex(where: { $0.name == name }) {
            people[i].templates.append(v)
            if people[i].templates.count > Self.maxTemplates { people[i].templates.removeFirst() }
        } else {
            people.append(Person(name: name, owner: owner, templates: [v]))
        }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot: Double = 0, na: Double = 0, nb: Double = 0
        for i in a.indices { dot += Double(a[i] * b[i]); na += Double(a[i] * a[i]); nb += Double(b[i] * b[i]) }
        guard na > 0, nb > 0 else { return nil }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}

/// The fact handed to Hermes with a spoken phrase — only when it is not simply the owner speaking: Hermes' gateway
/// has no field for it (`voice_context` is only for live-voice delegation), so a short note goes before the words.
public enum SpeakerNote {
    public static func prefix(book: VoiceBook, match: (person: VoiceBook.Person?, cosine: Double)?) -> String {
        guard !book.people.isEmpty, let match else { return "" }
        guard let p = match.person else { return "[голос не узнан] " }
        return p.owner ? "" : "[говорит: \(p.name)] "
    }
}
