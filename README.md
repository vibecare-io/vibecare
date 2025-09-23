# VibeCare

A modern wellness and routine management app with native macOS/iOS clients and a Go backend.

## Architecture

- **Backend**: Go with gRPC, SQLite, and RRule-based scheduling
- **Protocol**: Protocol Buffers (protobuf) for type-safe communication
- **Clients**: Native Swift for macOS/iOS, Kotlin for Android, GTK for Linux
- **Database**: SQLite with Goose migrations

## Project Structure

```
vibecare/
├── proto/              # Protocol Buffer definitions
├── backend/            # Go backend server
│   ├── cmd/server/     # Main server entry point
│   ├── internal/       # Internal packages
│   │   ├── api/        # gRPC service implementations
│   │   ├── models/     # Domain models
│   │   ├── storage/    # Database layer
│   │   ├── scheduler/  # Scheduling engine
│   │   └── actions/    # Action executors
│   └── pkg/proto/      # Generated protobuf code
├── clients/
│   └── macos-swift/    # macOS/iOS Swift client
└── scripts/            # Build and utility scripts
```

## Prerequisites

- Go 1.21+
- Protocol Buffers compiler (`protoc`)
- SQLite 3
- Just command runner (`brew install just`)
- Xcode (for macOS client)

## Quick Start

1. **Install dependencies and setup**:
```bash
just setup
```

2. **Run the server**:
```bash
just run
```

3. **Build the macOS client**:
```bash
just macos-build
```

## Development

### Available Commands

```bash
just              # Show all available commands
just setup        # Initial setup
just run          # Run the server
just test         # Run tests
just proto        # Generate protobuf code
just migrate      # Run database migrations
just db           # Connect to SQLite database
just watch        # Auto-reload on changes
```

### Creating a New Migration

```bash
just new-migration add_user_settings
```

### Testing gRPC APIs

```bash
# List available services
just grpc-test

# Create a profile
just grpc-create-profile "John Doe" "john@example.com"
```

## Core Concepts

### Profiles
User accounts that own routines and have preferences.

### Actions
Everything in VibeCare is an action:
- Notifications
- Open links
- Send emails
- Run scripts
- Play sounds
- System commands
- API calls

### Routines
Collections of actions that execute together on a schedule.

### Schedules
RRule-based recurring schedules (RFC 5545 compatible) that trigger routines.

### Execution Logs
Track when routines ran and whether they completed successfully.

## API Example

### Create a Profile
```protobuf
rpc CreateProfile(CreateProfileRequest) returns (CreateProfileResponse);
```

### Create a Routine with Actions
```protobuf
rpc CreateRoutine(CreateRoutineRequest) returns (CreateRoutineResponse);
```

### Set up a Schedule
```protobuf
rpc CreateSchedule(CreateScheduleRequest) returns (Schedule);
```

## RRule Examples

Daily at 9 AM and 6 PM:
```json
{
  "freq": "DAILY",
  "interval": 1,
  "byhour": [9, 18],
  "byminute": [0]
}
```

Every weekday at 2 PM:
```json
{
  "freq": "WEEKLY",
  "byday": ["MO", "TU", "WE", "TH", "FR"],
  "byhour": [14],
  "byminute": [0]
}
```

## License

MIT