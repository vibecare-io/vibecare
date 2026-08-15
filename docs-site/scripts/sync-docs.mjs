import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DOCS_SRC = path.resolve(HERE, '../../docs');
const CONTENT_DIR = path.resolve(HERE, '../src/content/docs');

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

// First `# H1`, ignoring headings inside fenced code blocks; else humanized filename.
export function deriveTitle(content, filename) {
  let inFence = false;
  for (const line of content.split(/\r?\n/)) {
    if (/^\s*(```|~~~)/.test(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    const h = line.match(/^\s*#\s+(.+?)\s*$/);
    if (h) return h[1].trim();
  }
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

// Remove the first `# H1` (outside code fences) when it equals the page title,
// so Starlight's rendered frontmatter title isn't duplicated by an in-body H1.
function stripFirstH1(content, title) {
  const lines = content.split(/\r?\n/);
  let inFence = false;
  for (let i = 0; i < lines.length; i++) {
    if (/^\s*(```|~~~)/.test(lines[i])) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    const h = lines[i].match(/^\s*#\s+(.+?)\s*$/);
    if (h) {
      if (h[1].trim() === title) {
        lines.splice(i, 1);
        if (lines[i] !== undefined && lines[i].trim() === '') lines.splice(i, 1);
      }
      break; // only the first heading is a candidate
    }
  }
  return lines.join('\n');
}

export function ensureTitle(content, filename) {
  if (hasFrontmatterTitle(content)) return content;
  const title = deriveTitle(content, filename);
  const esc = title.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  const body = stripFirstH1(content, title);
  return `---\ntitle: "${esc}"\n---\n\n${body}`;
}

export function orgFilesExist(files) {
  return files.some((f) => f.toLowerCase().endsWith('.org'));
}

// Convert a docs-relative source path (POSIX) to its Starlight route.
// README (root or nested) collapses to the directory index. Routes are lowercased.
export function routeForDocsPath(docsRelPath) {
  let p = docsRelPath.replace(/\\/g, '/').replace(/\.(md|org)$/i, '');
  p = p.replace(/(^|\/)README$/i, '$1');
  p = p.replace(/\/+$/, '').toLowerCase();
  return p ? `/${p}/` : '/';
}

// Rewrite Markdown links that point at another in-docs .md/.org file to its
// Starlight route. Links to files outside the docs set (or external URLs) are
// left untouched. `docSet` holds POSIX docs-relative paths of every doc file.
export function rewriteLinks(content, srcRelPath, docSet) {
  const srcDir = path.posix.dirname(srcRelPath.replace(/\\/g, '/'));
  return content.replace(/\]\(([^)\s]+)((?:\s+"[^"]*")?)\)/g, (match, target, title) => {
    if (/^(https?:|\/\/|#|mailto:|tel:)/i.test(target)) return match;
    const hashIdx = target.indexOf('#');
    const rawPath = hashIdx === -1 ? target : target.slice(0, hashIdx);
    const anchor = hashIdx === -1 ? '' : target.slice(hashIdx);
    if (!/\.(md|org)$/i.test(rawPath)) return match;
    const base = srcDir === '.' ? '' : srcDir;
    const resolved = path.posix.normalize(path.posix.join(base, rawPath));
    if (resolved.startsWith('..') || !docSet.has(resolved)) return match;
    return `](${routeForDocsPath(resolved)}${anchor}${title})`;
  });
}

// Astro's content loader ignores files/directories whose names start with `.`
// or `_`. Docs may live under a dot-directory (e.g. the `.superpowers`
// symlink), so strip a single leading dot from each path segment to make them
// routable: `.superpowers/sdd/x.md` -> `superpowers/sdd/x.md` (merging with the
// real `superpowers/` docs). Applied to both the doc set and output paths so
// intra-docs links stay consistent.
export function normalizeDocsRel(rel) {
  return rel
    .split('/')
    .map((seg) => (seg.startsWith('.') ? seg.slice(1) : seg))
    .join('/');
}

function walk(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    // Follow symlinked directories (e.g. docs/.superpowers -> repo-root
    // .superpowers) so their docs are synced too. Dirent.isDirectory() is
    // false for symlinks, so resolve the target with statSync.
    let isDir = entry.isDirectory();
    if (entry.isSymbolicLink()) {
      try {
        isDir = fs.statSync(full).isDirectory();
      } catch {
        continue; // skip broken symlinks
      }
    }
    if (isDir) out.push(...walk(full));
    else out.push(full);
  }
  return out;
}

function cleanContentDir() {
  fs.rmSync(CONTENT_DIR, { recursive: true, force: true });
  fs.mkdirSync(CONTENT_DIR, { recursive: true });
}

function writeOut(outPath, content) {
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, content);
}

// A Starlight splash landing page so the site root isn't a raw README dump.
function writeLandingPage() {
  const page = `---
title: VibeCare Docs
description: Documentation for the VibeCare wellness & routine platform.
template: splash
hero:
  tagline: Wellness & routine management — backend, macOS client, protocol, and design docs.
  actions:
    - text: Architecture
      link: /architecture/
      icon: right-arrow
      variant: primary
    - text: MCP Setup
      link: /mcp_setup/
      icon: external
    - text: Docs Index
      link: /readme/
      icon: document
---

## Explore the docs

- **Architecture** — [Overview](/architecture/) · [Deep Dive](/arch/)
- **Guides** — [Local Build](/local_build/) · [Release Process](/release_process/) · [Signing Setup](/signing_setup/)
- **MCP** — [Setup](/mcp_setup/) · [Implementation Status](/mcp_implementation_status/)
- **Plugin System** — [Architecture Findings](/plugin-architecture-findings/) · [Decisions](/plugin-system-decisions/)
- **Plans & Specs** — browse the **Plans** and **Specs** groups in the sidebar to review Claude's design docs.
`;
  writeOut(path.join(CONTENT_DIR, 'index.md'), page);
}

export function main() {
  const files = walk(DOCS_SRC);

  if (orgFilesExist(files) && !hasPandoc()) {
    console.error(
      'Error: .org files found in docs/ but pandoc is not installed.\n' +
      '  Install it with: brew install pandoc\n' +
      '  (or run: just docs-setup)'
    );
    process.exit(1);
  }

  const docSet = new Set(
    files
      .map((f) => normalizeDocsRel(path.relative(DOCS_SRC, f).split(path.sep).join('/')))
      .filter((f) => /\.(md|org)$/i.test(f))
  );

  cleanContentDir();
  for (const abs of files) {
    const rel = normalizeDocsRel(path.relative(DOCS_SRC, abs).split(path.sep).join('/'));
    const ext = path.extname(abs).toLowerCase();
    if (ext === '.md') {
      const raw = fs.readFileSync(abs, 'utf8');
      const body = rewriteLinks(raw, rel, docSet);
      writeOut(path.join(CONTENT_DIR, rel), ensureTitle(body, abs));
    } else if (ext === '.org') {
      const md = rewriteLinks(convertOrg(abs), rel, docSet);
      const outRel = rel.replace(/\.org$/i, '.md');
      writeOut(path.join(CONTENT_DIR, outRel), ensureTitle(md, abs));
    }
    // other files (e.g. org-roam.db) are skipped.
  }
  writeLandingPage();
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) main();
