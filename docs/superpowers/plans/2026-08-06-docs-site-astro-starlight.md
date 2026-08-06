# Docs Site (Astro + Starlight) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve everything under `docs/` as a searchable Astro + Starlight website, launched with a single `just docs` command.

**Architecture:** A `docs-site/` Astro project (Starlight theme, bun) is the committed scaffold. A sync script (`scripts/sync-docs.mjs`) regenerates `docs-site/src/content/docs/` from the repo `docs/` directory on every run — copying Markdown, pandoc-converting `.org` → `.md`, and injecting `title` frontmatter where missing. `docs/` stays the source of truth and is never modified; the generated content dir is gitignored. Just recipes chain sync → dev/build.

**Tech Stack:** bun 1.3.9, Astro, @astrojs/starlight, pandoc (for `.org`), Just.

## Global Constraints

- Package manager is **bun** (not npm/pnpm/yarn). All installs/scripts run via `bun`/`bunx`.
- `docs/` is the **source of truth and is never modified** by the site — no edits, no moves.
- Starlight **requires a `title` in each doc's frontmatter**; the sync script must guarantee one.
- Generated `docs-site/src/content/docs/` and `docs-site/.astro/` are gitignored; the Astro scaffold + sync script are committed.
- Justfile recipes go under a new `[group('📚 Documentation')]`; match existing recipe style (`@echo "{{GREEN}}…{{NC}}"`).
- `pandoc` is required only when `.org` files exist; guard with a `brew install pandoc` hint.
- Skip non-doc files: `org-roam.db` and anything not `.md`/`.org`.
- `docs/README.md` maps to the site homepage (`src/content/docs/index.md`).

---

### Task 1: Scaffold the Astro + Starlight project

**Files:**
- Create: `docs-site/package.json`
- Create: `docs-site/astro.config.mjs`
- Create: `docs-site/src/content.config.ts`
- Create: `docs-site/tsconfig.json`
- Create: `docs-site/.gitignore`
- Create: `docs-site/public/.gitkeep`

**Interfaces:**
- Produces: an Astro project buildable with `bun run build`; Starlight reads docs from `src/content/docs/`; npm scripts `dev`, `build`, `preview`, and `sync` (→ `node scripts/sync-docs.mjs`).

- [ ] **Step 1: Create `docs-site/package.json`**

```json
{
  "name": "vibecare-docs",
  "type": "module",
  "version": "0.0.1",
  "private": true,
  "scripts": {
    "sync": "node scripts/sync-docs.mjs",
    "dev": "astro dev",
    "build": "astro build",
    "preview": "astro preview"
  },
  "dependencies": {
    "@astrojs/starlight": "^0.30.0",
    "astro": "^5.1.0",
    "sharp": "^0.33.5"
  }
}
```

- [ ] **Step 2: Create `docs-site/astro.config.mjs`**

```js
// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  integrations: [
    starlight({
      title: 'VibeCare Docs',
      description: 'Documentation for the VibeCare wellness & routine platform.',
      sidebar: [
        { label: 'Docs', autogenerate: { directory: '.' } },
      ],
    }),
  ],
});
```

- [ ] **Step 3: Create `docs-site/src/content.config.ts`**

```ts
import { defineCollection } from 'astro:content';
import { docsLoader } from '@astrojs/starlight/loaders';
import { docsSchema } from '@astrojs/starlight/schema';

export const collections = {
  docs: defineCollection({ loader: docsLoader(), schema: docsSchema() }),
};
```

- [ ] **Step 4: Create `docs-site/tsconfig.json`**

```json
{
  "extends": "astro/tsconfigs/strict",
  "include": [".astro/types.d.ts", "**/*"],
  "exclude": ["dist"]
}
```

- [ ] **Step 5: Create `docs-site/.gitignore`**

```gitignore
# build output
dist/
.astro/

# generated docs content (synced from ../docs)
src/content/docs/

# deps
node_modules/
```

- [ ] **Step 6: Create `docs-site/public/.gitkeep`** (empty file, so `public/` exists for Astro)

```

```

- [ ] **Step 7: Install dependencies with bun**

Run: `cd docs-site && bun install`
Expected: creates `node_modules/` and `bun.lock`; no errors.

- [ ] **Step 8: Verify Astro recognizes the project**

Run: `cd docs-site && bunx astro --version`
Expected: prints an Astro version (e.g. `astro  5.x.x`), no config error.

- [ ] **Step 9: Commit**

```bash
git add docs-site/package.json docs-site/astro.config.mjs docs-site/src/content.config.ts docs-site/tsconfig.json docs-site/.gitignore docs-site/public/.gitkeep docs-site/bun.lock
git commit -m "feat(docs): scaffold Astro + Starlight docs site (bun)"
```

---

### Task 2: Sync script — Markdown copy + title injection

