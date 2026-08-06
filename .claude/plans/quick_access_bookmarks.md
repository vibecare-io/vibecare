# Task: Quick Access Bookmarks in Sidebar

**Status**: 🟡 Planning
**Created**: 2025-11-28
**Last Updated**: 2025-11-28

---

## Overview

### Goal
Add a Quick Access bookmarks section to the VibeCare macOS sidebar that allows users to bookmark routines and schedules for easy access. Bookmarks will sync across devices via server-side storage in `Profile.preferences`.

### Success Criteria
- [ ] Users can bookmark routines and schedules
- [ ] Bookmarks appear in sidebar "Quick Access" section below Settings
- [ ] Star icon toggle in routine/schedule list rows
- [ ] Drag-and-drop from lists to sidebar bookmark section
- [ ] Click bookmark navigates to the item
- [ ] Bookmarks sync across devices (stored in Profile.preferences)
- [ ] Maximum 20 bookmarks enforced
- [ ] Auto-cleanup when bookmarked items are deleted
- [ ] Schedules show parent routine name in bookmark list
- [ ] User can reorder bookmarks via drag-and-drop

### Scope
**In Scope:**
- Server-side bookmark storage using Profile.preferences
- Routines and schedules as bookmarkable items
- Star icon toggle for adding/removing bookmarks
- Drag-and-drop from lists to sidebar
- Sidebar "Quick Access" section with count badge
- Navigation from bookmark to item detail view
- 20 bookmark limit with user feedback
- Validation and auto-cleanup of deleted items
- Reordering bookmarks

**Out of Scope:**
- Bookmarking actions (only routines and schedules)
- Bookmark folders/categories
- Smart bookmarks (auto-suggest based on usage)
- Sharing bookmarks between users
- Keyboard shortcuts for bookmarking
- Search/filter within bookmarks
- Export/import bookmarks

---

## Research & Context

### External Research
- **SwiftUI Drag & Drop**: Uses `NSItemProvider` with custom `UTType` for type-safe drag operations
- **Profile.preferences Pattern**: Existing storage mechanism for user preferences in JSON format

### Codebase Analysis
Files reviewed and key findings:

**Data Models:**
- `clients/macos-swift/VibeCare/vibecare/Models/Profile.swift:8` - `preferences: [String: String]` dictionary for storing JSON data
- `clients/macos-swift/VibeCare/vibecare/Models/Routine.swift:3-42` - Routine model with metadata
- `clients/macos-swift/VibeCare/vibecare/Models/Schedule.swift` - Schedule model with routineId reference

**Services:**
- `clients/macos-swift/VibeCare/vibecare/Services/ProfileService.swift:116-145` - `updateProfile()` method for persistence
- Pattern: Serialize to JSON → update Profile.preferences → call ProfileService.updateProfile()

**ViewModels:**
- `clients/macos-swift/VibeCare/vibecare/ViewModels/RoutineViewModel.swift:17-24` - NotificationCenter pattern for profile changes
- `clients/macos-swift/VibeCare/vibecare/ViewModels/AppState.swift` - Global state and profile change notifications

**UI Components:**
- `clients/macos-swift/VibeCare/vibecare/Views/Dashboard/Sidebar.swift:4-29` - SidebarItem enum and sidebar structure
- `clients/macos-swift/VibeCare/vibecare/Views/Dashboard/DashboardState.swift:46-70` - Navigation state management
- `clients/macos-swift/VibeCare/vibecare/Views/Routines/RoutinesContent.swift` - RoutineRowView with action buttons
- `clients/macos-swift/VibeCare/vibecare/Views/Schedules/ScheduleRowView.swift` - Schedule row component

### Design Decisions

1. **Decision**: Store bookmarks in Profile.preferences as JSON
   - **Reasoning**: Leverages existing infrastructure, automatic cross-device sync via ProfileService, no backend schema changes needed
   - **Trade-offs**: Small sync latency (~100-500ms) but mitigated with optimistic UI updates

2. **Decision**: Don't add bookmarks to SidebarItem enum
   - **Reasoning**: Bookmarks are a dynamic section, not a navigation destination like routines/schedules/actions/settings
   - **Trade-offs**: Cleaner separation but requires custom section in sidebar

3. **Decision**: Maximum 20 bookmarks
   - **Reasoning**: Reasonable limit for "quick access" use case, prevents performance issues, encourages thoughtful selection
   - **Trade-offs**: Users may want more, but 20 is sufficient for quick access pattern

4. **Decision**: Auto-cleanup deleted items silently
   - **Reasoning**: Items already deleted from system, no user action needed, reduces friction
   - **Trade-offs**: Could surprise users but deletions are intentional anyway

