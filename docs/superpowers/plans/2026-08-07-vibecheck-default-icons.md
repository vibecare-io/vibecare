# VibeCheck Default Bundled Icons + Mild-Blur Defaults — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the three user-provided traced SVGs as built-in default alert icons per BFRB behavior — delivered via the existing backend icon bundle — with a mild (light) blurred background on by default. Seeded defaults, still overridable in the Advanced UI.

**Architecture:** Add the three SVGs + catalog entries to the Go-embedded icon bundle (`backend/internal/storage/data/icons/`). On the client, give each `BFRBBehavior` a `defaultIconId` and change `DetectionAlertPreferencesStore`'s per-behavior seed from `.default.copy()` to a factory that sets the bundled icon URL + `.light` screen blur.

**Tech Stack:** Go (embed + catalog JSON), SwiftUI/Swift, swift-testing, existing VibeNotify SVG-URL render path. Backend tests via `just test`; client tests via xcodebuild; app build via `just swift-build`; backend build via `just build`.

## Global Constraints

- Backend delivery only — add to the embedded icon bundle; no app-bundled fallback. No proto changes (catalog is embedded JSON).
- Do NOT edit `VCStubs/` or `backend/pkg/proto/` (generated).
- Source SVGs (copy the CLEAN vector traces, NOT the ~1 MB raster-embedded ones):
  - `/tmp/res/output.svg` → `backend/internal/storage/data/icons/nail-biting.svg`
  - `/tmp/res/nose-output.svg` → `backend/internal/storage/data/icons/nose-picking.svg`
  - `/tmp/res/hair-output.svg` → `backend/internal/storage/data/icons/hair-pulling.svg`
- Catalog ids MUST be exactly `nail-biting`, `nose-picking`, `hair-pulling` (they equal the client `defaultIconId` and the `/api/icons/<id>.svg` path). Category `health`.
- Client `defaultIconId`: `nailBiting→"nail-biting"`, `nosePicking→"nose-picking"`, `hairPulling→"hair-pulling"`.
- Seed override fields ONLY: `svgPath` (bundled URL via `NetworkConfiguration.buildIconURL`), `svgWidth = 220`, `svgHeight = 150`, `screenBlurEnabled = true`, `screenBlurIntensity = .light`. Leave `position`/`width`/`height`/`moveable`/`autoDismissAfter`/title/message at `.default` (so existing store tests asserting `.position`/`.width` stay green).
- Existing tests stay green: backend `just test`; client `DetectionAlertPreferencesStoreTests` (the seed still has `.default` position/width), `VibeCheckViewModelTests`, `DetectionPreferenceTests`, schedule flow.
- ⚠️ Case-insensitive FS: client sources on disk at lowercase `.../vibecare/…`; git tracks under capital `.../VibeCare/VibeCare/…`. Edit where files exist; `git add` and verify with `git status`.
- Client paths below are relative to `clients/macos-swift/VibeCare/`; backend paths relative to repo root.

---

### Task 1: Add the three icons to the backend bundle (TDD)

**Files:**
- Create: `backend/internal/storage/data/icons/nail-biting.svg` (copy of `/tmp/res/output.svg`)
- Create: `backend/internal/storage/data/icons/nose-picking.svg` (copy of `/tmp/res/nose-output.svg`)
- Create: `backend/internal/storage/data/icons/hair-pulling.svg` (copy of `/tmp/res/hair-output.svg`)
- Modify: `backend/internal/storage/data/icons/catalog.json`
- Test: `backend/internal/storage/icon_loader_test.go`

**Interfaces:**
- Consumes: `IconLoader` (`LoadIcons`, `GetIconData`, `GetIcons`).
- Produces: catalog ids `nail-biting`/`nose-picking`/`hair-pulling` resolvable via the loader and served at `/api/icons/<id>.svg`.

- [ ] **Step 1: Copy the SVG files into the bundle**

```bash
cp /tmp/res/output.svg      backend/internal/storage/data/icons/nail-biting.svg
cp /tmp/res/nose-output.svg backend/internal/storage/data/icons/nose-picking.svg
cp /tmp/res/hair-output.svg backend/internal/storage/data/icons/hair-pulling.svg
```
Verify each is a valid SVG (`xmllint --noout <file>` → no output) and non-empty.

- [ ] **Step 2: Write the failing test**

Create `backend/internal/storage/icon_loader_test.go`:

```go
package storage

import (
	"testing"

	"go.uber.org/zap"
)

func TestBundledVibeCheckIconsLoad(t *testing.T) {
	il := NewIconLoader(zap.NewNop())
	if err := il.LoadIcons(""); err != nil {
		t.Fatalf("LoadIcons failed: %v", err)
	}

	want := map[string]bool{"nail-biting": false, "nose-picking": false, "hair-pulling": false}
	for _, ic := range il.GetIcons() {
		if _, ok := want[ic.Id]; ok {
			want[ic.Id] = true
			if ic.Category != "health" {
				t.Errorf("icon %q: category = %q, want \"health\"", ic.Id, ic.Category)
			}
		}
	}
	for id, found := range want {
		if !found {
			t.Errorf("catalog missing icon id %q", id)
		}
		data, err := il.GetIconData(id)
		if err != nil {
			t.Errorf("GetIconData(%q) error: %v", id, err)
		}
		if len(data) == 0 {
			t.Errorf("GetIconData(%q) returned empty data", id)
		}
	}
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd backend && go test ./internal/storage/ -run TestBundledVibeCheckIconsLoad`
Expected: FAIL — catalog missing the three ids / GetIconData errors (files present but not in catalog yet).

- [ ] **Step 4: Add the three catalog entries**

In `backend/internal/storage/data/icons/catalog.json`, add to the `"icons"` array (valid JSON — mind the commas):

```json
{"id":"nail-biting","name":"Nail Biting","category":"health","filename":"nail-biting.svg","keywords":["nail","biting","bfrb","vibecheck","hand","habit"]},
{"id":"nose-picking","name":"Nose Picking","category":"health","filename":"nose-picking.svg","keywords":["nose","picking","bfrb","vibecheck","face","habit"]},
{"id":"hair-pulling","name":"Hair Pulling","category":"health","filename":"hair-pulling.svg","keywords":["hair","pulling","trichotillomania","bfrb","vibecheck","habit"]}
```

Validate the file parses: `python3 -c "import json; json.load(open('backend/internal/storage/data/icons/catalog.json'))"` (no error).

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd backend && go test ./internal/storage/ -run TestBundledVibeCheckIconsLoad -v`
Expected: PASS.

- [ ] **Step 6: Full backend test + build sanity**

Run: `just test` (or `cd backend && go test ./...`) and `just build` (backend compiles; embed includes the new files).
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add backend/internal/storage/data/icons/nail-biting.svg \
        backend/internal/storage/data/icons/nose-picking.svg \
        backend/internal/storage/data/icons/hair-pulling.svg \
        backend/internal/storage/data/icons/catalog.json \
        backend/internal/storage/icon_loader_test.go
git commit -m "feat(icons): bundle VibeCheck default icons (nail-biting, nose-picking, hair-pulling)"
```

---

### Task 2: Client per-behavior default icon + mild-blur seed (TDD)

**Files:**
- Modify: `vibecare/Models/BFRB.swift`
- Modify: `vibecare/Services/Detection/DetectionAlertPreferencesStore.swift`
- Test: `vibecareTests/DetectionAlertPreferencesStoreTests.swift`

**Interfaces:**
- Consumes: `NotificationPreferences` (`.default`, `copy()`, `svgPath`/`svgWidth`/`svgHeight`/`screenBlurEnabled`/`screenBlurIntensity`), `NetworkConfiguration.buildIconURL(iconId:)`.
- Produces: `BFRBBehavior.defaultIconId: String`; `DetectionAlertPreferencesStore.makeDefault(for:) -> NotificationPreferences` used by `init` seeding and the `preferences(for:)` fallback.

- [ ] **Step 1: Add `defaultIconId` to `BFRBBehavior`**

In `vibecare/Models/BFRB.swift`, add:

```swift
    /// Bundled icon id used as this behavior's default alert icon
    /// (matches the backend catalog id and the /api/icons/<id>.svg path).
    var defaultIconId: String {
        switch self {
        case .nailBiting:  return "nail-biting"
        case .nosePicking: return "nose-picking"
        case .hairPulling: return "hair-pulling"
        }
    }
```

- [ ] **Step 2: Write the failing test**

Append to `vibecareTests/DetectionAlertPreferencesStoreTests.swift`:

```swift
@MainActor
@Test func seededDefaultUsesBundledIconAndMildBlur() {
    let name = "test.vibecheck.alertprefs.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }

    let store = DetectionAlertPreferencesStore(defaults: defaults)
    for b in BFRBBehavior.allCases {
        let p = store.preferences(for: b)
        #expect(p.svgPath?.hasSuffix("/api/icons/\(b.defaultIconId).svg") == true)
        #expect(p.screenBlurEnabled == true)
        #expect(p.screenBlurIntensity == .light)
        // regression: window geometry still the shared default
        #expect(p.position == NotificationPreferences.default.position)
        #expect(p.width == NotificationPreferences.default.width)
    }
}
```

