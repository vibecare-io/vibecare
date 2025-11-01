# Task: Improve Action Creation Flow in Schedule Edit View

**Status**: 🟡 Planning
**Created**: 2025-10-31
**Last Updated**: 2025-10-31

---

## Overview

### Goal
Improve the ScheduleEditView to save actions to backend immediately when added/edited (eager save). When user cancels without saving the schedule, mark actions as inactive/disabled instead of deleting them, allowing users to enable or permanently delete them later.

**Why is this needed?**
- Current implementation has race condition risk (actions saved during schedule save)
- Poor error handling (partial saves possible)
- User loses work if they cancel after creating actions
- No way to reuse actions across schedules

### Success Criteria
- [ ] Actions saved to backend immediately when added
- [ ] Actions created with `enabled: false` (orphaned state)
- [ ] Actions updated to `enabled: true` when schedule is saved
- [ ] Actions remain as `enabled: false` if user cancels (preserves work)
- [ ] Loading indicators shown during action save
- [ ] Validation errors shown inline
- [ ] Schedule save disabled while actions are saving
- [ ] No orphaned enabled actions (all enabled actions must be attached to schedules)
- [ ] Swift project builds without errors

### Scope
**In Scope:**
- Eager save actions to backend when added/edited
- Mark actions as disabled/inactive by default
- Enable actions when schedule is saved successfully
- Add validation before action save
- Add loading states and error feedback
- Debounce parameter updates (300ms)
- Update ScheduleEditView.swift only

**Out of Scope:**
- Actions management view (future enhancement)
- Bulk enable/delete orphaned actions (future)
- Action reuse across schedules (future)
- Action templates or presets (future)
- Offline mode or local caching (removed in previous task)

---

## Research & Context

### Current Implementation Analysis

**File**: `clients/macos-swift/VibeCare/VibeCare/Views/Schedules/ScheduleEditView.swift`

**Current Flow:**
1. User adds actions → stored in `@State actionCards: [ScheduleActionCard]` array
2. User edits parameters → binding updates actionCards
3. User clicks "Save Schedule" → `saveActions()` called
4. `saveActions()` creates/updates all actions sequentially on backend
5. Action IDs collected and passed to schedule creation
6. Schedule created with action IDs

**Problems Identified:**

1. **Race Condition Risk**: Actions saved sequentially during schedule save. If schedule save fails after some actions are created, orphaned actions remain on backend.

2. **Poor Error Handling** (line 1467):
   ```swift
   } catch {
       print("ERROR [saveActions]: Failed to save action: \(error)")
   }
   ```
   Errors are logged but schedule continues to save with partial action IDs.

3. **No User Work Preservation**: If user creates actions then cancels, all work is lost (actions never saved).

4. **Blocking Network Calls**: User waits for all actions to save before schedule can be created. No progress feedback.

5. **No Validation**: Actions not validated before save attempt.

### Codebase Analysis

**Action Model** (`vibecare/Models/Action.swift`):
```swift
struct Action: Identifiable, Codable {
    let id: String
    let profileId: String
    var type: ActionType
    var name: String
    var description: String
    var parameters: [String: String]
    let createdAt: Date
    var enabled: Bool  // ← Use this field for orphaned state
}
```

**ActionService** (`vibecare/Services/ActionService.swift`):
- `createAction(id:profileId:type:name:description:parameters:enabled:)` - Direct gRPC call
- `updateAction(_ action: Action)` - Direct gRPC call
- `deleteAction(id:)` - Direct gRPC call
- `getAction(id:)` - Direct gRPC call

**ScheduleActionCard** (`vibecare/Views/Schedules/ActionCardView.swift`):
- Holds UI state for action being edited
- `toAction(profileId:)` method converts to Action model
- Notification preferences serialized to parameters

### Design Decisions

1. **Decision**: Use `enabled: false` for orphaned actions instead of deleting
   - **Reasoning**: Preserves user work, allows future reuse, gives user control
   - **Trade-offs**:
     - Gain: No data loss, user-friendly, flexible cleanup
     - Lose: May accumulate orphaned actions over time (need cleanup UI eventually)

