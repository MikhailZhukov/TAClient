import SwiftUI

struct SplashView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Color.accentColor)

            Text("Tube Archivist")
                .font(.largeTitle)
                .fontWeight(.bold)

            ProgressView()
                .controlSize(.regular)

            Spacer()
        }
    }
}
