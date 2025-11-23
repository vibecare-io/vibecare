//
//  SVGIconPickerView.swift
//  vibecare
//
//  Created by Claude Code on 2025-11-06.
//

import SwiftUI

/// Mac-style icon picker for selecting bundled SVG icons
struct SVGIconPickerView: View {
  @ObservedObject var iconManager: SVGIconManager
  @Binding var selectedIconId: String?
  var onSelect: (SVGIcon) -> Void
  var onDismiss: () -> Void

  @State private var searchQuery: String = ""
  @State private var selectedCategory: IconCategory?

  // Compact grid: 40×40pt cells, 8 columns (more like macOS emoji picker)
  private let gridColumns = [
    GridItem(.adaptive(minimum: 40), spacing: 6)
  ]

  var body: some View {
    VStack(spacing: 0) {
      // Header (compact)
      header
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

      Divider()

      // Search bar (compact)
      searchBar
        .padding(.horizontal, 10)
        .padding(.vertical, 6)

      // Category tabs (compact)
      if iconManager.isLoaded && !iconManager.icons.isEmpty {
        categoryTabs
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
      }

      Divider()

      // Icon grid (compact)
      ScrollView {
        if iconManager.isLoaded {
          if filteredIcons.isEmpty {
            emptyState
          } else {
            iconGrid
              .padding(8)
          }
        } else if let error = iconManager.loadError {
          errorState(error)
        } else {
          loadingState
        }
      }
      .frame(height: 320)
    }
    .frame(width: 350)
    .background(Color(NSColor.windowBackgroundColor))
    .task {
      // Load icons from backend if not already loaded
      print("🔍 [SVGIconPickerView] .task triggered")
      print("🔍 [SVGIconPickerView] iconManager.isLoaded = \(iconManager.isLoaded)")
      print(
        "🔍 [SVGIconPickerView] iconManager.loadError = \(iconManager.loadError?.localizedDescription ?? "nil")"
      )
      print("🔍 [SVGIconPickerView] iconManager.icons.count = \(iconManager.icons.count)")

      if !iconManager.isLoaded && iconManager.loadError == nil {
        print("🔍 [SVGIconPickerView] Calling iconManager.loadIcons()...")
        try? await iconManager.loadIcons()
        print("🔍 [SVGIconPickerView] After loadIcons: icons.count = \(iconManager.icons.count)")
      } else {
        print("🔍 [SVGIconPickerView] Skipping load: already loaded or has error")
      }
    }
  }

  // MARK: - Private Views

