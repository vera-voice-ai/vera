import Foundation

/// Silero TTS v5 (ru) text side, ported line by line from the Python inside `v5_ru.pt` (`multi_acc_v3_package.py`,
/// `models/accentor.py`, `models/homosolver.py`, `custom_tokenizers/bert_tokenizer.py`): the same text in gives the
/// same symbol ids out (golden cases from the original in `Tests/SileroVoiceTests`). Only the plain-text path Vera
/// uses: `apply_tts(text, put_accent, put_yo)` with every other option at its default; no SSML.
///
/// Strings are walked as Unicode scalars, as Python walks code points. The homograph BERT is a model, so it is asked
/// through `HomographScorer`; everything else here is plain code over the data from `silero-text.json`.
public final class SileroText: @unchecked Sendable {
    public let speakers: [String: Int]
    let symbolToId: [Unicode.Scalar: Int64]
    let allowed: Set<Unicode.Scalar>
    let sos: Unicode.Scalar, eos: Unicode.Scalar
    let accentor: Accentor
    let homographs: Homographs

    /// `dir` holds `silero-text.json`, `silero-ngrams.txt`, `silero-ngrams.bin` (scripts/build-mouth-ios.sh).
    public init(dir: URL) throws {
        let data = try Data(contentsOf: dir.appending(path: "silero-text.json"))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let speakers = root["speakers"] as? [String: Int],
              let symbols = root["symbols"] as? String,
              let s2i = root["symbol_to_id"] as? [String: Int],
              let sos = (root["sos"] as? String)?.unicodeScalars.first,
              let eos = (root["eos"] as? String)?.unicodeScalars.first,
              let acc = root["accentor"] as? [String: Any],
              let homo = root["homo"] as? [String: Any]
        else { throw SileroError.data("silero-text.json") }
        self.speakers = speakers
        var map: [Unicode.Scalar: Int64] = [:]
        for (k, v) in s2i { if let s = k.unicodeScalars.first, k.unicodeScalars.count == 1 { map[s] = Int64(v) } }
        symbolToId = map
        // prepare_text_input keeps symbols[3:] (and "^", which no id exists for: dropped here instead of failing).
        allowed = Set(symbols.unicodeScalars.dropFirst(3))
        self.sos = sos; self.eos = eos
        accentor = try Accentor(json: acc, dir: dir)
        homographs = try Homographs(json: homo)
    }

    /// `prepare_text_input`: lower case, dashes, only the model's symbols, spaces collapsed. nil when nothing is left
    /// to say (no Russian letters).
    public func prepare(_ text: String) -> String? {
        var t = text.lowercased().replacingOccurrences(of: "—", with: "–").replacingOccurrences(of: "‑", with: "-")
        t = String(String.UnicodeScalarView(t.unicodeScalars.filter { allowed.contains($0) }))
        // clean_star_text without "^": runs of whitespace to one space, trimmed.
        let words = t.split(separator: " ", omittingEmptySubsequences: true)
        let sentence = words.joined(separator: " ")
        // has_text: any of [а-я-] other than space (ё is outside а-я, as in the original).
        let has = sentence.unicodeScalars.contains { ($0.value >= 0x430 && $0.value <= 0x44F) || $0 == "-" }
        return has ? sentence : nil
    }

    /// The accented sentence the TTS model reads: homographs by the BERT, then stress and ё by the n-gram accentor.
    public func accent(_ sentence: String, scorer: HomographScorer) throws -> String {
        accentor.accent(try homographs.solve(sentence, scorer: scorer))
    }

    /// Symbol ids for the model: `|` + accented sentence + `~`.
    public func ids(accented: String) -> [Int64] {
        var out: [Int64] = []
        for s in [sos] + Array(accented.unicodeScalars) + [eos] { if let id = symbolToId[s] { out.append(id) } }
        return out
    }
}

public enum SileroError: LocalizedError {
    case data(String)
    case model(String)
    case runtime(String)
    public var errorDescription: String? {
        switch self {
        case .data(let f): "голос Silero: не читаются данные \(f)"
        case .model(let why): "голос Silero: модель — \(why)"
        case .runtime(let why): "голос Silero: onnxruntime — \(why)"
        }
    }
}

