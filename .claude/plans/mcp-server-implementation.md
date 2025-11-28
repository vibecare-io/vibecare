# Task: MCP Server for VibeCare

**Status**: 🔵 In Progress
**Created**: 2025-10-30
**Last Updated**: 2025-10-30

**Architecture**: Embedded mode (primary) + Standalone mode (optional)

---

## Overview

### Goal
Create a Model Context Protocol (MCP) server that exposes VibeCare's routine and schedule management APIs to Claude and other LLMs, enabling natural language interaction with the VibeCare backend.

### Success Criteria
- [ ] Backend starts with `--with-mcp` flag and initializes MCP server
- [ ] MCP server accessible via STDIO transport in Claude Desktop
- [ ] Claude can create routines through conversation
- [ ] Claude can create schedules with RRule syntax
- [ ] Claude can list and view existing routines/schedules
- [ ] All operations persist to backend database correctly

### Scope
**In Scope:**
- MCP server package in Go with two deployment modes:
  - **Embedded mode**: Run with backend using `--with-mcp` flag (recommended)
  - **Standalone mode**: Separate process with gRPC client (advanced)
- MCP Resources: list routines, schedules, actions, execution logs
- MCP Tools: create/update/delete routines, schedules, actions
- MCP Tools: execute routines, pause/resume schedules
- Support STDIO transport (HTTP+SSE deferred)
- Configuration file for profile ID

**Out of Scope:**
- Authentication/authorization (personal use only)
- Multi-user support
- HTTP+SSE transport (future enhancement)
- Real-time event streaming (future enhancement)

---

## Research & Context

### External Research
- MCP Specification 2025-06-18: https://modelcontextprotocol.io/specification/2025-06-18
- MCP uses JSON-RPC 2.0 over STDIO or HTTP+SSE
- MCP Go SDK: https://github.com/modelcontextprotocol (TypeScript/Python SDKs available)
- May need to implement JSON-RPC 2.0 handler manually if no Go SDK

### Codebase Analysis
- `proto/vibecare.proto` - All gRPC service definitions available
- `backend/pkg/proto/` - Generated Go protobuf code
- Backend services: ProfileService, RoutineService, ScheduleService, ActionService, EventService
- Client-provided UUIDs supported (good for offline-first MCP clients)

### Design Decisions
1. **Decision**: Embedded mode as primary deployment (with standalone option)
   - **Reasoning**: Single process for personal use, simpler setup, direct storage access (faster)
   - **Trade-offs**: MCP code lives in backend repo, but that's acceptable for monorepo

2. **Decision**: Direct storage layer access in embedded mode
   - **Reasoning**: No gRPC overhead, can share DB connection and services, more efficient
   - **Trade-offs**: MCP package depends on storage package, but cleaner than gRPC client

3. **Decision**: `--with-mcp` flag to enable MCP server
   - **Reasoning**: Opt-in, doesn't affect existing backend behavior, easy to enable/disable
   - **Trade-offs**: None significant

4. **Decision**: Configuration file for profile ID
   - **Reasoning**: Personal use, no auth needed, simple setup
   - **Trade-offs**: Not multi-user ready, but that's out of scope

---

## Implementation Plan

### Files to Create
- [x] `backend/internal/mcp/protocol.go` - JSON-RPC 2.0 types and MCP protocol definitions
- [x] `backend/internal/mcp/server.go` - MCP server implementation, handler registry
- [x] `backend/internal/mcp/resources.go` - MCP resource providers
- [x] `backend/internal/mcp/tools.go` - MCP tool implementations
- [x] `backend/internal/mcp/transport_stdio.go` - STDIO transport handler
- [x] `docs/MCP_SETUP.md` - Setup and usage documentation
- [x] `.claude/mcp-config-example.json` - Example Claude Desktop config
- [ ] `backend/cmd/mcp-server/main.go` - Standalone mode entry point (deferred)

