# Move Templates & SVG Icons to Backend

**Status**: 🔵 In Progress
**Created**: 2025-11-06
**Estimated Time**: 2.5 hours

## Overview
Migrate template system and SVG icon library from Swift client to Go backend, making them accessible via gRPC API and HTTP endpoints. VibeNotify 0.0.4+ supports SVG URLs directly, simplifying the architecture.

## User Modifications
- Use `ScheduleTemplate` instead of `RoutineTemplate` (more accurate naming)

## Phase 1: Backend - Templates API (30 min)

### 1.1 Define Protobuf Messages
**File**: `proto/vibecare.proto`

Add messages:

```protobuf
// Template category enum
enum TemplateCategory {
  TEMPLATE_CATEGORY_UNSPECIFIED = 0;
  TEMPLATE_CATEGORY_DAILY = 1;
  TEMPLATE_CATEGORY_WEEKLY = 2;
  TEMPLATE_CATEGORY_MONTHLY_YEARLY = 3;
}

// Main schedule template message
message ScheduleTemplate {
  string id = 1;
  TemplateCategory category = 2;
  string routine_name = 3;
  string routine_description = 4;
  string routine_icon = 5;
  string routine_color = 6;
  string schedule_name = 7;
  string schedule_description = 8;
  string rrule = 9;
  repeated string default_times = 10;  // Format: "HH:MM"

  // Embedded notification configuration (optional)
  message NotificationConfig {
    string title = 1;
    string body = 2;
    string icon_id = 3;
    string position = 4;
    int32 auto_dismiss = 5;
    int32 width = 6;
    int32 height = 7;
  }

  optional NotificationConfig notification = 11;
}

// Request/Response messages
message ListScheduleTemplatesRequest {
  optional TemplateCategory category = 1;  // Filter by category
}

message ListScheduleTemplatesResponse {
  repeated ScheduleTemplate templates = 1;
}

// Service definition
service ScheduleTemplateService {
  rpc ListScheduleTemplates(ListScheduleTemplatesRequest) returns (ListScheduleTemplatesResponse);
}
```

**Action**: Run `just proto-gen` to generate code.

### 1.2 Create Template Storage
**File**: `backend/internal/storage/template_loader.go`

- Load from `backend/internal/storage/data/schedule_templates.json`
- In-memory cache (templates are static)
- `LoadScheduleTemplates() ([]ScheduleTemplate, error)` function

**File**: `backend/internal/storage/data/schedule_templates.json`
- Copy from `clients/macos-swift/VibeCare/vibecare/Resources/TemplateConfigs.json`
- Rename on backend for clarity

### 1.3 Implement Template Service
**File**: `backend/internal/api/schedule_template_service.go`

```go
type ScheduleTemplateService struct {
    templates []*pb.ScheduleTemplate
}

func (s *ScheduleTemplateService) ListScheduleTemplates(ctx context.Context, req *pb.ListScheduleTemplatesRequest) (*pb.ListScheduleTemplatesResponse, error) {
    // Filter by category if requested
    // Return all or filtered templates
}
```

### 1.4 Register Service
**File**: `backend/internal/api/server.go`
- Register ScheduleTemplateService in `RegisterServices()`

**Tasks**:
- [x] Define protobuf messages
- [x] Run proto-gen
- [x] Create template_loader.go
- [x] Copy JSON file to backend
- [x] Implement schedule_template_service.go
- [x] Register service
- [ ] Test with grpcurl

## Phase 2: Backend - SVG Icons API (45 min)

### 2.1 Define Protobuf Messages
**File**: `proto/vibecare.proto`

Add messages:
- `SVGIcon` (id, name, category, filename, keywords[])
- `IconCategory` (id, name, order)
- `ListIconsRequest` (optional category filter, search query)
- `ListIconsResponse` (icons[], categories[])
- `IconService` with `ListIcons` RPC

### 2.2 Create Icon Storage
**Files**:
- `backend/internal/storage/icon_loader.go` - Load catalog from JSON
- `backend/internal/storage/data/icons/` - Directory for SVG files (80+ files)
- `backend/internal/storage/data/icons/catalog.json` - Icon metadata

**Copy from Swift**:
- `clients/.../Resources/SVGIcons/*.svg` → `backend/.../data/icons/`
- `clients/.../Resources/SVGIcons/SVGIconCatalog.json` → `backend/.../data/icons/catalog.json`

### 2.3 Implement Icon Service
**File**: `backend/internal/api/icon_service.go`

