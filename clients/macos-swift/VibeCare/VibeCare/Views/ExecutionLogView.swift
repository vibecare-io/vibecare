import SwiftUI

struct ExecutionLogView: View {
    let searchText: String

    var body: some View {
        VStack {
            EmptyStateView(
                title: "Execution Logs",
                subtitle: "View the history of routine executions",
                systemImage: "doc.text.circle"
            )
        }
        .navigationTitle("Execution Logs")
    }
}

#Preview {
    ExecutionLogView(searchText: "")
}