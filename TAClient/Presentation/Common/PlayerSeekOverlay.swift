import SwiftUI

/// Non-interactive visual feedback for double-tap seek.
/// Gesture detection happens inside the player views themselves.
struct PlayerSeekFeedbackOverlay: View {
    let seekInterval: Int
    let feedback: PlayerSeekFeedback?

    var body: some View {
        Group {
            if let feedback {
                HStack {
                    if feedback.direction == .backward {
                        seekIndicator(feedback)
                        Spacer()
                    } else {
                        Spacer()
                        seekIndicator(feedback)
                    }
                }
                .padding(.horizontal, 40)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func seekIndicator(_ feedback: PlayerSeekFeedback) -> some View {
        VStack(spacing: 4) {
            Image(systemName: feedback.direction == .backward
                  ? "gobackward.\(seekInterval)" : "goforward.\(seekInterval)")
                .font(.title)
            Text(feedback.direction == .backward ? "−\(seekInterval)s" : "+\(seekInterval)s")
                .font(.caption)
                .fontWeight(.semibold)
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(Circle().fill(.black.opacity(0.5)))
    }
}

struct PlayerSeekFeedback: Equatable {
    enum Direction { case forward, backward }
    let direction: Direction
    let id: UUID = UUID()
}
