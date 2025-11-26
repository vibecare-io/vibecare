# Task: Remove Debug Sidebar Items (Execution Logs, gRPC Testing, Storage Debug)

**Status**: 🟡 Planning
**Created**: 2025-11-26
**Last Updated**: 2025-11-26

---

## Overview

### Goal
Remove three debug/development features from the sidebar navigation that are no longer needed:
1. **Execution Logs** - View for schedule execution history
2. **gRPC Testing** - UI for testing gRPC connections
3. **Storage Debug** - Debug view for storage inspection

These are development tools that should not be in the production UI.

### Success Criteria
- [ ] All three sidebar items removed from navigation
- [ ] All related views, models, and state management removed
- [ ] App builds successfully with `swift build`
- [ ] No orphaned code references
- [ ] Debug settings (log level configuration) remains intact

### Scope
**In Scope:**
- Sidebar navigation items removal
- Views for these features
- Models specific to these features (ExecutionLog)
- DashboardState properties for these features
- RoutineService methods for execution logs
- Test runner infrastructure

**Out of Scope:**
- DebugSettings (log level configuration) - KEEP
- LogCollector infrastructure - KEEP (used by debug settings)
- VibeCareLogHandler - KEEP (core logging infrastructure)

---

## Research & Context

### Codebase Analysis

**Files to Delete (Complete Removal):**

| File | Lines | Purpose |
|------|-------|---------|
| `Views/Logs/LogsContent.swift` | 149 | Execution logs list view |
| `Views/Logs/LogsDetail.swift` | 103 | Execution log detail view |
| `Views/Testing/TestingContent.swift` | 280 | gRPC test UI |
| `Views/Testing/TestingDetail.swift` | 84 | Test result detail view |
| `Views/Testing/EventServiceTestView.swift` | 138 | EventService test UI |
| `Models/ExecutionLog.swift` | 81 | ExecutionLog model & status enum |
| `Tests/GRPCTest.swift` | 194 | gRPC connection tests |
| `Tests/TestRunner.swift` | 42 | Test execution runner |

**Files to Modify:**

| File | Changes Needed |
|------|---------------|
| `Views/Dashboard/Sidebar.swift` | Remove 3 enum cases (.logs, .testing, .debugStorage) and their properties |
| `Views/Dashboard/Dashboard.swift` | Remove switch cases and content view properties |
| `Views/Dashboard/DashboardState.swift` | Remove selectedLogId, selectedTestResult, and related methods |
| `Services/RoutineService.swift` | Remove executeRoutine, getExecutionLogs, convertToExecutionLog methods |

### Design Decisions

1. **Keep LogCollector & DebugSettings**
   - **Reasoning**: These are used by the Debug settings tab for log level configuration
   - **Trade-offs**: Some dead code may remain if in-app log viewer is never built

2. **Remove TestResult references entirely**
   - **Reasoning**: TestResult is only used by gRPC Testing feature
   - **Trade-offs**: None - completely isolated to testing feature

3. **Delete entire Views/Logs and Views/Testing directories**
   - **Reasoning**: Cleaner than individual file deletion
   - **Trade-offs**: None - all files in these directories are for removed features

---

## Implementation Plan

### Files to Delete
- [ ] `vibecare/Views/Logs/` (entire directory)
- [ ] `vibecare/Views/Testing/` (entire directory)
- [ ] `vibecare/Models/ExecutionLog.swift`
- [ ] `vibecare/Tests/GRPCTest.swift`
- [ ] `vibecare/Tests/TestRunner.swift`

### Files to Modify
- [ ] `vibecare/Views/Dashboard/Sidebar.swift`
- [ ] `vibecare/Views/Dashboard/Dashboard.swift`
- [ ] `vibecare/Views/Dashboard/DashboardState.swift`
- [ ] `vibecare/Services/RoutineService.swift`

### Implementation Steps

#### Phase 1: State Management Cleanup
- [ ] **DashboardState.swift** - Remove properties and methods
  - Remove `@Published var selectedLogId: Int64?`
  - Remove `@Published var selectedTestResult: TestResult?`
  - Remove switch cases in `hasSelectedItem`
  - Remove `selectedLogId = nil` and `selectedTestResult = nil` from `clearAllSelections()`
  - Remove `selectLog()` and `selectTestResult()` methods

#### Phase 2: Sidebar Enum Cleanup
- [ ] **Sidebar.swift** - Remove enum cases
  - Remove `case logs = "Execution Logs"`
  - Remove `case testing = "gRPC Testing"`
  - Remove `case debugStorage` (inside #if DEBUG block)
  - Remove corresponding cases from `iconName` property
  - Remove corresponding cases from `color` property
  - Remove corresponding cases from `getItemCount` method

#### Phase 3: Dashboard Navigation Cleanup
- [ ] **Dashboard.swift** - Remove navigation and content views
  - Remove switch cases in `contentViewForSelectedItem`
  - Remove switch cases in `detailView`
  - Remove `logContentView` computed property
  - Remove `testingContentView` computed property
  - Remove `debugStorageContentView` computed property
  - Remove `logDetailView` computed property
  - Remove `testingDetailView` computed property

#### Phase 4: Delete Feature Files
- [ ] Delete `Views/Logs/` directory
- [ ] Delete `Views/Testing/` directory
- [ ] Delete `Models/ExecutionLog.swift`
- [ ] Delete `Tests/GRPCTest.swift`
- [ ] Delete `Tests/TestRunner.swift`

#### Phase 5: Service Cleanup
- [ ] **RoutineService.swift** - Remove execution log methods
  - Remove or modify `executeRoutine()` method
  - Remove `getExecutionLogs()` method
  - Remove `convertToExecutionLog()` helper

#### Phase 6: Verification
- [ ] Run `swift build` to verify compilation
- [ ] Verify app launches correctly
- [ ] Verify remaining sidebar items work (Schedules, Routines, Actions, Settings)

### Testing Plan
- [ ] `swift build` passes
- [ ] `swift run` launches app
- [ ] Navigate to each remaining sidebar item
- [ ] Settings > Debug tab still works
- [ ] No console errors about missing views

---

## Implementation Log

_To be filled during implementation_

---

## Dependencies & Blockers

### Questions
- [ ] Should `executeRoutine()` in RoutineService be kept but modified to return Void instead of ExecutionLog? (Need to check if it's called elsewhere)

---

## Completion Checklist

Before marking as 🟢 Completed:
- [ ] All implementation steps completed
- [ ] App builds successfully
- [ ] App runs and navigates correctly
- [ ] No orphaned code references
- [ ] Implementation log fully documented
- [ ] CLAUDE.md updated if needed

---

## Archive Notes

**Completed**: _TBD_
**Outcome**: _TBD_
**Follow-up Tasks**: _TBD_
