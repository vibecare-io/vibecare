import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp

final class OTELManager: @unchecked Sendable {
    static let shared = OTELManager()

    private(set) var tracer: TracerSdk?
    private(set) var isEnabled: Bool = false

    private init() {
        // Check if telemetry is enabled (default: false)
        let enabled = UserDefaults.standard.bool(forKey: "telemetryEnabled")
        self.isEnabled = enabled

        if enabled {
            initializeTelemetry()
        }
    }

    private func initializeTelemetry() {
        // Configure resource information
        let resource = Resource(attributes: [
            "service.name": AttributeValue.string("vibecare-ui"),
            "service.version": AttributeValue.string("1.0.0"),
            "service.namespace": AttributeValue.string("vibecare")
        ])

        // Configure OTLP HTTP exporter to send to existing Jaeger
        // Default Jaeger OTLP HTTP endpoint is localhost:4318
        let spanExporter = OtlpHttpTraceExporter(
            endpoint: URL(string: "http://localhost:4318/v1/traces")!
        )

        // Configure span processor
        let spanProcessor = BatchSpanProcessor(spanExporter: spanExporter)

        // Create tracer provider
        let tracerProvider = TracerProviderSdk(
            resource: resource,
            spanProcessors: [spanProcessor]
        )

        // Set as global tracer provider
        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)

        // Get tracer instance
        self.tracer = tracerProvider.get(instrumentationName: "vibecare-ui", instrumentationVersion: "1.0.0") as? TracerSdk
    }

    func enable() {
        guard !isEnabled else { return }

        UserDefaults.standard.set(true, forKey: "telemetryEnabled")
        isEnabled = true
        initializeTelemetry()
    }

    func disable() {
        guard isEnabled else { return }

        UserDefaults.standard.set(false, forKey: "telemetryEnabled")
        isEnabled = false
        tracer = nil
    }

    // Convenience method to create spans with common attributes
    func startSpan(_ operationName: String, attributes: [String: AttributeValue] = [:]) -> Span {
        guard let tracer = tracer, isEnabled else {
            // Return no-op span if telemetry is disabled
            return DefaultTracer.instance.spanBuilder(spanName: "noop").startSpan()
        }
        let spanBuilder = tracer.spanBuilder(spanName: operationName)

        // Add common attributes
        spanBuilder.setSpanKind(spanKind: .client)
        spanBuilder.setAttribute(key: "component", value: AttributeValue.string("ui"))
        spanBuilder.setAttribute(key: "thread", value: AttributeValue.string(Thread.isMainThread ? "main" : "background"))

        // Add custom attributes
        for (key, value) in attributes {
            spanBuilder.setAttribute(key: key, value: value)
        }

        return spanBuilder.startSpan()
    }

    // Create a child span from a parent span
    func createChildSpan(parent: Span, operationName: String, attributes: [String: AttributeValue] = [:]) -> Span {
        guard let tracer = tracer, isEnabled else {
            return DefaultTracer.instance.spanBuilder(spanName: "noop").startSpan()
        }
        let spanBuilder = tracer.spanBuilder(spanName: operationName)

        // Set parent relationship
        spanBuilder.setParent(parent)

        // Add common attributes
        spanBuilder.setSpanKind(spanKind: .client)
        spanBuilder.setAttribute(key: "component", value: AttributeValue.string("ui"))
        spanBuilder.setAttribute(key: "thread", value: AttributeValue.string(Thread.isMainThread ? "main" : "background"))

        // Add custom attributes
        for (key, value) in attributes {
            spanBuilder.setAttribute(key: key, value: value)
        }

        return spanBuilder.startSpan()
    }

    // Method to trace view operations
    func traceViewOperation<T>(_ operationName: String, attributes: [String: AttributeValue] = [:], operation: () -> T) -> T {
        let span = startSpan(operationName, attributes: attributes)
        defer { span.end() }

        let result = operation()
        span.status = .ok
        return result
    }

    // Method to trace async operations
    func traceAsyncOperation<T: Sendable>(_ operationName: String, attributes: [String: AttributeValue] = [:], operation: @Sendable () async throws -> T) async rethrows -> T {
        let span = startSpan(operationName, attributes: attributes)
        defer { span.end() }

        do {
            let result = try await operation()
            span.status = .ok
            return result
        } catch {
            span.status = .error(description: error.localizedDescription)
            throw error
        }
    }

    // Manually flush spans when needed
    func flush() {
        // Remove flush functionality to avoid concurrency issues
        // Application will automatically flush on shutdown
    }
}

// Extension for easy span creation in SwiftUI views
extension OTELManager {
    func traceViewInit(_ viewName: String) -> Span {
        return startSpan("view.init", attributes: [
            "view.name": AttributeValue.string(viewName),
            "view.lifecycle": AttributeValue.string("init")
        ])
    }

    func traceViewBody(_ viewName: String) -> Span {
        return startSpan("view.body", attributes: [
            "view.name": AttributeValue.string(viewName),
            "view.lifecycle": AttributeValue.string("body")
        ])
    }

    func traceViewAppear(_ viewName: String) -> Span {
        return startSpan("view.appear", attributes: [
            "view.name": AttributeValue.string(viewName),
            "view.lifecycle": AttributeValue.string("appear")
        ])
    }

    func traceUserAction(_ action: String, component: String) -> Span {
        return startSpan("user.action", attributes: [
            "user.action": AttributeValue.string(action),
            "ui.component": AttributeValue.string(component)
        ])
    }

    // Create child spans for common view operations
    func traceChildViewInit(_ viewName: String, parent: Span) -> Span {
        return createChildSpan(parent: parent, operationName: "view.init", attributes: [
            "view.name": AttributeValue.string(viewName),
            "view.lifecycle": AttributeValue.string("init")
        ])
    }

    func traceChildViewBody(_ viewName: String, parent: Span) -> Span {
        return createChildSpan(parent: parent, operationName: "view.body", attributes: [
            "view.name": AttributeValue.string(viewName),
            "view.lifecycle": AttributeValue.string("body")
        ])
    }

    func traceChildUserAction(_ action: String, component: String, parent: Span) -> Span {
        return createChildSpan(parent: parent, operationName: "user.action", attributes: [
            "user.action": AttributeValue.string(action),
            "ui.component": AttributeValue.string(component)
        ])
    }
}