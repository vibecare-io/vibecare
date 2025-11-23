# VibeCare macOS Swift Client

## Architecture Overview

The VibeCare macOS client is a **server-centric, MVVM-based native application** built with SwiftUI. It communicates with the backend exclusively via gRPC using Protocol Buffers for type-safe data transfer.

**Key Architectural Decision**: This client follows a **server-first architecture** with in-memory state management. There is **no local persistence layer** (SQLite, CoreData, etc.) and no offline-first sync capabilities.

## Directory Structure

```
clients/macos-swift/VibeCare/
├── Package.swift                    # Swift Package Manager configuration
├── VCStubs/                        # Generated protobuf/gRPC stubs (do not edit)
│   ├── vibecare.grpc.swift        # Generated gRPC service clients
│   └── vibecare.pb.swift          # Generated protobuf messages
└── vibecare/                       # Main application source
    ├── App.swift                   # Application entry point
    ├── AppDelegate.swift           # macOS app delegate (lifecycle, menu bar)
    ├── ContentView.swift           # Root view container
    │
    ├── Models/                     # Domain models (8 files)
    │   ├── Action.swift           # Action entity with type enum and parameters
    │   ├── ExecutionLog.swift     # Routine execution audit trail
    │   ├── NotificationPreferences.swift
    │   ├── Profile.swift          # User profile with optional email
    │   ├── Routine.swift          # Routine metadata (no embedded actions)
    │   ├── RoutineScheduleTemplate.swift
    │   ├── Schedule.swift         # Schedule with RRule parsing/generation
    │   └── SVGIcon.swift          # Icon metadata with dynamic URL
    │
    ├── Services/                   # Service layer (16 files)
    │   ├── GRPCClientManager.swift         # gRPC connection lifecycle manager
    │   ├── ProfileService.swift            # Profile CRUD + device management
    │   ├── RoutineService.swift            # Routine CRUD + execution control
    │   ├── ScheduleService.swift           # Schedule CRUD + schedule-action association
    │   ├── ActionService.swift             # Action CRUD operations
    │   ├── EventService.swift              # Real-time event streaming (SSE)
    │   ├── ScheduleTemplateService.swift   # Template management
    │   ├── SVGIconManager.swift            # Icon loading from backend
    │   ├── TemplateConfigLoader.swift      # Bundled template JSON loader
    │   ├── NotificationManager.swift       # VibeNotify integration
    │   ├── NotificationPolicy.swift        # Notification display rules
    │   ├── StatusBarManager.swift          # Transient status messages
    │   ├── OTELManager.swift              # OpenTelemetry instrumentation
    │   ├── ViewInstrumentation.swift       # View-level tracing
    │   ├── VibeNotifyConfiguration.swift   # Notification config
    │   └── LinkHandler.swift              # URL scheme handling
    │
    ├── ViewModels/                 # Business logic layer (5 files)
    │   ├── AppState.swift         # Global app state (singleton)
    │   ├── RoutineViewModel.swift # Routine list management
    │   ├── ScheduleViewModel.swift # Schedule list + validation
    │   ├── ActionViewModel.swift   # Action list management
    │   └── NotificationActionViewModel.swift
    │
    ├── Views/                      # SwiftUI views (70+ files)
    │   ├── Actions/               # Action management views
    │   ├── Common/                # Reusable view utilities
    │   ├── Components/            # Reusable UI components
    │   ├── Dashboard/             # Main dashboard
    │   ├── Logs/                  # Execution log views
    │   ├── Routines/              # Routine management views
    │   ├── Schedules/             # Schedule management (15 files)
    │   ├── Settings/              # Settings and preferences
    │   └── Testing/               # Development/testing views
    │
    ├── Utilities/
    │   └── NetworkConfiguration.swift  # Backend URL management
    │
    └── Resources/
        ├── TemplateConfigs.json    # Bundled schedule templates
        └── SVGIcons/
            └── SVGIconCatalog.json # Icon catalog (actual icons from backend)
```

**Total Code**: ~21,179 lines of Swift across 70+ files

## Application Entry Point

**File**: `vibecare/App.swift`

### Initialization Flow

1. **@main Entry Point** (Line 5-6):
   - SwiftUI `App` protocol with `NSApplicationDelegateAdaptor`
   - Creates singleton `AppState` instance