- [ ] **Step 3: Run tests to verify the new one fails**

Run: `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | tail -20`
Expected: FAIL — `seededDefaultUsesBundledIconAndMildBlur` fails (seed has no svgPath / blur off). Existing tests still compile.

- [ ] **Step 4: Add the `makeDefault` factory and use it in the store**

In `vibecare/Services/Detection/DetectionAlertPreferencesStore.swift`, add:

```swift
    /// The built-in default alert prefs for a behavior: bundled SVG icon +
    /// mild (light) screen blur, everything else from `.default`.
    static func makeDefault(for b: BFRBBehavior) -> NotificationPreferences {
        let p = NotificationPreferences.default.copy()
        p.svgPath = NetworkConfiguration.buildIconURL(iconId: b.defaultIconId)
        p.svgWidth = 220
        p.svgHeight = 150
        p.screenBlurEnabled = true
        p.screenBlurIntensity = .light
        return p
    }
```

Replace the two `.default.copy()` seed sites:
- In `init`, the gap-fill seed becomes `seededMap[b.rawValue] = Self.makeDefault(for: b)` (for each `BFRBBehavior.allCases` missing from decoded data).
- In `preferences(for:)`, the defensive fallback becomes `byBehavior[b.rawValue] ?? Self.makeDefault(for: b)`.

(Ensure `NetworkConfiguration` is importable here — it's in the same module; add `import` only if the file doesn't already compile.)

- [ ] **Step 5: Run tests to verify GREEN**

Run: `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:"`
Expected: `** TEST SUCCEEDED **` — new test passes; existing store tests (`preferencesForSeedsFromDefaultAndReturnsStableInstance` etc.) still green because position/width are unchanged.

- [ ] **Step 6: App build sanity**

Run: `just swift-build`
Expected: succeeds.

- [ ] **Step 7: Commit**

```bash
git add clients/macos-swift/VibeCare/VibeCare/Models/BFRB.swift \
        clients/macos-swift/VibeCare/VibeCare/Services/Detection/DetectionAlertPreferencesStore.swift \
        clients/macos-swift/VibeCare/vibecareTests/DetectionAlertPreferencesStoreTests.swift
git status
git commit -m "feat(vibecheck): default per-behavior bundled icon + mild blur"
```

---

### Task 3: Full verification + handoff

**Files:** none (verification only).

- [ ] **Step 1: Backend + client test suites**

Run: `just test` (backend) and `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Executed"`
Expected: backend green; client `** TEST SUCCEEDED **`.

- [ ] **Step 2: Builds**

Run: `just build` (backend) and `just swift-build` (client).
Expected: both succeed.

- [ ] **Step 3: Hand off to the user for the manual run**

Ask the user to run backend (`just run`) then the app (`just swift-run`) and confirm:
1. VibeCheck → controls → Advanced: Alert Appearance → each behavior tab shows its new bundled SVG as the current icon (not the SF Symbol).
2. The three icons also appear in the icon picker under Health & Wellness (browse icons in the reused editor / a schedule's Send Notification action).
3. **Preview** for each behavior shows the traced SVG floating on a **mild** (light) blur.
4. A real detection (camera) shows the same.
5. Changing/removing the icon or blur in the Advanced UI still works and persists across relaunch.
6. Schedule notifications are unaffected.
   - If the icons don't render, confirm the backend is running and reachable at the configured `backend_url` (bundled icons are backend-served by design).

- [ ] **Step 4: Final scope check**

Confirm only the feature files were committed. Do NOT stage unrelated pre-existing working-tree changes (`VCStubs/*`, `docs-site/*`, `docs/backlog.org`, `docs/ideas.org`, `plugins/vibecheck/vibecheck`).

---

## Notes on decisions carried from the spec

- Backend bundle only; ids `nail-biting`/`nose-picking`/`hair-pulling` under `health` (Tasks 1, 2).
- Seed overrides only icon + light blur; window geometry unchanged so existing store tests pass (Task 2).
- Persisted user customizations win; only fresh/uncustomised behaviors pick up the new defaults (spec behavior note).
- SF-Symbol `alertIcon` retained as the ultimate fallback when svgPath is cleared.
- Monochrome-black SVG visibility on dark desktops is a manual-run judgment, not a code concern.
