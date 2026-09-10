import AppKit
import SwiftUI

/// Displays completed audio updates only; this presenter cannot change audio
/// or device settings. Its panel never takes focus or intercepts pointer input.
@MainActor
final class AudioFeedbackPresenter {
    private let state = AudioFeedbackState()
    private var panel: AudioFeedbackPanel?
    private var dismissal: Task<Void, Never>?

    func receive(_ status: AudioExecutionStatus) {
        switch status {
        case let .volumeAdjusting(currentPercent, _):
            show(.volume(min(100, max(0, currentPercent))))
        case let .volumeChanged(percent):
            show(.volume(min(100, max(0, percent))))
        case let .muteChanged(isMuted):
            show(.mute(isMuted))
        case .disabled, .failed:
            hide()
        case .ready:
            break // Preparing audio is not a user adjustment.
        }
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
    }

    private func show(_ value: AudioFeedbackValue) {
        dismissal?.cancel()
        state.value = value
        state.opacity = 1
        let panel = panel ?? makePanel()
        // Follow the pointing device onto its display without activating this app.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.minY + min(80, frame.height * 0.1)
            ))
        }
        panel.orderFrontRegardless()
        dismissal = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(1500))
            } catch { return }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // Cancellation of an older timer must not hide a newer update.
            withAnimation(.easeOut(duration: 0.2)) {
                self.state.opacity = 0
            }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch { return }
            guard !Task.isCancelled else { return }
            self.hide()
        }
    }

    private func makePanel() -> AudioFeedbackPanel {
        let panel = AudioFeedbackPanel(
            contentRect: NSRect(x: 0, y: 0, width: 264, height: 104),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: AudioFeedbackView(state: state))
        self.panel = panel
        return panel
    }
}

private final class AudioFeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum AudioFeedbackValue {
    case volume(Int)
    case mute(Bool)
}

@MainActor
private final class AudioFeedbackState: ObservableObject {
    @Published var value: AudioFeedbackValue = .volume(0)
    @Published var opacity = 1.0
}

private struct AudioFeedbackView: View {
    @ObservedObject var state: AudioFeedbackState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state.value {
            case let .volume(percent):
                HStack(spacing: 10) {
                    Image(systemName: percent == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 24)
                    Text("Volume")
                    Spacer()
                    Text("\(percent)%").monospacedDigit()
                }
                // Native progress indicators animate independently and can trail
                // rapid wheel updates. Draw the reported level directly.
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.12))
                        Capsule().fill(.primary.opacity(0.65))
                            .frame(width: geometry.size.width * Double(percent) / 100)
                    }
                }
                .frame(height: 7)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Volume")
                .accessibilityValue("\(percent) percent")
            case let .mute(isMuted):
                HStack(spacing: 14) {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.title2)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isMuted ? "Muted" : "Unmuted")
                        Text(isMuted ? "Sound off" : "Sound on")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .font(.system(.body, design: .rounded, weight: .semibold))
        .padding(22)
        .frame(width: 264, height: 104)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
        }
        .opacity(state.opacity)
    }
}
