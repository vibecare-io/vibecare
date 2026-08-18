# Actions Implementation Guide

## Overview
This document tracks the implementation of reusable actions for schedules, enabling users to define what happens when a schedule triggers (notifications, opening links, playing sounds, running scripts, etc.).

## Status: Backend Foundation Complete ✅

### Completed (Backend)
- ✅ Protobuf schema updated with `action_ids` field in Schedule message
- ✅ Database migration created (actions table + action_ids column)
- ✅ Backend models updated (Action & Schedule with ActionIDs)
- ✅ Action storage layer implemented (CRUD operations)
- ✅ Schedule storage partially updated (CreateSchedule & GetSchedule)
- ✅ Backend compiles successfully

### Architecture Overview

**Database Schema:**
```sql
-- Actions are independent, reusable entities
CREATE TABLE actions (
    action_id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL,
    type TEXT NOT NULL,  -- notification, open_link, send_email, etc.
    name TEXT NOT NULL,
    description TEXT,
    parameters_json TEXT DEFAULT '{}',
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE
);

-- Schedules reference actions via JSON array
ALTER TABLE schedules ADD COLUMN action_ids TEXT DEFAULT '[]';
```

**Action Types Supported:**
1. `notification` - Show system notification
2. `open_link` - Open URL in browser
3. `send_email` - Send email
4. `run_script` - Execute shell script
5. `play_sound` - Play audio file
6. `system_command` - System command (e.g., lock screen)
7. `api_call` - Webhook/API call
8. `log_entry` - Create log entry

**Data Flow:**
```
1. User creates action (e.g., "Join Zoom" with URL parameter)
2. User creates schedule and attaches action_ids
3. Backend stores schedule with action_ids as JSON array
4. Schedule triggers → Backend sends ScheduleTriggeredEvent (with schedule_id)
5. Client looks up schedule in local storage → gets action_ids
6. Client fetches actions by IDs from local storage
7. Client executes each action in parallel
```

## Remaining Work

### 1. Backend - Schedule Storage Functions (1-2 hours)

**Files to Update:**
- `backend/internal/storage/schedule.go`

**Functions to Update:**
```go
// Add action_ids to SELECT queries and scanning
- ListSchedulesByRoutine(routineID string)
- GetActiveSchedules()
- UpdateSchedule(...)
- Any other schedule query functions
```

**Pattern to Follow:**
```go
// In SELECT query
SELECT schedule_id, ..., action_ids, created_at, updated_at

// In Scan()
var actionIDsJSON sql.NullString
err := rows.Scan(..., &actionIDsJSON, ...)

// After scan
if actionIDsJSON.Valid && actionIDsJSON.String != "" {
    json.Unmarshal([]byte(actionIDsJSON.String), &schedule.ActionIDs)
} else {
    schedule.ActionIDs = []string{}
}
```

### 2. Backend - ActionService gRPC API (2-3 hours)

**Create File:**
- `backend/internal/api/action_service.go`

**Implement Methods:**
```go
// Action CRUD
- CreateAction(ctx, *pb.CreateActionRequest) (*pb.Action, error)
- GetAction(ctx, *pb.GetActionRequest) (*pb.Action, error)
- UpdateAction(ctx, *pb.UpdateActionRequest) (*pb.Action, error)
- DeleteAction(ctx, *pb.DeleteActionRequest) (*empty.Empty, error)
- ListActions(ctx, *pb.ListActionsRequest) (*pb.ListActionsResponse, error)

// Action operations
- ExecuteAction(ctx, *pb.ExecuteActionRequest) (*pb.ExecuteActionResponse, error)
- ValidateAction(ctx, *pb.ValidateActionRequest) (*pb.ValidateActionResponse, error)
- ListActionTypes(ctx, *pb.ListActionTypesRequest) (*pb.ListActionTypesResponse, error)
```

**Register Service:**
Update `backend/internal/api/server.go`:
```go
func RegisterServices(grpcServer *grpc.Server, db *storage.DB, eventHub *scheduler.EventHub, logger *zap.Logger) {
    server := NewServer(db, eventHub, logger)

    pb.RegisterProfileServiceServer(grpcServer, server)
    pb.RegisterRoutineServiceServer(grpcServer, server)
    pb.RegisterScheduleServiceServer(grpcServer, server)
    pb.RegisterActionServiceServer(grpcServer, server)  // ADD THIS
    pb.RegisterEventServiceServer(grpcServer, server)
}
```

### 3. Swift - Action Model Updates (30 min)

**File:**
- `clients/macos-swift/VibeCare/vibecare/Models/Action.swift`

