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
            model.bootstrapOnLaunch()
        }
        ControllerLaunch.presentOnLaunch = { reason in
            ControllerWindowPresenter.shared.presentOnLaunch(model: model, reason: reason)
        }
        ControllerLaunch.openController = {
            ControllerWindowPresenter.shared.show(model: model)
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
    static var presentOnLaunch: ((ControllerLaunchPresentation.Reason) -> Void)?
    static var openController: (() -> Void)?
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
        // Capture before bootstrap can request a permission or process another
        // event. Registration alone says nothing about why this launch happened.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let isLogin = event?.eventClass == kCoreEventClass
            && event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
        let reason: ControllerLaunchPresentation.Reason = isLogin ? .loginItem : .otherOrUnknown
        ControllerLaunch.bootstrap?()
        ControllerLaunch.presentOnLaunch?(reason)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        ControllerLaunch.openController?()
        return false
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
        Text("Precision audio: \(model.precisionSummary)")
        if model.savedPrecisionNeedsReview {
            Text("Saved Precision state needs review. Open the controller for details.")
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

    private var connectionStatusText: String { model.connectionSummary }

    private func showControllerWindow() {
        ControllerWindowPresenter.shared.show(model: model)
    }
}

@MainActor
private final class ControllerWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = ControllerWindowPresenter()

    private var windowController: NSWindowController?
    private var launchPresentation = ControllerLaunchPresentation()

    func presentOnLaunch(model: AppModel, reason: ControllerLaunchPresentation.Reason) {
        guard !model.isTerminating else { return }
        guard launchPresentation.shouldPresentOnLaunch(
            reason: reason,
            hasPresentedBefore: UserDefaults.standard.bool(
                forKey: ControllerLaunchPresentation.hasPresentedPreferenceKey
            ),
            needsAttention: model.launchNeedsAttention
        ) else { return }
        show(model: model)
    }

    func show(model: AppModel) {
        guard !model.isTerminating else { return }
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
        if window.isVisible {
            UserDefaults.standard.set(true, forKey: ControllerLaunchPresentation.hasPresentedPreferenceKey)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
