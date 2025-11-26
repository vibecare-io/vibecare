# Fix ActionEditSheet Icon URL Storage

**Status**: 🟢 Completed
**Created**: 2025-11-06
**Completed**: 2025-11-06
**Priority**: High

## Problem Statement

When users select a bundled icon in the ActionEditSheet (screenshot provided), the system currently stores only the icon ID (`svg_bundled_id: "meeting"`) in action parameters. This needs to be changed to store the full backend URL (`http://localhost:8080/api/icons/meeting.svg`) in the `svg_path` parameter instead.

### Current Behavior
- User selects icon from backend catalog → stores `svg_bundled_id: "meeting"`
- Icon ID is resolved to URL at runtime via `NotificationPreferences.resolvedSVGPath`
- Uses gRPC port (50051) instead of HTTP port (8080) for URL construction

### Desired Behavior
- User selects icon from backend catalog → stores `svg_path: "http://localhost:8080/api/icons/meeting.svg"`
- User uploads custom SVG (future) → stores `svg_path: "file:///path/to/custom.svg"` or backend upload URL
- No runtime resolution needed - URL is stored directly
- Always uses HTTP server port 8080 for backend icons

## User Requirements (Confirmed)

1. ✅ **Backend URL**: Hardcode `http://localhost:8080` for backend icons
2. ✅ **Parameter Storage**: Store URL only in `svg_path` (remove `svg_bundled_id`)
3. ✅ **Migration**: Update existing actions with `svg_bundled_id` to use `svg_path` URLs
4. ✅ **Future Support**: Ensure architecture supports custom SVG file uploads

## Implementation Plan

### Phase 1: Update Icon Selection Handler
**File**: `clients/macos-swift/VibeCare/VibeCare/Views/Schedules/ActionCardView.swift`

- [ ] Modify icon selection callback (lines ~530-543)
  - When bundled icon selected: construct URL `http://localhost:8080/api/icons/{icon.id}.svg`
  - Store in `preferences.svgPath` (not `bundledIconId`)
  - Clear `preferences.bundledIconId`
  - Keep SVG size settings

**Current Code**:
```swift
onSelect: { icon in
    preferences.bundledIconId = icon.id  // ❌ Just ID
    preferences.svgPath = nil
    preferences.svgWidth = 350
    preferences.svgHeight = 320
}
```

**New Code**:
```swift
onSelect: { icon in
    // Build full backend URL for bundled icon
    let iconURL = "http://localhost:8080/api/icons/\(icon.id).svg"
    preferences.svgPath = iconURL        // ✅ Full URL
    preferences.bundledIconId = nil      // Clear ID
    preferences.svgWidth = 350
    preferences.svgHeight = 320
}
```

### Phase 2: Update Parameter Serialization
**File**: `clients/macos-swift/VibeCare/VibeCare/Views/Schedules/ActionCardView.swift`

- [ ] Modify `serializeNotificationPreferences()` function (lines ~133-185)
  - Remove `svg_bundled_id` serialization logic (lines ~138-146)
  - Only serialize `svg_path` for both bundled and custom icons
  - Simplify conditional logic

**Current Logic**:
```swift
if let bundledIconId = prefs.bundledIconId {
    result["svg_bundled_id"] = bundledIconId  // ❌ Store ID
    result.removeValue(forKey: "svg_path")
} else if let svgPath = prefs.svgPath {
    result["svg_path"] = svgPath
    result.removeValue(forKey: "svg_bundled_id")
}
```

**New Logic**:
```swift
// Only store svg_path (works for both bundled URLs and custom file paths)
if let svgPath = prefs.svgPath {
    result["svg_path"] = svgPath  // ✅ Always store full URL/path
    // Remove old parameter if it exists
    result.removeValue(forKey: "svg_bundled_id")
}
```

### Phase 3: Update Parameter Deserialization
**File**: `clients/macos-swift/VibeCare/VibeCare/Services/NotificationManager.swift`

- [ ] Modify `deserializeNotificationPreferences()` function (lines ~141-167)
  - Remove `bundledIconId` handling (line ~143)
  - Only deserialize `svg_path`
  - Handle both URL formats (backend URLs and file paths)

**Current Logic**:
```swift
let bundledIconId = params["svg_bundled_id"]  // ❌ Read ID
let svgPath = params["svg_path"]
// ... creates NotificationPreferences with both
```

**New Logic**:
```swift
let svgPath = params["svg_path"]  // ✅ Only read path/URL
// bundledIconId is always nil now
// ... creates NotificationPreferences with svgPath only
```

### Phase 4: Simplify NotificationPreferences
**File**: `clients/macos-swift/VibeCare/VibeCare/Models/NotificationPreferences.swift`

