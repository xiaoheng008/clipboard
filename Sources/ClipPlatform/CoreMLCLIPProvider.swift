import ClipCore
import CoreML
import Foundation
import Vision

/// Any CLIP-style Core ML pair (image encoder + text encoder) described by a manifest:
/// input/output names, image size and context length all come from JSON, so new variants need no code.
public final class CoreMLCLIPProvider: EmbeddingProvider, @unchecked Sendable {
    public let modelID: String
    public let dimension: Int
    public let capabilities = EmbeddingCapabilities(image: true, text: true)

    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: CLIPTokenizer
    private let manifest: ModelManifest
    private let imageConstraint: MLImageConstraint
    // MLModel prediction is thread-safe for distinct calls, but we serialise to bound memory.
    private let lock = NSLock()

    public init(manifest: ModelManifest, home: AppHome) throws {
        guard let record = ModelPaths.installRecord(home: home, id: manifest.id),
              let imageDir = record.compiled["image"], let textDir = record.compiled["text"] else {
            throw ProviderError.modelUnavailable(manifest.id)
        }
        let dir = ModelPaths.directory(home: home, id: manifest.id)
        let config = MLModelConfiguration()
        config.computeUnits = .all
        imageModel = try MLModel(contentsOf: dir.appendingPathComponent(imageDir), configuration: config)
        textModel = try MLModel(contentsOf: dir.appendingPathComponent(textDir), configuration: config)
        tokenizer = try CLIPTokenizer(vocabURL: dir.appendingPathComponent("vocab.json"), mergesURL: dir.appendingPathComponent("merges.txt"))
        self.manifest = manifest
        modelID = manifest.id
        dimension = manifest.dim
        guard let c = imageModel.modelDescription.inputDescriptionsByName[manifest.imageInput ?? "image"]?.imageConstraint else {
            throw ProviderError.failed("\(manifest.id): image input '\(manifest.imageInput ?? "image")' not found")
        }
        imageConstraint = c
    }

    public func embed(imageAt url: URL) async throws -> [Float] {
        guard let cg = ImageInfo.cgImage(at: url, maxPixel: max(imageConstraint.pixelsWide, imageConstraint.pixelsHigh) * 2) else {
            throw ProviderError.unreadableImage
        }
        let value = try MLFeatureValue(cgImage: cg, constraint: imageConstraint,
                                       options: [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue])
        let input = try MLDictionaryFeatureProvider(dictionary: [manifest.imageInput ?? "image": value])
        return try predict(imageModel, input)
    }

    public func embed(text: String) async throws -> [Float] {
        let ids = tokenizer.contextTokens(text, length: manifest.contextLength ?? 77)
        let arr = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32)
        for (i, v) in ids.enumerated() { arr[i] = NSNumber(value: v) }
        let input = try MLDictionaryFeatureProvider(dictionary: [manifest.textInput ?? "text": MLFeatureValue(multiArray: arr)])
        return try predict(textModel, input)
    }

    private func predict(_ model: MLModel, _ input: MLFeatureProvider) throws -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let out = try model.prediction(from: input)
        guard let arr = out.featureValue(for: manifest.output ?? "final_emb_1")?.multiArrayValue else {
            throw ProviderError.failed("\(modelID): output '\(manifest.output ?? "")' missing")
        }
        guard arr.count == dimension else { throw ProviderError.failed("\(modelID): output has \(arr.count) values, expected \(dimension)") }
        var v = [Float](repeating: 0, count: arr.count)
        if arr.dataType == .float32 {
            arr.withUnsafeBufferPointer(ofType: Float.self) { p in for i in 0..<v.count { v[i] = p[i] } }
        } else {
            for i in 0..<v.count { v[i] = arr[i].floatValue }
        }
        return VectorCodec.normalized(v)
    }
}

/// Maps a manifest family to its provider (the registration point for new backends).
public enum ProviderRegistry {
    public static func make(_ manifest: ModelManifest, home: AppHome) throws -> EmbeddingProvider {
        switch manifest.family {
        case "coreml-clip": return try CoreMLCLIPProvider(manifest: manifest, home: home)
        case "vision-featureprint": return VisionFeaturePrintProvider(manifest: manifest)
        default: throw ProviderError.unsupported("model family \(manifest.family)")
        }
    }
}