### Files to Modify
- [x] `backend/cmd/server/main.go` - Add `--with-mcp` and `--mcp-profile-id` flags
- [x] `justfile` - Add MCP-related commands (run-with-mcp, build-mcp, mcp-list-profiles, mcp-setup-guide)

### Implementation Steps
- [x] **Phase 1: MCP Package Foundation**
  - Create `backend/internal/mcp/` package
  - Implement JSON-RPC 2.0 request/response types
  - Create STDIO transport handler (stdin/stdout)
  - Handle MCP initialization handshake
  - Add basic logging

- [x] **Phase 2: MCP Resources (Read-only)**
  - `vibecare://routines` - List all routines for profile
  - `vibecare://schedules` - List all schedules
  - `vibecare://actions` - List all actions
  - `vibecare://execution-logs` - Recent execution history
  - Connect to storage layer interface

- [x] **Phase 3: MCP Tools (Write operations)**
  - `create_routine` - Create routine with name, description
  - `get_routine` - Get routine details by name
  - `delete_routine` - Remove routine
  - `list_routines` - List all routines with filtering
  - `create_schedule` - Add RRule schedule to routine
  - `list_schedules` - List schedules for routine
  - `execute_routine` - Trigger routine immediately
  - Use storage layer directly for operations

- [x] **Phase 4: Embedded Mode Integration**
  - Add `--with-mcp` and `--mcp-profile-id` flags to `backend/cmd/server/main.go`
  - Initialize MCP server when flags are set
  - Pass storage.DB instance to MCP server
  - Add graceful shutdown for MCP transport

- [ ] **Phase 5: Standalone Mode (Optional - Deferred)**
  - Create `backend/cmd/mcp-server/main.go`
  - Implement gRPC client wrapper around storage operations
  - Support same config format

- [x] **Phase 6: Documentation**
  - Create MCP_SETUP.md with usage instructions
  - Create example Claude Desktop config
  - Document RRule format examples

### Testing Plan
- [ ] Manual: Start backend with `just run --with-mcp`
- [ ] Manual: Create test profile if needed
- [ ] Manual: Add to Claude Desktop config (~/.claude/config.json)
- [ ] Manual: Open Claude Desktop, verify MCP server connected
- [ ] Manual: Ask Claude to create a simple routine
- [ ] Verify: Check backend DB has new routine (`just inspect-db`)
- [ ] Manual: Ask Claude to list routines
- [ ] Manual: Ask Claude to create a schedule for the routine
- [ ] Verify: Schedule appears in database
- [ ] Manual: Test standalone mode `just mcp-server` (optional)

---

## Implementation Log

### [2025-10-30] - Base MCP Server Implementation

**Changes Made:**

1. **Created MCP Protocol Foundation** (`backend/internal/mcp/protocol.go:1-250`)
   - Implemented JSON-RPC 2.0 types (Request, Response, Notification, Error)
   - Defined MCP protocol types (Initialize, Tools, Resources, Content)
   - Added helper functions for creating responses and notifications
   - Clean type definitions following MCP spec 2024-11-05

2. **Created MCP Server** (`backend/internal/mcp/server.go:1-145`)
   - Implements handler registry pattern for extensibility
   - Handles initialize handshake with capability negotiation
   - Routes tool calls and resource reads to appropriate handlers
   - Integrated with zap logger for structured logging
   - Initialization state management

3. **Implemented STDIO Transport** (`backend/internal/mcp/transport_stdio.go:1-145`)
   - Reads JSON-RPC messages from stdin line-by-line
   - Writes responses to stdout with newline delimiter
   - Graceful shutdown with context cancellation
   - 1MB message size limit for safety
   - Background goroutine for continuous reading

