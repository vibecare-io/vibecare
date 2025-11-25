//
//  TimezonePickerView.swift
//  vibecare
//
//  Created by Claude Code on 2025-11-24.
//

import SwiftUI

/// Mac-style timezone picker for selecting IANA timezones
struct TimezonePickerView: View {
    let selectedTimezone: String
    var onSelect: (String) -> Void

    @State private var searchQuery: String = ""
    @Environment(\.dismiss) private var dismiss

    // Popular timezones shown at top
    private let popularTimezones = [
        "America/Los_Angeles",
        "America/Denver",
        "America/Chicago",
        "America/New_York",
        "Europe/London",
        "Europe/Paris",
        "Europe/Berlin",
        "Asia/Tokyo",
        "Asia/Shanghai",
        "Asia/Dubai",
        "Australia/Sydney"
    ]

    // All available IANA timezones
    private var allTimezones: [String] {
        TimeZone.knownTimeZoneIdentifiers.sorted()
    }

    // Filtered timezones based on search
    private var filteredTimezones: [String] {
        if searchQuery.isEmpty {
            return allTimezones
        }
        return allTimezones.filter { timezone in
            timezone.localizedCaseInsensitiveContains(searchQuery) ||
            TimeZone(identifier: timezone)?.localizedName(for: .standard, locale: .current)?.localizedCaseInsensitiveContains(searchQuery) == true
        }
    }

    // Group timezones by region (America, Europe, Asia, etc.)
    private var groupedTimezones: [String: [String]] {
        Dictionary(grouping: filteredTimezones) { timezone in
            timezone.split(separator: "/").first.map(String.init) ?? "Other"
        }
    }

    private var sortedRegions: [String] {
        groupedTimezones.keys.sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            // Search bar
            searchBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

            // Timezone list
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Popular timezones section (only show if not searching)
                    if searchQuery.isEmpty {
                        popularSection
                        Divider()
                            .padding(.vertical, 8)
                    }

                    // All timezones grouped by region
                    ForEach(sortedRegions, id: \.self) { region in
                        Section {
                            ForEach(groupedTimezones[region] ?? [], id: \.self) { timezone in
                                timezoneRow(timezone)
                            }
                        } header: {
                            Text(region)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.controlBackgroundColor))
                        }
                    }
                }
            }

            Divider()

            // Footer with cancel button
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 500, height: 600)
    }

    private var header: some View {
        HStack {
            Image(systemName: "globe")
                .font(.title2)
                .foregroundColor(.blue)

            VStack(alignment: .leading) {
                Text("Select Timezone")
                    .font(.title3)
                    .fontWeight(.bold)

                Text("Choose your current timezone")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("Search timezones...", text: $searchQuery)
                .textFieldStyle(.plain)

            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }

    private var popularSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Popular Timezones")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))

            ForEach(popularTimezones, id: \.self) { timezone in
                timezoneRow(timezone)
            }
        }
    }

    private func timezoneRow(_ timezone: String) -> some View {
        Button(action: {
            onSelect(timezone)
        }) {
            HStack(spacing: 12) {
                // Checkmark for selected timezone
                Image(systemName: selectedTimezone == timezone ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selectedTimezone == timezone ? .blue : .secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    // Timezone display name
                    Text(TimeZone(identifier: timezone)?.localizedName(for: .standard, locale: .current) ?? timezone)
                        .font(.body)
                        .foregroundColor(.primary)

                    // Timezone identifier
                    Text(timezone)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospaced()
                }

                Spacer()

                // Current time in this timezone
                Text(currentTimeIn(timezone))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selectedTimezone == timezone ? Color.blue.opacity(0.1) : Color.clear)
    }

    private func currentTimeIn(_ timezoneIdentifier: String) -> String {
        guard let timezone = TimeZone(identifier: timezoneIdentifier) else {
            return ""
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = timezone
        return formatter.string(from: Date())
    }
}

#Preview {
    TimezonePickerView(
        selectedTimezone: "America/Los_Angeles",
        onSelect: { timezone in
            print("Selected: \(timezone)")
        }
    )
}