2. **Decision**: Eager save (immediate backend sync)
   - **Reasoning**: Consistent with backend-first architecture we just established
   - **Trade-offs**:
     - Gain: Simple, no sync complexity, immediate validation
     - Lose: Network calls on every add/edit, requires backend availability

3. **Decision**: Debounce parameter updates (300ms)
   - **Reasoning**: Avoid excessive backend calls while user is typing
   - **Trade-offs**:
     - Gain: Reduced network traffic, better performance
     - Lose: Slight delay before save (acceptable)

4. **Decision**: Validate before save
   - **Reasoning**: Prevent invalid actions from being created on backend
   - **Trade-offs**:
     - Gain: Better data quality, clear error feedback
     - Lose: Slightly more complex logic

---

## Implementation Plan

### Files to Modify
- [ ] `clients/macos-swift/VibeCare/VibeCare/Views/Schedules/ScheduleEditView.swift`
  - Purpose: Implement eager save logic, validation, error handling

### Implementation Steps

#### Phase 1: Add State Management
- [ ] Add `@State private var savingActionId: String?` - Track which action is saving
- [ ] Add `@State private var newlyCreatedActionIds: Set<String>` - Track session actions
- [ ] Add `@State private var actionSaveErrors: [String: String]` - Track errors per action ID
- [ ] Add `@State private var actionSaveSuccess: Set<String>` - Track successfully saved actions

#### Phase 2: Implement Eager Save
- [ ] Modify `addActionCard(type:)`:
  - Create action card in UI
  - Save to backend immediately with `enabled: false`
  - Add to `newlyCreatedActionIds`
  - Set `savingActionId` during save
  - Handle errors and update `actionSaveErrors`

- [ ] Add `updateActionParameters(cardId:)` method:
  - Debounced update (300ms delay)
  - Find card in `actionCards`
  - Update action on backend
  - Handle errors

- [ ] Modify `deleteActionCard(at:)`:
  - Remove from UI immediately
  - Update backend to set `enabled: false`
  - Remove from `newlyCreatedActionIds`

#### Phase 3: Update Schedule Save
- [ ] Modify `saveSchedule()`:
  - Remove call to `saveActions()`
  - Validate all action cards first
  - For each action in `newlyCreatedActionIds`, update to `enabled: true`
  - Collect action IDs from `actionCards`
  - Pass IDs to schedule creation
  - Clear `newlyCreatedActionIds` on success

- [ ] Remove `saveActions(profileId:)` method:
  - No longer needed (actions already saved)

#### Phase 4: Add Validation
- [ ] Add `validateActionCard(_ card: ScheduleActionCard) -> String?` method:
  - Check required fields based on action type
  - Return error message if invalid, nil if valid

- [ ] Add `validateAllActions() -> Bool` method:
  - Validate all cards in `actionCards`
  - Update `actionSaveErrors` with validation errors
  - Return true if all valid

#### Phase 5: UI Updates
- [ ] Update `ActionCardView` to show:
  - Loading spinner when `savingActionId == card.id`
  - Success checkmark when `actionSaveSuccess.contains(card.id)`
  - Error message when `actionSaveErrors[card.id] != nil`

- [ ] Disable "Save Schedule" button when:
  - `savingActionId != nil` (action currently saving)
  - `!actionSaveErrors.isEmpty` (validation errors exist)

- [ ] Add inline error display in action cards

#### Phase 6: Cleanup Strategy
- [ ] On `onDisappear()` or cancel:
  - Leave actions with `enabled: false` (orphaned)
  - User can manage later in Actions management view (future)
  - No deletion needed

### Testing Plan

**Unit Tests** (if applicable):
- Test validation logic for different action types
- Test debounce mechanism

**Manual Testing Steps**:
1. [ ] Add action → verify saved to backend with `enabled: false`
2. [ ] Edit action parameters → verify updated on backend after debounce
3. [ ] Delete action → verify marked as `enabled: false` on backend
4. [ ] Save schedule with actions → verify actions enabled (`enabled: true`)
5. [ ] Cancel without saving → verify actions remain with `enabled: false`
6. [ ] Try to save with validation errors → verify save button disabled
7. [ ] Network error during action save → verify error shown inline
8. [ ] Rapid parameter edits → verify debouncing works (only one save)

