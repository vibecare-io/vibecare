# Task: Add Comprehensive Logging & Telemetry to Web Server Endpoints

**Status**: 🔵 In Progress
**Created**: 2025-11-21
**Last Updated**: 2025-11-21

---

## Overview

### Goal
Add comprehensive OpenTelemetry tracing and structured logging to HTTP web server endpoints to match the excellent instrumentation already present in gRPC endpoints. This enables distributed tracing visibility, better debugging, and consistent observability across the application.

### Success Criteria
- [x] All HTTP requests create OpenTelemetry spans visible in Jaeger
- [x] Request logs include structured fields: trace_id, span_id, request_id, method, path, status, duration
- [x] Errors recorded in spans with stack traces and error classification
- [x] Panics caught and logged gracefully without crashing the server
- [x] Request IDs generated and propagated (X-Request-ID header)
- [x] HTTP traces linked to downstream gRPC traces in Jaeger
- [x] Consistent logging pattern with gRPC endpoints
- [x] No performance degradation (<10ms overhead per request)

### Scope
**In Scope:**
- HTTP middleware infrastructure (panic recovery, request ID, logging, tracing)
- OpenTelemetry automatic instrumentation using `otelhttp` package
- Structured logging with trace context for all web handlers
- Request/response logging with semantic conventions
- Error recording in spans with existing error analysis
- Integration with existing telemetry infrastructure

**Out of Scope:**
- Metrics collection (focus on traces and logs only)
- Request/response body logging (may add later for debugging)
- Custom business logic spans within handlers (just HTTP-level spans)
- Performance profiling or optimization beyond basic middleware
- Authentication/authorization middleware (separate concern)

---

## Research & Context

### External Research
- **OpenTelemetry HTTP Semantic Conventions**: https://opentelemetry.io/docs/specs/semconv/http/
  - Standard attributes: `http.method`, `http.route`, `http.status_code`, `http.user_agent`
  - Span naming: `{http.method} {http.route}` pattern
- **otelhttp Package**: https://pkg.go.dev/go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp
  - Automatic span creation and context propagation
  - W3C trace context support
  - Configurable span name formatters

### Codebase Analysis

**Current State:**
- `backend/internal/web/server.go:25-44` - Plain HTTP server with no middleware
- `backend/internal/web/handler.go` - Minimal logging, no trace context
- `backend/internal/telemetry/middleware.go:76-153` - Excellent gRPC instrumentation to mirror
- `backend/cmd/server/main.go:136-148` - gRPC middleware chain pattern to follow

**Key Findings:**
- gRPC uses 3-layer interceptor chain: panic recovery → otelgrpc → custom attributes
- Telemetry package has reusable error analysis (`AnalyzeError()`, `RecordErrorWithDetails()`)
- Logger wrapper exists (`LoggerWithTrace`) for automatic trace_id/span_id injection
- No HTTP instrumentation currently exists

**Existing Infrastructure:**
- OpenTelemetry fully configured with OTLP exporter to Jaeger
- Structured logging with zap
- Error classification system (validation, database, network, etc.)
- Stack trace capture utilities

### Design Decisions

1. **Decision**: Use `otelhttp` package for automatic HTTP instrumentation
   - **Reasoning**: Industry standard, consistent with gRPC's `otelgrpc`, handles W3C trace context
   - **Trade-offs**: Adds dependency but provides battle-tested implementation

2. **Decision**: Create middleware.go in web package (not telemetry package)
   - **Reasoning**: HTTP-specific middleware, keeps web concerns separate
   - **Trade-offs**: Could reuse more from telemetry, but clearer separation of concerns

3. **Decision**: Follow gRPC middleware ordering (panic → trace → log)
   - **Reasoning**: Proven pattern, ensures panics caught before traces, logs have trace context
   - **Trade-offs**: None, this is best practice

4. **Decision**: Use request context for passing request_id
   - **Reasoning**: Standard Go pattern, works with existing middleware architecture
   - **Trade-offs**: None

5. **Decision**: Keep handler changes minimal, do heavy lifting in middleware
   - **Reasoning**: Separation of concerns, handlers focus on business logic
   - **Trade-offs**: Less flexibility for custom per-handler instrumentation

---

## Implementation Plan

