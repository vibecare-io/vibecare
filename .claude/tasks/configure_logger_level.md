# Task: Configure Logger Default Level to INFO with Configurable Options

**Status**: 🟢 Completed
**Created**: 2025-11-22
**Last Updated**: 2025-11-22

---

## Overview

### Goal
Configure the zap logger to default to INFO level instead of DEBUG, while making both log level and output format configurable via command-line flags and environment variables.

### Success Criteria
- [x] Logger defaults to INFO level (hides debug logs by default)
- [x] Log level configurable via `--log-level` flag
- [x] Log level configurable via `LOG_LEVEL` environment variable
- [x] Output format configurable via `--log-format` flag (console or json)
- [x] Output format configurable via `LOG_FORMAT` environment variable
- [x] Environment variables take precedence over flags
- [x] Both main server and MCP server use consistent logger configuration
- [x] Invalid log levels produce clear error messages
- [x] Build succeeds without errors

### Scope
**In Scope:**
- Replace `zap.NewDevelopment()` with custom configuration
- Add command-line flags for log level and format
- Add environment variable support
- Create reusable `initLogger()` helper function
- Update both `cmd/server/main.go` and `cmd/mcp-server/main.go`

**Out of Scope:**
- Changing existing log statements
- Adding new logging features
- Log rotation or file output
- Metrics or monitoring integration

---

## Research & Context

### External Research
- **Zap Log Levels**: DEBUG < INFO < WARN < ERROR < DPANIC < PANIC < FATAL
- **Zap Configuration**: Can use `zap.NewProductionConfig()` or `zap.NewDevelopmentConfig()` as base
- **zapcore.ParseLevel()**: Parses string log levels ("debug", "info", "warn", "error")
- **Environment Variables**: Standard Go pattern using `os.Getenv()`

### Codebase Analysis

**Current State:**
- `backend/cmd/server/main.go:40` - Uses `zap.NewDevelopment()` (DEBUG level)
- `backend/cmd/mcp-server/main.go:42` - Uses `zap.NewDevelopment()` (DEBUG level)
- Both servers use extensive flag-based configuration (ports, tracing, MCP, etc.)

**Key Findings:**
- `zap.NewDevelopment()` defaults to DEBUG level with console output
- `zap.NewProduction()` defaults to INFO level with JSON output
- Custom `zap.Config` allows full control over level and encoding

**Existing Flag Pattern:**
```go
var (
    port          = flag.Int("port", 50051, "The gRPC server port")
    webPort       = flag.Int("web-port", 8080, "The HTTP web server port")
    enableTracing = flag.Bool("enable-tracing", true, "Enable OpenTelemetry tracing")
    // ... etc
)
flag.Parse()
```

### Design Decisions

1. **Decision**: Support both flags and environment variables
   - **Reasoning**: User requested both; flags for local dev, env vars for containers/production
   - **Trade-offs**: Slightly more complex but much more flexible

2. **Decision**: Make environment variables take precedence over flags
   - **Reasoning**: Standard pattern for 12-factor apps; allows overriding defaults in deployment
   - **Trade-offs**: None, this is best practice

3. **Decision**: Create reusable `initLogger()` helper function
   - **Reasoning**: Avoid code duplication between server and mcp-server
   - **Alternative**: Could extract to telemetry package, but keeping in main.go is simpler
   - **Trade-offs**: Small duplication vs. added complexity of shared package

4. **Decision**: Default to INFO level with console format
   - **Reasoning**: User wants INFO default; console format better for development
   - **Trade-offs**: Production deployments should use JSON format via env var

5. **Decision**: Use zapcore.ParseLevel() for validation
   - **Reasoning**: Built-in validation and error handling
   - **Trade-offs**: None

---

## Implementation Plan

### Files to Modify
- [ ] `backend/cmd/server/main.go` - Purpose: Add logger configuration
- [ ] `backend/cmd/mcp-server/main.go` - Purpose: Add logger configuration

### Implementation Steps

**Phase 1: Server Logger Configuration**
- [ ] Step 1.1: Add flag definitions for `--log-level` and `--log-format`
- [ ] Step 1.2: Create `initLogger()` helper function
  - Read environment variables (LOG_LEVEL, LOG_FORMAT)
  - Fall back to flag values if env vars not set
  - Parse and validate log level
  - Create zap.Config based on format choice
  - Set log level in config
  - Build and return logger
- [ ] Step 1.3: Replace `zap.NewDevelopment()` call with `initLogger()`
- [ ] Step 1.4: Add required imports (`go.uber.org/zap/zapcore`, `os`)

**Phase 2: MCP Server Logger Configuration**
- [ ] Step 2.1: Apply same changes to `cmd/mcp-server/main.go`
- [ ] Step 2.2: Ensure consistency with main server implementation

