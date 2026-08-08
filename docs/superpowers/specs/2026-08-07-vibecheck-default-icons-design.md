# VibeCheck Default Bundled Icons + Mild-Blur Defaults — Design & Spec

> Design doc. Date: 2026-08-07. Branch: `ft/plugin/vibecheck`.
> Backend (Go icon bundle) + client (SwiftUI defaults). Self-contained for a fresh session.

## Problem / Goal

The three BFRB behaviors currently default to SF-Symbol icons and no screen blur.
Ship user-provided traced SVGs as the built-in default alert icons for each
behavior, delivered through the **existing backend icon bundle** (so they also
appear in the icon picker), with a **mild (light) blurred background** on by
default. These are seeded defaults — still fully overridable in the Advanced
alert settings.

## Decisions (confirmed with the user)

- **Delivery:** backend bundle only (the embedded `data/icons` catalog served at
  `/api/icons/<id>.svg`). No app-bundled fallback. The default icon therefore
  depends on the backend being up (the app already requires it for all data).
- **Source SVGs** (`/tmp/res`, validated monochrome-black vector traces; the
  ~1 MB raster-embedded `nail-biting.svg`/`nb.svg` are NOT used):
  - `output.svg`      (viewBox 1498×1034, matches `nail-biting.png`) → **nail-biting**
  - `nose-output.svg` (1536×1024) → **nose-picking**
  - `hair-output.svg` (1536×1024) → **hair-pulling**
- **Mild blur:** default seed sets `screenBlurEnabled = true`,
  `screenBlurIntensity = .light`.

## Key facts (verified)

- **Bundle mechanism:** `backend/internal/storage/icon_loader.go` `//go:embed
  data/icons/*`. `LoadIcons` reads `data/icons/catalog.json` (`version`,
  `categories`, `icons[{id,name,category,filename,keywords}]`). `GetIconData(id)`
  reads `data/icons/<filename>`. Icons served at `/api/icons/<id>.svg`
  (`internal/web/icon_handler.go`). Existing categories: `health` (Health &
  Wellness), `productivity`, `communication`, `lifestyle` — the three fit `health`.
  Catalog currently has 110 icons; entry shape example:
  `{"id":"water-bottle","name":"Water Bottle","category":"health",
  "filename":"water-bottle-svgrepo-com.svg","keywords":[...]}`. No existing
  `icon_loader_test.go`.
- **Client consumption:** `NetworkConfiguration.buildIconURL(iconId:)` →
  `"<backend>/api/icons/<iconId>.svg"`. A bundled icon is stored in
  `NotificationPreferences.svgPath` as that full URL; the alert renderer
  (`VibeNotifyConfig.showNotification`) uses `.svgURL(url, size:)` for http paths.
- **Client defaults today:** `DetectionAlertPreferencesStore` seeds each behavior
  in `init` (and the pure `preferences(for:)` fallback) with
  `NotificationPreferences.default.copy()`. `.default` = position `.center`, 480×300,
  moveable, `screenBlurEnabled = false`, autoDismiss 20 s, no icon → falls back to
  `behavior.alertIcon` (SF Symbol). This is where the new per-behavior defaults hook in.
- `BFRBBehavior` (`clients/.../vibecare/Models/BFRB.swift`): `nailBiting/nosePicking/
  hairPulling`, with `label`, `alertIcon` (SF Symbol, still the ultimate fallback if
  svgPath is ever cleared), `nudge`.
- Backend tests: `just test` (Go). Client tests: xcodebuild whole target. App:
  `just swift-build`; backend: `just build`/`just run` (embed recompiles the new
  icon files in).

## Design

### 1. Backend — add the three icons to the bundle
- Copy the clean vector SVGs into `backend/internal/storage/data/icons/`:
  - `/tmp/res/output.svg`      → `data/icons/nail-biting.svg`
  - `/tmp/res/nose-output.svg` → `data/icons/nose-picking.svg`
  - `/tmp/res/hair-output.svg` → `data/icons/hair-pulling.svg`
