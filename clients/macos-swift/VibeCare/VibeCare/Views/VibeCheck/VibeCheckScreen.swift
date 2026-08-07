import SwiftUI

struct VibeCheckScreen: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.trianglebadge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.pink)
            Text("VibeCheck")
                .font(.title2).bold()
            Text("Camera preview coming next.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("VibeCheck")
    }
}
