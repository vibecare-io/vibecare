# VibeCare macOS Client - OpenTelemetry Instrumentation Guide

## Overview

This document describes the OpenTelemetry instrumentation system implemented in the VibeCare macOS client. The system provides automated tracing for SwiftUI views and user interactions, helping diagnose performance issues and understand user flows.

## Architecture

### Core Components

1. **OTELManager** (`vibecare/Services/OTELManager.swift`)
   - Singleton class managing OpenTelemetry configuration
   - Configured to send traces to Jaeger at `localhost:4318`
   - Provides convenience methods for creating spans and child spans

2. **ViewInstrumentation** (`vibecare/Services/ViewInstrumentation.swift`)
   - Property wrappers and helpers for automated instrumentation
   - Reduces manual tracing code while maintaining performance

## Automated Instrumentation Tools

### 1. View Tracing Modifier

**Usage:**
```swift
SomeView()
    .withTracing(viewName: "MyView", parentSpan: optionalParentSpan)
```

**What it does:**
- Automatically creates spans for view appear/disappear lifecycle
- Optionally creates child spans if parent span provided
- Zero configuration required

### 2. TraceableAction Wrapper

**Usage:**
```swift
Button("Submit") {
    TraceableAction(
        actionName: "submit_form",
        component: "form_view"
    ).execute {
        // Your action code here
        submitForm()
    }
}
```

**For async actions:**
```swift
Button("Load Data") {
    Task {
        await TraceableAction(
            actionName: "load_data",
            component: "data_view"
        ).executeAsync {
            await loadDataFromAPI()
        }
    }
}
```

**What it does:**
- Wraps user actions with tracing spans
- Automatically sets success/error status
- Captures timing information
- Can create child spans with parent parameter

### 3. Parent-Child Span Relationships

**For complex user flows:**
```swift
// Create parent span for entire flow
let parentSpan = OTELManager.shared.startSpan("edit_schedule_flow")
parentSpan.setAttribute(key: "user.action", value: AttributeValue.string("edit"))

// Pass to child components
ScheduleEditView(parentSpan: parentSpan) {
    // End parent span when complete
    parentSpan.status = .ok
    parentSpan.end()
}
```

## Manual Instrumentation (When Needed)

### Basic Span Creation

```swift
// Simple span
let span = OTELManager.shared.startSpan("operation_name")
defer { span.end() }

// Span with attributes
let span = OTELManager.shared.startSpan("operation_name", attributes: [
    "key": AttributeValue.string("value"),
    "count": AttributeValue.int(42)
])
```

### Child Spans

```swift
let childSpan = OTELManager.shared.createChildSpan(
    parent: parentSpan,
    operationName: "child_operation",
    attributes: [
        "child.property": AttributeValue.string("value")
    ]
)
```

### View Lifecycle Spans

```swift
// Use built-in convenience methods
let viewSpan = OTELManager.shared.traceViewAppear("MyView")
let userActionSpan = OTELManager.shared.traceUserAction("button_click", component: "toolbar")
```

## Best Practices

### 1. Span Naming Convention

- Use dot notation: `view.appear`, `user.action`, `api.request`
- Be descriptive but concise: `schedule.edit.submit`
- Include context: `routine_detail.schedule.create`

### 2. Attributes to Include

**Essential attributes:**
- `view.name`: Name of the SwiftUI view
- `user.action`: What action the user performed
- `ui.component`: Which UI component triggered the action
- `operation.type`: Type of operation (create, read, update, delete)

**Timing attributes:**
- `timestamp`: ISO8601 formatted timestamp
- `duration_ms`: Operation duration in milliseconds

**Context attributes:**
- `routine.id`, `schedule.id`: Entity identifiers
- `thread.name`: Main thread vs background
- `ui.state`: Current UI state when relevant

### 3. Error Handling

```swift
do {
    let result = try riskyOperation()
    span.status = .ok
    return result
} catch {
    span.status = .error(description: error.localizedDescription)
    span.setAttribute(key: "error.type", value: AttributeValue.string(String(describing: type(of: error))))
    throw error
}
```

### 4. Performance Considerations

- **Always use defer** for span cleanup
- **Minimize attributes** in hot paths
- **Use child spans** for hierarchical operations
- **Preserve performance-critical onChange modifiers**

## Common Patterns

### 1. Sheet Presentation Flow

```swift
// Parent span for entire flow
@State private var editFlowSpan: Span?

Button("Edit") {
    editFlowSpan = OTELManager.shared.startSpan("edit_flow")
    showSheet = true
}

.sheet(isPresented: $showSheet) {
    EditView(parentSpan: editFlowSpan) {
        editFlowSpan?.end()
        editFlowSpan = nil
        showSheet = false
    }
}
```

### 2. State Change Tracking

```swift
.onChange(of: importantState) { oldValue, newValue in
    // Keep this for performance!
    let span = OTELManager.shared.startSpan("state.change")
    span.setAttribute(key: "old_value", value: AttributeValue.string(String(describing: oldValue)))
    span.setAttribute(key: "new_value", value: AttributeValue.string(String(describing: newValue)))
    defer { span.end() }

    // Your state change logic
}
```

### 3. API Integration

```swift
func loadData() async {
    await OTELManager.shared.traceAsyncOperation("api.load_data") {
        let data = try await apiClient.fetchData()
        return data
    }
}
```

## Jaeger Integration

### Configuration

The client is configured to send traces to:
- **Endpoint**: `http://localhost:4318/v1/traces`
- **Service Name**: `vibecare-ui`
- **Version**: `1.0.0`

### Viewing Traces

1. Open Jaeger UI (typically `http://localhost:16686`)
2. Select service: `vibecare-ui`
3. Search for traces by operation name or tags
4. Analyze parent-child relationships and timing

### Useful Queries

- Find slow operations: Filter by duration > 1s
- Find errors: Search for `error=true` tag
- User journey: Search by `user.session.id` (if implemented)
- View performance: Filter by `operation=view.body`

## Troubleshooting

### High Trace Volume

If generating too many traces:
- Increase sampling rate in OTELManager
- Remove tracing from high-frequency operations
- Focus on user-facing interactions

### Missing Parent-Child Relationships

- Ensure parent span is passed to child components
- Verify span lifecycle (created → used → ended)
- Check that parent span hasn't been ended before child creation

### Performance Impact

- Profile with and without tracing enabled
- Use batch exporting (already configured)
- Monitor memory usage for long-running spans

## Future Enhancements

1. **Automatic State Tracking**: Property wrapper that automatically traces state changes
2. **User Session Tracking**: Track user sessions across app lifecycle
3. **Performance Benchmarking**: Automated performance regression detection
4. **Custom Metrics**: Business metrics alongside tracing data
5. **Distributed Tracing**: Connect UI traces with backend API traces

## Migration Guide

### From Manual to Automated Instrumentation

1. **Replace manual view tracing:**
   ```swift
   // Old
   .onAppear {
       let span = OTELManager.shared.traceViewAppear("MyView")
       defer { span.end() }
   }

   // New
   .withTracing(viewName: "MyView")
   ```

2. **Replace manual action tracing:**
   ```swift
   // Old
   let span = OTELManager.shared.traceUserAction("submit", component: "form")
   submitForm()
   span.end()

   // New
   TraceableAction(actionName: "submit", component: "form").execute {
       submitForm()
   }
   ```

3. **Preserve performance-critical code:**
   - Keep onChange modifiers that improved performance
   - Maintain parent-child span relationships for complex flows
   - Don't remove instrumentation from hot paths without testing

---

**Last Updated**: Based on performance discovery and instrumentation cleanup - October 2025