**Files:**
- Create: `docs-site/scripts/sync-docs.mjs`
- Test: `docs-site/scripts/sync-docs.test.mjs`

**Interfaces:**
- Consumes: repo `docs/` directory (relative to `docs-site/`: `../docs`).
- Produces: `deriveTitle(content, filename)` and `ensureTitle(content, filename)` exported helpers; a `main()` that populates `../docs-site/src/content/docs`. This task handles `.md` + title injection + `README.md`→`index.md`; Task 3 adds `.org`/pandoc; Task 4 adds the pandoc guard + `org-roam.db` skip (skip is implicit here since only `.md` is globbed).

The script uses only Node built-ins (`node:fs`, `node:path`, `node:url`, `node:child_process`) so it runs identically under `bun run` and `node`.

- [ ] **Step 1: Write the failing test**

```js
// docs-site/scripts/sync-docs.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deriveTitle, ensureTitle } from './sync-docs.mjs';

test('deriveTitle uses first H1', () => {
  assert.equal(deriveTitle('# My Heading\n\nbody', 'foo.md'), 'My Heading');
});

test('deriveTitle falls back to humanized filename', () => {
  assert.equal(deriveTitle('no heading here', 'MCP_SETUP.md'), 'MCP SETUP');
});

test('ensureTitle injects frontmatter when missing', () => {
  const out = ensureTitle('# Hello\n\nbody', 'hello.md');
  assert.match(out, /^---\ntitle: "Hello"\n---\n/);
  assert.match(out, /# Hello/);
});

test('ensureTitle leaves existing title frontmatter untouched', () => {
  const input = '---\ntitle: Kept\n---\n# Body\n';
  assert.equal(ensureTitle(input, 'x.md'), input);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd docs-site && node --test scripts/sync-docs.test.mjs`
Expected: FAIL — cannot import `deriveTitle`/`ensureTitle` (module or exports missing).

- [ ] **Step 3: Write minimal implementation**

```js
// docs-site/scripts/sync-docs.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DOCS_SRC = path.resolve(HERE, '../../docs');
const CONTENT_DIR = path.resolve(HERE, '../src/content/docs');

export function deriveTitle(content, filename) {
  const m = content.match(/^\s*#\s+(.+?)\s*$/m);
  if (m) return m[1].trim();
  const base = path.basename(filename).replace(/\.(md|org)$/i, '');
  return base.replace(/[_-]+/g, ' ').trim();
}

function hasFrontmatterTitle(content) {
  if (!content.startsWith('---')) return false;
  const end = content.indexOf('\n---', 3);
  if (end === -1) return false;
  const fm = content.slice(0, end);
  return /\n\s*title\s*:/.test(fm);
}

export function ensureTitle(content, filename) {
  if (hasFrontmatterTitle(content)) return content;
  const title = deriveTitle(content, filename).replace(/"/g, '\\"');
  return `---\ntitle: "${title}"\n---\n\n${content}`;
}

function walk(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full));
    else out.push(full);
  }
  return out;
}

function cleanContentDir() {
  fs.rmSync(CONTENT_DIR, { recursive: true, force: true });
  fs.mkdirSync(CONTENT_DIR, { recursive: true });
}

function outPathFor(relPath) {
  // docs/README.md -> index.md (site homepage)
  if (relPath.toLowerCase() === 'readme.md') return path.join(CONTENT_DIR, 'index.md');
  return path.join(CONTENT_DIR, relPath);
}

function writeOut(outPath, content) {
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, content);
}

export function main() {
  cleanContentDir();
  const files = walk(DOCS_SRC);
  for (const abs of files) {
    const rel = path.relative(DOCS_SRC, abs);
    const ext = path.extname(abs).toLowerCase();
    if (ext === '.md') {
      const raw = fs.readFileSync(abs, 'utf8');
      writeOut(outPathFor(rel), ensureTitle(raw, abs));
    }
    // .org handled in Task 3; other files skipped.
  }
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) main();
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd docs-site && node --test scripts/sync-docs.test.mjs`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the sync against real docs and spot-check**

Run: `cd docs-site && node scripts/sync-docs.mjs && ls src/content/docs && test -f src/content/docs/index.md && head -4 src/content/docs/architecture.md`
Expected: `index.md` exists (from README), `architecture.md` starts with `---\ntitle: "VibeCare Architecture"\n---`, nested `superpowers/` and `macos/` dirs present, no `.org` yet.

- [ ] **Step 6: Commit**

```bash
git add docs-site/scripts/sync-docs.mjs docs-site/scripts/sync-docs.test.mjs
git commit -m "feat(docs): sync script copies markdown and injects titles"
```

---

### Task 3: Sync script — Org conversion via pandoc

**Files:**
- Modify: `docs-site/scripts/sync-docs.mjs` (add `.org` branch + `convertOrg`)
- Test: `docs-site/scripts/sync-docs.test.mjs` (add org conversion test, gated on pandoc)

