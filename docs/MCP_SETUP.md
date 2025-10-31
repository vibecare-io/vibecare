# VibeCare MCP Server Setup

## Overview

The VibeCare MCP (Model Context Protocol) server allows you to interact with your routines and schedules through natural language using Claude Desktop or other MCP-compatible clients.

**📋 For detailed implementation status and architecture, see [MCP_IMPLEMENTATION_STATUS.md](./MCP_IMPLEMENTATION_STATUS.md)**

VibeCare supports three deployment modes:

1. **HTTP Mode** (RECOMMENDED): MCP server runs as HTTP service - best for development
   - ✅ No orphan processes
   - ✅ Restart server without restarting Claude
   - ✅ Works with remote backends
   - ✅ Simple configuration

2. **Embedded Mode**: MCP server runs with backend in single process
   - Good for production single-server deployments
   - Requires rebuilding backend for MCP changes

3. **STDIO Mode** (Legacy): MCP server as separate process via command
   - May leave orphan processes
   - Use HTTP mode instead

## Quick Start - HTTP Mode (Recommended)

### 1. Configure MCP (One-time Setup)

Run the interactive configuration wizard to select your profile and save settings:

```bash
just mcp-configure
```

This will:
- List all available profiles from the database
- Let you select a profile interactively
- Prompt for optional settings (gRPC address, HTTP port)
- Save configuration to `~/.vibecare/config.yaml`

If you don't have any profiles yet:

```bash
# Create a new profile first
just grpc-create-profile "Your Name" "your@email.com"

# Then run configure
just mcp-configure
```

### 2. Start Backend Server

```bash
# Terminal 1: Start the backend gRPC server
just run
```

### 3. Start MCP HTTP Server

```bash
# Terminal 2: Start MCP server (uses config file)
just mcp-start-http-server

# Or with custom settings (overrides config):
just mcp-start-http-server YOUR_PROFILE_ID remote-host:50051 8082
```

The MCP server will start on `http://localhost:8081` by default (configurable).

The server implements the MCP Streamable HTTP transport (2025-06-18 specification) with the `/mcp` endpoint for all operations.

### 4. Configure Claude Desktop

**Important:** Claude Desktop does not support direct HTTP URLs. You need to use one of these approaches:

#### Option A: Use HTTP with mcp-remote proxy (Recommended)

First, install the mcp-remote bridge:
```bash
npm install -g mcp-remote
```

Then get your npx path (required for Claude Desktop):
```bash
which npx
# Example output: /Users/yourusername/.asdf/shims/npx
```

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "vibecare": {
      "command": "/absolute/path/to/npx",
      "args": ["-y", "mcp-remote", "http://localhost:8081/mcp"]
    }
  }
}
```

**Important:** Replace `/absolute/path/to/npx` with the actual path from `which npx`.

**Or use the helper command:**
```bash
just mcp-print-config
```
This will auto-detect your npx path and print the correct configuration.

This allows you to use HTTP mode with the benefits of:
- No orphan processes
- Restart server without restarting Claude
- Works with remote backends

#### Option B: Use embedded mode (Simplest)

This doesn't require HTTP server at all. Just run:

```bash
just run-with-mcp YOUR_PROFILE_ID
```

And configure:

```json
{
  "mcpServers": {
    "vibecare": {
      "command": "/absolute/path/to/vibecare/bin/vibecare-server",
      "args": ["--with-mcp", "--mcp-profile-id", "YOUR_PROFILE_ID"]
    }
  }
}
```

**Note:** Replace `/absolute/path/to/vibecare` with your actual project path. Use `pwd` in the project root to get it.

### 5. Restart Claude Desktop

Restart Claude Desktop once. After that, you can restart the MCP server anytime without restarting Claude.

## Configuration File

The configuration is stored in `~/.vibecare/config.yaml`:

```yaml
mcp:
  profile_id: YOUR_PROFILE_ID
  grpc_addr: localhost:50051
  port: 8081