/// The homograph BERT: padded token rows, the [HOMO]/[/HOMO] positions → one logit per row.
public protocol HomographScorer {
    func homographLogits(ids: [[Int64]], starts: [Int64], ends: [Int64]) throws -> [Float]
}

// MARK: - Scalars

typealias Scalars = [Unicode.Scalar]

extension Unicode.Scalar {
    var lower: Unicode.Scalar { String(self).lowercased().unicodeScalars.first ?? self }
    var upper: Unicode.Scalar { String(self).uppercased().unicodeScalars.first ?? self }
    /// Python's str.islower() for one character: cased and lower case.
    var isLowerCased: Bool { properties.isLowercase && properties.changesWhenUppercased }
}

func str(_ s: some Sequence<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(s)) }

// MARK: - Homograph solver (models/homosolver.py)

final class Homographs {
    let dict: [String: [String]]        // variants already sorted as Python sorts them
    let tokenizer: BertTokenizer
    let startId: Int64, endId: Int64, padId: Int64

    init(json: [String: Any]) throws {
        guard let d = json["dict"] as? [String: [String]], let start = json["start"] as? Int, let end = json["end"] as? Int,
              let pad = json["pad"] as? Int else { throw SileroError.data("homo") }
        dict = d; startId = Int64(start); endId = Int64(end); padId = Int64(pad)
        tokenizer = try BertTokenizer(json: json)
    }

    /// `_find_and_tag_homos`: re.finditer(r'(?=.*[а-яё])[а-яё+]+', IGNORECASE) — a run of letters and "+" with a
    /// letter somewhere from its start on.
    static func words(_ s: Scalars) -> [(start: Int, end: Int)] {
        func inClass(_ c: Unicode.Scalar) -> Bool { isRuLetter(c) || c == "+" }
        var lastLetter = -1
        for (i, c) in s.enumerated() where isRuLetter(c) { lastLetter = i }
        var out: [(Int, Int)] = []
        var i = 0
        while i < s.count {
            if i <= lastLetter, inClass(s[i]) {
                var j = i
                while j < s.count, inClass(s[j]) { j += 1 }
                out.append((i, j)); i = j
            } else { i += 1 }
        }
        return out
    }

    static func isRuLetter(_ c: Unicode.Scalar) -> Bool {
        (c.value >= 0x430 && c.value <= 0x44F) || (c.value >= 0x410 && c.value <= 0x42F) || c == "ё" || c == "Ё"
    }

    func solve(_ sentence: String, scorer: HomographScorer) throws -> String {
        let s = Scalars(sentence.unicodeScalars)
        var found: [(start: Int, end: Int, word: Scalars)] = []
        var rows: [[Int64]] = [], starts: [Int64] = [], ends: [Int64] = []
        for (a, b) in Self.words(s) {
            let word = Scalars(s[a..<b])
            guard dict[str(word).lowercased()] != nil else { continue }
            let mark = str(s[..<a]) + " [HOMO] " + str(word) + " [/HOMO] " + str(s[b...])
            let ids = tokenizer.encode(mark)
            guard let st = ids.firstIndex(of: startId), let en = ids.firstIndex(of: endId) else { continue }
            rows.append(ids); starts.append(Int64(st)); ends.append(Int64(en))
            found.append((a, b, word))
        }
        if found.isEmpty { return sentence }
        let width = rows.map(\.count).max() ?? 0
        let padded = rows.map { $0 + Array(repeating: padId, count: width - $0.count) }
        let logits = try scorer.homographLogits(ids: padded, starts: starts, ends: ends)
        var out = s
        var offset = 0
        for (k, f) in found.enumerated() {
            // torch.round(torch.sigmoid(x)): 1 above 0.5, and 0.5 itself rounds to even (0).
            let pred = 1 / (1 + Foundation.exp(-logits[k])) > 0.5 ? 1 : 0
            guard let variants = dict[str(f.word).lowercased()], pred < variants.count else { continue }
            var wp = Scalars(variants[pred].unicodeScalars)
            let nVowels = wp.filter { Accentor.vowels.contains($0.lower) }.count
            guard let stressIdx = wp.firstIndex(of: "+") else { continue }
            wp.removeAll { $0 == "+" }
            wp = zip(f.word, wp).map { c1, c2 in c1.isLowerCased ? c2.lower : c2.upper }
            _ = nVowels  // (n_vowels > 1 or stress_single_vowel) is always true at Vera's defaults
            wp.insert("+", at: min(stressIdx, wp.count))
            let a = f.start + offset, b = f.end + offset
            offset += 1
            out.replaceSubrange(a..<b, with: wp)
        }
        return str(out)
    }
}

