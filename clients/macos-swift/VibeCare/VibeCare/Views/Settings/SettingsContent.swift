import SwiftUI

public struct SettingsContentView: View {
    @Binding var selectedCategory: SettingCategory?

    @State private var hoveredCategoryId: String?

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Settings Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Configure your VibeCare preferences")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Settings Categories
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 16) {
                    ForEach(SettingCategory.allCases) { category in
                        SettingCategoryCard(
                            category: category,
                            isSelected: selectedCategory == category,
                            isHovered: hoveredCategoryId == category.id,
                            onSelect: {
                                selectedCategory = category
                            }
                        )
                        .onHover { isHovered in
                            hoveredCategoryId = isHovered ? category.id : nil
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .navigationTitle("Settings")
    }
}

struct SettingCategoryCard: View {
    let category: SettingCategory
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: category.iconName)
                .font(.title)
                .foregroundColor(category.color)

            VStack(spacing: 4) {
                Text(category.title)
                    .font(.headline)

                Text(category.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : (isHovered ? Color.secondary.opacity(0.05) : Color(NSColor.controlBackgroundColor)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
        )
        .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

public struct SettingsView: View {
    public init() {}

    public var body: some View {
        SettingsContentView(selectedCategory: .constant(nil))
    }
}

#Preview {
    SettingsContentView(selectedCategory: .constant(nil))
}