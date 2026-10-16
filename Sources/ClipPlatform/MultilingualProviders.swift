import Accelerate
import ClipCore
import CoreGraphics
import CoreML
import Foundation

/// Shared helpers for manifest-described Core ML encoders.
enum CoreMLSupport {
    static func load(_ manifest: ModelManifest, home: AppHome, role: String) throws -> MLModel {
        guard let record = ModelPaths.installRecord(home: home, id: manifest.id), let dir = record.compiled[role] else {
            throw ProviderError.modelUnavailable(manifest.id)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine     // GPU path is much slower for these graphs (model cards)
        return try MLModel(contentsOf: ModelPaths.directory(home: home, id: manifest.id).appendingPathComponent(dir), configuration: config)
    }

    static func tokenizer(_ manifest: ModelManifest, home: AppHome) throws -> HFTokenizer {
        try HFTokenizer.shared(url: ModelPaths.directory(home: home, id: manifest.id).appendingPathComponent(manifest.tokenizerFile ?? "tokenizer.json"))
    }

    static func ids(_ ids: [Int], length: Int) throws -> MLMultiArray {
        let arr = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let p = arr.dataPointer.bindMemory(to: Int32.self, capacity: length)
        for i in 0..<length { p[i] = Int32(i < ids.count ? ids[i] : 0) }
        return arr
    }

    /// Synchronous prediction under `lock` (bounded memory; never awaited while held).
    static func predict(_ model: MLModel, _ input: MLFeatureProvider, lock: NSLock) throws -> MLFeatureProvider {
        try lock.withLock { try model.prediction(from: input) }
    }

    static func vector(_ out: MLFeatureProvider, name: String, dim: Int, modelID: String) throws -> [Float] {
        guard let arr = out.featureValue(for: name)?.multiArrayValue else { throw ProviderError.failed("\(modelID): output '\(name)' missing") }
        guard arr.count == dim else { throw ProviderError.failed("\(modelID): output has \(arr.count) values, expected \(dim)") }
        var v = [Float](repeating: 0, count: dim)
        switch arr.dataType {
        case .float32: arr.withUnsafeBufferPointer(ofType: Float.self) { p in for i in 0..<dim { v[i] = p[i] } }
        case .float16: arr.withUnsafeBufferPointer(ofType: Float16.self) { p in for i in 0..<dim { v[i] = Float(p[i]) } }
        default: for i in 0..<dim { v[i] = arr[i].floatValue }
        }
        return VectorCodec.normalized(v)
    }
}

/// SigLIP / SigLIP2: multilingual text→image. Image: stretch-resize to S×S, (x/255 − mean)/std, CHW float.
/// Text: lowercase, HF tokenizer (appends <eos>), pad to `textLength` — no attention mask (trained without one).
public final class CoreMLSigLIPProvider: EmbeddingProvider, @unchecked Sendable {
    public let modelID: String
    public let dimension: Int
    public let capabilities = EmbeddingCapabilities(image: true, text: true)
    private let manifest: ModelManifest
    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: HFTokenizer
    private let lock = NSLock()

    public init(manifest: ModelManifest, home: AppHome) throws {
        self.manifest = manifest
        modelID = manifest.id
        dimension = manifest.dim
        imageModel = try CoreMLSupport.load(manifest, home: home, role: "image")
        textModel = try CoreMLSupport.load(manifest, home: home, role: "text")
        tokenizer = try CoreMLSupport.tokenizer(manifest, home: home)
    }

    public func embed(imageAt url: URL) async throws -> [Float] {
        let size = manifest.imageSize ?? 256
        guard let src = ImageInfo.cgImage(at: url, maxPixel: size * 2) else { throw ProviderError.unreadableImage }
        let pixels = try Self.pixelValues(src, size: size, mean: manifest.imageMean ?? [0.5, 0.5, 0.5], std: manifest.imageStd ?? [0.5, 0.5, 0.5])
        let input = try MLDictionaryFeatureProvider(dictionary: [manifest.imageInput ?? "pixel_values": MLFeatureValue(multiArray: pixels)])
        return try CoreMLSupport.vector(try CoreMLSupport.predict(imageModel, input, lock: lock), name: manifest.output ?? "image_embeds", dim: dimension, modelID: modelID)
    }

    public func embed(text: String) async throws -> [Float] {
        let length = manifest.textLength ?? 64
        let t = (manifest.lowercase ?? true) ? text.lowercased() : text
        let ids = tokenizer.contextIDs(t, length: length, padID: manifest.padID ?? 0)
        let input = try MLDictionaryFeatureProvider(dictionary: [manifest.textInput ?? "input_ids": MLFeatureValue(multiArray: try CoreMLSupport.ids(ids, length: length))])
        return try CoreMLSupport.vector(try CoreMLSupport.predict(textModel, input, lock: lock), name: "text_embeds", dim: dimension, modelID: modelID)
    }

    /// RGB CHW float array. Bilinear resize via CoreGraphics (high interpolation quality).
    static func pixelValues(_ image: CGImage, size: Int, mean: [Float], std: [Float]) throws -> MLMultiArray {
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        guard let ctx = CGContext(data: &rgba, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ProviderError.unreadableImage
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        let arr = try MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: 3 * size * size)
        let plane = size * size
        for i in 0..<plane {
            for c in 0..<3 { p[c * plane + i] = (Float(rgba[i * 4 + c]) / 255 - mean[c]) / std[c] }
        }
        return arr
    }
}

/// Sentence-embedding text models (multilingual-e5): input_ids + attention_mask at an enumerated length,
/// pooling + L2 normalisation inside the graph. Query/document prefixes come from the manifest.
public final class CoreMLTextEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public let modelID: String
    public let dimension: Int
    public let capabilities = EmbeddingCapabilities(image: false, text: true)
    private let manifest: ModelManifest
    private let model: MLModel
    private let tokenizer: HFTokenizer
    private let lengths: [Int]
    private let lock = NSLock()

    public init(manifest: ModelManifest, home: AppHome) throws {
        self.manifest = manifest
        modelID = manifest.id
        dimension = manifest.dim
        model = try CoreMLSupport.load(manifest, home: home, role: "text")
        tokenizer = try CoreMLSupport.tokenizer(manifest, home: home)
        lengths = (manifest.inputLengths ?? [512]).sorted()
    }

    public func embed(imageAt url: URL) async throws -> [Float] { throw ProviderError.unsupported("images") }
    public func embed(text: String) async throws -> [Float] { try encode((manifest.queryPrefix ?? "") + text) }
    public func embed(document: String) async throws -> [Float] { try encode((manifest.documentPrefix ?? "") + document) }

    private func encode(_ text: String) throws -> [Float] {
        let maxLen = lengths.last ?? 512
        let full = tokenizer.encode(text)
        let length = lengths.first { $0 >= full.count } ?? maxLen
        let ids = tokenizer.contextIDs(text, length: length, padID: manifest.padID ?? 1)   // truncates keeping </s> (H10)
        let real = min(full.count, length)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let mp = mask.dataPointer.bindMemory(to: Int32.self, capacity: length)
        for i in 0..<length { mp[i] = i < real ? 1 : 0 }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            manifest.textInput ?? "input_ids": MLFeatureValue(multiArray: try CoreMLSupport.ids(ids, length: length)),
            manifest.attentionMaskInput ?? "attention_mask": MLFeatureValue(multiArray: mask),
        ])
        return try CoreMLSupport.vector(try CoreMLSupport.predict(model, input, lock: lock), name: manifest.output ?? "embedding", dim: dimension, modelID: modelID)
    }
}