```

You can:
- Edit this file manually
- Re-run `just mcp-configure` to change settings
- Override settings with command-line flags when starting the server

## Alternative Modes

### Embedded Mode

MCP server runs within the backend process. Good for production single-server deployments.

```bash
# Start backend with embedded MCP
just run-with-mcp YOUR_PROFILE_ID
```

**Claude config:**
```json
{
  "mcpServers": {
    "vibecare": {
      "command": "/path/to/vibecare/bin/vibecare-server",
      "args": ["--with-mcp", "--mcp-profile-id", "YOUR_PROFILE_ID"]
    }
  }
}
```

### STDIO Mode (Legacy)

**⚠️ Not recommended** - Use HTTP mode instead to avoid orphan processes.

If you must use STDIO mode:

```bash
just run-mcp-standalone YOUR_PROFILE_ID
```

**Claude config:**
```json
{
  "mcpServers": {
    "vibecare": {
      "command": "/path/to/vibecare/bin/vibecare-mcp-server",
      "args": ["--grpc-addr", "localhost:50051", "--profile-id", "YOUR_PROFILE_ID"]
    }
  }
}
```

**Note:** You may need to run `just mcp-cleanup` to kill orphaned processes.

## Usage Examples

Once configured, you can interact with VibeCare using natural language:

### Creating Routines

```
"Create a morning routine called 'Wake Up Routine' that I'll do every day"
```

### Viewing Routines

```
"Show me all my routines"
"What routines do I have?"
```

### Creating Schedules

```
"Schedule my morning routine to run every day at 7am"
"Add a schedule for 'Exercise' routine on Monday, Wednesday, and Friday at 6pm"
```

### Deleting Schedules

```
"Delete the morning schedule from my routine"
"Remove the daily 9am schedule from Exercise routine"
```

### Executing Routines

```
"Run my morning routine now"
"Execute the evening routine"
```

## Available Tools

The MCP server exposes the following tools:

- **list_routines** - List all routines
- **create_routine** - Create a new routine
- **get_routine** - Get details about a specific routine
- **delete_routine** - Delete a routine
- **create_schedule** - Create a recurring schedule using RRule format
- **list_schedules** - List schedules for a routine
- **delete_schedule** - Delete a schedule
- **execute_routine** - Execute a routine immediately

## Available Resources

The MCP server exposes these resources (read-only data):

- `vibecare://routines` - All routines as JSON
- `vibecare://schedules` - All schedules as JSON
- `vibecare://actions` - All actions as JSON
- `vibecare://execution-logs` - Recent execution history as JSON

## RRule Format

Schedules use RRule format (RFC 5545). Common examples:

```
Daily at 9am:
FREQ=DAILY;BYHOUR=9;BYMINUTE=0

Weekdays at 2:30pm:
FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=14;BYMINUTE=30

Every Monday at 10am:
FREQ=WEEKLY;BYDAY=MO;BYHOUR=10;BYMINUTE=0
```

Claude understands RRule format and can help you create the right schedule string.

## Troubleshooting

### "spawn npx ENOENT" Error

**Problem:** Claude Desktop can't find npx because GUI apps on macOS don't inherit your terminal's PATH.

**Solution:** Use the absolute path to npx in your configuration.

1. Find your npx path:
   ```bash
   which npx
   # Example: /Users/yourusername/.asdf/shims/npx
   ```

2. Use the full path in your Claude config:
   ```json
   {
     "mcpServers": {
       "vibecare": {
         "command": "/Users/yourusername/.asdf/shims/npx",
         "args": ["-y", "mcp-remote", "http://localhost:8081/mcp"]
       }
     }
   }
   ```

3. Or use the helper command to get the correct config:
   ```bash
   just mcp-print-config
   ```

**Common npx locations:**
- asdf: `~/.asdf/shims/npx`
- Homebrew (Apple Silicon): `/opt/homebrew/bin/npx`
- Homebrew (Intel): `/usr/local/bin/npx`
- nvm: `~/.nvm/versions/node/vX.X.X/bin/npx`

### MCP Server Not Connecting

1. Check Claude Desktop logs for connection errors (in Console.app, search for "Claude")
2. Verify the MCP HTTP server is running: `just mcp-start-http-server`
3. Verify the backend gRPC server is running: `just run`
4. Test the HTTP endpoint: `curl http://localhost:8081`
5. Ensure `mcp-remote` is installed: `npm list -g mcp-remote`

### No Routines Found

1. Verify you're using the correct profile ID
2. Check config file: `cat ~/.vibecare/config.yaml`
3. Create a test routine using the tool: `create_routine`

### Backend Logs

The backend logs MCP activity. Look for lines like:

```
INFO    Initializing MCP server    {"profile_id": "..."}
DEBUG   Handling MCP request       {"method": "tools/call", "id": 1}
```

## Development

### Running in Development

```bash
# Terminal 1: Run backend with MCP
cd backend
go run ./cmd/server --with-mcp --mcp-profile-id YOUR_PROFILE_ID

# The backend will run until you stop it with Ctrl+C
```

### Testing MCP Directly

You can test the MCP server directly using the MCP Inspector tool or by sending JSON-RPC messages to stdin.

Example initialize request:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
```

## Next Steps

- Add actions to your routines
- Create complex schedules
- View execution history through resources
- Integrate with other MCP-compatible tools
