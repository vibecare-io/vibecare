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

export function orgFilesExist(files) {
  return files.some((f) => f.toLowerCase().endsWith('.org'));
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
  const files = walk(DOCS_SRC);

  if (orgFilesExist(files) && !hasPandoc()) {
    console.error(
      'Error: .org files found in docs/ but pandoc is not installed.\n' +
      '  Install it with: brew install pandoc\n' +
      '  (or run: just docs-setup)'
    );
    process.exit(1);
  }

  cleanContentDir();
  for (const abs of files) {
    const rel = path.relative(DOCS_SRC, abs);
    const ext = path.extname(abs).toLowerCase();
    if (ext === '.md') {
      const raw = fs.readFileSync(abs, 'utf8');
      writeOut(outPathFor(rel), ensureTitle(raw, abs));
    } else if (ext === '.org') {
      const md = convertOrg(abs);
      const outRel = rel.replace(/\.org$/i, '.md');
      writeOut(outPathFor(outRel), ensureTitle(md, abs));
    }
    // other files (e.g. org-roam.db) are skipped.
  }
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) main();
