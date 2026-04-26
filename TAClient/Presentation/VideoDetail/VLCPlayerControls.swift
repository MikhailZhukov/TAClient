import SwiftUI

@Observable
final class VLCPlayerState {
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var controlsVisible = true
}

struct VLCPlayerControls: View {
    let state: VLCPlayerState
    let onPlayPause: () -> Void
    let onSeek: (Double) -> Void
    let onToggleFullScreen: () -> Void
    let onTapToggle: () -> Void

    @State private var isSeeking = false
    @State private var seekValue: Double = 0

    var body: some View {
        ZStack {
            // Tap target — covers full area, passes through to controls when visible
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onTapToggle() }

            if state.controlsVisible {
                VStack {
                    Spacer()
                    controlsBar
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.controlsVisible)
    }

    private var controlsBar: some View {
        VStack(spacing: 8) {
            Slider(
                value: isSeeking ? $seekValue : .constant(state.currentTime),
                in: 0...max(state.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        isSeeking = true
                        seekValue = state.currentTime
                    } else {
                        isSeeking = false
                        onSeek(seekValue)
                    }
                }
            )

            HStack {
                Text(formatTime(isSeeking ? seekValue : state.currentTime))
                    .font(.caption)
                    .monospacedDigit()

                Spacer()

                Button(action: onPlayPause) {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .accessibilityLabel(state.isPlaying ? String(localized: "vlc_pause") : String(localized: "vlc_play"))

                Spacer()

                Text(formatTime(state.duration))
                    .font(.caption)
                    .monospacedDigit()

                Button(action: onToggleFullScreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
                .accessibilityLabel(String(localized: "vlc_fullscreen"))
                .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .foregroundStyle(.white)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

}
