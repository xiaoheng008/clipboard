import AppKit
import ClipCore
import ImageIO
import UniformTypeIdentifiers

/// Reads the general pasteboard into a plain-value snapshot. Main thread only.
@MainActor
public enum PasteboardReader {
    public static var changeCount: Int { NSPasteboard.general.changeCount }

    /// Type names only. Reading types does not read content (I7 relies on this order).
    public static func types() -> [String] {
        NSPasteboard.general.types?.map(\.rawValue) ?? []
    }

    public static func snapshot() -> PasteboardSnapshot {
        let pb = NSPasteboard.general
        let types = pb.types?.map(\.rawValue) ?? []
        var s = PasteboardSnapshot(changeCount: pb.changeCount, types: types)

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            s.fileURLs = urls.map(\.absoluteString)
            return s
        }
        if let str = pb.string(forType: .string) {
            s.string = str
            s.rtf = pb.data(forType: .rtf)
            s.html = pb.data(forType: .html)
            return s
        }
        s.image = readImage(pb)
        return s
    }

    /// PNG as-is; JPEG as-is; anything else NSImage can read (TIFF, HEIC, PDF…) is converted to PNG (E4).
    static func readImage(_ pb: NSPasteboard) -> CapturedImage? {
        if let png = pb.data(forType: .png), let dims = ImageInfo.dimensions(png) {
            return CapturedImage(data: png, uti: UTType.png.identifier, width: dims.0, height: dims.1)
        }
        let jpeg = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        if let j = pb.data(forType: jpeg), let dims = ImageInfo.dimensions(j) {
            return CapturedImage(data: j, uti: UTType.jpeg.identifier, width: dims.0, height: dims.1)
        }
        if let tiff = pb.data(forType: .tiff), let png = ImageInfo.pngData(from: tiff), let dims = ImageInfo.dimensions(png) {
            return CapturedImage(data: png, uti: UTType.png.identifier, width: dims.0, height: dims.1)
        }
        if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation, let png = ImageInfo.pngData(from: tiff),
           let dims = ImageInfo.dimensions(png) {
            return CapturedImage(data: png, uti: UTType.png.identifier, width: dims.0, height: dims.1)
        }
        return nil
    }
}

public enum ImageInfo {
    public static func dimensions(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    public static func pngData(from data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, nil)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    /// Downsampled decode (bounded memory for huge screenshots, E7).
    public static func cgImage(at url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// Writes items back. Always adds the self-write marker (contract with CaptureDecision).
public struct SystemPasteboardWriter: PasteboardWriting {
    public init() {}

    public func write(text: String?, representations: [Representation], imageFile: URL?) throws -> Int {
        try onMain {
            let pb = NSPasteboard.general
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setData(Data(), forType: NSPasteboard.PasteboardType(SelfWriteMarker.type))
            if let file = representations.first(where: { $0.uti == "public.file-url" }) {
                // Files: write one item per URL so Finder pastes all of them.
                let urls = String(decoding: file.data, as: UTF8.self).split(separator: "\n").map(String.init)
                let items = urls.map { u -> NSPasteboardItem in
                    let i = NSPasteboardItem()
                    i.setString(u, forType: .fileURL)
                    return i
                }
                items.first?.setData(Data(), forType: NSPasteboard.PasteboardType(SelfWriteMarker.type))
                guard pb.writeObjects(items) else { throw CocoaError(.fileWriteUnknown) }
                return pb.changeCount
            }
            if let text { item.setString(text, forType: .string) }
            for r in representations { item.setData(r.data, forType: NSPasteboard.PasteboardType(r.uti)) }
            if let imageFile {
                let data = try Data(contentsOf: imageFile)
                let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
                item.setData(data, forType: isPNG ? .png : NSPasteboard.PasteboardType(UTType.jpeg.identifier))
                if let img = NSImage(data: data), let tiff = img.tiffRepresentation { item.setData(tiff, forType: .tiff) }
            }
            guard pb.writeObjects([item]) else { throw CocoaError(.fileWriteUnknown) }
            return pb.changeCount
        }
    }
}

/// Runs `body` on the main thread. If already on main, runs inline (never `sync` onto ourselves, C39).
func onMain<T>(_ body: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try body() }
    return try DispatchQueue.main.sync(execute: body)
}

/// Clipboard privacy state (macOS 15.4+, F4). "Denied" must be distinguishable from "empty" (C13).
public enum PasteboardAccess: String, Sendable {
    case allowed = "alwaysAllow", ask = "ask", denied = "alwaysDeny", systemDefault = "default", unknown

    public static func current() -> PasteboardAccess {
        onMain {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow: .allowed
            case .ask: .ask
            case .alwaysDeny: .denied
            case .default: .systemDefault
            @unknown default: .unknown
            }
        }
    }
}

public struct FrontmostApp {
    @MainActor public static func current() -> SourceApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return SourceApp(bundleID: app.bundleIdentifier, name: app.localizedName)
    }
}
