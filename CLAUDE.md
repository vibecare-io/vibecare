# CLAUDE.md

## Project Overview

VibeCare is a wellness and routine management system with:
- **Backend**: Go server with gRPC API, SQLite database, RRule-based scheduling engine
- **Frontend**: Native Swift macOS/iOS client
- **Protocol**: Type-safe communication via Protocol Buffers
- **Build Tool**: Just command runner

## Plan & Review Workflow

### Before Starting Work
1. **Always enter plan mode** to create a detailed implementation plan
2. **Write the plan** to `.claude/tasks/TASK_NAME.md` (use `_TEMPLATE.md` as guide)
3. **Include in the plan**:
   - Detailed implementation steps with reasoning
   - Tasks broken down into checkboxes
   - External research findings (use Task tool if needed)
   - MVP scope definition (avoid over-planning)
   - Files to be modified/created with purposes
4. **Ask for review** - Do not continue until plan is approved by user

### While Implementing
1. **Update the plan** as you work through tasks
2. **Check off completed tasks** with ✅ in the markdown file
3. **Document changes in Implementation Log**: After completing tasks, append detailed descriptions including:
   - File paths with line numbers (e.g., `main.go:123`)
   - What changed and why
   - Design decisions made
   - Any deferred items or scope changes
4. **Track blockers**: Update Dependencies section with any issues discovered
5. **Maintain handoff readiness**: Write clear notes so other engineers can continue work

### After Completion
1. **Final update**: Complete Implementation Log with all changes, decisions, and outcomes
2. **Move to archive**: `mv .claude/tasks/TASK.md .claude/archive/tasks/TASK_YYYYMMDD.md`
3. **Update Recent Development**: Add summary to CLAUDE.md with key changes and files modified
4. **Update status**: Mark task as 🟢 Completed before archiving

### Task Status Indicators
- 🟡 **Planning** - Creating plan, awaiting approval
- 🔵 **In Progress** - Actively implementing
- 🔴 **Blocked** - Cannot proceed, needs resolution
- 🟢 **Completed** - Ready for archive

## Active Tasks
_Tasks currently in progress are tracked in `.claude/tasks/`_

**View active tasks**: `ls .claude/tasks/*.md | grep -v "_TEMPLATE\|README"`

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
```

### Code Generation

When modifying protobuf definitions in `proto/`:
1. Run `just proto-gen` to regenerate code for both backend and Swift client
2. Backend code goes to: `backend/pkg/proto/`
3. Swift code goes to: `clients/macos-swift/VibeCare/VCStubs/`

## Quick Reference

### Architecture at a Glance
- **Backend**: Go server (gRPC + HTTP), SQLite, RRule scheduler
- **Frontend**: Swift macOS client (server-first, no local DB)
- **Communication**: gRPC with Protocol Buffers
- **Real-time**: Server-Sent Events (SSE) via EventHub

### Key File Locations
| Component | Location |
|-----------|----------|
| Backend entry point | `backend/cmd/server/main.go` |
| Frontend entry point | `clients/macos-swift/VibeCare/vibecare/App.swift` |
| gRPC services | `backend/internal/api/*_service.go` |
| Frontend services | `clients/macos-swift/VibeCare/vibecare/Services/` |
| Database migrations | `backend/internal/storage/migrations/` |
| Protobuf definitions | `proto/vibecare.proto` |
| Swift models | `clients/macos-swift/VibeCare/vibecare/Models/` |
| ViewModels | `clients/macos-swift/VibeCare/vibecare/ViewModels/` |
| UI Views | `clients/macos-swift/VibeCare/vibecare/Views/` |

### Important Architectural Decisions
1. **Server-First Frontend**: No local persistence (no SQLite/CoreData), requires active backend
2. **Schedule-Action Join Table**: Actions not embedded, managed via `schedule_actions` table
3. **Backend-Served Icons**: Icons from HTTP API, not bundled in app
4. **Custom Notifications**: Uses VibeNotify library for full control

### Default Ports & Locations
- gRPC: `localhost:50051`
- HTTP: `localhost:8080`
- Database: `~/.vibecare/vibecare.db`
- Jaeger UI: `http://localhost:16686`

## Documentation Links

**For detailed information, see:**

- **[Architecture Deep Dive](./docs/arch.org)** - Complete system architecture, ADRs, diagrams
- **[Frontend Details](./clients/macos-swift/VibeCare/CLAUDE.md)** - Swift client architecture, patterns
- **[Documentation Index](./docs/README.md)** - All available documentation
- **[MCP Setup](./docs/MCP_SETUP.md)** - Model Context Protocol integration
- **[Local Build Guide](./docs/LOCAL_BUILD.md)** - Development environment setup
- **[Release Process](./docs/RELEASE_PROCESS.md)** - Creating releases

## Common Workflows

### Adding a New gRPC Service
1. Define in `proto/vibecare.proto` → 2. `just proto-gen` → 3. Implement backend service → 4. Add Swift service wrapper → 5. Update ViewModel/UI

### Database Schema Change
1. `just new-migration NAME` → 2. Edit SQL → 3. `just migrate` → 4. Update storage layer → 5. Update protobuf → 6. `just proto-gen`

### Debugging
- **Backend**: Logs to stdout, traces at http://localhost:16686, DB via `just inspect-db`
- **Frontend**: Console.app logs, check UserDefaults config, view traces in Jaeger