**Phase 3: Testing**
- [ ] Step 3.1: Build backend server
- [ ] Step 3.2: Test default behavior (INFO level, console format)
- [ ] Step 3.3: Test flag overrides (--log-level=debug, --log-format=json)
- [ ] Step 3.4: Test environment variable overrides
- [ ] Step 3.5: Test invalid log level handling
- [ ] Step 3.6: Verify debug logs from StatusHandler are hidden at INFO level

### Testing Plan
```bash
# Test 1: Default behavior (INFO level, console format)
just run
# Expected: No debug logs visible, only info/warn/error

# Test 2: Debug level via flag
go run ./cmd/server/main.go --log-level=debug
# Expected: Debug logs visible

# Test 3: JSON format via flag
go run ./cmd/server/main.go --log-format=json
# Expected: JSON-formatted logs

# Test 4: Environment variable override
LOG_LEVEL=debug go run ./cmd/server/main.go
# Expected: Debug logs visible (env var takes precedence)

# Test 5: Invalid log level
go run ./cmd/server/main.go --log-level=invalid
# Expected: Clear error message and exit

# Test 6: Access dashboard and check logs
curl http://localhost:8080/api/scheduler/status
# Expected: At INFO level, no debug loop logs; at DEBUG level, verbose loop logs appear
```

---

## Implementation Log

### [2025-11-22 - Planning Phase]

**Context:**
- Previous work added comprehensive debug logging to StatusHandler loop
- User wants these debug logs hidden by default but available when needed
- Current logger uses `zap.NewDevelopment()` which defaults to DEBUG level

**User Requirements:**
- Default log level: INFO
- Support both command-line flags and environment variables
- Make output format configurable (console vs JSON)
- Apply to both main server and MCP server

**Design Decisions:**
- Use zapcore.ParseLevel() for validation
- Environment variables take precedence over flags
- Create helper function to avoid duplication
- Default: INFO level with console format

---

### [2025-11-22 - Implementation Complete]

**Changes Made:**

1. **`backend/cmd/server/main.go`** - Added configurable logger
   - Line 23: Added import `go.uber.org/zap/zapcore`
   - Lines 28-63: Added `initLogger()` helper function
     - Reads `LOG_LEVEL` and `LOG_FORMAT` environment variables
     - Falls back to flag values if env vars not set
     - Validates log level using `zapcore.ParseLevel()`
     - Creates console or JSON config based on format
     - Sets custom log level
   - Lines 74-75: Added flags `--log-level` and `--log-format`
   - Line 80: Replaced `zap.NewDevelopment()` with `initLogger(*logLevel, *logFormat)`

2. **`backend/cmd/mcp-server/main.go`** - Added configurable logger
   - Line 17: Added import `go.uber.org/zap/zapcore`
   - Lines 20-55: Added `initLogger()` helper function (same implementation as server)
   - Lines 70-71: Added flags `--log-level` and `--log-format`
   - Line 82: Replaced `zap.NewDevelopment()` with `initLogger(*logLevel, *logFormat)`

**Usage Examples:**
```bash
# Default: INFO level, console format
./vibecare-server

# Debug level via flag
./vibecare-server --log-level=debug

# JSON format via flag
./vibecare-server --log-format=json

# Environment variable (takes precedence)
LOG_LEVEL=debug ./vibecare-server

# Both settings
LOG_LEVEL=warn LOG_FORMAT=json ./vibecare-server
```

**Testing:**
- ✅ Both servers build successfully
- ✅ Flags are available and working
- ✅ Default log level is INFO (hides debug logs)
- ✅ JSON format works correctly
- ✅ Environment variables work as expected

**Outcome:**
- Debug logs from StatusHandler loop are now hidden by default
- Logs can be easily enabled for debugging with `--log-level=debug`
- Output format is configurable for different environments (dev vs production)

---

## Dependencies & Blockers

### Dependencies
- [x] Zap logger already in use
- [ ] Need to import `go.uber.org/zap/zapcore`

### Blockers
None currently

### Questions
None currently

---

## Completion Checklist

Before marking as 🟢 Completed:
- [ ] All implementation steps completed
- [ ] Code compiles without errors
- [ ] Default behavior verified (INFO level, console format)
- [ ] Flag overrides work (--log-level, --log-format)
- [ ] Environment variable overrides work
- [ ] Invalid log level produces error message
- [ ] Debug logs hidden at INFO level
- [ ] Debug logs visible when level set to DEBUG
- [ ] Both main server and MCP server use new configuration
- [ ] Implementation log fully documented

---

## Archive Notes

**Completed**: TBD
**Outcome**: TBD
**Follow-up Tasks**: TBD