  private var header: some View {
    HStack {
      Text("Choose an Icon")
        .font(.subheadline)
        .fontWeight(.medium)

      Spacer()

      Button(action: onDismiss) {
        Image(systemName: "xmark.circle.fill")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
      .help("Close")
    }
  }

  private var searchBar: some View {
    HStack(spacing: 4) {
      Image(systemName: "magnifyingglass")
        .font(.caption)
        .foregroundColor(.secondary)

      TextField("Search...", text: $searchQuery)
        .textFieldStyle(.plain)
        .font(.caption)

      if !searchQuery.isEmpty {
        Button(action: { searchQuery = "" }) {
          Image(systemName: "xmark.circle.fill")
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(Color(NSColor.controlBackgroundColor))
    .cornerRadius(4)
  }

  private var categoryTabs: some View {
    HStack(spacing: 4) {
      // "All" tab
      categoryTab(title: "All", category: nil, count: iconManager.icons.count)

      ForEach(iconManager.availableCategories()) { category in
        categoryTab(
          title: category.displayName,
          category: category,
          count: iconManager.icons(for: category).count
        )
      }

      Spacer()
    }
  }

  private func categoryTab(title: String, category: IconCategory?, count: Int) -> some View {
    Button(action: { selectedCategory = category }) {
      VStack(spacing: 1) {
        if let cat = category {
          // Icon only for categories (cleaner)
          Image(systemName: cat.symbolName)
            .font(.caption)
        } else {
          // "All" tab
          Text("All")
            .font(.caption2)
            .fontWeight(.medium)
        }
        // Count below icon
        Text("\(count)")
          .font(.caption2)
          .foregroundColor(.secondary)
      }
      .frame(minWidth: 32)
      .padding(.horizontal, 4)
      .padding(.vertical, 4)
      .background(selectedCategory == category ? Color.accentColor.opacity(0.15) : Color.clear)
      .cornerRadius(4)
      .overlay(
        RoundedRectangle(cornerRadius: 4)
          .stroke(selectedCategory == category ? Color.accentColor : Color.clear, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .help(title)  // Show full category name on hover
  }

  private var iconGrid: some View {
    LazyVGrid(columns: gridColumns, spacing: 6) {
      ForEach(filteredIcons) { icon in
        SVGIconCell(
          icon: icon,
          isSelected: selectedIconId == icon.id,
          onTap: {
            selectedIconId = icon.id
            onSelect(icon)
            // Auto-dismiss after selection
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
              onDismiss()
            }
          }
        )
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 36))
        .foregroundColor(.secondary)

      Text("No icons found")
        .font(.subheadline)
        .fontWeight(.medium)
        .foregroundColor(.secondary)

      if !searchQuery.isEmpty {
        VStack(spacing: 8) {
          Text("Try a different search term")
            .font(.caption)
            .foregroundColor(.secondary)

          // Clickable link to SVG Repo
          Button(action: {
            let searchTerm =
              searchQuery.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
              ?? searchQuery
            if let url = URL(string: "https://www.svgrepo.com/vectors/\(searchTerm)/") {
              NSWorkspace.shared.open(url)
            }
          }) {
            HStack(spacing: 4) {
              Image(systemName: "arrow.up.forward.square")
                .font(.caption)
              Text("Search '\(searchQuery)' on SVG Repo")
                .font(.caption)
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.1))
            .cornerRadius(6)
          }
          .buttonStyle(.plain)
        }
      } else {
        Text("Try searching or browsing by category")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  private func errorState(_ error: Error) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 36))
        .foregroundColor(.orange)

      Text("Failed to load icons")
        .font(.subheadline)
        .fontWeight(.medium)

      Text(error.localizedDescription)
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)

      VStack(spacing: 8) {
        Button("Retry") {
          Task {
            await iconManager.reload()
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)

        // Helpful link to download more icons
        Button(action: {
          if let url = URL(string: "https://www.svgrepo.com/") {
            NSWorkspace.shared.open(url)
          }
        }) {
          HStack(spacing: 4) {
            Image(systemName: "arrow.down.circle")
              .font(.caption)
            Text("Download icons from SVG Repo")
              .font(.caption)
          }
          .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
      }
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  private var loadingState: some View {
    VStack(spacing: 12) {
      ProgressView()
        .scaleEffect(0.8)

      Text("Loading icons...")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  // MARK: - Filtering Logic

  private var filteredIcons: [SVGIcon] {
    var icons = iconManager.icons

    // Filter by category
    if let category = selectedCategory {
      icons = icons.filter { $0.category == category }
    }

    // Filter by search query
    if !searchQuery.isEmpty {
      icons = icons.filter { $0.matches(searchQuery: searchQuery) }
    }

    return icons
  }
}

// MARK: - Previews

#Preview("Icon Picker") {
  SVGIconPickerView(
    iconManager: .shared,
    selectedIconId: .constant("meditation"),
    onSelect: { icon in
      print("Selected: \(icon.name)")
    },
    onDismiss: {}
  )
}

#Preview("Icon Picker - Empty") {
  SVGIconPickerView(
    iconManager: SVGIconManager.mock(withIcons: []),
    selectedIconId: .constant(nil),
    onSelect: { _ in },
    onDismiss: {}
  )
}

#if DEBUG
  #Preview("Icon Picker - With Sample Icons") {
    SVGIconPickerView(
      iconManager: SVGIconManager.mock(withIcons: SVGIconManager.sampleIcons),
      selectedIconId: .constant("water"),
      onSelect: { icon in
        print("Selected: \(icon.name)")
      },
      onDismiss: {}
    )
  }
#endif