// MARK: - BERT tokenizer (custom_tokenizers/bert_tokenizer.py)

final class BertTokenizer {
    let vocab: [String: Int64]
    let cls: Int64, sep: Int64, unk: Int64
    let neverSplit: Set<String>
    let maxChars: Int

    init(json: [String: Any]) throws {
        guard let list = json["vocab"] as? [String], let cls = json["cls"] as? Int, let sep = json["sep"] as? Int,
              let unk = json["unk"] as? Int, let never = json["never_split"] as? [String] else { throw SileroError.data("vocab") }
        var v: [String: Int64] = [:]
        v.reserveCapacity(list.count)
        for (i, t) in list.enumerated() { v[t] = Int64(i) }
        vocab = v; self.cls = Int64(cls); self.sep = Int64(sep); self.unk = Int64(unk)
        neverSplit = Set(never); maxChars = json["max_chars"] as? Int ?? 100
    }

    func encode(_ text: String) -> [Int64] {
        [cls] + wordpiece(basic(text)).map { vocab[$0] ?? unk } + [sep]
    }

    /// Python's str.split(): runs of whitespace.
    static func pySplit(_ s: Scalars) -> [Scalars] {
        var out: [Scalars] = [], cur: Scalars = []
        for c in s {
            if c.properties.isWhitespace { if !cur.isEmpty { out.append(cur); cur = [] } } else { cur.append(c) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    func basic(_ text: String) -> [Scalars] {
        var cleaned: Scalars = []
        for c in text.unicodeScalars {
            if c.value == 0 || c.value == 0xFFFD || Self.isControl(c) { continue }
            cleaned.append(Self.isWhitespace(c) ? " " : c)
        }
        // (Chinese characters get spaces around them in the original; none survive Vera's symbol filter.)
        var tokens: [Scalars] = []
        for tok in Self.pySplit(cleaned) {
            if neverSplit.contains(str(tok)) { tokens.append(tok); continue }
            var start = true
            for c in tok {
                if Self.isPunctuation(c) { tokens.append([c]); start = true }
                else { if start { tokens.append([]) }; start = false; tokens[tokens.count - 1].append(c) }
            }
        }
        return tokens.filter { !$0.isEmpty }
    }

    func wordpiece(_ tokens: [Scalars]) -> [String] {
        var out: [String] = []
        for chars in tokens {
            if chars.count > maxChars { out.append("[UNK]"); continue }
            var start = 0, subs: [String] = [], bad = false
            while start < chars.count {
                var end = chars.count, cur: String?
                while start < end {
                    let sub = (start > 0 ? "##" : "") + str(chars[start..<end])
                    if vocab[sub] != nil { cur = sub; break }
                    end -= 1
                }
                guard let found = cur else { bad = true; break }
                subs.append(found); start = end
            }
            if bad { out.append("[UNK]") } else { out += subs }
        }
        return out
    }

    static func isControl(_ c: Unicode.Scalar) -> Bool {
        if c == "\t" || c == "\n" || c == "\r" { return false }
        switch c.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned: return true
        default: return false
        }
    }

    static func isWhitespace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r" || c.properties.generalCategory == .spaceSeparator
    }

    static func isPunctuation(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        if (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v) { return true }
        switch c.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }
}

// MARK: - Stress and ё (models/accentor.py, AccentorNgram)

final class Accentor {
    static let vowels: Set<Unicode.Scalar> = Set("аоуыэиеяёю".unicodeScalars)
    let ngrams: [String: Int32]
    let table: [Float]                  // rows × dim, dequantized as the original does at load
    let dim: Int
    let stress: [Layer], yo: [Layer]
    let exceptions: [String: (stress: Int, yo: Int)]
    let stopWords: Set<String>

    struct Layer { let w: [Float]; let b: [Float]; let inputs: Int; let outputs: Int }