4. **Created MCP Tools** (`backend/internal/mcp/tools.go:1-530`)
   - `list_routines` - Lists routines with enabled filter
   - `create_routine` - Creates routine with UUID generation
   - `get_routine` - Gets routine details by name with schedules
   - `delete_routine` - Deletes routine by name
   - `create_schedule` - Creates RRule schedule for routine
   - `list_schedules` - Lists schedules for specific routine
   - `execute_routine` - Executes routine and creates execution log
   - Rich tool descriptions with RRule examples for LLM guidance

5. **Implemented MCP Resources** (`backend/internal/mcp/resources.go:1-230`)
   - `vibecare://routines` - JSON list of all routines
   - `vibecare://schedules` - JSON list of all schedules with routine names
   - `vibecare://actions` - JSON list of all actions
   - `vibecare://execution-logs` - JSON list of recent execution logs (last 100 per routine)
   - Individual routine resource: `vibecare://routines/{id}`

6. **Integrated with Backend** (`backend/cmd/server/main.go:16,34-35,84-98,153-159`)
   - Added `--with-mcp` flag to enable MCP server
   - Added `--mcp-profile-id` flag for profile configuration
   - MCP server starts in goroutine alongside gRPC/web servers
   - Graceful shutdown integrated into shutdown sequence
   - MCP stops before scheduler/web to ensure clean shutdown

7. **Documentation**
   - Created `docs/MCP_SETUP.md` - Complete setup guide with examples
   - Created `.claude/mcp-config-example.json` - Claude Desktop config template
   - Documented RRule format with common examples
   - Troubleshooting section for common issues

8. **Just Commands** (`justfile:99-144`)
   - `just run-with-mcp PROFILE_ID` - Run backend with MCP enabled
   - `just build-mcp` - Build binary with MCP support
   - `just mcp-list-profiles` - List available profile IDs from database
   - `just mcp-setup-guide` - Show quick setup instructions
   - New '🤖 MCP Server' command group for organization

**Design Decisions:**
- **No config file**: Use command-line flags for simplicity (--mcp-profile-id)
- **Embedded only**: Deferred standalone mode to future iteration
- **Tool-first approach**: Implemented 7 core tools before resources
- **Name-based lookup**: Tools accept routine names instead of UUIDs for better UX
- **Rich error messages**: All errors include helpful context for debugging

**Issues Encountered:**
- Initial build errors due to incorrect ExecutionLog method signatures
  - Fixed: GetExecutionLogs takes (routineID, limit) not (routineID, startTime, endTime, limit)
  - Fixed: CreateExecutionLog takes individual params, not *models.ExecutionLog struct
- Missing zap import in resources.go - added go.uber.org/zap

**Notes:**
- Backend builds successfully with all MCP features
- Ready for manual testing with Claude Desktop
- Future enhancements: HTTP+SSE transport, update_routine tool, pause/resume schedule tools

---

## Dependencies & Blockers

### Dependencies
- [x] VibeCare backend code (storage layer)
- [ ] Test profile created in backend
- [ ] Config file with valid profile UUID at `~/.vibecare/mcp-config.yaml`
- [ ] Claude Desktop installed and configured

### Questions
- [ ] Should we use existing Go JSON-RPC library or implement minimal version?
  - **Answer**: Start minimal, add library if needed
- [ ] What's the best way to describe RRule syntax to LLMs in tool descriptions?
  - **Answer**: Provide examples in tool descriptions, LLMs understand RRule format

---

## Completion Checklist

Before marking as 🟢 Completed:
- [ ] Backend builds with MCP package
- [ ] `--with-mcp` flag works correctly
- [ ] Can create routines from Claude Desktop
- [ ] Can create schedules with RRule
- [ ] Can list existing routines/schedules
- [ ] STDIO transport working in embedded mode
- [ ] Just commands added (`just run --with-mcp`)
- [ ] Example config file created at `~/.vibecare/mcp-config.yaml`
- [ ] Updated CLAUDE.md with MCP usage instructions

---

## Next Steps After Completion
- Document MCP usage examples
- Add natural language RRule generation helper
- Consider HTTP+SSE transport for remote use
- Add event streaming for real-time updates
