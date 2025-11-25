//
//  TemplateIconView.swift
//  vibecare
//

import SwiftUI
import SVGView

/// Displays an SVG icon from the backend for template cards
struct TemplateIconView: View {
    let iconId: String?
    let backgroundColor: Color
    let size: CGFloat

    @State private var svgData: Data?
    @State private var isLoading: Bool = false
    @State private var loadError: Error?

    init(iconId: String?, backgroundColor: Color = Color.blue.opacity(0.15), size: CGFloat = 48) {
        self.iconId = iconId
        self.backgroundColor = backgroundColor
        self.size = size
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)
                .frame(width: size, height: size)

            iconContent
                .frame(width: size * 0.6, height: size * 0.6)
        }
        .task {
            await loadSVGData()
        }
    }

    @ViewBuilder
    private var iconContent: some View {
        if let data = svgData {
            SVGView(data: data)
        } else if isLoading {
            ProgressView()
                .scaleEffect(0.5)
        } else if loadError != nil || iconId == nil {
            Image(systemName: "photo")
                .font(.system(size: size * 0.4))
                .foregroundColor(.gray)
        } else {
            Image(systemName: "photo")
                .font(.system(size: size * 0.4))
                .foregroundColor(.gray)
        }
    }

    private func loadSVGData() async {
        guard let iconId = iconId, !iconId.isEmpty else { return }
        guard svgData == nil, !isLoading else { return }

        let urlString = NetworkConfiguration.buildIconURL(iconId: iconId)
        guard let iconURL = URL(string: urlString) else {
            return
        }

        isLoading = true
        loadError = nil

        do {
            let (data, _) = try await URLSession.shared.data(from: iconURL)
            await MainActor.run {
                self.svgData = data
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.loadError = error
                self.isLoading = false
            }
        }
    }
}

#Preview("With Icon") {
    TemplateIconView(
        iconId: "water-bottle",
        backgroundColor: Color.blue.opacity(0.15),
        size: 48
    )
    .padding()
}

#Preview("No Icon") {
    TemplateIconView(
        iconId: nil,
        backgroundColor: Color.gray.opacity(0.15),
        size: 48
    )
    .padding()
}
