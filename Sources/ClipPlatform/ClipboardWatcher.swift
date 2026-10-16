import AppKit
import ClipCore

/// Polls `changeCount` (the only change signal macOS offers; reading it never prompts).
/// Order per change: types → preflight (may skip without reading) → read snapshot → ingest.
@MainActor
public final class ClipboardWatcher {
    private let service: ClipService
    private var timer: Timer?
    private var lastChangeCount: Int
    private var inFlight = false
    public private(set) var lastPoll: Date?
    public private(set) var accessDeniedObserved = false
    public var onAccessDenied: (() -> Void)?

    public init(service: ClipService) {
        self.service = service
        // Do not back-fill whatever was on the pasteboard before launch (state-model 4.4).
        lastChangeCount = PasteboardReader.changeCount
    }

    public func start(interval: TimeInterval = 0.25) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = interval / 4
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        lastPoll = Date()
        let cc = PasteboardReader.changeCount
        guard cc != lastChangeCount, !inFlight else { return }
        lastChangeCount = cc
        if PasteboardAccess.current() == .denied {
            accessDeniedObserved = true
            onAccessDenied?()
            Task { await service.recordSkip(.accessDenied) }
            return
        }
        let types = PasteboardReader.types()
        let front = FrontmostApp.current()
        inFlight = true
        Task { [service] in
            defer { Task { @MainActor in self.inFlight = false } }
            let pre = await service.preflight(types: types, changeCount: cc, frontmost: front)
            guard pre == .read else { return }
            // R15 / I7: read only if the pasteboard still holds the change that was judged. Otherwise the
            // types / frontmost app / exclusion decision belong to older content; the next poll handles it.
            guard let snapshot = await MainActor.run(body: { PasteboardReader.changeCount == cc ? PasteboardReader.snapshot() : nil }),
                  snapshot.changeCount == cc else {
                Log.shared.event("capture.superseded", ["change": .int(Int64(cc))])
                return
            }
            if snapshot.types.isEmpty && !types.isEmpty {
                // Types were visible but content was not: access was refused at read time (A1).
                await service.recordSkip(.accessDenied)
                return
            }
            let ctx = await service.captureContext(frontmost: front)
            _ = await service.ingest(snapshot, context: ctx)
        }
    }
}