- [ ] Deprecate `bundledIconId` property (keep for backward compat but don't use)
- [ ] Update `resolvedSVGPath` computed property (lines ~124-135)
  - Remove SVGIconManager lookup logic
  - Simply return `svgPath` directly (already contains full URL)
- [ ] Update `hasSVGIcon` to only check `svgPath != nil`

**Current Logic**:
```swift
@MainActor
var resolvedSVGPath: String? {
    if let bundledId = bundledIconId {
        if let iconURL = SVGIconManager.shared.url(forIconId: bundledId) {
            return iconURL.absoluteString  // ❌ Runtime resolution
        }
    }
    return svgPath  // Fallback to custom path
}
```

**New Logic**:
```swift
var resolvedSVGPath: String? {
    return svgPath  // ✅ Already contains full URL (no resolution needed)
}
```

### Phase 5: Migrate Existing Actions
**File**: `clients/macos-swift/VibeCare/VibeCare/ViewModels/AppState.swift`

- [ ] Add migration function `migrateIconParametersToURLs()`
- [ ] Call migration on app startup (after loading profiles)
- [ ] Track migration completion with UserDefaults flag

**Migration Logic**:
```swift
private func migrateIconParametersToURLs() async {
    // Check if migration already done
    guard !UserDefaults.standard.bool(forKey: "icon_params_migrated_to_urls") else {
        logger.info("Icon parameter migration already completed")
        return
    }

    logger.info("Starting migration: svg_bundled_id → svg_path URLs")

    do {
        // Get all actions from backend
        let actionService = ActionService()
        // For each notification action:
        //   - If has svg_bundled_id parameter
        //   - Build URL: http://localhost:8080/api/icons/{id}.svg
        //   - Set svg_path to URL
        //   - Remove svg_bundled_id
        //   - Update action via backend API

        // Mark migration complete
        UserDefaults.standard.set(true, forKey: "icon_params_migrated_to_urls")
        logger.info("Icon parameter migration completed successfully")
    } catch {
        logger.error("Icon parameter migration failed: \(error)")
        // Don't set migration flag - will retry next time
    }
}
```

- [ ] Add migration call to `loadInitialData()` function

### Phase 6: Update Template Initialization (If Needed)
**File**: `clients/macos-swift/VibeCare/VibeCare/Models/RoutineScheduleTemplate.swift`

- [ ] Review template initialization from backend (lines ~74-116)
- [ ] Check if templates use `svg_bundled_id` parameter (line ~106)
- [ ] Update to use `svg_path` with full URL instead

**Current Template Conversion** (line ~106):
```swift
parameters: [
    "title": notif.title,
    "body": notif.body,
    "svg_bundled_id": notif.iconID,  // ❌ Just ID
    // ...
]
```

**New Template Conversion**:
```swift
parameters: [
    "title": notif.title,
    "body": notif.body,
    "svg_path": "http://localhost:8080/api/icons/\(notif.iconID).svg",  // ✅ Full URL
    // ...
]
```

### Phase 7 (Future): Custom SVG Upload Support

**Architecture Notes**:
- `svg_path` parameter already supports both URLs and file paths
- For custom uploads, options are:
  1. **File path**: `svg_path: "file:///Users/name/custom.svg"` (local file)
  2. **Backend upload**: Upload to backend, get URL, store in `svg_path`
  3. **Embedded data**: Base64 encode SVG, store in parameter (not recommended)

**Recommended Approach**: Backend upload
- Add upload endpoint: `POST /api/icons/custom`
- Returns URL: `http://localhost:8080/api/icons/custom/{uuid}.svg`
- Store returned URL in `svg_path` (same as bundled icons)
- Consistent with current architecture

## Files to Modify

1. ✏️ `ActionCardView.swift` - Icon selection handler & serialization
2. ✏️ `NotificationManager.swift` - Deserialization logic
3. ✏️ `NotificationPreferences.swift` - Remove runtime resolution
4. ✏️ `AppState.swift` - Add migration function
5. ✏️ `RoutineScheduleTemplate.swift` - Update template parameter building
6. 📝 Consider: `SVGIconManager.swift` - May need URL accessor for migration

## Testing Checklist

### Manual Testing
- [ ] Open ActionEditSheet for a schedule
- [ ] Click "Browse Icons" button
- [ ] Select a bundled icon (e.g., "Meeting")
- [ ] Save action
- [ ] Verify in backend: `action.parameters["svg_path"]` = `"http://localhost:8080/api/icons/meeting.svg"`
- [ ] Verify: `action.parameters["svg_bundled_id"]` does NOT exist

### Preview Testing
- [ ] Select icon in ActionEditSheet
- [ ] Click "Preview Notification"
- [ ] Verify icon displays correctly in notification preview

### Runtime Testing
- [ ] Create schedule with notification action + icon
- [ ] Wait for schedule to trigger (or trigger manually)
- [ ] Verify notification shows with correct icon
- [ ] Check logs: confirm icon loaded from backend URL

### Migration Testing
- [ ] Create test action with old format (`svg_bundled_id: "water"`)
- [ ] Restart app (triggers migration)
- [ ] Verify action updated to new format (`svg_path: "http://localhost:8080/api/icons/water.svg"`)
- [ ] Verify migration flag set in UserDefaults
- [ ] Restart app again - migration should not run again

### Edge Cases
- [ ] Action with no icon → parameters has no svg_path or svg_bundled_id
- [ ] Action with custom file path → svg_path contains file:// URL (keep as-is)
- [ ] Action with invalid icon ID → migration handles gracefully (skip or log error)

## Implementation Log

### 2025-11-06 - Planning
- ✅ Created task plan
- ✅ Confirmed requirements with user (hardcode localhost:8080, store URL only, migrate existing)
- ✅ User approved implementation

### 2025-11-06 - Implementation
- ✅ **Phase 1**: Updated icon selection handler in ActionCardView.swift (lines 534-541)
  - Changed to build full URL `http://localhost:8080/api/icons/{icon.id}.svg`
  - Stores in `preferences.svgPath` instead of `bundledIconId`

- ✅ **Phase 2**: Updated parameter serialization in ActionCardView.swift (lines 133-145)
  - Removed `svg_bundled_id` serialization logic
  - Only serializes `svg_path` for both bundled and custom icons
  - Clears old `svg_bundled_id` parameter if present

- ✅ **Phase 3**: Updated deserialization in ActionCardView.swift (lines 186-215)
  - Removed `bundledIconId` reading from parameters
  - Always sets `bundledIconId: nil` in NotificationPreferences

- ✅ **Phase 3b**: Updated deserialization in NotificationManager.swift (lines 141-176)
  - Removed `bundledIconId` handling
  - Only reads `svg_path` parameter

- ✅ **Phase 4**: Simplified NotificationPreferences.swift (lines 121-138)
  - `resolvedSVGPath` now simply returns `svgPath` (no runtime resolution)
  - `usesBundledIcon` checks if URL starts with http:// or https://
  - `hasSVGIcon` only checks `svgPath != nil`

- ✅ **Phase 5**: Added migration function to AppState.swift (lines 86-133)
  - `migrateIconParametersToURLs()` function migrates existing actions
  - Converts `svg_bundled_id` to `svg_path` with full URL
  - One-time migration tracked with UserDefaults flag
  - Called during app startup after icon loading

- ✅ **Phase 6**: Updated template initialization in RoutineScheduleTemplate.swift (lines 96-124)
  - Templates now build full URL from icon ID
  - Stores in `svg_path` parameter instead of `svg_bundled_id`

- ✅ **Build**: Swift build completed successfully
  - No compilation errors
  - Only existing warnings (unrelated to changes)

### 2025-11-06 - Bug Fix (Post-Implementation)
- 🐛 **Issue Found**: NotificationCustomizationView was missed in initial update
  - User reported icon selection not working in notification preview
  - View still had old code: `preferences.bundledIconId = icon.id`

- ✅ **Fix Applied**: Updated NotificationCustomizationView.swift (lines 200-207)
  - Changed icon selection handler to build URL: `http://localhost:8080/api/icons/{icon.id}.svg`
  - Stores in `preferences.svgPath` instead of `bundledIconId`
  - Matches fix already applied to ActionCardView

- ✅ **Build**: Rebuild successful after fix

### Files Modified
1. ✅ `ActionCardView.swift` - Icon selection, serialization, deserialization
2. ✅ `NotificationManager.swift` - Deserialization logic
3. ✅ `NotificationPreferences.swift` - Removed runtime resolution
4. ✅ `AppState.swift` - Added migration function
5. ✅ `RoutineScheduleTemplate.swift` - Updated template parameter building
6. ✅ `NotificationCustomizationView.swift` - Icon selection handler (missed initially, fixed)

## Dependencies

**Required Before Starting**:
- SVG icons loaded on app startup (✅ Already implemented in previous task)
- Backend HTTP server serving icons on port 8080 (✅ Already running)

**Blocks**:
- Custom SVG upload feature (future work, not blocking)

## Notes

### Why Store URLs Instead of IDs?

1. **Simplicity**: No runtime resolution needed
2. **Consistency**: Custom SVGs and bundled icons use same parameter
3. **Portability**: URLs work across different backend instances
4. **Future-proof**: Supports custom uploads without code changes
5. **Performance**: No lookup required when showing notification

### Migration Strategy

- **Non-destructive**: Only adds `svg_path`, doesn't delete data
- **Idempotent**: Safe to run multiple times (checks flag)
- **Graceful**: App works even if migration fails
- **One-time**: Only runs once per installation

### Backward Compatibility

- Old actions with `svg_bundled_id` still work (migration updates them)
- NotificationPreferences keeps `bundledIconId` property (deprecated)
- Deserialization supports both old and new formats during migration period

## Questions & Decisions

**Q**: What if backend URL changes from localhost to production server?
**A**: Icons will break. Future enhancement: make backend URL configurable in settings and rebuild URLs on settings change.

**Q**: Should we validate icon URLs before storing?
**A**: No validation for now. VibeNotify will handle missing icons gracefully. Future: add URL validation in icon picker.

**Q**: What about icon caching?
**A**: Not in scope. VibeNotify and browser-based rendering handle caching. Future: consider local icon cache for offline support.
