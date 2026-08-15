# Plugin System — Discussion & Decision Log

> **⚠️ Superseded — describes plugin system v1, which no longer exists.**
> v1 plugins were stateless and stored data through Core; v2 plugins own their own data
> directory, and Core never calls into a plugin. See
> [`docs/plugin-architecture.md`](plugin-architecture.md) for the current architecture.
> Kept as a historical record of how the design got here.

> Summary of the brainstorming session that led to the plugin architecture.
> Date: 2026-08-06. Captures *why* the decisions were made, for future reference.
> Companions: [findings](plugin-architecture-findings.md) · [Spec 1](superpowers/specs/2026-08-06-plugin-system-v1-design.md).

## The ask

Keep VibeCare Core small; push complexity into **plugins** pulled from a registry that
extend core. Example plugins span a wide weight range: **todos** (data + UI), **activity-watch**
(background monitoring), **vibecheck** (camera/vision BFRB detection — nose-picking / hair-pulling).

## What we learned about the current architecture

- VibeCare is a `schedule → event → action` pipeline. The backend is a **coordinator/store**;
  the **client executes actions**. Backend does not execute actions.
- Everything extensible is a **closed enum + exhaustive switch**, duplicated across proto, Go,
  Swift: `ActionType` (8 values), `SidebarItem` (4 values). **No registry anywhere.**
- Two existing "plugin-shaped" patterns worth reusing: the metadata-driven
  `ActionType.requiredParameters → generic UI` on the client, and the `mcp.Storage` interface
  + **MCP subprocess** on the backend (a process speaking a contract over RPC — the template
  for what a plugin is).

## The decision journey (and why)

1. **What is a "plugin"?** → Bundles pulled from a registry that extend core.
2. **Trust model?** → Started at "third-party from day one," which forced a sandbox discussion
   (WASM vs JS-VM vs subprocess). **Reversed** — that was over-engineering for now.
3. **KISS reset (the pivot).** Decided: **a plugin is a small RPC process** (any language)
   implementing an agreed gRPC contract — *trusted*, like the existing MCP server. No sandbox
   in v1. Core ↔ plugin talk over gRPC. This reuses infrastructure that already exists.
4. **Two-way contract.** `PluginService` (plugin implements, Core calls) + `HostService`
   (Core implements, plugin calls back for storage/events/notify/schedules).
5. **Core becomes a kernel with registries.** Closed `ActionType`/`SidebarItem` enums become
   registries populated from plugin **manifests**. This is the one real refactor in Core.
6. **The UI question — the hardest one.** A headless cross-platform plugin can't draw SwiftUI.
   Explored the spectrum: built-in Swift ↔ server-driven declarative ↔ native module ↔ webview.
   - First landed on **server-driven declarative UI** (Block-Kit model: plugin ships UI *intent*,
     VibeCare renders → independent dev + consistent + cross-platform).
   - Then weighed **plugins owning their own web UI** (easier to develop, more independent, but
     divergent + non-native). Balance found: **web by default + a `none` fallback shell**, with
     a VibeCare design kit to soften divergence.
   - Then the "**native UI without webview?**" question: clarified that **native performance +
     hardware access come free from a native *process*** — only native *pixels* are hard.
     Native embedding is possible (in-process bundle loading, or IOSurface compositing) but
     costs isolation + cross-platform + ABI discipline.
   - **Final v1 direction (per user): native VibeShell UI** — the plugin stays a **headless
     process** and the **Swift client renders its screen natively** from a **declarative
     descriptor** (server-driven UI, rendered natively — no webview, no in-process bundle).
     The `web` and `native-module` tiers are **reserved in the manifest for later slices**.
7. **Developer experience is the make-or-break.** Agreed a first-party **SDK** is mandatory so a
   headless plugin (todos) is ~30–50 lines + a manifest. The floor must be very low; the ceiling
   is only the author's own feature complexity, not tax VibeCare imposes.

## Locked model (v1)

**Plugin = RPC process (logic/data/events over gRPC) + a declarative view descriptor the
VibeShell renders natively + a manifest. Core supervises plugins like the MCP server. Trusted,
no sandbox. Go SDK first (todos is Go).**

## Decomposition (each slice = its own spec → plan → build)

1. **Spec 1 (now):** plugin spine + manifest + gRPC contract + registries + generic storage +
   Go SDK + **headless todos with native VibeShell UI**.
2. Web UI tier (`ui.kind: web`, webview + design kit).
3. Native-module UI tier (in-process bundle, per-platform).
4. Native providers: activity-watch, then vibecheck (same contract, native processes).
5. Registry + distribution (bundle format, signing/trust, enum→registry migration).

## Rejected / deferred (and why)

- **WASM / JS-VM sandbox** — over-engineered for a trusted, personal-app v1. Reserve for a real
  third-party-untrusted future.
- **Third-party-from-day-one** — reframed: native/hardware plugins are inherently trust-gated
  (you can't safely hand a stranger your camera), so anonymous install is a later, separate concern.
- **Webview as the v1 UI** — deferred in favor of native shell rendering per the user's call.
- **In-process native UI module** — highest complexity (crash blast radius, per-platform, ABI);
  reserved as the premium tier. Not needed for native vibecheck (that's a native *process*).
