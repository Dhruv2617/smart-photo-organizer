import Testing
import Foundation
@testable import PhotoOrganizer

struct HashServiceTests {
    @Test func testSHA256IsStableForIdenticalBytes() throws {
        let url1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data("identical content".utf8)
        try bytes.write(to: url1)
        try bytes.write(to: url2)

        let hash1 = try HashService.sha256(fileAt: url1)
        let hash2 = try HashService.sha256(fileAt: url2)

        #expect(hash1 == hash2)
    }

    @Test func testHammingDistanceOfIdenticalHashesIsZero() {
        let distance = HashService.hammingDistance(0b1010, 0b1010)
        #expect(distance == 0)
    }

    @Test func testHammingDistanceCountsDifferingBits() {
        let distance = HashService.hammingDistance(0b1010, 0b1000)
        #expect(distance == 1)
    }
}
