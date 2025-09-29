import SwiftUI

struct EditableDescription: View {
    @Binding var text: String
    let placeholder: String
    let onSave: (String) -> Void
    var forceEndEditing: Bool = false

    @State private var isEditing = false
    @State private var editingText = ""
    @State private var saveWorkItem: DispatchWorkItem?
    @FocusState private var isTextFieldFocused: Bool
    @State private var isSaving = false
    @State private var showSavedIndicator = false

    private let autosaveDelay: TimeInterval = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)

            if isEditing {
                TextEditor(text: $editingText)
                    .frame(minHeight: 80, maxHeight: 150)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor, lineWidth: 2)
                    )
                    .focused($isTextFieldFocused)
                    .onChange(of: editingText) { _, newValue in
                        scheduleAutosave(newValue)
                    }
                    .onKeyPress { press in
                        if press.key == .escape {
                            cancelEditing()
                            return .handled
                        }
                        else if press.key == .return  && press.modifiers.contains(.shift) {
                            finishEditing()
                            return .handled
                        }
                        return .ignored
                    }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .italic()
                    } else {
                        Text(text)
                            .font(.body)
                            .foregroundColor(.secondary)
                    }

                    // Save status indicator
                    if isSaving {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Saving...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } else if showSavedIndicator {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption2)
                            Text("Saved")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    startEditing()
                }
                .help("Double-click to edit")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSaving)
        .animation(.easeInOut(duration: 0.2), value: showSavedIndicator)
        .onTapGesture {
            if isEditing {
                finishEditing()
            }
        }
        .onChange(of: text) { _, newValue in
            // If text changed from outside while editing, cancel edit
            if isEditing && editingText != newValue {
                cancelEditing()
            }
        }
        .onChange(of: forceEndEditing) { _, shouldEnd in
            // Force end editing when switching routines
            if shouldEnd && isEditing {
                finishEditing()
            }
        }
    }

    private func startEditing() {
        editingText = text
        isEditing = true

        // Small delay to ensure the text editor is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isTextFieldFocused = true
        }
    }

    private func finishEditing() {
        guard isEditing else { return }

        // Cancel any pending autosave
        saveWorkItem?.cancel()

        // Save immediately if text changed
        if editingText != text {
            saveChanges(editingText)
        }

        isEditing = false
        isTextFieldFocused = false
    }

    private func cancelEditing() {
        saveWorkItem?.cancel()
        editingText = text
        isEditing = false
        isTextFieldFocused = false
    }

    private func scheduleAutosave(_ newValue: String) {
        // Cancel previous autosave
        saveWorkItem?.cancel()

        // Schedule new autosave
        let workItem = DispatchWorkItem {
            if newValue != text {
                saveChanges(newValue)
            }
        }
        saveWorkItem = workItem

        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveDelay, execute: workItem)
    }

    private func saveChanges(_ newValue: String) {
        guard newValue != text else { return }

        isSaving = true
        showSavedIndicator = false

        // Update the binding immediately for responsive UI
        text = newValue

        // Call the save handler
        onSave(newValue)

        // Show saving feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isSaving = false
            showSavedIndicator = true

            // Hide saved indicator after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                showSavedIndicator = false
            }
        }
    }
}

#Preview {
    @Previewable @State var description = "Save your eyes with the 20-20-20 rule - every 20 minutes, look at something 20 feet away for 20 seconds"

    return VStack(spacing: 20) {
        EditableDescription(
            text: $description,
            placeholder: "Enter a description for your routine"
        ) { newDescription in
            print("Saving description: \(newDescription)")
        }

        Text("Current description: \(description)")
            .font(.caption)
            .foregroundColor(.secondary)

        Spacer()
    }
    .padding()
    .frame(width: 400, height: 300)
}
