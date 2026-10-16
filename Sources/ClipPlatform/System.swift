import ClipCore
import Foundation

public enum HardwareProbe {
    public static var memoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }

    public static var cpuBrand: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    public static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
}

extension PlatformServices {
    /// The real platform: Vision OCR, Apple translation, system pasteboard, Core ML providers.
    public static func system(home: AppHome) -> PlatformServices {
        PlatformServices(
            ocr: VisionOCR(),
            translator: AppleTranslator(),
            pasteboard: SystemPasteboardWriter(),
            makeProvider: { manifest in try ProviderRegistry.make(manifest, home: home) },
            memoryGB: { HardwareProbe.memoryGB })
    }
}
