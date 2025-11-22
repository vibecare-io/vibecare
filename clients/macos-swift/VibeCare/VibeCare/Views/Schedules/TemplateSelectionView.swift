import SwiftUI

struct TemplateSelectionView: View {
    @ObservedObject var templateService: ScheduleTemplateService
    @Binding var selectedTemplate: RoutineScheduleTemplate?
    let onNext: () -> Void
    let onCancel: () -> Void

    @State private var searchText = ""
    @State private var hoveredTemplateId: String?

    private var filteredTemplates: [RoutineScheduleTemplate] {
        let templates = templateService.templates
        if searchText.isEmpty {
            return templates
        }
        let lowercased = searchText.lowercased()
        return templates.filter {
            $0.routineName.lowercased().contains(lowercased) ||
            $0.scheduleName.lowercased().contains(lowercased) ||
            $0.routineDescription.lowercased().contains(lowercased)
        }
    }

    private var templatesByCategory: [TemplateCategory: [RoutineScheduleTemplate]] {
        Dictionary(grouping: filteredTemplates) { $0.category }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Loading or content
            if templateService.isLoading {
                Spacer()
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading templates from backend...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else if let error = templateService.error {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    Text("Failed to load templates")
                        .font(.headline)
                    Text(error.localizedDescription)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task {
                            try? await templateService.loadTemplates()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(40)
                Spacer()
            } else {
                // Search bar
                searchBar
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)

                Divider()

                // Template grid
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(TemplateCategory.allCases, id: \.self) { category in
                            if let templates = templatesByCategory[category], !templates.isEmpty {
                                categorySection(category: category, templates: templates)
                            }
                        }
                    }
                    .padding(20)
                }
            }

            Divider()

            // Footer with actions
            footerView
        }
        .frame(minWidth: 700, minHeight: 600)
        .task {
            if templateService.templates.isEmpty {
                try? await templateService.loadTemplates()
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose a Template")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Start with a pre-configured routine and schedule")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("Search templates...", text: $searchText)
                .textFieldStyle(.plain)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Category Section

    private func categorySection(
        category: TemplateCategory,
        templates: [RoutineScheduleTemplate]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Category header
            HStack(spacing: 8) {
                Image(systemName: category.icon)
                    .font(.headline)
                    .foregroundColor(.accentColor)

                Text(category.rawValue)
                    .font(.headline)
                    .fontWeight(.semibold)

                Text("\(templates.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())

                Spacer()
            }

            // Template grid
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ],
                spacing: 16
            ) {
                ForEach(templates) { template in
                    templateCard(template)
                }
            }
        }
    }

    // MARK: - Template Card

    private func templateCard(_ template: RoutineScheduleTemplate) -> some View {
        let isSelected = selectedTemplate?.id == template.id
        let isHovered = hoveredTemplateId == template.id

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTemplate = template
            }
            // Auto-advance after short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                onNext()
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                // Icon and color indicator
                HStack {
                    ZStack {
                        Circle()
                            .fill(Color(template.routineColor).opacity(0.15))
                            .frame(width: 48, height: 48)

                        Image(systemName: template.routineIcon)
                            .font(.system(size: 22))
                            .foregroundColor(Color(template.routineColor))
                    }

                    Spacer()

                    // Selected indicator
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.accentColor)
                    }
                }

                // Routine name
                Text(template.routineName)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                // Schedule description
                Text(template.scheduleDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                Spacer()

                // Frequency badge
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)

                    Text(frequencyLabel(template.rruleString))
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
            }
            .padding(16)
            .frame(height: 180)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected
                            ? Color.accentColor
                            : (isHovered ? Color.secondary.opacity(0.3) : Color.secondary.opacity(0.1)),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .shadow(
                color: isSelected ? Color.accentColor.opacity(0.2) : Color.clear,
                radius: isSelected ? 8 : 0
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredTemplateId = hovering ? template.id : nil
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Spacer()

            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.escape, modifiers: [])

            Button("Next") {
                onNext()
            }
            .keyboardShortcut(.return, modifiers: [])
            .buttonStyle(.borderedProminent)
            .disabled(selectedTemplate == nil)
        }
        .padding(20)
    }

    // MARK: - Helpers

    private func frequencyLabel(_ rruleString: String) -> String {
        if rruleString.contains("FREQ=DAILY") {
            return "Daily"
        } else if rruleString.contains("FREQ=WEEKLY") {
            if rruleString.contains("BYDAY=MO,TU,WE,TH,FR") {
                return "Weekdays"
            }
            return "Weekly"
        } else if rruleString.contains("FREQ=MONTHLY") {
            if rruleString.contains("INTERVAL=3") {
                return "Quarterly"
            }
            return "Monthly"
        } else if rruleString.contains("FREQ=YEARLY") {
            return "Yearly"
        } else if rruleString.contains("FREQ=HOURLY") {
            if let interval = rruleString.range(of: "INTERVAL=(\\d+)", options: .regularExpression) {
                let intervalStr = String(rruleString[interval]).replacingOccurrences(of: "INTERVAL=", with: "")
                return "Every \(intervalStr)h"
            }
            return "Hourly"
        } else if rruleString.contains("FREQ=MINUTELY") {
            if let interval = rruleString.range(of: "INTERVAL=(\\d+)", options: .regularExpression) {
                let intervalStr = String(rruleString[interval]).replacingOccurrences(of: "INTERVAL=", with: "")
                return "Every \(intervalStr)m"
            }
            return "Every minute"
        }
        return "Custom"
    }
}

// MARK: - Preview

#Preview {
    TemplateSelectionView(
        templateService: ScheduleTemplateService(),
        selectedTemplate: .constant(nil),
        onNext: {},
        onCancel: {}
    )
}
