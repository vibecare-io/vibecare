import SwiftUI

/// Card-less content for a BFRB detection alert. Mirrors VibeNotify's
/// `SVGNotificationView` (the schedule-notification look): a large icon, bold
/// title, and nudge floating directly on the blurred backdrop with **no card
/// background**. Rendered via `OverlayWindowManager.show(content:)` from
/// `VibeNotifyConfig.showBFRBAlert`, since the standard builder path always
/// draws an opaque card.
struct BFRBAlertView: View {
    let behavior: BFRBBehavior
    let count: Int
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var scale: CGFloat = 0.85
    @State private var opacity: Double = 0.0

    /// Light text on dark mode, dark text on light mode — same rule
    /// SVGNotificationView uses so the text reads against the blur.
    private var useLightText: Bool { colorScheme == .dark }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: behavior.alertIcon)
                .font(.system(size: 64))
                .foregroundStyle(useLightText ? Color.white : Color.primary)
                .shadow(color: (useLightText ? Color.white : Color.black).opacity(0.35), radius: 12)
                .scaleEffect(scale)
                .opacity(opacity)

            Text(behavior.label)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(useLightText ? Color.white : Color.primary)
                .multilineTextAlignment(.center)

            Text("\(behavior.nudge)\n\(VibeNotifyConfig.ordinal(count)) nudge today")
                .font(.body)
                .foregroundStyle(useLightText ? Color.white.opacity(0.9) : Color.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                scale = 1.0
                opacity = 1.0
            }
        }
    }
}
