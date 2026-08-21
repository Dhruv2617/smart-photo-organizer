import Testing
import Foundation
import AVFoundation
@testable import PhotoOrganizer

struct VideoFrameSamplerTests {
    @Test func testSampleFramesReturnsEmptyForZeroDurationAsset() throws {
        // A file with no video track (e.g. empty data) should yield no frames,
        // not throw — callers treat "no frames" as "skip video hashing".
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try Data().write(to: url)

        let frames = try VideoFrameSampler.sampleFrames(videoAt: url, interval: 2.0)

        #expect(frames.count == 0)
    }
}
