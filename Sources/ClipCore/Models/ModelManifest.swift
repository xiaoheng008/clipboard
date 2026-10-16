import Foundation

// Contract: BuiltinModels.json ↔ these Codable types ↔ docs/scv/2-data-contracts.md「模型清单」.
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

    public init(id: String, family: String, displayName: String, tier: Int, dim: Int, imageSize: Int?, contextLength: Int?,
                minMemoryGB: Int, imageInput: String?, textInput: String?, output: String?, tokenizer: String?,
                files: [ModelFile], notes: String?) {
        self.id = id; self.family = family; self.displayName = displayName; self.tier = tier; self.dim = dim
        self.imageSize = imageSize; self.contextLength = contextLength; self.minMemoryGB = minMemoryGB
        self.imageInput = imageInput; self.textInput = textInput; self.output = output; self.tokenizer = tokenizer
        self.files = files; self.notes = notes
    }

    public static let supportedFamilies: Set<String> = ["coreml-clip", "vision-featureprint"]
    public var isSupportedFamily: Bool { Self.supportedFamilies.contains(family) }
    /// Needs a download before it can be activated.
    public var requiresInstall: Bool { !files.isEmpty }
    public var supportsTextQueries: Bool { family == "coreml-clip" }
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
        for m in custom.models {
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

    /// H8: the most capable text-capable model whose memory floor fits this machine.
    public func recommended(memoryGB: Int) -> ModelManifest? {
        models.filter { $0.supportsTextQueries && $0.minMemoryGB <= memoryGB }
            .max { ($0.tier, -$0.minMemoryGB) < ($1.tier, -$1.minMemoryGB) }
    }
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
    public static func directory(home: AppHome, id: String) -> URL {
        home.modelsURL.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
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
