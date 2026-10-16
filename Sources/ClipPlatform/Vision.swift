import ClipCore
import Foundation
import Vision

/// Offline OCR (zh-Hans / zh-Hant / en) + coarse scene labels, from one decode of the image.
public struct VisionOCR: OCRProvider {
    public var languages = ["zh-Hans", "zh-Hant", "en-US"]
    public var maxPixel = 2048
    public var labelConfidence: Float = 0.3
    public var maxLabels = 8

    public init() {}

    public func recognize(imageAt url: URL) async throws -> OCRResult {
        guard let image = ImageInfo.cgImage(at: url, maxPixel: maxPixel) else { throw ProviderError.unreadableImage }
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.recognitionLanguages = languages
        text.usesLanguageCorrection = true
        let classify = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([text, classify])
        let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let labels = (classify.results ?? [])
            .filter { $0.confidence >= labelConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxLabels)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        return OCRResult(text: lines.joined(separator: "\n"), labels: Array(labels))
    }
}

/// Image-to-image similarity with Apple's built-in feature print. Zero download; no text queries.
public struct VisionFeaturePrintProvider: EmbeddingProvider {
    public let modelID: String
    public let dimension: Int
    public let capabilities = EmbeddingCapabilities(image: true, text: false)

    public init(manifest: ModelManifest) {
        modelID = manifest.id
        dimension = manifest.dim
    }

    public func embed(imageAt url: URL) async throws -> [Float] {
        guard let image = ImageInfo.cgImage(at: url, maxPixel: 512) else { throw ProviderError.unreadableImage }
        let req = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        guard let obs = req.results?.first as? VNFeaturePrintObservation else { throw ProviderError.failed("no feature print") }
        guard obs.elementType == .float, obs.elementCount == dimension else {
            throw ProviderError.failed("feature print has \(obs.elementCount) elements, manifest says \(dimension)")
        }
        let floats = obs.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return VectorCodec.normalized(floats)
    }

    public func embed(text: String) async throws -> [Float] { throw ProviderError.unsupported("text queries") }
}