**Edge Cases**:
- [ ] Add action while previous action still saving
- [ ] Network timeout during action save
- [ ] Backend returns error on action creation
- [ ] User cancels during action save
- [ ] Multiple rapid parameter changes (debouncing)

---

## Data Flow Diagrams

### Adding Action (New Flow)

```
User clicks "Add Action"
  ↓
Create ScheduleActionCard in UI
  ↓
savingActionId = card.id
  ↓
ActionService.createAction(enabled: false)
  ↓
newlyCreatedActionIds.insert(card.id)
  ↓
Success:                           Error:
  actionSaveSuccess.insert(id)       actionSaveErrors[id] = error
  savingActionId = nil               savingActionId = nil
```

### Editing Action Parameters (New Flow)

```
User edits parameter
  ↓
Debounce 300ms
  ↓
savingActionId = card.id
  ↓
ActionService.updateAction(card.toAction())
  ↓
Success:                           Error:
  actionSaveSuccess.insert(id)       actionSaveErrors[id] = error
  savingActionId = nil               savingActionId = nil
```

### Saving Schedule (Updated Flow)

```
User clicks "Save Schedule"
  ↓
Validate all actions
  ↓
Valid:                            Invalid:
  ↓                                 Show errors, prevent save
Enable all newly created actions
(ActionService.updateAction with enabled: true)
  ↓
Collect action IDs from actionCards
  ↓
ScheduleViewModel.createSchedule(actionIDs: ids)
  ↓
Success:                          Error:
  Clear newlyCreatedActionIds       Show error, rollback enables
  Navigate back
```

### Canceling (New Behavior)

```
User cancels or navigates away
  ↓
onDisappear()
  ↓
Actions remain with enabled: false
  ↓
Can be managed later in Actions view
```

---

## Dependencies & Blockers

### Dependencies
- [x] Backend ActionService working (createAction, updateAction, deleteAction)
  - Status: ✅ Already implemented and working

- [x] Action model has `enabled` field
  - Status: ✅ Exists in protobuf and Swift model

### Blockers
None identified

### Questions
- [x] Should we delete actions or mark as inactive on cancel?
  - **Answer**: Mark as inactive (`enabled: false`) to preserve user work

- [ ] What's the debounce delay for parameter updates?
  - **Suggested**: 300ms (standard for text input)

- [ ] Should we show a list of orphaned actions somewhere?
  - **Future**: Add Actions management view to list/manage orphaned actions

---

## Implementation Log

### [2025-10-31 11:00] - Planning Phase Complete

**Analysis Completed:**
- Identified current implementation issues (race condition, poor error handling)
- Analyzed ActionService capabilities
- Reviewed Action model fields
- Designed eager save architecture

**Design Decisions:**
- Use `enabled: false` for orphaned actions (preserves user work)
- Eager save to backend (consistent with simplified architecture)
- Debounce parameter updates (300ms)
- Validate before save

**Next Steps:**
- Implement Phase 1: Add state management
- Implement Phase 2: Eager save logic
- Implement Phase 3: Update schedule save
- Implement Phase 4: Validation
- Implement Phase 5: UI updates

---

## Completion Checklist

Before marking as 🟢 Completed:
- [ ] State variables added (savingActionId, newlyCreatedActionIds, errors, success)
- [ ] addActionCard() implements eager save with enabled: false
- [ ] updateActionParameters() implements debounced updates
- [ ] deleteActionCard() marks as enabled: false on backend
- [ ] saveSchedule() enables actions and uses existing IDs
- [ ] saveActions() method removed
- [ ] Validation logic implemented
- [ ] UI shows loading/success/error states
- [ ] Save button disabled during action save
- [ ] Swift project builds without errors
- [ ] Manual testing completed (all scenarios pass)
- [ ] Edge cases tested and handled

---

## Archive Notes

**Completed**: TBD
**Outcome**: TBD
**Follow-up Tasks**:
- Create Actions management view to list/manage orphaned actions
- Add bulk enable/delete for orphaned actions
- Consider action templates or presets
- Add action reuse across schedules feature
