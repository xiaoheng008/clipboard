import Foundation

// Contract: BuiltinModels.json ↔ these Codable types ↔ docs/scv/2.2-data-contracts.md「模型清单」.
// New optional fields only; unknown families are kept but cannot be activated.

public struct ModelFile: Codable, Sendable, Equatable {
    public var path: String      // relative to the model's install directory
    public var url: String
    public var sha256: String
    public var size: Int64
    public init(path: String, url: String, sha256: String, size: Int64) {
        self.path = path; self.url = url; self.sha256 = sha256; self.size = size
    }
}

public struct ModelManifest: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var family: String
    public var displayName: String
    public var tier: Int
    public var dim: Int
    public var imageSize: Int?
    public var contextLength: Int?
    public var minMemoryGB: Int
    public var imageInput: String?
    public var textInput: String?
    public var output: String?
    public var tokenizer: String?
    public var files: [ModelFile]
    public var notes: String?
    // Optional fields (added 2026-10-17 for multilingual families; absent = family default).
    public var textLength: Int?          // fixed text context (SigLIP2: 64)
    public var padID: Int?
    public var lowercase: Bool?
    public var imageMean: [Float]?
    public var imageStd: [Float]?
    public var inputLengths: [Int]?      // enumerated Core ML input lengths (e5: 16…512)
    public var attentionMaskInput: String?
    public var queryPrefix: String?
    public var documentPrefix: String?
    public var tokenizerFile: String?    // HF tokenizer.json (otherwise CLIP vocab.json + merges.txt)
    public var multilingual: Bool?
    public var scoreFloor: Float?        // H5: semantic hits below this are dropped
    public var scoreMargin: Float?       // H5: …and those further than this below the best hit

    public init(id: String, family: String, displayName: String, tier: Int, dim: Int, imageSize: Int?, contextLength: Int?,
                minMemoryGB: Int, imageInput: String?, textInput: String?, output: String?, tokenizer: String?,
                files: [ModelFile], notes: String?) {
        self.id = id; self.family = family; self.displayName = displayName; self.tier = tier; self.dim = dim
        self.imageSize = imageSize; self.contextLength = contextLength; self.minMemoryGB = minMemoryGB
        self.imageInput = imageInput; self.textInput = textInput; self.output = output; self.tokenizer = tokenizer
        self.files = files; self.notes = notes
    }

    public static let supportedFamilies: Set<String> = ["coreml-clip", "coreml-siglip", "vision-featureprint", "coreml-text-embed"]
    public var isSupportedFamily: Bool { Self.supportedFamilies.contains(family) }
    /// Needs a download before it can be activated.
    public var requiresInstall: Bool { !files.isEmpty }
    /// Can answer a text query (image models: text→image; text models: text→text).
    public var supportsTextQueries: Bool { ["coreml-clip", "coreml-siglip", "coreml-text-embed"].contains(family) }
    /// Which active-model slot this model occupies.
    public var slot: ModelSlot { family == "coreml-text-embed" ? .text : .image }
    public var isMultilingual: Bool { multilingual ?? false }
    public var floor: Float { scoreFloor ?? 0.10 }
    public var margin: Float { scoreMargin ?? 0.06 }
    public var downloadBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public struct ModelCatalog: Codable, Sendable, Equatable {
    public var models: [ModelManifest]

    public static func builtin() throws -> ModelCatalog {
        try JSONDecoder().decode(ModelCatalog.self, from: Data(BuiltinModels.json.utf8))
    }

    /// Custom entries (models/custom.json) are appended; a custom entry with an existing id replaces it.
    public func merging(customJSON: Data) throws -> ModelCatalog {
        let custom = try JSONDecoder().decode(ModelCatalog.self, from: customJSON)
        var out = models
        for m in custom.models where ModelPaths.manifestIsSafe(m) {   // R1/R2: unsafe entries are ignored
            if let i = out.firstIndex(where: { $0.id == m.id }) { out[i] = m } else { out.append(m) }
        }
        return ModelCatalog(models: out)
    }

    public static func load(home: AppHome) -> (catalog: ModelCatalog, customError: String?) {
        var catalog = (try? builtin()) ?? ModelCatalog(models: [])
        let custom = home.modelsURL.appendingPathComponent("custom.json")
        guard let data = try? Data(contentsOf: custom) else { return (catalog, nil) }
        do { catalog = try catalog.merging(customJSON: data); return (catalog, nil) }
        catch { return (catalog, "models/custom.json: \(error)") }
    }

    public func model(id: String) -> ModelManifest? { models.first { $0.id == id } }

    /// H8: the most capable text-queryable model for `slot` whose memory floor fits this machine.
    public func recommended(memoryGB: Int, slot: ModelSlot = .image) -> ModelManifest? {
        models.filter { $0.slot == slot && $0.supportsTextQueries && $0.isSupportedFamily && $0.minMemoryGB <= memoryGB }
            .max { ($0.tier, -$0.minMemoryGB) < ($1.tier, -$1.minMemoryGB) }
    }
}

public enum ModelPathError: Error, CustomStringConvertible {
    case unsafeID(String), unsafePath(String)
    public var description: String {
        switch self {
        case .unsafeID(let s): "unsafe model id '\(s)'"
        case .unsafePath(let s): "unsafe model file path '\(s)'"
        }
    }
}

/// Two independent active models: one for images, one for text semantics (FR20).
public enum ModelSlot: String, Sendable, CaseIterable, Codable {
    case image, text
}

/// Install layout written by ModelInstaller. Directory without install.json = not installed.
public struct InstallRecord: Codable, Sendable, Equatable {
    public var modelID: String
    public var installedAt: Date
    public var compiled: [String: String]   // role ("image"/"text") → compiled .mlmodelc dir name
    public init(modelID: String, installedAt: Date, compiled: [String: String]) {
        self.modelID = modelID; self.installedAt = installedAt; self.compiled = compiled
    }
}

public enum ModelPaths {
    /// R1: ids become directory names under models/. Only a conservative charset; never "." / "..".
    public static func isSafeID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 100, id != ".", id != "..", !id.hasPrefix(".") else { return false }
        return id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._@-".unicodeScalars.contains($0) }
    }

    /// R2: manifest file paths are relative, non-empty, without "." / ".." components.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    public static func manifestIsSafe(_ m: ModelManifest) -> Bool {
        isSafeID(m.id) && m.files.allSatisfy { isSafeRelativePath($0.path) }
    }

    public static func directory(home: AppHome, id: String) -> URL {
        home.modelsURL.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    /// Directory for a validated id; throws instead of resolving outside models/.
    public static func safeDirectory(home: AppHome, id: String) throws -> URL {
        guard isSafeID(id) else { throw ModelPathError.unsafeID(id) }
        // Lexical check only: filesystem normalisation differs for existing vs new paths under
        // symlinked roots such as /private/tmp. isSafeID already excludes "/", "." and "..".
        let dir = directory(home: home, id: id)
        guard dir.deletingLastPathComponent().path == home.modelsURL.path || dir.deletingLastPathComponent().path + "/" == home.modelsURL.path
        else { throw ModelPathError.unsafeID(id) }
        return dir
    }

    public static func installRecord(home: AppHome, id: String) -> InstallRecord? {
        let url = directory(home: home, id: id).appendingPathComponent("install.json")
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(InstallRecord.self, from: d)
    }

    public static func isInstalled(home: AppHome, model: ModelManifest) -> Bool {
        !model.requiresInstall || installRecord(home: home, id: model.id) != nil
    }
}
