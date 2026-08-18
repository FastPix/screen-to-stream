import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// First-frame JPEG thumbnails for local recordings. Best-effort: returns nil on any failure.
enum ThumbnailGenerator {
    nonisolated static var defaultDirectory: URL {
        HistoryStore.defaultDirectory.appendingPathComponent("thumbnails", isDirectory: true)
    }

    static func generate(from videoURL: URL, id: String,
                         directory: URL = ThumbnailGenerator.defaultDirectory) async -> String? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        guard let cgImage = try? await generator.image(at: .zero).image else { return nil }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let output = directory.appendingPathComponent("\(id).jpg")
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }

        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return output.path
    }
}