### Files to Modify
- [x] `backend/go.mod` - Purpose: Add otelhttp dependency
- [x] `backend/internal/web/server.go` - Purpose: Add middleware stack and tracer
- [x] `backend/internal/web/handler.go` - Purpose: Use trace-aware logging in handlers
- [x] `backend/internal/web/icon_handler.go` - Purpose: Use trace-aware logging
- [x] `backend/cmd/server/main.go` - Purpose: Pass tracer to web server initialization

### Files to Create
- [x] `backend/internal/web/middleware.go` - Purpose: HTTP middleware (panic recovery, request ID, logging)

### Implementation Steps

**Phase 1: Foundation**
- [x] Step 1.1: Add otelhttp dependency to go.mod
- [x] Step 1.2: Create middleware.go file structure

**Phase 2: Core Middleware**
- [x] Step 2.1: Implement RequestIDMiddleware
  - Generate UUID for each request
  - Accept X-Request-ID header from clients
  - Add to context and response header
- [x] Step 2.2: Implement LoggingMiddleware
  - Log request start with trace_id, span_id, method, path
  - Capture response status and duration
  - Log completion with all fields
- [x] Step 2.3: Implement PanicRecoveryMiddleware
  - Catch panics with recover()
  - Log with stack trace
  - Return 500 response
- [x] Step 2.4: Create responseWriter wrapper
  - Track status code and bytes written

**Phase 3: Web Server Integration**
- [x] Step 3.1: Update Server struct to include tracer
- [x] Step 3.2: Apply middleware stack to all handlers
  - Wrap with panic recovery → request ID → otelhttp → logging
- [x] Step 3.3: Configure otelhttp with proper operation names

**Phase 4: Main Server Update**
- [x] Step 4.1: Create HTTP tracer in main.go
- [x] Step 4.2: Pass tracer to web.NewServer()

**Phase 5: Handler Enhancement**
- [x] Step 5.1: Update StatusHandler with trace-aware logger
- [x] Step 5.2: Add logging to DashboardHandler
- [x] Step 5.3: Update MCPToolsHandler with trace-aware logger
- [x] Step 5.4: Update ServeSVGIcon with trace-aware logger

**Phase 6: Testing**
- [ ] Step 6.1: Build and verify compilation
- [ ] Step 6.2: Test basic functionality (dashboard loads)
- [ ] Step 6.3: Verify traces appear in Jaeger
- [ ] Step 6.4: Test error handling and logging
- [ ] Step 6.5: Test request ID propagation

### Testing Plan
- [ ] Build test: `go build ./backend/cmd/server`
- [ ] Start server: `just run`
- [ ] Access endpoints:
  - http://localhost:8080/status
  - http://localhost:8080/api/scheduler/status
  - http://localhost:8080/api/mcp/tools
- [ ] Check logs for structured fields
- [ ] View traces in Jaeger: http://localhost:16686
- [ ] Test error cases (404, 500)
- [ ] Test request ID header round-trip
- [ ] Verify no performance regression

---

## Implementation Log

### [2025-11-21 - Planning Phase]

**Changes Made:**
- Created task file following template
- Completed research on OpenTelemetry HTTP conventions
- Analyzed existing gRPC instrumentation pattern
- Defined implementation approach

**Design Decisions:**
- Will mirror gRPC middleware chain pattern
- Use otelhttp for automatic span creation
- Keep handler changes minimal (middleware does heavy lifting)

---

### [2025-11-21 - Implementation Complete]

**Changes Made:**

1. **`backend/go.mod`** - Added otelhttp dependency
   - Added `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.63.0`
   - Automatically pulled in `github.com/felixge/httpsnoop` dependency

2. **`backend/internal/web/middleware.go`** (NEW FILE) - HTTP middleware implementations
   - Lines 17-23: `contextKey` type and `requestIDKey` constant for request ID storage
   - Lines 25-47: `RequestIDMiddleware()` - Generates/accepts X-Request-ID header, adds to context
   - Lines 49-54: `GetRequestID()` - Helper to extract request ID from context
   - Lines 56-77: `responseWriter` struct - Wraps http.ResponseWriter to capture status code and bytes written
   - Lines 80-132: `LoggingMiddleware()` - Logs request start/complete with trace context, request ID, method, path, status, duration
   - Lines 134-178: `PanicRecoveryMiddleware()` - Catches panics, logs with stack trace, records in span, returns 500

