import AppKit
import SwiftUI
import MXErgoCore

@main
struct MXErgoControllerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        ControllerLaunch.termination = { model.requestTermination() }
        ControllerLaunch.bootstrap = {
            ControllerWindowPresenter.shared.showOnceOnLaunch(model: model)
            model.bootstrapOnLaunch()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ControllerStatusMenu(model: model)
                .onAppear {
                    ControllerLaunch.bootstrap?()
                }
        } label: {
            Label("MX Ergo Controller", systemImage: model.menuBarIcon)
                .onAppear {
                    ControllerLaunch.bootstrap?()
                }
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
enum ControllerLaunch {
    static var bootstrap: (() -> Void)?
    static var termination: (() -> ApplicationTerminationDecision)?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch ControllerLaunch.termination?() ?? .cancel {
        case .terminateNow: return .terminateNow
        case .terminateLater: return .terminateLater
        case .cancel: return .terminateCancel
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ControllerLaunch.bootstrap?()
    }
}

private struct ControllerWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            ObserverMenuView(model: model)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 390, minHeight: 560)
    }
}

private struct ControllerStatusMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button("Open MX Ergo Controller…") {
            showControllerWindow()
        }

        Divider()

        if let message = model.terminationStatusText { Text(message) }
        Text(connectionStatusText)
        if !model.inputMonitoringGranted {
            Button("Grant Input Monitoring…") {
                model.openInputMonitoringSettings()
            }
        }
        if let report = model.lastReport {
            Text("HID reports: \(report.count)")
        } else {
            Text("HID reports: none yet")
        }
        if let intent = model.lastIntent {
            Text("Last preview: \(intent.name)")
        }
        Text(model.eventLayerEnabled
            ? "Button remapping active. Keep BetterTouchTool quit to avoid duplicate actions."
            : "Button remapping inactive. Open the controller to enable it.")

        if model.status == .stopped {
            Button("Start observer") {
                model.start()
                showControllerWindow()
            }
            .disabled(model.runtimeOwnerBlocksRestart || model.isTerminating)
        } else {
            Button("Stop observer") {
                model.stop()
            }
            .disabled(model.firmwareMigrationCommitInProgress || model.isTerminating)
        }

        Divider()

        Button("Quit") {
            model.quit()
        }
    }

    private var connectionStatusText: String {
        if model.status == .stopped {
            return "Observer stopped"
        }

        if model.devices.isEmpty {
            return "Waiting for MX Ergo"
        }

        return "MX Ergo connected"
    }

    private func showControllerWindow() {
        ControllerWindowPresenter.shared.show(model: model)
    }
}

@MainActor
private final class ControllerWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = ControllerWindowPresenter()

    private var windowController: NSWindowController?
    private var didAutoPresent = false

    func showOnceOnLaunch(model: AppModel) {
        guard !didAutoPresent else { return }
        didAutoPresent = true
        show(model: model)
    }

    func show(model: AppModel) {
        if windowController == nil {
            let hostingController = NSHostingController(
                rootView: ControllerWindow(model: model)
            )
            let window = NSWindow(contentViewController: hostingController)
            window.title = "MX Ergo Controller"
            window.styleMask = [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
            ]
            window.setContentSize(NSSize(width: 420, height: 820))
            window.minSize = NSSize(width: 390, height: 560)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("MXErgoControllerWindow")
            window.center()
            window.delegate = self
            windowController = NSWindowController(window: window)
        }

        guard let window = windowController?.window else {
            return
        }

        windowController?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
