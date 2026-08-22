import Foundation

/// Byte-level BPE tokenizer matching OpenAI's CLIP `SimpleTokenizer` exactly
/// (same vocab.json/merges.txt format, same byte-to-unicode mapping, same
/// merge algorithm) — needed because the CLIP text encoder expects token
/// IDs from this exact vocabulary, not arbitrary text.
final class CLIPTokenizer {
    private let encoder: [String: Int32]
    private let bpeRanks: [BytePair: Int]
    private let byteEncoder: [UInt8: Character]
    private var cache: [String: [String]] = [:]

    let startOfTextId: Int32
    let endOfTextId: Int32
    /// The model's fixed input length (from its declared shape) — sequences
    /// are truncated or padded (with `endOfTextId`, matching HuggingFace's
    /// CLIPTokenizer default pad token) to exactly this length.
    let contextLength: Int

    struct BytePair: Hashable {
        let first: String
        let second: String
    }

    init(vocabURL: URL, mergesURL: URL, contextLength: Int) throws {
        self.contextLength = contextLength

        let vocabData = try Data(contentsOf: vocabURL)
        let rawEncoder = try JSONDecoder().decode([String: Int32].self, from: vocabData)
        self.encoder = rawEncoder

        guard let sot = rawEncoder["<|startoftext|>"], let eot = rawEncoder["<|endoftext|>"] else {
            throw CLIPTokenizerError.missingSpecialTokens
        }
        self.startOfTextId = sot
        self.endOfTextId = eot

        let mergesText = try String(contentsOf: mergesURL, encoding: .utf8)
        var ranks: [BytePair: Int] = [:]
        let lines = mergesText.split(separator: "\n", omittingEmptySubsequences: false)
        // First line is a version header ("#version: 0.2 - ..."), skip it.
        for (index, line) in lines.dropFirst().enumerated() {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            ranks[BytePair(first: String(parts[0]), second: String(parts[1]))] = index
        }
        self.bpeRanks = ranks

        self.byteEncoder = Self.buildByteEncoder()
    }

    /// OpenAI's CLIP maps every possible byte (0-255) to a printable unicode
    /// character so byte-level BPE can operate on ordinary strings. Bytes
    /// that are already printable ASCII/Latin-1 map to themselves; the rest
    /// map to characters starting at U+0100.
    private static func buildByteEncoder() -> [UInt8: Character] {
        var byteToUnicode: [UInt8: UInt32] = [:]
        var assigned = Set<UInt8>()

        func addRange(_ range: ClosedRange<UInt8>) {
            for b in range {
                byteToUnicode[b] = UInt32(b)
                assigned.insert(b)
            }
        }
        addRange(33...126)   // '!' ... '~'
        addRange(161...172)  // '¡' ... '¬'
        addRange(174...255)  // '®' ... 'ÿ'

        var n: UInt32 = 0
        for b in UInt8.min...UInt8.max {
            if !assigned.contains(b) {
                byteToUnicode[b] = 256 + n
                n += 1
            }
        }

        var result: [UInt8: Character] = [:]
        for (byte, scalarValue) in byteToUnicode {
            if let scalar = Unicode.Scalar(scalarValue) {
                result[byte] = Character(scalar)
            }
        }
        return result
    }

    /// Tokenizes `text`, returning exactly `contextLength` token IDs:
    /// `[startOfTextId] + bpeTokens + [endOfTextId]`, truncated if too long
    /// or padded with `endOfTextId` if too short.
    func encode(_ text: String) -> [Int32] {
        var ids: [Int32] = [startOfTextId]
        for word in Self.splitIntoWords(text.lowercased()) {
            for bpeToken in bpe(word) {
                if let id = encoder[bpeToken] {
                    ids.append(id)
                }
            }
        }
        ids.append(endOfTextId)

        if ids.count > contextLength {
            ids = Array(ids.prefix(contextLength - 1)) + [endOfTextId]
        } else if ids.count < contextLength {
            ids += Array(repeating: endOfTextId, count: contextLength - ids.count)
        }
        return ids
    }

    /// Splits cleaned text into the same word-ish units as CLIP's regex
    /// (`'s|'t|'re|'ve|'m|'ll|'d|letters+|digit|non-space-non-alnum+`),
    /// implemented by hand since Swift's regex engine handles this pattern
    /// shape fine but a hand-rolled scan avoids any Unicode-property-class
    /// edge-case mismatches with Python's `regex` module.
    private static func splitIntoWords(_ text: String) -> [String] {
        let contractions = ["'s", "'t", "'re", "'ve", "'m", "'ll", "'d"]
        var words: [String] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == " " { i += 1; continue }

            var matchedContraction = false
            for c in contractions {
                let cChars = Array(c)
                if i + cChars.count <= chars.count && Array(chars[i..<(i + cChars.count)]) == cChars {
                    words.append(c)
                    i += cChars.count
                    matchedContraction = true
                    break
                }
            }
            if matchedContraction { continue }

            let c = chars[i]
            if c.isLetter {
                var j = i
                while j < chars.count && chars[j].isLetter { j += 1 }
                words.append(String(chars[i..<j]))
                i = j
            } else if c.isNumber {
                words.append(String(c))
                i += 1
            } else {
                var j = i
                while j < chars.count && chars[j] != " " && !chars[j].isLetter && !chars[j].isNumber { j += 1 }
                words.append(String(chars[i..<j]))
                i = j
            }
        }
        return words
    }

    /// Byte-level BPE merge for a single word: encode to byte-unicode
    /// characters, append a word-boundary marker to the last one, then
    /// repeatedly merge the lowest-rank adjacent pair until no known merge
    /// applies. Matches OpenAI's reference `bpe()` exactly.
    private func bpe(_ token: String) -> [String] {
        if let cached = cache[token] {
            return cached
        }

        let byteChars: [String] = token.utf8.map { String(byteEncoder[$0] ?? Character(UnicodeScalar($0))) }
        guard !byteChars.isEmpty else { return [] }

        var word = byteChars
        word[word.count - 1] += "</w>"

        while word.count > 1 {
            var bestPair: BytePair?
            var bestRank = Int.max
            for i in 0..<(word.count - 1) {
                let pair = BytePair(first: word[i], second: word[i + 1])
                if let rank = bpeRanks[pair], rank < bestRank {
                    bestRank = rank
                    bestPair = pair
                }
            }
            guard let pair = bestPair else { break }

            var newWord: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1 && word[i] == pair.first && word[i + 1] == pair.second {
                    newWord.append(pair.first + pair.second)
                    i += 2
                } else {
                    newWord.append(word[i])
                    i += 1
                }
            }
            word = newWord
        }

        cache[token] = word
        return word
    }
}

enum CLIPTokenizerError: Error {
    case missingSpecialTokens
}
