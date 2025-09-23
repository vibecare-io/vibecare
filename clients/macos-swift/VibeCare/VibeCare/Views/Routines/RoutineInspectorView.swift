import SwiftUI

struct RoutineInspectorView: View {
    let routineId: String
    @ObservedObject var viewModel: RoutineViewModel

    var routine: Routine? {
        viewModel.routines.first { $0.id == routineId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let routine = routine {
                Text("Edit Routine")
                    .font(.title2)
                    .fontWeight(.semibold)

                Form {
                    Section("Basic Information") {
                        TextField("Name", text: .constant(routine.name))
                        TextField("Description", text: .constant(routine.description), axis: .vertical)
                            .lineLimit(3...5)
                    }

                    Section("Settings") {
                        Toggle("Enabled", isOn: .constant(routine.enabled))
                        TextField("Category", text: .constant(routine.category))
                    }
                }
                .formStyle(.grouped)

                Spacer()

                HStack {
                    Button("Cancel") {
                        // Handle cancel
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Save") {
                        // Handle save
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("Routine not found")
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

#Preview {
    RoutineInspectorView(
        routineId: "sample-id",
        viewModel: RoutineViewModel()
    )
    .frame(width: 300, height: 400)
}