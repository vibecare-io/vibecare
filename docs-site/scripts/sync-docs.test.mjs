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
  routeForDocsPath,
  rewriteLinks,
} from './sync-docs.mjs';

test('deriveTitle uses first H1', () => {
  assert.equal(deriveTitle('# My Heading\n\nbody', 'foo.md'), 'My Heading');
});

test('deriveTitle ignores headings inside code fences', () => {
  const content = 'intro\n\n```bash\n# not a title\n```\n\n# Real Heading\n';
  assert.equal(deriveTitle(content, 'foo.md'), 'Real Heading');
});

test('deriveTitle falls back to humanized filename', () => {
  assert.equal(deriveTitle('no heading here', 'MCP_SETUP.md'), 'MCP SETUP');
});

test('ensureTitle injects frontmatter and strips the duplicated H1', () => {
  const out = ensureTitle('# Hello\n\nbody', 'hello.md');
  assert.match(out, /^---\ntitle: "Hello"\n---\n/);
  assert.doesNotMatch(out, /# Hello/);
  assert.match(out, /body/);
});

test('ensureTitle keeps body when title comes from filename fallback', () => {
  const out = ensureTitle('no heading here', 'MCP_SETUP.md');
  assert.match(out, /title: "MCP SETUP"/);
  assert.match(out, /no heading here/);
});

test('ensureTitle leaves existing title frontmatter untouched', () => {
  const input = '---\ntitle: Kept\n---\n# Body\n';
  assert.equal(ensureTitle(input, 'x.md'), input);
});

test('orgFilesExist detects org files in a list', () => {
  assert.equal(orgFilesExist(['/a/x.md', '/a/y.org']), true);
  assert.equal(orgFilesExist(['/a/x.md', '/a/z.txt']), false);
});

test('routeForDocsPath lowercases and strips extension', () => {
  assert.equal(routeForDocsPath('MCP_SETUP.md'), '/mcp_setup/');
  assert.equal(routeForDocsPath('superpowers/specs/x.md'), '/superpowers/specs/x/');
  assert.equal(routeForDocsPath('arch.org'), '/arch/');
});

test('routeForDocsPath collapses README to the directory index', () => {
  assert.equal(routeForDocsPath('README.md'), '/');
  assert.equal(routeForDocsPath('macos/README.md'), '/macos/');
});

test('rewriteLinks rewrites in-docs .md/.org links to routes', () => {
  const docSet = new Set(['MCP_SETUP.md', 'arch.org', 'superpowers/specs/x.md']);
  const src = 'see [setup](./MCP_SETUP.md) and [arch](arch.org#top) and [x](superpowers/specs/x.md)';
  const out = rewriteLinks(src, 'README.md', docSet);
  assert.match(out, /\[setup\]\(\/mcp_setup\/\)/);
  assert.match(out, /\[arch\]\(\/arch\/#top\)/);
  assert.match(out, /\[x\]\(\/superpowers\/specs\/x\/\)/);
});

test('rewriteLinks leaves external and out-of-docs links untouched', () => {
  const docSet = new Set(['MCP_SETUP.md']);
  const src = '[ext](https://x.com) [up](../CLAUDE.md) [img](logo.png) [missing](nope.md)';
  const out = rewriteLinks(src, 'README.md', docSet);
  assert.equal(out, src);
});

test('rewriteLinks resolves relative to the source file directory', () => {
  const docSet = new Set(['superpowers/specs/x.md', 'superpowers/specs/y.md']);
  const src = 'link to [y](y.md)';
  const out = rewriteLinks(src, 'superpowers/specs/x.md', docSet);
  assert.match(out, /\[y\]\(\/superpowers\/specs\/y\/\)/);
});

test('convertOrg turns org into markdown (needs pandoc)', { skip: !hasPandoc() }, () => {
  const tmp = path.join(os.tmpdir(), `sync-org-${process.pid}.org`);
  fs.writeFileSync(tmp, '* Heading One\n\nSome *bold* text.\n');
  const md = convertOrg(tmp);
  fs.rmSync(tmp, { force: true });
  assert.match(md, /Heading One/);
  assert.match(md, /\*\*bold\*\*/);
});