**Interfaces:**
- Consumes: `deriveTitle`/`ensureTitle` from Task 2; `pandoc` binary on `PATH`.
- Produces: `convertOrg(absPath)` → GFM Markdown string; `.org` files emitted as `<name>.md` in the content dir with injected titles.

- [ ] **Step 1: Write the failing test**

```js
// append to docs-site/scripts/sync-docs.test.mjs
import { convertOrg, hasPandoc } from './sync-docs.mjs';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

test('convertOrg turns org into markdown (needs pandoc)', { skip: !hasPandoc() }, () => {
  const tmp = path.join(os.tmpdir(), `sync-org-${process.pid}.org`);
  fs.writeFileSync(tmp, '* Heading One\n\nSome *bold* text.\n');
  const md = convertOrg(tmp);
  fs.rmSync(tmp, { force: true });
  assert.match(md, /Heading One/);
  assert.match(md, /\*\*bold\*\*/); // gfm bold
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd docs-site && node --test scripts/sync-docs.test.mjs`
Expected: FAIL — `convertOrg`/`hasPandoc` not exported.

- [ ] **Step 3: Add implementation to `sync-docs.mjs`**

Add these exports (place `hasPandoc`/`convertOrg` near the top, after imports):

```js
export function hasPandoc() {
  try {
    execFileSync('pandoc', ['--version'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

export function convertOrg(absPath) {
  return execFileSync('pandoc', ['-f', 'org', '-t', 'gfm', absPath], {
    encoding: 'utf8',
  });
}
```

In `main()`, add an `.org` branch inside the file loop, after the `.md` branch:

```js
    } else if (ext === '.org') {
      const md = convertOrg(abs);
      const outRel = rel.replace(/\.org$/i, '.md');
      writeOut(outPathFor(outRel), ensureTitle(md, abs));
    }
```

