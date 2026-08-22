import Testing
import Foundation
@testable import PhotoOrganizer

struct SemanticSearchServiceTests {
    @Test func testCosineSimilarityOfIdenticalVectorsIsOne() {
        let v: [Float] = [1, 2, 3, 4]
        #expect(abs(SemanticSearchService.cosineSimilarity(v, v) - 1.0) < 0.0001)
    }

    @Test func testCosineSimilarityOfOrthogonalVectorsIsZero() {
        let a: [Float] = [1, 0]
        let b: [Float] = [0, 1]
        #expect(SemanticSearchService.cosineSimilarity(a, b) == 0.0)
    }

    @Test func testRankOrdersCandidatesBestFirst() {
        let query: [Float] = [1, 0]
        let candidates: [(mediaFileId: String, embedding: [Float])] = [
            ("far", [0.3, 0.95]),
            ("close", [0.99, 0.01]),
            ("medium", [0.5, 0.5])
        ]

        let ranked = SemanticSearchService.rank(queryEmbedding: query, candidates: candidates, limit: 10)

        #expect(ranked == ["close", "medium", "far"])
    }

    @Test func testRankRespectsLimit() {
        let query: [Float] = [1, 0]
        let candidates: [(mediaFileId: String, embedding: [Float])] = (0..<10).map { i in
            (String(i), [Float(i), 1])
        }

        let ranked = SemanticSearchService.rank(queryEmbedding: query, candidates: candidates, limit: 3)

        #expect(ranked.count == 3)
    }

    @Test func testRankUsesBestFrameScoreForVideosWithMultipleEmbeddings() {
        // Simulates a video with 3 sampled frames, only one of which matches
        // well — the video's overall score should be its BEST frame, not an
        // average, per spec.
        let query: [Float] = [1, 0]
        let candidates: [(mediaFileId: String, embedding: [Float])] = [
            ("video", [0, 1]),   // frame 1: bad match
            ("video", [0.9, 0.1]), // frame 2: good match
            ("video", [0.1, 0.9]), // frame 3: bad match
            ("photo", [0.5, 0.5])
        ]

        let ranked = SemanticSearchService.rank(queryEmbedding: query, candidates: candidates, limit: 10)

        #expect(ranked.first == "video", "video's best frame should outrank the photo")
    }
}
