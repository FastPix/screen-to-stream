import XCTest
import CoreVideo
@testable import App

final class CompositorTests: XCTestCase {
    func testPiPRectIsSquareAndInsideBounds() {
        let rect = PiPGeometry.rect(centerX: 0.02, centerY: 0.98, diameter: 0.2,
                                    videoWidth: 1920, videoHeight: 1080)
        XCTAssertEqual(rect.width, rect.height, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxX, 1920)
        XCTAssertLessThanOrEqual(rect.maxY, 1080)
    }

    func testDiameterScalesWithShorterSide() {
        let rect = PiPGeometry.rect(centerX: 0.5, centerY: 0.5, diameter: 0.25,
                                    videoWidth: 1920, videoHeight: 1080)
        XCTAssertEqual(rect.width, 1080 * 0.25, accuracy: 0.5)
    }

    func testCenteredPiPIsActuallyCentered() {
        let rect = PiPGeometry.rect(centerX: 0.5, centerY: 0.5, diameter: 0.2,
                                    videoWidth: 1920, videoHeight: 1080)
        XCTAssertEqual(rect.midX, 960, accuracy: 0.5)
        XCTAssertEqual(rect.midY, 540, accuracy: 0.5)
    }

    func testNoCameraNoCropCanvasSizedIsZeroCopy() {
        let buffer = TestBuffers.make(width: 320, height: 240)
        let out = Compositor().compose(screen: buffer, contentPixelRect: nil, camera: nil,
                                       pip: .zero, canvasWidth: 320, canvasHeight: 240, into: nil)
        XCTAssertTrue(out === buffer)
    }

    func testCompositesCameraIntoNewBufferOfCanvasSize() {
        let screen = TestBuffers.make(width: 320, height: 240)
        let camera = TestBuffers.make(width: 160, height: 120)
        let pip = PiPGeometry.rect(centerX: 0.8, centerY: 0.2, diameter: 0.3,
                                   videoWidth: 320, videoHeight: 240)
        let out = Compositor().compose(screen: screen, contentPixelRect: nil, camera: camera,
                                       pip: pip, canvasWidth: 320, canvasHeight: 240, into: nil)
        XCTAssertFalse(out === screen)
        XCTAssertEqual(CVPixelBufferGetWidth(out), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 240)
    }

    // MARK: - Issue F: resize / cross-display geometry

    func testCroppedContentRendersAtCanvasSize() {
        // A resized window: SCK letterboxed the content into the top-left 200×80 of the buffer.
        let buffer = TestBuffers.make(width: 320, height: 240)
        let out = Compositor().compose(screen: buffer,
                                       contentPixelRect: CGRect(x: 0, y: 0, width: 200, height: 80),
                                       camera: nil, pip: .zero,
                                       canvasWidth: 320, canvasHeight: 240, into: nil)
        XCTAssertFalse(out === buffer, "cropped content must be re-rendered")
        XCTAssertEqual(CVPixelBufferGetWidth(out), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 240)
    }

    func testMismatchedBufferSizeRendersAtCanvasSize() {
        // Post-reconfiguration: SCK now delivers smaller buffers than the writer canvas.
        let buffer = TestBuffers.make(width: 200, height: 80)
        let out = Compositor().compose(screen: buffer, contentPixelRect: nil, camera: nil,
                                       pip: .zero, canvasWidth: 320, canvasHeight: 240, into: nil)
        XCTAssertFalse(out === buffer)
        XCTAssertEqual(CVPixelBufferGetWidth(out), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 240)
    }

    // MARK: - ContentBox (semantics verified by live frameGeom measurements)

    func testSteadyStateFullBufferIsNoCrop() {
        // Real measurement: contentRect (0,0 1008x671) x2 in a 2032x1344 buffer → fills.
        XCTAssertNil(ContentBox.pixelRect(contentRect: CGRect(x: 0, y: 0, width: 1008, height: 671),
                                          scaleFactor: 2, bufferWidth: 2032, bufferHeight: 1344))
    }

    func testLetterboxedContentReportsPixelBox() {
        // SCK letterboxed content into the top band: crop is the visible band in pixels.
        let box = ContentBox.pixelRect(contentRect: CGRect(x: 0, y: 0, width: 1464, height: 436),
                                       scaleFactor: 2, bufferWidth: 2928, bufferHeight: 1840)
        XCTAssertEqual(box, CGRect(x: 0, y: 0, width: 2928, height: 872))
    }

    func testDegenerateGeometryIsNoCrop() {
        XCTAssertNil(ContentBox.pixelRect(contentRect: .zero, scaleFactor: 2,
                                          bufferWidth: 2928, bufferHeight: 1840))
        XCTAssertNil(ContentBox.pixelRect(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                          scaleFactor: 0, bufferWidth: 2928, bufferHeight: 1840))
    }

    // MARK: - AspectFit

    func testAspectFitLetterboxesWideContentIntoSquare() {
        let r = AspectFit.rect(content: CGSize(width: 200, height: 100), into: CGSize(width: 100, height: 100))
        XCTAssertEqual(r.width, 100, accuracy: 0.001)   // fills width
        XCTAssertEqual(r.height, 50, accuracy: 0.001)   // half height
        XCTAssertEqual(r.minY, 25, accuracy: 0.001)     // centered vertically
        XCTAssertEqual(r.minX, 0, accuracy: 0.001)
    }

    func testAspectFitPreservesSquareAndFillsBounds() {
        let r = AspectFit.rect(content: CGSize(width: 50, height: 50), into: CGSize(width: 100, height: 100))
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testAspectFitZeroContentFallsBackToBounds() {
        let r = AspectFit.rect(content: .zero, into: CGSize(width: 80, height: 60))
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 80, height: 60))
    }
}
