import Testing
import Foundation
@testable import PhotoOrganizer

struct CLIPTokenizerTests {
    private static func makeTokenizer(contextLength: Int = 77) throws -> CLIPTokenizer {
        guard let (vocabURL, mergesURL) = CLIPResources.tokenizerURLs() else {
            struct MissingResource: Error {}
            throw MissingResource()
        }
        return try CLIPTokenizer(vocabURL: vocabURL, mergesURL: mergesURL, contextLength: contextLength)
    }

    // Ground truth computed directly from OpenAI's reference SimpleTokenizer
    // algorithm in Python against the same vocab.json/merges.txt bundled here
    // — see the session's verification script. Confirms the Swift BPE
    // implementation produces byte-for-byte identical token IDs, not just
    // "some" tokens.
    @Test func testEncodeMatchesReferencePythonTokenizer() throws {
        let tokenizer = try Self.makeTokenizer()

        let cases: [(String, [Int32])] = [
            ("a beach at sunset", [49406, 320, 2117, 536, 3424, 49407]),
            ("dog", [49406, 1929, 49407]),
            ("birthday cake", [49406, 1166, 2972, 49407])
        ]

        for (text, expectedPrefix) in cases {
            let ids = tokenizer.encode(text)
            #expect(Array(ids.prefix(expectedPrefix.count)) == expectedPrefix, "mismatch for \"\(text)\"")
            // Everything after the real tokens should be end-of-text padding.
            #expect(ids.dropFirst(expectedPrefix.count).allSatisfy { $0 == tokenizer.endOfTextId })
        }
    }

    @Test func testEncodeAlwaysReturnsExactlyContextLengthTokens() throws {
        let tokenizer = try Self.makeTokenizer(contextLength: 77)

        #expect(tokenizer.encode("a").count == 77)
        #expect(tokenizer.encode("a very long sentence with quite a few words describing many things in a scene").count == 77)
    }

    @Test func testEncodeTruncatesOverlongTextButKeepsEndOfTextToken() throws {
        let tokenizer = try Self.makeTokenizer(contextLength: 8)
        let longText = String(repeating: "word ", count: 50)

        let ids = tokenizer.encode(longText)

        #expect(ids.count == 8)
        #expect(ids.first == tokenizer.startOfTextId)
        #expect(ids.last == tokenizer.endOfTextId)
    }
}