2. **Startup Sequence** (Lines 11-24):
   ```swift
   init() {
       // 1. Configure logging
       LoggingSystem.bootstrap(StreamLogHandler.standardOutput)

       // 2. Initialize OpenTelemetry
       OTELManager.shared  // Lazy initialization

       // 3. gRPC connection deferred until view appears
   }
   ```

3. **Lifecycle Events** (Lines 30-44):
   - `onAppear`: Calls `AppState.loadInitialData()`
   - Notification observers for app activation state
   - Reconnects event stream when app becomes active

### Application Structure

The app provides three main windows:

1. **Main Window** (Lines 27-48): Dashboard view with navigation
2. **Menu Bar Extra** (Lines 49-58): Status bar icon with quick actions
3. **Settings Window** (Lines 60-67): Preferences and configuration

## Architecture Pattern: Server-First MVVM

### Data Flow

```
User Interaction
    ↓
SwiftUI View
    ↓
ViewModel (@Published state)
    ↓
Service Layer
    ↓
GRPCClientManager
    ↓
gRPC Call → Backend Server
    ↓
Protobuf Response
    ↓
Service converts to Swift model
    ↓
ViewModel updates @Published property
    ↓
SwiftUI View automatically refreshes
```

### State Management

**Global State**: `AppState` (singleton)
- Current profile and profile list
- Connection status
- Global loading states
- Event stream coordination

**Feature ViewModels**: Manage feature-specific state
- `RoutineViewModel`: Routine list and CRUD operations
- `ScheduleViewModel`: Schedule list, validation, statistics
- `ActionViewModel`: Action list and CRUD operations

**State Synchronization**:
- ViewModels observe `NotificationCenter` for profile changes
- `EventService` broadcasts backend events via NotificationCenter
- All ViewModels reload data when profile switches

### No Local Persistence

**Critical**: This client has **no local database or persistent cache**.

**What this means**:
- All CRUD operations require active backend connection
- No offline functionality (returns empty arrays on connection failure)
- No conflict resolution or sync managers
- App state is rebuilt from backend on each launch
- Only in-memory caching via ViewModel @Published properties

**Configuration Storage**: Only UserDefaults for:
- Network configuration (`grpc_url`, `backend_url`)
- Current profile ID (for quick startup)

## Service Layer Architecture

### GRPCClientManager: Connection Lifecycle

**Pattern**: `withXServiceClient` methods provide connection management:

```swift
// Example usage
let profiles = try await GRPCClientManager.shared.withProfileServiceClient { client in
    let response = try await client.listProfiles(...)
    return profiles
}
// Connection automatically closed
```

**Available Service Clients**:
- `withProfileServiceClient` → VCProfileService
- `withRoutineServiceClient` → VCRoutineService
- `withScheduleServiceClient` → VCScheduleService
- `withActionServiceClient` → VCActionService
- `withEventServiceClient` → VCEventService
- `withTemplateServiceClient` → VCScheduleTemplateService
- `withIconServiceClient` → VCIconService

### Core Services

#### ProfileService
**File**: `Services/ProfileService.swift`

**Features**:
- Profile CRUD operations
- Device registration/unregistration
- Optional email support (converts empty string ↔ nil)

**Key Methods**:
- `listProfiles()` → Returns empty array if backend unavailable
- `createProfile(name, email?)` → Creates with optional email
- `updateProfile(id, name, email?)` → Updates profile
- `registerDevice(profileId, deviceId, deviceType)` → Associates device

#### RoutineService
**File**: `Services/RoutineService.swift`

**Features**:
- Routine CRUD (no embedded actions)
- Execution control (enable/disable/execute immediately)
- Execution log retrieval

**Note**: Routines are "simple metadata containers" - actions managed separately via schedule-action associations.

#### ScheduleService
**File**: `Services/ScheduleService.swift`

**Features**:
- Schedule CRUD with RRule strings
- Schedule operations (pause/resume)
- Next execution calculation

**Schedule-Action Association** (Lines 304-381):
- `getScheduleActions(scheduleId)` → Fetch actions for schedule
- `addActionToSchedule(scheduleId, actionId, order)` → Add action with ordering
- `removeActionFromSchedule(scheduleId, actionId)` → Remove association
- `updateScheduleActionOrder(scheduleId, actionId, order)` → Change order
- `replaceScheduleActions(scheduleId, actionIds)` → Bulk replace