5. **Decision**: Implement both star icon AND drag-and-drop
   - **Reasoning**: Star icon is familiar and reliable, drag-and-drop is discoverable and visual
   - **Trade-offs**: More implementation work but better UX with multiple methods

---

## Implementation Plan

### Files to Create
- [ ] `clients/macos-swift/VibeCare/vibecare/Models/Bookmark.swift` - Purpose: Data models for BookmarkItem and BookmarkCollection
- [ ] `clients/macos-swift/VibeCare/vibecare/Services/BookmarkService.swift` - Purpose: CRUD operations and Profile.preferences persistence
- [ ] `clients/macos-swift/VibeCare/vibecare/ViewModels/BookmarkViewModel.swift` - Purpose: State management and business logic
- [ ] `clients/macos-swift/VibeCare/vibecare/Views/Components/BookmarkRowView.swift` - Purpose: Bookmark list item UI with navigation
- [ ] `clients/macos-swift/VibeCare/vibecare/Views/Components/EmptyBookmarksView.swift` - Purpose: Empty state when no bookmarks
- [ ] `clients/macos-swift/VibeCare/vibecare/Views/Components/BookmarkDropDelegate.swift` - Purpose: Drag-and-drop handling

### Files to Modify
- [ ] `clients/macos-swift/VibeCare/vibecare/Views/Dashboard/Sidebar.swift` - Purpose: Add Quick Access section below Settings
- [ ] `clients/macos-swift/VibeCare/vibecare/Views/Dashboard/DashboardState.swift` - Purpose: Add selectBookmark() navigation method
- [ ] `clients/macos-swift/VibeCare/vibecare/Views/Dashboard/Dashboard.swift` - Purpose: Create BookmarkViewModel and inject into environment
- [ ] `clients/macos-swift/VibeCare/vibecare/Views/Routines/RoutinesContent.swift` - Purpose: Add star button to RoutineRowView
- [ ] `clients/macos-swift/VibeCare/vibecare/Views/Schedules/ScheduleRowView.swift` - Purpose: Add star button to schedule rows

### Implementation Steps

#### Phase 1: Data Model & Service Layer (4-6 hours)
- [ ] Create BookmarkItem struct with id, type (routine/schedule), targetId, order, createdAt
- [ ] Create BookmarkCollection struct with items array, version, maxBookmarks constant
- [ ] Implement Codable conformance for JSON serialization
- [ ] Create BookmarkService with loadBookmarks(), saveBookmarks(), addBookmark(), removeBookmark()
- [ ] Implement validation logic to filter out deleted items
- [ ] Implement reorderBookmarks() for drag-and-drop reordering
- [ ] Write unit tests for service layer

#### Phase 2: ViewModel Layer (3-4 hours)
- [ ] Create BookmarkViewModel with @Published bookmarks array
- [ ] Implement loadBookmarks() with NotificationCenter listener for profile changes
- [ ] Implement addBookmark() with limit checking (20 max)
- [ ] Implement removeBookmark() with optimistic update
- [ ] Implement toggleBookmark() for star icon (add if missing, remove if exists)
- [ ] Implement isBookmarked() helper for UI state
- [ ] Implement validateAndCleanup() to resolve bookmarks to actual objects
- [ ] Create ValidatedBookmark struct with bookmark + resolved routine/schedule
- [ ] Implement parent routine name lookup for schedules
- [ ] Write unit tests for ViewModel

#### Phase 3: Sidebar UI (5-6 hours)
- [ ] Modify Sidebar.swift to accept BookmarkViewModel parameter
- [ ] Add Divider with spacing after existing sidebar items
- [ ] Add Section with "Quick Access" header showing count (X/20)
- [ ] Add star icon to header (filled yellow)
- [ ] Implement empty state with EmptyBookmarksView
- [ ] Implement bookmark list with ForEach over validatedBookmarks
- [ ] Add .onMove modifier for reordering
- [ ] Add .onDrop for drag-and-drop target
- [ ] Create BookmarkRowView with icon, name, parent routine (for schedules)
- [ ] Add hover state with X button for removal
- [ ] Add onTapGesture for navigation
- [ ] Create EmptyBookmarksView with icon, message, hint text
- [ ] Test sidebar integration

#### Phase 4: List Integration (4-5 hours)
- [ ] Modify RoutinesContent.swift to accept @EnvironmentObject BookmarkViewModel
- [ ] Add star button to RoutineRowView action buttons section
- [ ] Implement toggle bookmark on star click
- [ ] Update star icon based on isBookmarked state (filled vs hollow)
- [ ] Add tooltip "Add to Quick Access" / "Remove from Quick Access"
- [ ] Add .onDrag modifier to create BookmarkDragItem
- [ ] Modify ScheduleRowView.swift with same pattern
- [ ] Create BookmarkDropDelegate to handle drop events
- [ ] Define custom UTType.bookmarkItem for drag operations
- [ ] Implement BookmarkDragItem with NSItemProvider conformance
- [ ] Test drag-and-drop flow

