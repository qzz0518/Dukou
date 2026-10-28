import AppKit

/// A deliberately tiny containing app for generated Share extensions.
///
/// The executable has no work of its own. Launching it makes macOS index the
/// `.appex` bundles beside it; the extension starts the real Dukou app through
/// `DKHostBundleIdentifier`.
final class ShareTargetsHostApplication: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApp.terminate(nil)
        }
    }
}

let application = NSApplication.shared
let delegate = ShareTargetsHostApplication()
application.delegate = delegate
application.run()