**Architecture**: Actions are managed via `schedule_actions` join table, not embedded in schedules.

#### ActionService
**File**: `Services/ActionService.swift`

**Features**:
- Action CRUD operations
- 8 action types: notification, open_link, run_script, api_call, display_message, system_command, log_entry, custom
- Parameters stored as `[String: String]` dictionary
- Required parameter validation per type

#### EventService: Real-Time Updates
**File**: `Services/EventService.swift`

**Purpose**: Listen for backend events and execute actions locally.

**Flow**:
1. `startListening(for profileId)` → Opens gRPC streaming connection
2. Receives `scheduleTriggered` or `routineExecuted` events
3. Fetches schedule details from backend
4. Fetches action IDs from `schedule_actions` table
5. Fetches full action details
6. Executes actions locally based on type:
   - `notification` → Shows via NotificationManager
   - `open_link` → Opens URL
   - `run_script` → Executes shell command
   - etc.

**Event Broadcasting**: Posts to NotificationCenter for UI updates

### Supporting Services

#### SVGIconManager
**File**: `Services/SVGIconManager.swift`

**Architecture Shift**: Icons moved from local bundle to backend HTTP API.

**Flow**:
1. Loads icon metadata via gRPC `IconService`
2. Constructs icon URLs dynamically from `backend_url` UserDefaults
3. SwiftUI views load images via HTTP from backend

**URL Construction**: `NetworkConfiguration.buildIconURL(iconId: "icon-123")`
→ `http://localhost:8080/api/icons/icon-123.svg`

#### TemplateConfigLoader
**File**: `Services/TemplateConfigLoader.swift`

**Purpose**: Load bundled schedule templates from `Resources/TemplateConfigs.json`

**Template Structure**:
- Category (daily, weekly, monthly_yearly)
- Routine metadata (name, icon, color)
- Default RRule string
- Notification configuration with icon_id

**Dynamic Icon URLs**: Builds URLs from current backend_url configuration

#### NotificationManager
**File**: `Services/NotificationManager.swift`