```go
type IconService struct {
    catalog *IconCatalog
}

func (s *IconService) ListIcons(ctx context.Context, req *pb.ListIconsRequest) (*pb.ListIconsResponse, error) {
    // Return catalog with base URL for icons
    // Each icon includes URL: http://localhost:8080/api/icons/{id}.svg
}
```

### 2.4 Add HTTP Endpoint for SVG Serving
**File**: `backend/cmd/server/main.go`

Add HTTP handler to serve SVG files:
```go
http.HandleFunc("/api/icons/{id}.svg", serveIconFile)
```

**Key feature**: Serves SVGs at `http://localhost:8080/api/icons/water-bottle.svg`

This endpoint will be used directly by VibeNotify (0.0.4+ supports SVG URLs).

**Tasks**:
- [x] Define protobuf messages for icons
- [x] Run proto-gen
- [x] Create icon_loader.go
- [x] Copy 80+ SVG files to backend
- [x] Copy catalog.json to backend
- [x] Implement icon_service.go
- [x] Add HTTP handler for SVG serving
- [x] Register service
- [ ] Test with curl and grpcurl

## Phase 3: Swift Client - Update VibeNotify (10 min)

### 3.1 Update Package.swift
Update VibeNotify dependency to 0.0.4+:

```swift
.package(url: "https://github.com/vibecare-io/vibe-notify-macos.git", from: "0.0.4")
```