- Add three entries to `data/icons/catalog.json` under `category: "health"`:
  ```json
  {"id":"nail-biting","name":"Nail Biting","category":"health","filename":"nail-biting.svg","keywords":["nail","biting","bfrb","vibecheck","hand","habit"]}
  {"id":"nose-picking","name":"Nose Picking","category":"health","filename":"nose-picking.svg","keywords":["nose","picking","bfrb","vibecheck","face","habit"]}
  {"id":"hair-pulling","name":"Hair Pulling","category":"health","filename":"hair-pulling.svg","keywords":["hair","pulling","trichotillomania","bfrb","vibecheck","habit"]}
  ```
- The embed picks up the new files on rebuild; `GetIconData("nail-biting")` etc.
  resolve, and the picker lists them.

### 2. Client — per-behavior default icon + mild blur seed
- Add to `BFRBBehavior` a `defaultIconId`:
  `nailBiting → "nail-biting"`, `nosePicking → "nose-picking"`, `hairPulling → "hair-pulling"`
  (these equal the catalog ids and the `/api/icons/<id>.svg` path component).
- In `DetectionAlertPreferencesStore`, replace the `.default.copy()` seed with a
  per-behavior factory:
  ```swift
  static func makeDefault(for b: BFRBBehavior) -> NotificationPreferences {
      let p = NotificationPreferences.default.copy()
      p.svgPath = NetworkConfiguration.buildIconURL(iconId: b.defaultIconId)
      p.svgWidth = 220
      p.svgHeight = 150            // ≈ the source ~1.45:1 aspect, sized for the 480×300 alert
      p.screenBlurEnabled = true
      p.screenBlurIntensity = .light   // "mild"
      return p
  }
  ```
  Use it in `init` seeding (for behaviors absent from decoded UserDefaults) and in
  the pure `preferences(for:)` fallback. Position/size/other fields stay at
  `.default`, so existing store tests that assert `.position`/`.width` still pass.
- Everything else is unchanged: title/message remain nil → fall back to
  `behavior.label`/`nudge`; the renderer resolves the http `svgPath` via `.svgURL`;
  the Advanced UI still lets the user change or remove the icon and blur.

### Behavior notes
- Persisted user customizations win (init only fills gaps), so only fresh installs
  / uncustomised behaviors pick up the new defaults; a user can `Reset to Default`
  in the reused editor to get `.default` (no icon) — acceptable, matches the
  schedule editor's reset semantics. (Out of scope: making reset restore the
  behavior-specific default.)
- autoDismiss stays at `.default` (20 s) — unchanged by this feature.
- The traced SVGs are monochrome black; visibility on very dark desktops is a
  visual judgment for the manual run, not a code concern.

## Testing (TDD where pure)

- **Backend:** new `backend/internal/storage/icon_loader_test.go` — after
  `LoadIcons`, the catalog contains ids `nail-biting`/`nose-picking`/`hair-pulling`
  in category `health`, and `GetIconData(id)` returns non-empty bytes for each
  (proves the files embed + resolve).
- **Client:** extend `DetectionAlertPreferencesStoreTests` — the seeded default for
  each behavior has `svgPath` ending `"/api/icons/<defaultIconId>.svg"`,
  `screenBlurEnabled == true`, `screenBlurIntensity == .light`; and (regression) its
  `position`/`width` still equal `.default`. Existing store/schedule/detection tests
  stay green.
- Rendering (remote SVG fetch, picker listing, actual alert look) verified by
  backend `just run` + app `just swift-run` + manual Preview/detection.

## Non-goals
- No app-bundled/offline icon fallback (backend bundle only).
- No change to detection geometry, autoDismiss, title/message, or the Advanced UI.
- No proto changes (catalog is embedded JSON, not proto).
- Not replacing `BFRBBehavior.alertIcon` (kept as the SF-Symbol fallback when no SVG).
