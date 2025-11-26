# VibeCare Documentation Index

**Quick Navigation for Claude and Developers**

## Essential Reading (Start Here)

1. **[CLAUDE.md](../CLAUDE.md)** - Project overview, commands, plan & review workflow
2. **[QUICK_REFERENCE.md](./QUICK_REFERENCE.md)** - Common patterns, file locations, quick answers

## Architecture Documentation

### High-Level
- **[arch.org](./arch.org)** - Complete system architecture (Org-mode format)
  - System diagrams
  - Data flow patterns
  - Architecture Decision Records (ADRs)
  - Component details

### Component-Specific
- **[Backend Architecture](../backend/README.md)** - Go server details *(to be created)*
- **[Frontend Architecture](../clients/macos-swift/VibeCare/CLAUDE.md)** - macOS Swift client details

## Development Guides

### Setup & Build
- **[LOCAL_BUILD.md](./LOCAL_BUILD.md)** - Local development setup
- **[RELEASE_PROCESS.md](./RELEASE_PROCESS.md)** - Release workflow
- **[SIGNING_SETUP.md](./SIGNING_SETUP.md)** - Code signing configuration

### Features
- **[ACTIONS_IMPLEMENTATION.md](./ACTIONS_IMPLEMENTATION.md)** - Action system details
- **[MCP_SETUP.md](./MCP_SETUP.md)** - Model Context Protocol setup
- **[MCP_IMPLEMENTATION_STATUS.md](./MCP_IMPLEMENTATION_STATUS.md)** - MCP feature status

### Platform-Specific
- **[macOS Client Guide](./macos/)** - macOS-specific documentation

## Quick Answers

### Where is...?

| What | Location |
|------|----------|
| **Backend entry point** | `backend/cmd/server/main.go` |
| **Frontend entry point** | `clients/macos-swift/VibeCare/vibecare/App.swift` |
| **gRPC services** | `backend/internal/api/*_service.go` |
| **Frontend services** | `clients/macos-swift/VibeCare/vibecare/Services/` |
| **Database migrations** | `backend/internal/storage/migrations/` |
| **Protobuf definitions** | `proto/vibecare.proto` |
| **Domain models (Swift)** | `clients/macos-swift/VibeCare/vibecare/Models/` |
| **ViewModels** | `clients/macos-swift/VibeCare/vibecare/ViewModels/` |
| **UI Views** | `clients/macos-swift/VibeCare/vibecare/Views/` |
| **Templates & Icons** | `clients/macos-swift/VibeCare/vibecare/Resources/` |

### Architecture at a Glance

**Backend (Go)**
- gRPC server on port 50051
- HTTP server on port 8080
- SQLite at `~/.vibecare/vibecare.db`
- Scheduler polls every 1 minute
- EventHub for real-time updates

**Frontend (Swift)**
- Server-first architecture (no local persistence)
- MVVM pattern with in-memory state
- gRPC communication via Protocol Buffers
- macOS 15+ only

**Data Flow**
```
View → ViewModel → Service → gRPC → Backend → SQLite
                                ↓
                            EventHub → SSE → EventService → UI
```

## Documentation Maintenance

### When to Update What

| Change Type | Update These Docs |
|-------------|-------------------|
| **New gRPC service** | `arch.org` (services section), `QUICK_REFERENCE.md` |
| **Schema change** | `arch.org` (database schema), relevant component README |
| **Architecture decision** | `arch.org` (new ADR), `CLAUDE.md` if workflow affected |
| **New workflow** | `CLAUDE.md` (if plan/review related), `QUICK_REFERENCE.md` |
| **Frontend change** | `clients/macos-swift/VibeCare/CLAUDE.md`, `arch.org` |
| **New development command** | `CLAUDE.md`, `QUICK_REFERENCE.md` |

### Documentation Hierarchy

```
CLAUDE.md (root)               ← Start here, plan & review workflow, commands
    ├── docs/README.md         ← This file, navigation hub
    ├── docs/QUICK_REFERENCE.md ← Quick answers, common patterns
    ├── docs/arch.org          ← Deep dive: full architecture
    ├── clients/*/CLAUDE.md    ← Component-specific details
    └── docs/*.md              ← Feature-specific guides
```

## For Claude Code

When starting fresh:
1. Read `CLAUDE.md` for workflow and commands
2. Check `QUICK_REFERENCE.md` for immediate context
3. Dive into `arch.org` only when needed for deep understanding
4. Reference component-specific docs for implementation details

## Contributing

When adding new documentation:
- Update this index
- Keep CLAUDE.md focused on workflow and commands
- Put architectural details in arch.org
- Create feature-specific docs for complex features
- Update QUICK_REFERENCE.md for common patterns