### 3.2 Verify New API
Per changelog (https://github.com/vibecare-io/vibe-notify-macos/blob/main/changelog/06112025-svg-url-support.md), VibeNotify 0.0.4 adds:
- `.svg(url: URL, size: CGSize)` - Direct URL support
- Old `.svg(path: String, size: CGSize)` still works for backward compatibility

**Tasks**:
- [x] Update Package.swift dependency
- [x] Run swift package update
- [x] Verify VibeNotify 0.0.4 builds correctly

## Phase 4: Swift Client - Template Migration (30 min)

### 4.1 Create ScheduleTemplateService
**File**: `vibecare/Services/ScheduleTemplateService.swift` (NEW)

```swift
@MainActor
class ScheduleTemplateService: ObservableObject {
    @Published var templates: [RoutineScheduleTemplate] = []
    @Published var isLoading = false
    @Published var error: Error?

    private let grpcClient: GRPCClientManager

    init(grpcClient: GRPCClientManager = .shared) {
        self.grpcClient = grpcClient
    }

    func loadTemplates(category: TemplateCategory? = nil) async throws {
        isLoading = true
        error = nil
        defer { isLoading = false }

        var request = Vibecare_ListScheduleTemplatesRequest()
        if let category = category {
            request.category = category.toProto()
        }

        let response = try await grpcClient.scheduleTemplateService.listScheduleTemplates(request)
        self.templates = response.templates.map { RoutineScheduleTemplate(from: $0) }
    }
}
```

### 4.2 Update RoutineScheduleTemplate Model
**File**: `vibecare/Models/RoutineScheduleTemplate.swift`

Add protobuf initializer:
```swift
init(from protobuf: Vibecare_ScheduleTemplate) {
    self.id = protobuf.id
    self.category = TemplateCategory(rawValue: protobuf.category.rawValue) ?? .daily
    self.routineName = protobuf.routineName
    self.routineDescription = protobuf.routineDescription
    self.routineIcon = protobuf.routineIcon
    self.routineColor = protobuf.routineColor
    self.scheduleName = protobuf.scheduleName
    self.scheduleDescription = protobuf.scheduleDescription
    self.rruleString = protobuf.rrule
    self.defaultTimes = protobuf.defaultTimes.map { TimeComponents(from: $0) }

    // Convert notification template
    if protobuf.hasNotification {
        let notif = protobuf.notification
        self.suggestedActions = [
            ActionTemplate(
                type: .notification,
                name: notif.title,
                parameters: [
                    "title": notif.title,
                    "body": notif.body,
                    "svg_bundled_id": notif.iconID,
                    "position": notif.position,
                    "auto_dismiss_after": String(notif.autoDismiss),
                    "width": String(notif.width),
                    "height": String(notif.height)
                ]
            )
        ]
    }
}
```

Remove static properties:
```swift
// DELETE these:
static var allTemplates: [RoutineScheduleTemplate] { ... }
static var library: [TemplateCategory: [RoutineScheduleTemplate]] { ... }
```

### 4.3 Update Wizard Views
**File**: `vibecare/Views/Schedules/ScheduleWizardView.swift`

Add template service:
```swift
@StateObject private var templateService = ScheduleTemplateService()
```

Pass to child views:
```swift
TemplateSelectionView(
    templateService: templateService,
    selectedTemplate: $selectedTemplate,
    onNext: { ... },
    onCancel: onCancel
)
```

**File**: `vibecare/Views/Schedules/TemplateSelectionView.swift`

Update to use service:
```swift
struct TemplateSelectionView: View {
    @ObservedObject var templateService: ScheduleTemplateService
    @Binding var selectedTemplate: RoutineScheduleTemplate?

    var body: some View {
        VStack {
            if templateService.isLoading {
                ProgressView("Loading templates...")
            } else if let error = templateService.error {
                ErrorView(error: error, retry: {
                    Task { try? await templateService.loadTemplates() }
                })
            } else {
                // Existing template grid UI
            }
        }
        .task {
            try? await templateService.loadTemplates()
        }
    }
}
```

### 4.4 Cleanup
**Tasks**:
- [x] Create ScheduleTemplateService.swift
- [x] Add protobuf initializer to RoutineScheduleTemplate
- [x] Update ScheduleWizardView to use service
- [x] Update TemplateSelectionView with loading states
- [ ] Delete TemplateConfigLoader.swift
- [ ] Delete Resources/TemplateConfigs.json
- [ ] Test template loading from backend

## Phase 5: Swift Client - Icon Migration (30 min)

### 5.1 Update SVGIconManager
**File**: `vibecare/Services/SVGIconManager.swift`

Major refactor to use backend:
```swift
@MainActor
class SVGIconManager: ObservableObject {
    @Published var icons: [SVGIcon] = []
    @Published var categories: [IconCategory] = []
    @Published var isLoading = false
    @Published var error: Error?

    private let grpcClient: GRPCClientManager
    private let baseURL: String

    init(grpcClient: GRPCClientManager = .shared, baseURL: String = "http://localhost:8080/api/icons") {
        self.grpcClient = grpcClient
        self.baseURL = baseURL
    }

    func loadCatalog(category: String? = nil, searchQuery: String? = nil) async throws {
        isLoading = true
        error = nil
        defer { isLoading = false }

        var request = Vibecare_ListIconsRequest()
        if let category = category {
            request.category = category
        }
        if let query = searchQuery {
            request.searchQuery = query
        }

        let response = try await grpcClient.iconService.listIcons(request)
        self.icons = response.icons.map { SVGIcon(from: $0) }
        self.categories = response.categories.map { IconCategory(from: $0) }
    }

    // NEW: Returns HTTP URL instead of file path
    func url(forIconId id: String) -> URL? {
        guard icons.contains(where: { $0.id == id }) else { return nil }
        return URL(string: "\(baseURL)/\(id).svg")
    }

    // DEPRECATED: Remove after migration
    // func path(forIconId id: String) -> String? { ... }
}
```

### 5.2 Update SVGIcon Model
**File**: `vibecare/Models/SVGIcon.swift`

Add protobuf initializer:
```swift
init(from protobuf: Vibecare_SVGIcon) {
    self.id = protobuf.id
    self.name = protobuf.name
    self.category = protobuf.category
    self.filename = protobuf.filename
    self.keywords = protobuf.keywords
}
```

Remove `bundlePath` property (no longer needed):
```swift
// DELETE:
var bundlePath: String? { ... }
```

### 5.3 Update NotificationPreferences
**File**: `vibecare/Models/NotificationPreferences.swift`

Replace `resolvedSVGPath` with `resolvedSVGURL`:
```swift
// OLD (DELETE):
var resolvedSVGPath: String? {
    if let bundledId = bundledIconId {
        return SVGIconManager.shared.path(forIconId: bundledId)
    }
    return svgPath
}

// NEW:
var resolvedSVGURL: URL? {
    if let bundledId = bundledIconId {
        return SVGIconManager.shared.url(forIconId: bundledId)
    }
    if let customPath = svgPath {
        return URL(fileURLWithPath: customPath)
    }
    return nil
}
```

### 5.4 Update VibeNotify Integration
**File**: `vibecare/Services/VibeNotifyConfiguration.swift`

Update notification builder to use URLs (VibeNotify 0.0.4+):
```swift
// OLD:
if let svgPath = prefs.resolvedSVGPath, let svgSize = prefs.svgSize {
    builder = builder.svg(svgPath, size: svgSize)
}

// NEW (VibeNotify 0.0.4+):
if let svgURL = prefs.resolvedSVGURL, let svgSize = prefs.svgSize {
    builder = builder.svg(url: svgURL, size: svgSize)
}
```

### 5.5 Update Icon Picker
**File**: `vibecare/Views/Components/SVGIconPickerView.swift`

Add catalog loading:
```swift
@EnvironmentObject var iconManager: SVGIconManager

var body: some View {
    VStack {
        if iconManager.isLoading {
            ProgressView("Loading icons...")
        } else if let error = iconManager.error {
            ErrorView(error: error, retry: {
                Task { try? await iconManager.loadCatalog() }
            })
        } else {
            // Existing icon grid UI
        }
    }
    .task {
        if iconManager.icons.isEmpty {
            try? await iconManager.loadCatalog()
        }
    }
}
```

Icon preview using URLs:
```swift
AsyncImage(url: iconManager.url(forIconId: icon.id)) { image in
    image.resizable()
} placeholder: {
    ProgressView()
}
```

### 5.6 Cleanup
**Tasks**:
- [x] Refactor SVGIconManager to use backend
- [x] Add protobuf initializer to SVGIcon
- [x] Update NotificationPreferences (resolvedSVGPath returns URL now)
- [x] Update VibeNotifyConfiguration (no changes needed - uses resolvedSVGPath)
- [x] Update SVGIconPickerView with loading states (.task modifier)
- [x] Add withIconServiceClient to GRPCClientManager
- [ ] Delete Resources/SVGIcons/ directory (80+ files)
- [ ] Delete Resources/SVGIcons/SVGIconCatalog.json
- [ ] Test icon loading and notifications
- [ ] Verify build compiles successfully

## Phase 6: Testing & Validation (30 min)

### 6.1 Backend Testing
```bash
# Build and run backend
just run

# Test template API
grpcurl -plaintext localhost:50051 list vibecare.ScheduleTemplateService
grpcurl -plaintext localhost:50051 vibecare.ScheduleTemplateService/ListScheduleTemplates

# Test icon API
grpcurl -plaintext localhost:50051 list vibecare.IconService
grpcurl -plaintext localhost:50051 vibecare.IconService/ListIcons

# Test SVG serving
curl http://localhost:8080/api/icons/water-bottle.svg  # Should return SVG XML
curl http://localhost:8080/api/icons/yoga.svg
curl http://localhost:8080/api/icons/notification.svg
```

### 6.2 Client Testing
```bash
# Update dependencies
cd clients/macos-swift/VibeCare
swift package update

# Build
swift build

# Run
swift run
```

**Manual testing checklist**:
- [ ] Open wizard → templates load from backend (check for loading spinner)
- [ ] Select template → verify it creates schedule correctly
- [ ] Open icon picker → icons load from backend (check for 80+ icons)
- [ ] Icon search/filter works
- [ ] Create notification action with icon
- [ ] Trigger schedule → notification displays with SVG from HTTP URL
- [ ] Test offline: stop backend → verify graceful error messages
- [ ] Restart backend → verify client recovers

### 6.3 Migration Verification
- [ ] All 17 templates load from backend (check logs)
- [ ] All 80+ icons load from backend
- [ ] All 4 icon categories present (health, productivity, communication, lifestyle)
- [ ] Icon search works (test keyword matching)
- [ ] Notifications display SVGs correctly from `http://localhost:8080/api/icons/...`
- [ ] VibeNotify 0.0.4 SVG URL feature works
- [ ] Client bundle size reduced by ~2MB (check with `du -sh VibeCare.app`)
- [ ] No errors in logs
- [ ] Graceful error handling when backend unavailable

### 6.4 Performance Testing
- [ ] Template loading is fast (< 1s)
- [ ] Icon catalog loading is fast (< 1s)
- [ ] Icon preview renders smoothly in picker
- [ ] Notification icon loads quickly (< 500ms)

## Benefits
✅ Single source of truth for all clients
✅ Update templates/icons without app releases
✅ Multi-client ready (iOS, web, Android future)
✅ **No local file caching needed** - VibeNotify 0.0.4 handles URL loading
✅ Simplified architecture - direct HTTP URLs
✅ Can track template usage analytics
✅ Potential for user-submitted templates/icons
✅ A/B testing capabilities
✅ Reduced client bundle size (~2MB of SVG files removed)
✅ **Leverages VibeNotify's new SVG URL support**

## Architecture Changes

### Before (Client-side):
```
Swift Client → Bundle Resources → SVG Files → VibeNotify (file path)
Swift Client → Bundle Resources → Template JSON → Hardcoded
```

### After (Backend-served):
```
Swift Client → gRPC API → Backend (Templates) → In-memory Cache
Swift Client → gRPC API → Backend (Icon Catalog) → In-memory Cache
Swift Client → HTTP URL → Backend (SVG Files) → Disk → VibeNotify (URL)
```

## Risks & Mitigations
- **Risk**: Network dependency for templates/icons
  - **Mitigation**: Show loading states, clear error messages if backend unavailable
  - **Future**: Add client-side caching layer for offline support
- **Risk**: Migration complexity
  - **Mitigation**: Backend-first approach (no breaking changes until client migrates)
- **Risk**: VibeNotify 0.0.4 URL loading performance
  - **Mitigation**: VibeNotify likely caches internally; backend serves static files efficiently
  - **Future**: Add CDN or HTTP caching headers if needed

## Dependencies
- VibeNotify 0.0.4+ (with SVG URL support)
- Backend running on localhost:8080 (HTTP) and localhost:50051 (gRPC)
- Protobuf code generation working

## Rollback Plan
If issues arise:
1. Keep old code commented out (don't delete immediately)
2. Can revert to bundled resources by uncommenting old code
3. Backend services are additive (no breaking changes to existing APIs)

## Future Enhancements
- [ ] Add template versioning
- [ ] Track template usage analytics
- [ ] Allow users to create custom templates
- [ ] CDN support for SVG serving
- [ ] HTTP caching headers for icons
- [ ] Client-side cache for offline support
- [ ] Template/icon admin UI in web client

## Estimated Time: 2.5 hours
- Phase 1: 30 min (Backend Templates)
- Phase 2: 45 min (Backend Icons)
- Phase 3: 10 min (Update VibeNotify)
- Phase 4: 30 min (Swift Templates)
- Phase 5: 30 min (Swift Icons)
- Phase 6: 30 min (Testing)

## Implementation Log

### 2025-11-06 - Initial Planning
- Created task plan
- Researched current SVG icon implementation
- Identified VibeNotify 0.0.4 URL support as key enabler
- User requested `ScheduleTemplate` naming instead of `RoutineTemplate`

### 2025-11-06 - Phase 1: Backend Templates API (COMPLETED)
- Added protobuf messages to `proto/vibecare.proto:458-526`
  - `TemplateCategory` enum (DAILY, WEEKLY, MONTHLY_YEARLY)
  - `ScheduleTemplate` message with embedded `NotificationConfig`
  - `ListScheduleTemplatesRequest` and `ListScheduleTemplatesResponse`
  - `ScheduleTemplateService` service definition
- Created `backend/internal/storage/template_loader.go:1-156`
  - Loads templates from JSON with caching
  - Methods: `LoadTemplates()`, `GetTemplates()`, `GetTemplatesByCategory()`
- Created `backend/internal/storage/data/schedule_templates.json` (17 templates)
  - Copied from Swift client's TemplateConfigs.json
- Created `backend/internal/api/schedule_template_service.go:1-62`
  - Implements `ListScheduleTemplates` RPC with category filtering
- Updated `backend/internal/api/server.go:35,68-69`
  - Added templateLoader parameter to RegisterServices
  - Registered ScheduleTemplateService
- Updated `backend/cmd/server/main.go:97-106,122`
  - Initialize and load template loader on startup
  - Pass to RegisterServices

### 2025-11-06 - Phase 2: Backend SVG Icons API (COMPLETED)
- Added protobuf messages to `proto/vibecare.proto:528-575`
  - `IconCategory` enum (HEALTH, PRODUCTIVITY, COMMUNICATION, LIFESTYLE)
  - `SVGIcon` message (id, name, category, filename, keywords)
  - `ListIconsRequest` and `ListIconsResponse`
  - `IconService` service definition
- Created `backend/internal/storage/icon_loader.go:1-166`
  - Loads icon catalog from JSON
  - Methods: `LoadIcons()`, `GetIcons()`, `GetIconsByCategory()`, `SearchIcons()`, `GetIconPath()`
- Copied 93 files to `backend/internal/storage/data/icons/`
  - 80+ SVG files + catalog.json from Swift client
- Created `backend/internal/api/icon_service.go:1-68`
  - Implements `ListIcons` RPC with category filtering and search
- Created `backend/internal/web/icon_handler.go:1-68`
  - HTTP handler for serving SVG files
  - URL format: `/api/icons/{id}.svg`
  - Sets proper headers (Content-Type, Cache-Control, CORS)
- Updated `backend/internal/web/server.go:10,17-18,35-42`
  - Added iconLoader parameter
  - Registered `/api/icons/` route with icon handler
- Updated `backend/cmd/server/main.go:107-115,123,155`
  - Initialize and load icon loader on startup
  - Pass to both RegisterServices and web server

### 2025-11-06 - Phase 3: Swift VibeNotify Update (COMPLETED)
- Updated `clients/macos-swift/VibeCare/Package.swift:40`
  - Changed VibeNotify dependency from 0.0.3 to 0.0.4
  - New version supports SVG URLs directly

### 2025-11-06 - Phase 4: Swift Template Migration (COMPLETED)
- Created `vibecare/Services/ScheduleTemplateService.swift:1-63`
  - @MainActor ObservableObject for template loading
  - Methods: `loadTemplates(category:)`, `reload()`
  - Uses GRPCClientManager.withTemplateServiceClient
  - Converts protobuf messages to Swift models
- Updated `vibecare/Services/GRPCClientManager.swift:311-356`
  - Added `withTemplateServiceClient` method
  - Follows same pattern as other service clients
- Updated `vibecare/Models/RoutineScheduleTemplate.swift:8,67-119`
  - Added `import VCStubs`
  - Added protobuf initializer `init(from: VCScheduleTemplate)`
  - Added `TemplateCategory.toProto()` and `init(from:)` methods
  - Parses notification config from protobuf
- Updated `vibecare/Views/Schedules/ScheduleWizardView.swift:28,69`
  - Added `@StateObject private var templateService`
  - Passes templateService to TemplateSelectionView
- Updated `vibecare/Views/Schedules/TemplateSelectionView.swift:4,37-67,96-98`
  - Changed to accept `@ObservedObject var templateService`
  - Added loading state UI (ProgressView)
  - Added error state UI with retry button
  - Added `.task` modifier to load templates on appear
- Fixed multiple compilation errors:
  - Wrong protobuf type prefix (Vibecare_V1_ → VC)
  - gRPC client requires ClientRequest wrapper
  - Concurrency safety with captured vars
  - Preview code missing templateService parameter

### 2025-11-06 - Phase 5: Swift Icon Migration (COMPLETED)
- Updated `vibecare/Services/GRPCClientManager.swift:358-405`
  - Added `withIconServiceClient` method for icon service
- Updated `vibecare/Models/SVGIcon.swift:9,19-92,156-174`
  - Added `import VCStubs`
  - Added `backendURL: URL?` property
  - Added `iconURL` computed property (returns backend URL or file URL)
  - Added protobuf initializer `init(from: VCSVGIcon, baseURL: URL)`
  - Added legacy initializer for local icons (backwards compat)
  - Added `IconCategory.toProto()` and `init(from:)` methods
- Refactored `vibecare/Services/SVGIconManager.swift:9-11,13-79,87,111`
  - Changed from bundle loading to backend gRPC loading
  - Added `loadIcons(category:)` async method
  - Constructs backend URLs from gRPC host/port settings
  - Converts protobuf icons to Swift models
  - Changed `url(forIconId:)` to return URL instead of file path
  - Changed `reload()` to async function
  - Updated error types (removed catalog errors, added invalidBackendURL)
- Updated `vibecare/Models/NotificationPreferences.swift:121-135`
  - Updated `resolvedSVGPath` documentation (now returns URL strings)
  - Changed to call `SVGIconManager.url(forIconId:)` (returns URL)
  - Returns `iconURL.absoluteString` for backend icons
  - VibeNotify 0.0.4 supports both file paths and URL strings
- Updated `vibecare/Views/Components/SVGIconPickerView.swift:67-72,253-257`
  - Added `.task` modifier to load icons from backend
  - Updated retry button to use async `reload()` function

- Updated `vibecare/Views/Components/SVGIconPickerView.swift:67-72,253-257`
  - Added `.task` modifier to load icons from backend
  - Updated retry button to use async `reload()` function
- Fixed compilation errors:
  - IconCategory is a string in protobuf, not an enum
  - Changed `IconCategory(from: proto.category)` to `IconCategory(rawValue: proto.category)`
  - Removed protobuf conversion methods from IconCategory enum
  - Changed `request.category = category.toProto()` to `request.category = category.rawValue`
- **Build completed successfully** ✅

**Next Steps**:
- Test template and icon loading from backend
- Delete old resource files (TemplateConfigLoader, SVGIcons directory)
- Run Phase 6 testing & validation
