import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  deriveTitle,
  ensureTitle,
  convertOrg,
  hasPandoc,
  orgFilesExist,
} from './sync-docs.mjs';

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

test('orgFilesExist detects org files in a list', () => {
  assert.equal(orgFilesExist(['/a/x.md', '/a/y.org']), true);
  assert.equal(orgFilesExist(['/a/x.md', '/a/z.txt']), false);
});

test('convertOrg turns org into markdown (needs pandoc)', { skip: !hasPandoc() }, () => {
  const tmp = path.join(os.tmpdir(), `sync-org-${process.pid}.org`);
  fs.writeFileSync(tmp, '* Heading One\n\nSome *bold* text.\n');
  const md = convertOrg(tmp);
  fs.rmSync(tmp, { force: true });
  assert.match(md, /Heading One/);
  assert.match(md, /\*\*bold\*\*/);
});
