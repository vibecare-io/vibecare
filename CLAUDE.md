# CLAUDE.md

## Project Overview

VibeCare is a wellness and routine management system with:
- **Backend**: Go server with gRPC API, SQLite database, RRule-based scheduling engine
- **Frontend**: Native Swift macOS/iOS client
- **Protocol**: Type-safe communication via Protocol Buffers
- **Build Tool**: Just command runner

## Development Commands

### Backend Development

```bash
# Initial setup (installs dependencies, generates protobuf, runs migrations)
just setup

# Run backend server with OpenTelemetry tracing
just run

# Run backend tests
just test

# Generate protobuf code for all targets (backend + Swift client)
just proto-gen

# Database operations
just migrate              # Run migrations
just new-migration NAME   # Create new migration
just inspect-db           # Open litecli for backend DB

# gRPC testing
just grpc-test                            # List available services
just grpc-create-profile "Name" "email"   # Create test profile
just grpc-list-profiles                   # List all profiles
```

### Swift Client Development

```bash
# Build and run Swift client
cd clients/macos-swift/VibeCare
swift build
swift run

# Or use just commands from project root
just swift-build
just swift-run
just swift-test

# Database inspection
just swift-inspect-app-db   # Open litecli for client DB
just swift-reset-app-db     # Delete client database
```

### Code Generation

When modifying protobuf definitions in `proto/`:
1. Run `just proto-gen` to regenerate code for both backend and Swift client
2. Backend code goes to: `backend/pkg/proto/`
3. Swift code goes to: `clients/macos-swift/VibeCare/VCStubs/`

## Architecture

### Backend (Go)

**Entry Point**: `backend/cmd/server/main.go` - Initializes gRPC server, HTTP web server, scheduler, and telemetry

**Core Components**:

1. **gRPC Services** (`backend/internal/api/`)
   - `server.go` - Registers all gRPC services
   - Service implementations: `profile_service.go`, `routine_service.go`, `schedule_service.go`, `event_service.go`
   - All services share DB connection and EventHub

2. **Scheduler** (`backend/internal/scheduler/`)
   - `scheduler.go` - Polls database every minute for due schedules
   - `event_hub.go` - Event streaming mechanism for client notifications
   - Uses RRule library (RFC 5545) for recurring schedule calculations

3. **Storage Layer** (`backend/internal/storage/`)
   - SQLite with Goose migrations (`internal/storage/migrations/`)
   - Separate files per entity: `profile.go`, `routine.go`, `schedule.go`, `execution_log.go`
   - Database location: `~/.vibecare/vibecare.db`

4. **Telemetry** (`backend/internal/telemetry/`)
   - OpenTelemetry integration with Jaeger
   - Automatic gRPC instrumentation via `otelgrpc`
   - Enable with `--enable-tracing` flag (default: true)
   - OTLP endpoint: `localhost:4317` (configurable)

**Data Flow**:
```
gRPC Request → Service Layer → Storage Layer → SQLite
                     ↓
              Scheduler (polls) → EventHub → Client SSE Stream
```

### Swift Client (macOS/iOS)

**Entry Point**: `clients/macos-swift/VibeCare/vibecare/App.swift`

**Architecture Pattern**: MVVM with service layer
- Models: Domain models matching protobuf definitions
- Views: SwiftUI views with view-specific logic
- ViewModels: Business logic and state management
- Services: Backend communication and local storage

**Key Services** (`vibecare/Services/`):

1. **GRPCClientManager.swift** - Manages gRPC connection lifecycle
2. **ProfileService.swift** - Profile CRUD operations
3. **RoutineService.swift** / **RoutineLocalStorage.swift** - Routine management with local caching
4. **ScheduleService.swift** / **ScheduleLocalStorage.swift** - Schedule management with local caching
5. **EventService.swift** - Server-sent events for real-time schedule updates
6. **NotificationManager.swift** - macOS notification integration using VibeNotify library
7. **OTELManager.swift** - OpenTelemetry client instrumentation
8. **SyncManagers** - Offline-first sync between local SQLite and backend

**Local Storage**:
- Client maintains local SQLite database for offline functionality
- Location: `~/Library/Containers/io.vibecare.App.vibecare/Data/Library/Application Support/`
- Sync managers handle bidirectional synchronization with backend

**Notifications**:
- Uses custom `VibeNotify` library (https://github.com/vibecare-io/vibe-notify-macos)
- Supports interactive notifications with custom actions
- Configured via `VibeNotifyConfiguration.swift`

### Domain Models

**Core Entities** (defined in protobuf):

1. **Profile** - User account with preferences
2. **Routine** - Collection of Actions executed together
3. **Action** - Individual task (notification, script, API call, etc.)
4. **Schedule** - RRule-based recurring schedule
5. **ExecutionLog** - Audit trail of routine executions

**RRule Schedule Examples**:
```json
// Daily at 9 AM and 6 PM
{"freq": "DAILY", "interval": 1, "byhour": [9, 18], "byminute": [0]}

// Weekdays at 2 PM
{"freq": "WEEKLY", "byday": ["MO","TU","WE","TH","FR"], "byhour": [14], "byminute": [0]}
```

## Testing

### Backend Tests
```bash
just test              # Run all tests
just test-coverage     # Generate coverage report (opens HTML)
just test-stack        # Integration test: start server + test gRPC
```

### Swift Tests
```bash
just swift-test
# Or from Swift package directory:
cd clients/macos-swift/VibeCare && swift test
```

## Common Development Workflows

### Adding a New gRPC Service

1. Define service in `proto/vibecare.proto`
2. Run `just proto-gen` to generate code
3. Implement service in `backend/internal/api/` (create new file or extend existing)
4. Register service in `backend/internal/api/server.go` RegisterServices()
5. Add Swift client wrapper in `clients/macos-swift/VibeCare/vibecare/Services/`

### Database Schema Changes

1. Create migration: `just new-migration description`
2. Edit SQL in `backend/internal/storage/migrations/NNNN_description.sql`
3. Run migration: `just migrate`
4. Update storage layer in `backend/internal/storage/` if needed

### Debugging

**Backend**:
- Logs go to stdout with structured logging (zap)
- OpenTelemetry traces to Jaeger at http://localhost:16686
- Database inspection: `just inspect-db`

**Swift Client**:
- Uses swift-log with console output
- OpenTelemetry traces sent to backend's OTLP collector
- View instrumentation in `ViewInstrumentation.swift`
- Database inspection: `just swift-inspect-app-db`

## Important Notes

- Default gRPC port: 50051
- Default web port: 8080
- Database uses Goose for migrations (not go-migrate)
- Scheduler checks for due schedules every 1 minute
- Swift client requires macOS 15+ (specified in Package.swift)
- EventHub uses server-sent events (SSE) for real-time client updates
