//
//  SVGIconCell.swift
//  vibecare
//
//  Created by Claude Code on 2025-11-06.
//

import SwiftUI
import SVGView

/// Individual cell for displaying an SVG icon in the picker grid
struct SVGIconCell: View {
    let icon: SVGIcon
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onTap) {
            // Icon preview only (no label - more compact like emoji picker)
            iconPreview
                .frame(width: 40, height: 40)
                .background(iconBackground)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(borderColor, lineWidth: borderWidth)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(iconTooltip)
    }

    // MARK: - Private Views

    private var iconPreview: some View {
        Group {
            if let path = icon.bundlePath, FileManager.default.fileExists(atPath: path) {
                SVGView(contentsOf: URL(fileURLWithPath: path))
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundColor(.gray)
            }
        }
    }

    private var iconBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.2)
        } else if isHovered {
            return Color.gray.opacity(0.1)
        } else {
            return Color.clear
        }
    }

    private var borderColor: Color {
        if isSelected {
            return Color.accentColor
        } else if isHovered {
            return Color.gray.opacity(0.3)
        } else {
            return Color.clear
        }
    }

    private var borderWidth: CGFloat {
        isSelected ? 2 : 1
    }

    private var iconTooltip: String {
        var tooltip = icon.name
        if !icon.keywords.isEmpty {
            tooltip += "\n" + icon.keywords.prefix(3).joined(separator: ", ")
        }
        return tooltip
    }
}

// MARK: - Previews

#Preview("Single Icon") {
    SVGIconCell(
        icon: SVGIcon(
            id: "meditation",
            name: "Meditation",
            category: .health,
            filename: "meditation.svg",
            keywords: ["meditation", "mindfulness"]
        ),
        isSelected: false,
        onTap: {}
    )
    .padding()
}

#Preview("Selected Icon") {
    SVGIconCell(
        icon: SVGIcon(
            id: "water",
            name: "Water",
            category: .health,
            filename: "water.svg",
            keywords: ["water", "hydration"]
        ),
        isSelected: true,
        onTap: {}
    )
    .padding()
}

#Preview("Grid of Icons") {
    LazyVGrid(columns: [
        GridItem(.adaptive(minimum: 70), spacing: 12)
    ], spacing: 12) {
        ForEach(SVGIconManager.sampleIcons) { icon in
            SVGIconCell(
                icon: icon,
                isSelected: icon.id == "meditation",
                onTap: {}
            )
        }
    }
    .padding()
    .frame(width: 400)
}
