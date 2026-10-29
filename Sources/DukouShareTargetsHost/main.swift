import AppKit

/// The containing app of a generated 「发给 <app>」 entry.
///
/// It exists for its icon: the Share menu draws an entry with its containing
/// app's icon, so `DirectShareEntries` wraps each entry in one of these with
/// the target's icon. It has no work of its own and is never launched on
/// purpose; opened by hand, it quits.
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