(Change the `if (ext === '.md') { … }` closing so the `else if` chains onto it.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd docs-site && node --test scripts/sync-docs.test.mjs`
Expected: PASS — all Task 2 tests plus org test (or org test SKIPPED if pandoc absent; installing pandoc is Task 4/setup).

- [ ] **Step 5: Verify against real docs (requires pandoc)**

Run: `cd docs-site && node scripts/sync-docs.mjs && ls src/content/docs/*.md | grep -E 'arch|backlog|braindump|ideas|init' && head -4 src/content/docs/arch.md`
Expected: `arch.md`, `backlog.md`, etc. exist; `arch.md` starts with a `title:` frontmatter. (If pandoc is not yet installed, this step fails with pandoc's error — install via `brew install pandoc` first, added as a recipe in Task 4.)

- [ ] **Step 6: Commit**

```bash
git add docs-site/scripts/sync-docs.mjs docs-site/scripts/sync-docs.test.mjs
git commit -m "feat(docs): convert org files to markdown via pandoc"
```

---

### Task 4: Sync script — pandoc guard for missing binary

**Files:**
- Modify: `docs-site/scripts/sync-docs.mjs` (guard in `main()`)
- Test: `docs-site/scripts/sync-docs.test.mjs` (guard message test)

**Interfaces:**
- Consumes: `hasPandoc` from Task 3.
- Produces: `orgFilesExist(files)` helper; `main()` exits non-zero with a `brew install pandoc` message when `.org` files exist but pandoc is missing.

- [ ] **Step 1: Write the failing test**

```js
// append to docs-site/scripts/sync-docs.test.mjs
import { orgFilesExist } from './sync-docs.mjs';

test('orgFilesExist detects org files in a list', () => {
  assert.equal(orgFilesExist(['/a/x.md', '/a/y.org']), true);
  assert.equal(orgFilesExist(['/a/x.md', '/a/z.txt']), false);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd docs-site && node --test scripts/sync-docs.test.mjs`
Expected: FAIL — `orgFilesExist` not exported.

- [ ] **Step 3: Add implementation**

Add helper:

```js
export function orgFilesExist(files) {
  return files.some((f) => f.toLowerCase().endsWith('.org'));
}
```

In `main()`, right after `const files = walk(DOCS_SRC);`, add the guard:

```js
  if (orgFilesExist(files) && !hasPandoc()) {
    console.error(
      'Error: .org files found in docs/ but pandoc is not installed.\n' +
      '  Install it with: brew install pandoc\n' +
      '  (or run: just docs-setup)'
    );
    process.exit(1);
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd docs-site && node --test scripts/sync-docs.test.mjs`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git add docs-site/scripts/sync-docs.mjs docs-site/scripts/sync-docs.test.mjs
git commit -m "feat(docs): guard sync when pandoc missing but org files present"
```

---

### Task 5: Just recipes + end-to-end build verification

**Files:**
- Modify: `justfile` (add `[group('📚 Documentation')]` recipes)

**Interfaces:**
- Consumes: `docs-site/` scaffold (Task 1) and `scripts/sync-docs.mjs` (Tasks 2–4).
- Produces: `just docs-setup`, `just docs-sync`, `just docs`, `just docs-build`.

- [ ] **Step 1: Add recipes to `justfile`**

Append at end of file:

```just
# Install docs-site deps and ensure pandoc is available
[group('📚 Documentation')]
docs-setup:
    @echo "{{GREEN}}Installing docs-site dependencies...{{NC}}"
    cd docs-site && bun install
    @command -v pandoc >/dev/null 2>&1 || (echo "{{YELLOW}}Installing pandoc via brew...{{NC}}" && brew install pandoc)
    @echo "{{GREEN}}✓ Docs tooling ready{{NC}}"

# Regenerate site content from docs/ (internal helper)
[group('📚 Documentation')]
docs-sync:
    cd docs-site && bun run sync

# Serve the docs site with live reload (http://localhost:4321)
[group('📚 Documentation')]
docs: docs-sync
    @echo "{{GREEN}}Starting docs dev server...{{NC}}"
    cd docs-site && bun run dev

# Build the static docs site into docs-site/dist
[group('📚 Documentation')]
docs-build: docs-sync
    @echo "{{GREEN}}Building static docs site...{{NC}}"
    cd docs-site && bun run build
```

- [ ] **Step 2: Verify recipes are registered**

Run: `just --list | grep -A5 Documentation`
Expected: `docs`, `docs-build`, `docs-setup`, `docs-sync` listed under the Documentation group.

- [ ] **Step 3: Run setup (installs pandoc if missing)**

Run: `just docs-setup`
Expected: bun install completes; pandoc becomes available (`command -v pandoc` succeeds).

- [ ] **Step 4: Full static build passes with no Starlight errors**

Run: `just docs-build`
Expected: exits 0; `docs-site/dist/index.html` exists; no "missing title" / frontmatter errors; org-derived pages (e.g. `dist/arch/index.html`) present.

- [ ] **Step 5: Smoke-test the dev server**

Run: `just docs` in one shell; in another: `curl -sSf http://localhost:4321/ >/dev/null && echo OK`; then stop the server (Ctrl-C).
Expected: `OK` — homepage (from `README.md`) serves; sidebar reflects the `docs/` tree; search box present.

- [ ] **Step 6: Commit**

```bash
git add justfile
git commit -m "feat(docs): add just recipes to build and serve the docs site"
```

---

### Task 6: Wire docs site into README/CLAUDE docs

**Files:**
- Modify: `README.md` (or `docs/README.md`) — add a short "Browse the docs" note.
- Modify: `CLAUDE.md` — add `just docs` to Essential Commands.

**Interfaces:**
- Consumes: recipes from Task 5.

- [ ] **Step 1: Add a `just docs` line to CLAUDE.md Essential Commands**

In `CLAUDE.md`, under the Essential Commands code block, add:

```
just docs               # Serve docs/ as a Starlight site (http://localhost:4321)
just docs-setup         # One-time: install docs-site deps + pandoc
```

- [ ] **Step 2: Add a short pointer in the top-level `README.md`**

Add a line near the docs/links section:

```markdown
> 📚 Browse all docs as a website: `just docs-setup` then `just docs` (http://localhost:4321).
```

- [ ] **Step 3: Verify markdown renders (no broken code fences)**

Run: `git diff --stat CLAUDE.md README.md`
Expected: both files modified.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: document just docs site commands"
```

---

## Self-Review

**Spec coverage:**
- Astro+Starlight scaffold (bun) → Task 1 ✓
- Sync script: copy md → Task 2; org via pandoc → Task 3; title injection → Task 2; README→index → Task 2; skip org-roam.db/non-doc → Task 2 (only `.md`/`.org` globbed) ✓
- pandoc guard → Task 4 ✓
- Autogenerated sidebar + search → Task 1 (astro.config) ✓
- Just recipes (`docs-setup`/`docs`/`docs-build`/`docs-sync`) → Task 5 ✓
- .gitignore for generated content/.astro → Task 1 (`docs-site/.gitignore`) ✓
- Verification (setup/sync/serve/build) → Tasks 5 steps ✓
- Docs pointers → Task 6 ✓

**Placeholder scan:** No TBD/TODO; all code blocks concrete.

**Type consistency:** `deriveTitle`, `ensureTitle`, `convertOrg`, `hasPandoc`, `orgFilesExist`, `main`, `outPathFor`, `writeOut`, `walk` — names consistent across Tasks 2–4. Content dir path `src/content/docs` consistent with `.gitignore` (Task 1) and Starlight loader default. Dev server port `4321` (Astro default) consistent across Tasks 5–6.