**Already exists! Just verify:**
```swift
struct Action: Identifiable, Codable {
    let id: String
    let profileId: String
    var type: ActionType
    var name: String
    var description: String
    var parameters: [String: String]
    let createdAt: Date
}

enum ActionType: String, Codable {
    case notification
    case openLink
    case sendEmail
    case runScript
    case playSound
    case systemCommand
    case apiCall
    case logEntry
}
```

### 4. Swift - ActionLocalStorage Service (1-2 hours)

**Create File:**
- `clients/macos-swift/VibeCare/vibecare/Services/ActionLocalStorage.swift`

**Implementation:**
```swift
class ActionLocalStorage: ObservableObject {
    static let shared = ActionLocalStorage()
    private let db: Connection

    // CRUD operations
    func createAction(_ action: Action) throws
    func getAction(id: String) throws -> Action?
    func getActionsByIDs(_ ids: [String]) throws -> [Action]
    func updateAction(_ action: Action) throws
    func deleteAction(id: String) throws
    func listActions(profileId: String) throws -> [Action]

    // Similar pattern to ScheduleLocalStorage
}
```

### 5. Swift - ActionService (gRPC Wrapper) (1 hour)

**Create File:**
- `clients/macos-swift/VibeCare/vibecare/Services/ActionService.swift`

**Implementation:**
```swift
class ActionService: ObservableObject {
    static let shared = ActionService()

    func createAction(_ action: Action) async throws -> Action
    func getAction(id: String) async throws -> Action
    func updateAction(_ action: Action) async throws -> Action
    func deleteAction(id: String) async throws
    func listActions(profileId: String) async throws -> [Action]

    // Uses GRPCClientManager to call backend
}
```

### 6. Swift - Update ScheduleLocalStorage (30 min)

**File:**
- `clients/macos-swift/VibeCare/vibecare/Services/ScheduleLocalStorage.swift`

**Updates:**
```swift
// Add actionIDs column to table creation
// Update INSERT/UPDATE to include actionIDs
// Update SELECT queries to read actionIDs
// Deserialize actionIDs JSON array
```

### 7. Swift - Update EventService (1 hour)

**File:**
- `clients/macos-swift/VibeCare/vibecare/Services/EventService.swift`

**Update handleScheduleTriggered:**
```swift
private func handleScheduleTriggered(_ event: VCScheduleTriggeredEvent) async {
    logger.info("Schedule triggered: \(event.scheduleName)")

    // 1. Fetch schedule from local storage
    guard let schedule = try? ScheduleLocalStorage.shared.getSchedule(id: event.scheduleID) else {
        logger.error("Schedule not found: \(event.scheduleID)")
        return
    }

    // 2. Fetch actions by IDs
    guard let actions = try? ActionLocalStorage.shared.getActionsByIDs(schedule.actionIDs) else {
        logger.error("Failed to fetch actions")
        return
    }

    // 3. Execute each action
    for action in actions {
        await executeAction(action, for: event)
    }
}

private func executeAction(_ action: Action, for event: VCScheduleTriggeredEvent) async {
    switch action.type {
    case .notification:
        await MainActor.run {
            NotificationManager.shared.executeAction(action, for: event)
        }
    case .openLink:
        await MainActor.run {
            LinkHandler.shared.executeAction(action)
        }
    default:
        logger.warning("Unsupported action type: \(action.type)")
    }
}
```

### 8. Swift - Create LinkHandler Service (30 min)

**Create File:**
- `clients/macos-swift/VibeCare/vibecare/Services/LinkHandler.swift`

**Implementation:**
```swift
import Foundation
import AppKit
import Logging

@MainActor
class LinkHandler: ObservableObject {
    static let shared = LinkHandler()
    private let logger = Logger(label: "com.vibecare.link-handler")

    private init() {}

    func executeAction(_ action: Action) {
        guard let urlString = action.parameters["url"],
              let url = URL(string: urlString) else {
            logger.error("Invalid URL in action: \(action.id)")
            return
        }

        logger.info("Opening URL: \(urlString)")
        NSWorkspace.shared.open(url)
    }
}
```

### 9. Swift - Update NotificationManager (30 min)

**File:**
- `clients/macos-swift/VibeCare/vibecare/Services/NotificationManager.swift`

**Add Method:**
```swift
func executeAction(_ action: Action, for event: VCScheduleTriggeredEvent) {
    let title = action.parameters["title"] ?? event.scheduleName
    let body = action.parameters["body"] ?? "Scheduled: \(event.routineName)"

    let notificationID = VibeNotifyConfig.showScheduleNotification(
        scheduleName: title,
        routineName: body,
        scheduledTime: event.hasScheduledTime ? event.scheduledTime.date : Date(),
        notes: nil,
        preferences: nil
    )

    logger.info("Executed notification action: \(action.id)")
}
```