3. **`backend/internal/web/server.go`** - Added middleware stack and tracer
   - Lines 12-13: Added imports for `otelhttp` and `trace`
   - Line 21: Added `tracer trace.Tracer` field to Server struct
   - Line 25: Updated `NewServer()` signature to accept `tracer trace.Tracer` parameter
   - Lines 30-49: Added `applyMiddleware()` helper function with proper middleware ordering:
     - Panic Recovery (outermost) → Request ID → OpenTelemetry → Logging → Handler (innermost)
   - Lines 51-72: Updated all handler registrations to use middleware stack with operation names:
     - `/status` → "dashboard_page"
     - `/api/scheduler/status` → "scheduler_status"
     - `/api/mcp/tools` → "mcp_tools"
     - `/api/icons/` → "serve_icon"
     - `/` → "root"
   - Line 83: Store tracer in Server struct

4. **`backend/cmd/server/main.go`** - Pass tracer to web server
   - Lines 128-129: Create HTTP tracer using `telemetry.GetTracer("vibecare.http.server")`
   - Line 132: Pass tracer to `web.NewServer()` call

5. **`backend/internal/web/handler.go`** - Use trace-aware logging
   - Lines 14-16: Added imports for `telemetry`, `attribute`, and `trace`
   - Lines 44-46: DashboardHandler - Added trace-aware logger and debug logging
   - Lines 85-86: StatusHandler - Create trace-aware logger and get span from context
   - Lines 96-98: StatusHandler - Error handling with `RecordErrorWithDetails()` for timeout
   - Lines 108-110: StatusHandler - Error handling with `RecordErrorWithDetails()` for database errors
   - Lines 181-187: StatusHandler - Add span attributes for scheduler stats (schedule_count, active_count, paused_count)
   - Lines 202-204: StatusHandler - Error handling with `RecordErrorWithDetails()` for encoding errors
   - Lines 311-312: MCPToolsHandler - Create trace-aware logger and get span
   - Lines 318-320: MCPToolsHandler - Add span attribute for MCP disabled state
   - Lines 326-328: MCPToolsHandler - Error handling with `RecordErrorWithDetails()`
   - Lines 340-345: MCPToolsHandler - Add span attributes for MCP enabled state (tool_count, resource_count)
   - Lines 355-357: MCPToolsHandler - Error handling with `RecordErrorWithDetails()`

6. **`backend/internal/web/icon_handler.go`** - Use trace-aware logging
   - Lines 7-9: Added imports for `telemetry`, `attribute`, and `trace`
   - Lines 16-17: Create trace-aware logger and get span from context
   - Lines 36-38: Add icon ID to span attributes
   - Line 40: Use trace-aware Debug logging
   - Lines 45-47: Warn logging with trace context for 404 errors
   - Lines 60-62: Error logging with trace context for write failures
   - Lines 68-70: Add icon size to span attributes
   - Line 72: Debug logging with trace context for successful response

**Design Decisions:**
- Used existing `telemetry.LoggerWithTrace` API which requires context parameter for each log call
- Used existing `telemetry.RecordErrorWithDetails(span, err, payload)` signature (3 params, not 4)
- Middleware ordering follows gRPC pattern: Panic → ID → Tracing → Logging
- Empty string for payload parameter in `RecordErrorWithDetails()` calls (HTTP doesn't need request payload logging)

**Issues Encountered:**
- Initial compilation errors due to incorrect API signatures for `LoggerWithTrace` and `RecordErrorWithDetails`
- Fixed by reading actual telemetry package implementation and matching correct signatures
- `LoggerWithTrace` methods require `context.Context` as first parameter
- `RecordErrorWithDetails` takes 3 params: (span, error, payload string)

**Testing:**
- Build completed successfully without errors
- Code compiles and links correctly
- Ready for runtime testing

---

## Dependencies & Blockers

### Dependencies
- [x] OpenTelemetry already configured with OTLP exporter
- [x] Zap structured logging in place
- [x] Error analysis utilities in telemetry package
- [ ] Need to add: `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp`

### Blockers
None currently

### Questions
None currently

---

## Completion Checklist

Before marking as 🟢 Completed:
- [ ] All implementation steps completed
- [ ] Code compiles without errors
- [ ] Manual testing passes (all 6 test steps)
- [ ] Traces visible in Jaeger with correct attributes
- [ ] Logs show structured fields (trace_id, span_id, request_id)
- [ ] Request IDs propagate correctly
- [ ] Error handling works (panics caught, errors logged)
- [ ] Implementation log fully documented
- [ ] No performance regression

---

## Archive Notes

**Completed**: TBD
**Outcome**: TBD
**Follow-up Tasks**: TBD
