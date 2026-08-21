import Testing
import CoreGraphics
@testable import PhotoOrganizer

struct FaceDetectorTests {
    @Test func testDetectFacesOnBlankImageReturnsNoFaces() throws {
        let size = 64
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 255, count: size * size)
        let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8,
                                 bytesPerRow: size, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let blankImage = context.makeImage()!

        let faces = try FaceDetector.detectFaces(in: blankImage)

        #expect(faces.count == 0)
    }
}