### 10. Swift - ActionSyncManager (2 hours)

**Create File:**
- `clients/macos-swift/VibeCare/vibecare/Services/ActionSyncManager.swift`

**Implementation:**
Similar to ScheduleSyncManager:
- Bidirectional sync between local storage and backend
- Push local changes to backend
- Pull backend changes to local storage

### 11. UI - Action Management Views (3-4 hours)

**Create Files:**
- `Views/Actions/ActionsListView.swift`
- `Views/Actions/ActionEditView.swift`

**Features:**
- List all actions for current profile
- Filter by action type
- Create new action with type-specific form
- Edit existing action
- Delete action
- Show which schedules use each action

### 12. UI - Update Schedule Editor (2 hours)

**File:**
- `Views/Schedules/ScheduleEditView.swift`

**Add Section:**
```swift
Section("Actions") {
    // List selected actions
    ForEach(selectedActions) { action in
        ActionRowView(action: action)
    }

    // Add action button
    Button("+ Add Action") {
        showActionPicker = true
    }
}
.sheet(isPresented: $showActionPicker) {
    ActionPickerView(selectedActionIDs: $schedule.actionIDs)
}
```

## Testing Checklist

### Backend Tests
- [ ] Create action via gRPC → verify stored in DB
- [ ] Get action by ID → verify parameters retrieved
- [ ] Update action → verify changes persisted
- [ ] Delete action → verify removed from DB
- [ ] List actions by profile → verify filtering works
- [ ] Create schedule with action_ids → verify JSON stored
- [ ] Get schedule → verify action_ids deserialized correctly

### Swift Client Tests
- [ ] Create action locally → verify in SQLite
- [ ] Sync action to backend → verify on server
- [ ] Create schedule with action_ids → verify stored
- [ ] Sync schedule to backend → verify action_ids synced
- [ ] Trigger schedule with notification action → verify notification appears
- [ ] Trigger schedule with open_link action → verify browser opens
- [ ] Trigger schedule with both actions → verify both execute
- [ ] Test offline: trigger schedule without network → verify actions work from local storage

### End-to-End Scenarios
- [ ] Daily standup: notification + Zoom link
- [ ] Hourly stretch: notification + YouTube video
- [ ] Water reminder: notification only
- [ ] Pomodoro: notification + focus app link

## Example Action Configurations

> This document is a build plan from 2025-10-13, not a parameter reference. The
> current, complete list of `notification` action `parameters` keys — including
> the break-countdown keys (`task_timer_seconds` and friends) and how they
> resolve against the user's global notification settings — lives in
> [`clients/macos-swift/VibeCare/CLAUDE.md`](../clients/macos-swift/VibeCare/CLAUDE.md#action-parameters-keys).

### Meeting Reminder
```json
{
  "id": "act-001",
  "type": "notification",
  "name": "Standup Reminder",
  "parameters": {
    "title": "Daily Standup",
    "body": "Starting in 5 minutes"
  }
}
```

### Open Link
```json
{
  "id": "act-002",
  "type": "open_link",
  "name": "Join Zoom",
  "parameters": {
    "url": "https://zoom.us/j/123456789"
  }
}
```

### Schedule with Actions
```json
{
  "schedule_id": "sch-001",
  "name": "Daily Standup",
  "rrule": "FREQ=DAILY;BYHOUR=9;BYMINUTE=55",
  "action_ids": ["act-001", "act-002"]
}
```

## Time Estimates

| Task | Estimated Time |
|------|---------------|
| Backend - Schedule storage updates | 1-2 hours |
| Backend - ActionService API | 2-3 hours |
| Swift - Action model verification | 30 min |
| Swift - ActionLocalStorage | 1-2 hours |
| Swift - ActionService | 1 hour |
| Swift - Update ScheduleLocalStorage | 30 min |
| Swift - Update EventService | 1 hour |
| Swift - LinkHandler | 30 min |
| Swift - Update NotificationManager | 30 min |
| Swift - ActionSyncManager | 2 hours |
| UI - Action management views | 3-4 hours |
| UI - Update schedule editor | 2 hours |
| Testing & debugging | 2-3 hours |
| **Total** | **18-23 hours** |

## Next Steps

1. **Immediate**: Complete backend schedule storage updates
2. **Priority**: Implement ActionService gRPC API
3. **Then**: Swift client implementation (local storage → services → UI)
4. **Finally**: End-to-end testing and polish

---

**Last Updated**: 2025-10-13
**Status**: Backend foundation complete, ready for continued implementation
