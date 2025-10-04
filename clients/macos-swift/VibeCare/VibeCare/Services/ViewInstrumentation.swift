import SwiftUI
import OpenTelemetryApi

// MARK: - @ViewInstrumented Property Wrapper

@propertyWrapper
struct ViewInstrumented<T>: DynamicProperty {
    @State var wrappedValue: T
    @State private var viewSpan: Span?

    private let viewName: String
    private let parentSpan: Span?

    var projectedValue: ViewInstrumentedBinding<T> {
        ViewInstrumentedBinding(
            binding: $wrappedValue,
            viewName: viewName,
            parentSpan: parentSpan
        )
    }

    init(wrappedValue: T, viewName: String, parentSpan: Span? = nil) {
        self._wrappedValue = State(initialValue: wrappedValue)
        self.viewName = viewName
        self.parentSpan = parentSpan
    }

    func update() {
        if viewSpan == nil {
            if let parentSpan = parentSpan {
                viewSpan = OTELManager.shared.createChildSpan(
                    parent: parentSpan,
                    operationName: "view.lifecycle",
                    attributes: [
                        "view.name": AttributeValue.string(viewName),
                        "view.phase": AttributeValue.string("update")
                    ]
                )
            } else {
                viewSpan = OTELManager.shared.startSpan("view.lifecycle", attributes: [
                    "view.name": AttributeValue.string(viewName),
                    "view.phase": AttributeValue.string("update")
                ])
            }
        }
    }

    func endSpan() {
        viewSpan?.end()
        viewSpan = nil
    }
}

// MARK: - ViewInstrumentedBinding for State Changes

struct ViewInstrumentedBinding<T> {
    let binding: Binding<T>
    private let viewName: String
    private let parentSpan: Span?

    init(binding: Binding<T>, viewName: String, parentSpan: Span?) {
        self.binding = binding
        self.viewName = viewName
        self.parentSpan = parentSpan
    }

    func onChange<V: Equatable>(of value: V, perform action: @escaping (V, V) -> Void) -> some View {
        EmptyView().onChange(of: value) { oldValue, newValue in
            let stateSpan: Span
            if let parentSpan = parentSpan {
                stateSpan = OTELManager.shared.createChildSpan(
                    parent: parentSpan,
                    operationName: "state.change",
                    attributes: [
                        "view.name": AttributeValue.string(viewName),
                        "state.property": AttributeValue.string(String(describing: type(of: value)))
                    ]
                )
            } else {
                stateSpan = OTELManager.shared.startSpan("state.change", attributes: [
                    "view.name": AttributeValue.string(viewName),
                    "state.property": AttributeValue.string(String(describing: type(of: value)))
                ])
            }

            defer { stateSpan.end() }
            action(oldValue, newValue)
        }
    }
}

// MARK: - @TrackedState Property Wrapper

@propertyWrapper
struct TrackedState<T>: DynamicProperty, Sendable where T: Sendable {
    @State var wrappedValue: T
    private let propertyName: String
    private let viewName: String

    var projectedValue: Binding<T> {
        Binding(
            get: { wrappedValue },
            set: { newValue in
                let changeSpan = OTELManager.shared.startSpan("state.mutation", attributes: [
                    "view.name": AttributeValue.string(viewName),
                    "property.name": AttributeValue.string(propertyName),
                    "property.type": AttributeValue.string(String(describing: T.self))
                ])
                defer { changeSpan.end() }

                wrappedValue = newValue
            }
        )
    }

    init(wrappedValue: T, propertyName: String, viewName: String) {
        self._wrappedValue = State(initialValue: wrappedValue)
        self.propertyName = propertyName
        self.viewName = viewName
    }
}

// MARK: - TraceableAction Wrapper

struct TraceableAction {
    private let actionName: String
    private let component: String
    private let parentSpan: Span?

    init(actionName: String, component: String, parentSpan: Span? = nil) {
        self.actionName = actionName
        self.component = component
        self.parentSpan = parentSpan
    }

    func execute<T>(_ action: () throws -> T) rethrows -> T {
        let actionSpan: Span
        if let parentSpan = parentSpan {
            actionSpan = OTELManager.shared.createChildSpan(
                parent: parentSpan,
                operationName: "user.action",
                attributes: [
                    "action.name": AttributeValue.string(actionName),
                    "ui.component": AttributeValue.string(component)
                ]
            )
        } else {
            actionSpan = OTELManager.shared.traceUserAction(actionName, component: component)
        }

        defer { actionSpan.end() }

        do {
            let result = try action()
            actionSpan.status = .ok
            return result
        } catch {
            actionSpan.status = .error(description: error.localizedDescription)
            throw error
        }
    }

    func executeAsync<T: Sendable>(_ action: @Sendable () async throws -> T) async rethrows -> T {
        let actionSpan: Span
        if let parentSpan = parentSpan {
            actionSpan = OTELManager.shared.createChildSpan(
                parent: parentSpan,
                operationName: "user.action",
                attributes: [
                    "action.name": AttributeValue.string(actionName),
                    "ui.component": AttributeValue.string(component)
                ]
            )
        } else {
            actionSpan = OTELManager.shared.traceUserAction(actionName, component: component)
        }

        defer { actionSpan.end() }

        do {
            let result = try await action()
            actionSpan.status = .ok
            return result
        } catch {
            actionSpan.status = .error(description: error.localizedDescription)
            throw error
        }
    }
}

// MARK: - View Extension for Easy Instrumentation

extension View {
    func withTracing(viewName: String, parentSpan: Span? = nil) -> some View {
        self.modifier(ViewTracingModifier(viewName: viewName, parentSpan: parentSpan))
    }
}

struct ViewTracingModifier: ViewModifier {
    let viewName: String
    let parentSpan: Span?
    @State private var viewSpan: Span?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if let parentSpan = parentSpan {
                    viewSpan = OTELManager.shared.createChildSpan(
                        parent: parentSpan,
                        operationName: "view.appear",
                        attributes: [
                            "view.name": AttributeValue.string(viewName)
                        ]
                    )
                } else {
                    viewSpan = OTELManager.shared.traceViewAppear(viewName)
                }
            }
            .onDisappear {
                viewSpan?.end()
                viewSpan = nil
            }
    }
}