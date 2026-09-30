import AppKit
import SwiftUI

@main
struct OmidiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Omidi", id: "main") {
            ContentView(c: delegate.controller, p: delegate.pairing)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = Controller()
    lazy var pairing = Pairing(controller: controller)

    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        trimMenuBar()
        quitCleanlyOnSignals()
        OuraTool.reapLeftovers { [controller] in controller.start() }
    }

    /// `kill`, logging out or a terminal closing: quit the normal way, which stops the ring first.
    private func quitCleanlyOnSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    /// SwiftUI rebuilds the menu bar now and then (for example when the window opens), so the
    /// trim is repeated whenever the app updates; it's a no-op once only the app menu is left.
    func applicationDidUpdate(_ notification: Notification) {
        trimMenuBar()
    }

    /// Keep only the app menu (About, Hide, Quit). File, Edit, View, Window and Help have
    /// nothing useful for a single window of controls.
    private func trimMenuBar() {
        guard let menu = NSApp.mainMenu, menu.items.count > 1 else { return }
        for item in menu.items.dropFirst().reversed() {
            menu.removeItem(item)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting waits for the ring to switch its stream off, or it would keep streaming.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.isRunning else { return .terminateNow }
        controller.stop { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
