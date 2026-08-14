import CoreImage
import CoreVideo
import Foundation
import Metal

/// Where the circular camera PiP lands in video space. Center is normalized
/// (0-1, origin bottom-left) and mirrors the overlay window's on-screen position;
/// diameter is a fraction of the video's shorter side.
enum PiPGeometry {
    static func rect(centerX: Double, centerY: Double, diameter: Double,
                     videoWidth: Int, videoHeight: Int) -> CGRect {
        let side = Double(min(videoWidth, videoHeight)) * diameter
        let clampedX = min(max(centerX * Double(videoWidth), side / 2), Double(videoWidth) - side / 2)
        let clampedY = min(max(centerY * Double(videoHeight), side / 2), Double(videoHeight) - side / 2)

        return CGRect(x: clampedX - side / 2, y: clampedY - side / 2, width: side, height: side)
    }
}

/// Maps SCK's per-frame geometry attachments to the content's pixel box. contentRect is in surface
/// points and scaleFactor is the display's pixels-per-point, so pixels = rect × factor.
enum ContentBox {
    /// Returns the content's pixel rect, or nil when it fills the buffer (≥98% both axes) or the
    /// geometry is degenerate.
    static func pixelRect(contentRect: CGRect, scaleFactor: Double,
                          bufferWidth: Int, bufferHeight: Int) -> CGRect? {
        guard scaleFactor > 0 else { return nil }

        let pixels = CGRect(x: contentRect.minX * scaleFactor,
                            y: contentRect.minY * scaleFactor,
                            width: contentRect.width * scaleFactor,
                            height: contentRect.height * scaleFactor)
            .intersection(CGRect(x: 0, y: 0, width: bufferWidth, height: bufferHeight))

        guard !pixels.isEmpty, pixels.width >= 32, pixels.height >= 32 else { return nil }

        let fills = pixels.width >= CGFloat(bufferWidth) * 0.98
            && pixels.height >= CGFloat(bufferHeight) * 0.98
        return fills ? nil : pixels
    }
}

enum AspectFit {
    /// The centered rect that fits `content` inside `bounds` preserving aspect ratio (letterbox
    /// bars fill the remainder). Zero-sized content falls back to filling bounds.
    static func rect(content: CGSize, into bounds: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return CGRect(origin: .zero, size: bounds) }

        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let w = content.width * scale
        let h = content.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

final class Compositor {
    private let context: CIContext

    init(context: CIContext = Compositor.makeContext()) {
        self.context = context
    }

    static func makeContext() -> CIContext {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }

    /// Composes one output frame on the fixed canvas in a single GPU render: crop to real content,
    /// aspect-fit, then the camera PiP. SCK letterboxes a resized window inside its fixed-size
    /// buffer and reports the valid region via contentRect, so the padding must be cropped away.
    /// Zero-copy when there's no camera, no crop, and the buffer is already canvas-sized.
    /// - Parameter contentPixelRect: content sub-rect in buffer pixels (top-left origin), or nil
    ///   when the content fills the buffer.
    func compose(screen: CVPixelBuffer, contentPixelRect: CGRect?, camera: CVPixelBuffer?,
                 pip: CGRect, canvasWidth: Int, canvasHeight: Int,
                 into pool: CVPixelBufferPool?) -> CVPixelBuffer {
        let bufferWidth = CVPixelBufferGetWidth(screen)
        let bufferHeight = CVPixelBufferGetHeight(screen)

        if contentPixelRect == nil, camera == nil,
           bufferWidth == canvasWidth, bufferHeight == canvasHeight {
            return screen
        }

        var image = CIImage(cvPixelBuffer: screen)

        if let crop = contentPixelRect {
            // contentRect is top-left origin; CoreImage is bottom-left.
            let ciRect = CGRect(x: crop.minX, y: CGFloat(bufferHeight) - crop.maxY,
                                width: crop.width, height: crop.height)
            image = image.cropped(to: ciRect)
                .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
        }

        let canvas = CGSize(width: canvasWidth, height: canvasHeight)
        if image.extent.size != canvas {
            let fit = AspectFit.rect(content: image.extent.size, into: canvas)
            image = image
                .transformed(by: CGAffineTransform(scaleX: fit.width / image.extent.width,
                                                   y: fit.height / image.extent.height))
                .transformed(by: CGAffineTransform(translationX: fit.minX, y: fit.minY))
        }

        var composed = image.composited(over: CIImage(color: .black)
            .cropped(to: CGRect(origin: .zero, size: canvas)))

        if let camera {
            composed = circularPiP(from: camera, in: pip).composited(over: composed)
        }

        guard let output = makeBuffer(width: canvasWidth, height: canvasHeight,
                                      format: CVPixelBufferGetPixelFormatType(screen),
                                      from: pool) else { return screen }

        context.render(composed, to: output)
        return output
    }

    private func circularPiP(from camera: CVPixelBuffer, in rect: CGRect) -> CIImage {
        // Mirror horizontally to match the preview.
        let raw = CIImage(cvPixelBuffer: camera)
        let image = raw.transformed(
            by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -raw.extent.width, y: 0)
        )
        let extent = image.extent

        let scale = max(rect.width / extent.width, rect.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let cropped = scaled.cropped(to: CGRect(
            x: scaled.extent.midX - rect.width / 2,
            y: scaled.extent.midY - rect.height / 2,
            width: rect.width,
            height: rect.height
        ))

        let mask = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: rect.width / 2, y: rect.height / 2),
            "inputRadius0": rect.width / 2 - 1,
            "inputRadius1": rect.width / 2,
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
        ])?.outputImage

        let centered = cropped.transformed(by: CGAffineTransform(
            translationX: -cropped.extent.origin.x,
            y: -cropped.extent.origin.y
        ))

        let masked = mask.map {
            centered.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: $0,
            ])
        } ?? centered

        return masked.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    private func makeBuffer(width: Int, height: Int, format: OSType,
                            from pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?

        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            // Pool is the writer adaptor's, canvas-sized; on a size mismatch fall through to direct
            // allocation so the encoder never gets a wrong-sized frame.
            if let b = buffer, CVPixelBufferGetWidth(b) == width, CVPixelBufferGetHeight(b) == height {
                return b
            }
            buffer = nil
        }

        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &buffer)
        return buffer
    }
}
