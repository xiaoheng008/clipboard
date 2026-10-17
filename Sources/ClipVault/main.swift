import AppKit
import ClipCore

// Entry point: any argument → CLI (no UI); none → menu-bar app.
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--snapshot", arguments.count == 2 {
    // Offscreen UI snapshots need NSApplication's run loop (see SnapshotRunner).
    let app = NSApplication.shared
    let runner = SnapshotRunner(outDir: URL(fileURLWithPath: arguments[1]))
    app.delegate = runner
    app.setActivationPolicy(.prohibited)
    withExtendedLifetime(runner) { app.run() }
} else if !arguments.isEmpty {
    // The main queue keeps running (dispatchMain) so main-thread pasteboard work never waits on itself (C39).
    Task {
        let code = await CLI.run(arguments)
        exit(code)
    }
    dispatchMain()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