**Library**: Uses custom [VibeNotify](https://github.com/vibecare-io/vibe-notify-macos)

**Features**:
- Custom notification layouts
- Position control (center, top-right, etc.)
- Auto-dismiss with duration
- Interactive actions
- Bypasses native UNUserNotificationCenter for custom styling

#### OTELManager
**File**: `Services/OTELManager.swift`

**Purpose**: OpenTelemetry instrumentation for observability

**Integration**:
- Sends traces to backend's OTLP collector
- View-level instrumentation via `ViewInstrumentation.swift`
- Automatic gRPC call tracing

## Domain Models

All models are simple Swift structs with no persistence annotations.

### Profile
**File**: `Models/Profile.swift`

```swift
struct Profile: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var email: String?        // Optional email
    var devices: [Device]
    var preferences: [String: String]
}
```

### Routine
**File**: `Models/Routine.swift`

```swift
struct Routine: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: String
    var profileId: String
    var name: String
    var description: String
    var metadata: [String: String]  // category, color, icon, tags
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date
    // Note: No action references - managed via schedule-action join table
}
```

### Schedule
**File**: `Models/Schedule.swift`

```swift
struct Schedule: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: String
    var profileId: String
    var routineId: String
    var name: String
    var rrule: String           // RRule string (RFC 5545)
    var dtstart: Date
    var priority: Priority      // none, low, medium, high
    var enabled: Bool
    // Note: No action IDs - managed via schedule-action join table

    // Computed properties
    var ruleComponents: RRuleComponents?  // Parsed RRule
    var humanReadableRRule: String        // "Daily at 9:00 AM"
    var nextExecution: Date?              // Calculated from RRule
    var status: ScheduleStatus            // scheduled, upcoming, overdue, disabled
}
```

**RRule Features**:
- Full RFC 5545 support (DAILY, WEEKLY, MONTHLY, YEARLY)
- Complex recurrence patterns (BYHOUR, BYMINUTE, BYDAY, BYMONTHDAY, etc.)
- Human-readable descriptions
- Next execution calculation

### Action
**File**: `Models/Action.swift`

```swift
enum ActionType: String, Codable, CaseIterable {
    case notification
    case open_link
    case run_script
    case api_call
    case display_message
    case system_command
    case log_entry
    case custom
}

struct Action: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: String
    var profileId: String
    var name: String
    var type: ActionType
    var parameters: [String: String]  // Type-specific parameters
    var enabled: Bool

    // Required parameters per type
    static func requiredParameters(for type: ActionType) -> [String]
}
```

**Parameter Examples**:
- `notification`: title, body, icon_id, sound, duration
- `open_link`: url
- `run_script`: script_path, args
- `api_call`: url, method, headers, body

### SVGIcon
**File**: `Models/SVGIcon.swift`

```swift
struct SVGIcon: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var name: String
    var category: String
    var filename: String
    var keywords: [String]

    var iconURL: URL? {
        // Dynamically builds URL from UserDefaults backend_url
        NetworkConfiguration.buildIconURL(iconId: id)
    }
}
```

## Configuration

### Package Dependencies
**File**: `Package.swift`

**Platform**: macOS 15+ only

**Key Dependencies**:
- **gRPC Swift 2.x**: Backend communication
- **Swift Protobuf**: Message serialization
- **swift-log**: Structured logging
- **OpenTelemetry Swift**: Distributed tracing
- **VibeNotify**: Custom macOS notifications

### Network Configuration
**File**: `Utilities/NetworkConfiguration.swift`

**UserDefaults Keys**:
- `grpc_url`: Full gRPC URL (e.g., `grpc://localhost:50051`)
  - Legacy fallback: `grpc_host`, `grpc_port`, `grpc_use_tls`
- `backend_url`: HTTP backend URL (e.g., `http://localhost:8080`)

**Utility Methods**:
- `getBackendURL()` → HTTP URL for web resources (icons, etc.)
- `getGRPCURL()` → gRPC connection URL
- `buildIconURL(iconId)` → Full icon URL
- `parseGRPCURL()` → Parse into host/port/TLS components

**Defaults**:
- gRPC: `grpc://localhost:50051`
- HTTP: `http://localhost:8080`

### Bundled Resources

**TemplateConfigs.json** (`Resources/TemplateConfigs.json`):
- Predefined schedule templates
- Categories: daily, weekly, monthly_yearly
- Includes routine metadata, RRule, notification config

**SVGIconCatalog.json** (`Resources/SVGIcons/SVGIconCatalog.json`):
- Icon catalog metadata only
- Actual icon files served from backend HTTP API

## Development Workflow

### Building and Running

```bash
# From project root
cd clients/macos-swift/VibeCare

# Build
swift build

# Run
swift run

# Or use just commands from project root
just swift-build
just swift-run
just swift-test
```

### Generating Protobuf Stubs

When protobuf definitions change in `proto/vibecare.proto`:

```bash
# From project root
just proto-gen
```

This regenerates:
- `VCStubs/vibecare.pb.swift` (messages)
- `VCStubs/vibecare.grpc.swift` (service clients)

**Never edit files in `VCStubs/` directly** - they are auto-generated.

### Testing

```bash
# Run all tests
swift test

# Or from project root
just swift-test
```

### Debugging

**Logging**:
- Uses `swift-log` with console output
- Configure log level in `App.swift` init

**OpenTelemetry Tracing**:
- View traces in Jaeger: http://localhost:16686
- Traces include:
  - View lifecycle events
  - gRPC calls
  - Service method execution

**Connection Issues**:
- Check UserDefaults for `grpc_url` and `backend_url`
- Verify backend is running: `just run` (from project root)
- Check logs for gRPC connection errors

## Key Architectural Patterns

### 1. Service-Oriented Architecture
Each backend service has a corresponding Swift service wrapper with protobuf conversion.

### 2. Connection Lifecycle Management
`withXServiceClient` pattern handles connection creation/teardown automatically.

### 3. Event-Driven Updates
- `EventService` streams real-time events from backend
- `NotificationCenter` for cross-component communication
- Combine publishers for reactive state updates

### 4. MVVM with Dependency Injection
- Views depend on ViewModels via @StateObject/@ObservedObject
- ViewModels create services internally
- Services use `GRPCClientManager.shared` singleton

### 5. Protocol Buffers for Type Safety
All backend communication uses generated protobuf stubs, ensuring compile-time type safety.

## Important Implementation Notes

### Email is Optional
- `Profile.email` is `String?`
- Services convert empty string ↔ nil automatically
- Backend validates email format if provided

### Schedule-Action Relationship
- **Architecture**: Join table (`schedule_actions`)
- **Benefits**:
  - Actions can be reused across schedules
  - Ordering via `action_order` field
  - Bulk updates via `replaceScheduleActions`

### Icon Management
- **Shift**: Icons moved from local bundle to backend HTTP API
- **Flow**:
  1. Load metadata via gRPC `IconService`
  2. Display images via HTTP URLs
  3. URLs dynamically constructed from `backend_url`

### Real-Time Execution
- `EventService` receives schedule triggers
- Fetches actions on-demand from backend
- Executes locally (notifications, links, scripts, etc.)
- No local action queue or retry logic

### Optimistic Updates
**Limited usage** - only in `AppState.updateProfile()`:
- Updates local state immediately
- Syncs to server in background
- On failure: logs error but keeps local change
- Most operations wait for server confirmation

## Common Tasks

### Adding a New View

1. Create SwiftUI view in appropriate `Views/` subdirectory
2. Add to navigation in `ContentView.swift` or feature view
3. Create ViewModel if business logic needed
4. Use existing services for data operations

### Adding a New Service Method

1. Define RPC in `proto/vibecare.proto` (backend repository)
2. Run `just proto-gen` to regenerate stubs
3. Add method to appropriate service file (e.g., `ProfileService.swift`)
4. Add protobuf ↔ Swift model conversion
5. Update ViewModel to call new method

### Changing Network Configuration

Edit UserDefaults (or add UI in Settings):
```swift
UserDefaults.standard.set("http://192.168.1.100:8080", forKey: "backend_url")
UserDefaults.standard.set("grpc://192.168.1.100:50051", forKey: "grpc_url")
```

Restart app to use new configuration.

### Adding a New Action Type

1. Add case to `ActionType` enum in `Models/Action.swift`
2. Define required parameters in `requiredParameters(for:)` method
3. Add execution logic in `EventService.swift` event handlers
4. Update action creation UI in `Views/Actions/`

## Future Considerations

### Potential Offline Support

To add offline functionality, consider:
1. **Local Storage Layer**: Add SQLite or CoreData
2. **Sync Managers**: Bidirectional sync between local and backend
3. **Conflict Resolution**: Last-write-wins or user-driven
4. **Local Write-Through Cache**: Write locally first, sync in background
5. **Retry Logic**: Queue failed operations for retry

**Note**: Current architecture would require significant refactoring to support offline-first patterns.

### Performance Optimization

- Add in-memory caching in services (LRU cache)
- Batch gRPC calls where possible
- Pagination for large lists
- Lazy loading for views with many items

### Error Handling

Current error handling is basic (logs + empty arrays). Consider:
- User-facing error messages
- Retry logic for transient failures
- Connection status monitoring
- Graceful degradation

## Troubleshooting

### App Won't Connect to Backend

1. Check backend is running: `just run` (from project root)
2. Verify network configuration in UserDefaults
3. Check firewall/network settings
4. View logs in Console.app (search for "vibecare")

### Protobuf Compilation Errors

1. Ensure protobuf definitions are valid: `just proto-gen`
2. Clean build: `swift package clean && swift build`
3. Verify gRPC Swift version in Package.swift matches backend

### Notifications Not Showing

1. Check macOS notification permissions (System Preferences → Notifications)
2. Verify `NotificationManager` configuration
3. Check `EventService` is receiving events
4. View OpenTelemetry traces for notification execution

### Icons Not Loading

1. Verify backend is serving icons at `/api/icons/`
2. Check `backend_url` in UserDefaults
3. Inspect network requests in Console.app
4. Verify icon IDs match backend catalog

## References

- **VibeNotify Library**: https://github.com/vibecare-io/vibe-notify-macos
- **Swift Protobuf**: https://github.com/apple/swift-protobuf
- **gRPC Swift**: https://github.com/grpc/grpc-swift
- **RRule Specification**: RFC 5545 (iCalendar Recurrence Rules)