    init(json: [String: Any], dir: URL) throws {
        guard let scale = json["scale"] as? Double, let zp = json["zero_point"] as? Double, let dim = json["dim"] as? Int,
              let st = json["stress"] as? [[String: Any]], let yo = json["yo"] as? [[String: Any]],
              let exc = json["exceptions"] as? [String: [Int]], let stops = json["stop_words"] as? [String]
        else { throw SileroError.data("accentor") }
        let lines = try String(contentsOf: dir.appending(path: "silero-ngrams.txt"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
        var map: [String: Int32] = [:]
        map.reserveCapacity(lines.count)
        for (i, g) in lines.enumerated() where !g.isEmpty { map[String(g)] = Int32(i) }
        let raw = try Data(contentsOf: dir.appending(path: "silero-ngrams.bin"))
        guard raw.count == map.count * dim else { throw SileroError.data("silero-ngrams.bin") }
        // float32 scale * (q - zero_point), as torch computes it.
        let s = Float(scale), z = Float(zp)
        table = raw.withUnsafeBytes { buf in buf.bindMemory(to: Int8.self).map { s * (Float($0) - z) } }
        ngrams = map; self.dim = dim
        func layers(_ l: [[String: Any]]) throws -> [Layer] {
            try l.map {
                guard let w = $0["w"] as? [Double], let b = $0["b"] as? [Double], let i = $0["in"] as? Int, let o = $0["out"] as? Int
                else { throw SileroError.data("accentor mlp") }
                return Layer(w: w.map(Float.init), b: b.map(Float.init), inputs: i, outputs: o)
            }
        }
        stress = try layers(st); self.yo = try layers(yo)
        exceptions = exc.compactMapValues { $0.count == 2 ? ($0[0], $0[1]) : nil }
        stopWords = Set(stops)
    }

    /// `word_ngrams(word, 1, len(word) + 3)` over "<word>", looked up, mean of the rows ("UNK" when none is known).
    func embedding(_ word: String) -> [Float] {
        let w = Scalars(("<" + word + ">").unicodeScalars)
        var rows: [Int32] = []
        let n = word.unicodeScalars.count
        for len in 1...(n + 3) where len <= w.count {
            for i in 0...(w.count - len) { if let r = ngrams[str(w[i..<(i + len)])] { rows.append(r) } }
        }
        if n < 1, let r = ngrams[word] { rows.append(r) }
        if rows.isEmpty, let r = ngrams["UNK"] { rows.append(r) }
        var sum = [Float](repeating: 0, count: dim)
        for r in rows { let o = Int(r) * dim; for k in 0..<dim { sum[k] += table[o + k] } }
        return sum.map { $0 / Float(max(1, rows.count)) }
    }

    static func forward(_ x: [Float], _ layers: [Layer]) -> [Float] {
        var h = x
        for (li, l) in layers.enumerated() {
            var y = l.b
            for o in 0..<l.outputs {
                var acc: Float = 0
                let row = o * l.inputs
                for i in 0..<l.inputs { acc += l.w[row + i] * h[i] }
                y[o] += acc
            }
            h = li < layers.count - 1 ? y.map { max(0, $0) } : y
        }
        return h
    }

    static func softmax(_ x: [Float]) -> [Float] {
        let m = x.max() ?? 0
        let e = x.map { Foundation.exp($0 - m) }
        let s = e.reduce(0, +)
        return e.map { $0 / s }
    }

    /// stress probabilities, yo probabilities for one clean word.
    func predict(_ word: String) -> (stress: [Float], yo: [Float]) {
        let e = embedding(word)
        return (Self.softmax(Self.forward(e, stress)), Self.softmax(Self.forward(e, yo)))
    }

    /// `_tokenize`: words and the whitespace between them, hyphen parts kept with their "-"; what the model sees is the
    /// word lower-cased with only Russian letters; the last part after a hyphen is skipped if it is a stop word ("то").
    func tokenize(_ sentence: String) -> [(raw: Scalars, clean: String, process: Bool)] {
        let s = Scalars(sentence.unicodeScalars)
        var pieces: [Scalars] = []          // re.split(r'(\s+)')
        var cur: Scalars = [], curSpace = false
        for c in s {
            let sp = c.properties.isWhitespace
            if sp != curSpace { pieces.append(cur); cur = []; curSpace = sp }
            cur.append(c)
        }
        pieces.append(cur)
        var out: [(Scalars, String, Bool)] = []
        for word in pieces {
            let parts = word.split(separator: "-", omittingEmptySubsequences: false).map(Scalars.init)
            var toks: [Scalars], mask: [Bool]
            if parts.count == 1 { toks = [word]; mask = [true] } else {
                toks = parts.dropLast().map { $0 + ["-"] } + [parts.last!]
                mask = Array(repeating: true, count: parts.count - 1) + [!stopWords.contains(str(parts.last!))]
            }
            for (t, m) in zip(toks, mask) {
                let clean = str(t.map(\.lower).filter(Homographs.isRuLetter))
                out.append((t, clean, m && !clean.isEmpty))
            }
        }
        return out
    }

    func accent(_ sentence: String) -> String {
        var result: Scalars = []
        for (raw0, clean, process) in tokenize(sentence) {
            var raw = raw0
            guard process else { result += raw; continue }
            let lower = raw.map(\.lower)
            let haveStress = lower.contains("+"), haveYo = lower.contains("ё")
            if haveStress && haveYo { result += raw; continue }
            if !haveStress && haveYo {
                // stress each user "ё" (stress_single_vowel and no skip lists at Vera's defaults)
                let pos = lower.enumerated().filter { $0.element == "ё" }.map(\.offset)
                for (i, p) in pos.enumerated() { raw.insert("+", at: p + i) }
                result += raw; continue
            }
            if let exc = exceptions[clean] { result += exception(raw: raw, exc: exc, haveStress: haveStress); continue }

            let (sp, yp) = predict(clean)
            let stressPred = sp.indices.max { sp[$0] < sp[$1] } ?? 0     // argmax (first of equals, as torch on CPU)
            let yoPred = yp.indices.max { yp[$0] < yp[$1] } ?? 0
            var stressedIds = [stressPred]
            let setStress = sp[stressPred] > 0.5 && !haveStress
            let yoIds = [yoPred]
            let setYo = yp[yoPred] > 0.5
            if haveStress {
                stressedIds = str(lower).split(separator: "+", omittingEmptySubsequences: false)
                    .map { $0.unicodeScalars.filter { Self.vowels.contains($0) }.count }
            }
            let vowelIds = lower.indices.filter { Self.vowels.contains(lower[$0]) }
            let yeIds = lower.indices.filter { lower[$0] == "е" }
            var stressPos = stressedIds.filter { $0 < vowelIds.count && !vowelIds.isEmpty }.map { vowelIds[$0] }
            let yoPos = yoIds.filter { $0 > 0 && $0 - 1 < yeIds.count && !yeIds.isEmpty }.map { yeIds[$0 - 1] }
            if vowelIds.isEmpty { result += raw; continue }
            for p in yoPos where stressPos.contains(p) && setYo && lower[p] == "е" {
                raw[p] = raw[p].isLowerCased ? "ё" : "Ё"
            }
            var doStress = setStress
            if vowelIds.count == 1 { stressPos = [vowelIds[0]]; doStress = true }
            if !haveStress && doStress { for (i, p) in stressPos.enumerated() { raw.insert("+", at: p + i) } }
            result += raw
        }
        return str(result)
    }

    /// `_accentuate_exception`: stress (and ё) from the exception list, by character index.
    func exception(raw: Scalars, exc: (stress: Int, yo: Int), haveStress: Bool) -> Scalars {
        var w = raw
        func setYo(_ i: Int) { if i >= 0 && i < w.count { w[i] = w[i].isLowerCased ? "ё" : "Ё" } }
        if haveStress {
            let marks = raw.indices.filter { raw[$0] == "+" }
            w.removeAll { $0 == "+" }
            if exc.yo != -1 && marks.contains(exc.yo + 1) { setYo(exc.yo) }
            for m in marks { w.insert("+", at: min(m, w.count)) }
            return w
        }
        if exc.yo != -1 { setYo(exc.yo) }
        w.insert("+", at: max(0, min(exc.stress, w.count)))
        return w
    }
}
