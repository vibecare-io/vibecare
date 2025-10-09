import SwiftUI
import Combine

struct EditableTitle: View {
    @Binding var text: String
    var placeholder: String = "Enter name"
    var autoFocus: Bool = false
    var autoSelectText: String? = nil
    let onSave: (String) -> Void

    @State private var isEditing = false
    @State private var editingText = ""
    @State private var saveWorkItem: DispatchWorkItem?
    @FocusState private var isTextFieldFocused: Bool
    @State private var isSaving = false
    @State private var showSavedIndicator = false

    private let autosaveDelay: TimeInterval = 1.0

    var body: some View {
        HStack {
            if isEditing {
                TextField(placeholder, text: $editingText, onEditingChanged: { isEditing in
                    if isEditing && autoFocus, let autoSelectText = autoSelectText, editingText == autoSelectText {
                        // Select all text when starting to edit with specific text
                        DispatchQueue.main.async {
                            NSApp.keyWindow?.firstResponder?.selectAll(nil)
                        }
                    }
                })
                    .font(.title)
                    .fontWeight(.bold)
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        finishEditing()
                    }
                    .onChange(of: editingText) { _, newValue in
                        scheduleAutosave(newValue)
                    }
                    .onKeyPress(.escape) {
                        cancelEditing()
                        return .handled
                    }
            } else {
                Text(text)
                    .font(.title)
                    .fontWeight(.bold)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        startEditing()
                    }
                    .help("Double-click to edit")
            }

            Spacer()

            // Save status indicator
            if isSaving {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Saving...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if showSavedIndicator {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text("Saved")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSaving)
        .animation(.easeInOut(duration: 0.2), value: showSavedIndicator)
        .onTapGesture {
            if isEditing {
                finishEditing()
            }
        }
        .onAppear {
            // Auto-start editing if autoFocus is true
            if autoFocus && !isEditing {
                startEditing()
            }
        }
    }

    private func startEditing() {
        editingText = text
        isEditing = true

        // Small delay to ensure the text field is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isTextFieldFocused = true
        }
    }

    private func finishEditing() {
        guard isEditing else { return }

        // Cancel any pending autosave
        saveWorkItem?.cancel()

        // Save immediately if text changed
        if editingText != text && !editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

        // Don't save empty text
        guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

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
    @Previewable @State var title = "20-20-20 Eye Care Rule"

    return VStack(spacing: 20) {
        EditableTitle(text: $title, autoFocus: false) { newTitle in
            print("Saving title: \(newTitle)")
        }

        Text("Current title: \(title)")
            .font(.caption)
            .foregroundColor(.secondary)

        Spacer()
    }
    .padding()
    .frame(width: 400, height: 200)
}