import SwiftUI

struct FloatingActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))

                Text(title)
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.accentColor)
                    .shadow(
                        color: .black.opacity(0.2),
                        radius: isPressed ? 2 : 6,
                        x: 0,
                        y: isPressed ? 1 : 3
                    )
            )
            .scaleEffect(isPressed ? 0.95 : (isHovered ? 1.05 : 1.0))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .onLongPressGesture(
            minimumDuration: 0,
            maximumDistance: .infinity,
            pressing: { pressing in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isPressed = pressing
                }
            },
            perform: {}
        )
    }
}

struct FloatingActionButtonSmall: View {
    let systemImage: String
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color.accentColor)
                        .shadow(
                            color: .black.opacity(0.2),
                            radius: isPressed ? 1 : 4,
                            x: 0,
                            y: isPressed ? 0.5 : 2
                        )
                )
                .scaleEffect(isPressed ? 0.9 : (isHovered ? 1.1 : 1.0))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .onLongPressGesture(
            minimumDuration: 0,
            maximumDistance: .infinity,
            pressing: { pressing in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isPressed = pressing
                }
            },
            perform: {}
        )
    }
}

#Preview {
    VStack(spacing: 20) {
        FloatingActionButton(
            title: "Add Action",
            systemImage: "plus"
        ) {
            print("Add action tapped")
        }

        FloatingActionButtonSmall(systemImage: "plus") {
            print("Small add button tapped")
        }

        Spacer()
    }
    .padding()
    .frame(width: 300, height: 200)
}