import CoreVideo

enum TestBuffers {
    static func make(width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        return buffer!
    }
}