#### Phase 5: Dashboard Integration (2-3 hours)
- [ ] Modify Dashboard.swift to create @StateObject BookmarkViewModel
- [ ] Inject BookmarkViewModel into environment with .environmentObject()
- [ ] Pass bookmarkViewModel to DashboardSidebar
- [ ] Modify DashboardState to add selectedBookmark property
- [ ] Implement selectBookmark() method to navigate to routine/schedule
- [ ] Handle schedule parent routine selection for proper navigation
- [ ] Wire up bookmark row onSelect to call dashboardState.selectBookmark()
- [ ] Test end-to-end navigation flow

#### Phase 6: Polish & Edge Cases (3-4 hours)
- [ ] Implement limit reached feedback (disable star, show tooltip)
- [ ] Add status bar messages for bookmark operations
- [ ] Implement graceful degradation for deleted parent routines
- [ ] Add animations for bookmark add/remove
- [ ] Add smooth transitions for reordering
- [ ] Implement hover states and tooltips
- [ ] Add accessibility labels for VoiceOver
- [ ] Handle network errors gracefully (keep local state)
- [ ] Add confirmation dialog for bookmark removal via X button
- [ ] Performance optimization: cache routine lookup map
- [ ] Add code comments and documentation
- [ ] Update clients/macos-swift/VibeCare/CLAUDE.md with bookmark feature

#### Phase 7: Testing & Validation (2-3 hours)
- [ ] Test bookmark routine → verify in sidebar → click → navigate to routine
- [ ] Test bookmark schedule → verify nested under routine → click → navigate
- [ ] Test star icon toggle in both routines and schedules
- [ ] Test drag-and-drop from lists to sidebar
- [ ] Test reordering bookmarks within sidebar
- [ ] Test 20 bookmark limit enforcement
- [ ] Test deletion of bookmarked routine → auto-cleanup on next load
- [ ] Test deletion of bookmarked schedule → auto-cleanup
- [ ] Test cross-device sync (bookmark on device A, verify on device B)
- [ ] Test profile switching → bookmarks reload
- [ ] Test empty state display
- [ ] Test hover states and X button removal
- [ ] Test accessibility with VoiceOver
- [ ] Fix any bugs discovered during testing

### Testing Plan
- [ ] Unit tests for BookmarkService (CRUD, validation, limit enforcement)
- [ ] Unit tests for BookmarkViewModel (toggle, isBookmarked, cleanup)
- [ ] Integration test: End-to-end bookmark flow (add, navigate, remove)
- [ ] Integration test: Cross-device sync scenario
- [ ] Manual test: Drag-and-drop all scenarios
- [ ] Manual test: Star icon toggle with visual feedback
- [ ] Manual test: Navigation from bookmarks
- [ ] Edge case: Bookmark deleted routine, reload app
- [ ] Edge case: Reach 20 bookmark limit
- [ ] Edge case: Concurrent bookmark modifications
- [ ] Performance test: Load with 20 bookmarks, 100 routines/schedules
- [ ] Accessibility audit with VoiceOver

---

## Implementation Log

_Log entries will be added as work progresses_

---

## Dependencies & Blockers

### Dependencies
- [x] Profile.preferences infrastructure exists (ProfileService.swift)
- [x] NotificationCenter pattern for profile changes (RoutineViewModel.swift)
- [x] Sidebar structure and navigation (Sidebar.swift, DashboardState.swift)
- [ ] No backend changes required

### Blockers
_None identified_

### Questions
- [x] Storage location? → Profile.preferences (server-side)
- [x] What items to bookmark? → Routines and schedules
- [x] How to add bookmarks? → Star icon toggle + drag-and-drop
- [x] Sidebar position? → Below Settings with spacing
- [x] Bookmark limit? → 20 bookmarks maximum
- [x] Handle deleted items? → Auto-cleanup on validation

---

## Completion Checklist

Before marking as 🟢 Completed:
- [ ] All implementation steps completed (phases 1-7)
- [ ] Tests written and passing
- [ ] Code reviewed (self-review for patterns and consistency)
- [ ] Documentation updated (CLAUDE.md)
- [ ] Implementation log fully documented
- [ ] No outstanding blockers
- [ ] Success criteria met
- [ ] Feature tested on macOS 15+
- [ ] Cross-device sync verified
- [ ] Performance acceptable (< 100ms UI updates)

---

## Archive Notes

**Completed**: _TBD_
**Outcome**: _TBD_
**Follow-up Tasks**: _TBD_
