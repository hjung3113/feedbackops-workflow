#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const TOKENS = {
  'legacy-review-schemas': '.review/schemas',
  'legacy-review-readme': '.review/README.md',
  'legacy-repository-scripts': '$REPOSITORY_ROOT/scripts',
  'legacy-repository-docs': '$REPOSITORY_ROOT/docs/agents',
  'legacy-repository-skill': '$REPOSITORY_ROOT/.claude/skills/agent-workflow',
};

function fail(message) {
  process.stderr.write(`release-contract: ${message}\n`);
  process.exitCode = 1;
}

function trackedFiles(root) {
  return execFileSync('git', ['-C', root, 'ls-files', '-z'])
    .toString('utf8')
    .split('\0')
    .filter(Boolean)
    .sort();
}

function readText(file) {
  if (!fs.existsSync(file)) return null;
  const content = fs.readFileSync(file);
  return content.includes(0) ? null : content.toString('utf8');
}

function countLiteral(text, literal) {
  return text.split(literal).length - 1;
}

function validateLegacyReferences(root, files) {
  const exceptionsPath = path.join(root, '.github/tests/release-contract-exceptions.json');
  const metadataPaths = new Set([
    '.github/tests/release-contract-check.cjs',
    '.github/tests/release-contract-exceptions.json',
  ]);
  const config = JSON.parse(fs.readFileSync(exceptionsPath, 'utf8'));
  const exceptions = [];

  for (const kind of ['historicalReferences', 'compatibilityReferences']) {
    if (!Array.isArray(config[kind])) {
      fail(`exceptions field ${kind} must be an array`);
      continue;
    }
    for (const entry of config[kind]) {
      if (!TOKENS[entry.token]) {
        fail(`unknown exception token ${entry.token || '<missing>'}`);
        continue;
      }
      if (!entry.reason || !entry.context || !Number.isInteger(entry.expectedCount) || entry.expectedCount < 1 ||
          (kind === 'compatibilityReferences' && !entry.region)) {
        fail(`invalid ${kind} entry for ${entry.path || '<missing>'}`);
        continue;
      }
      exceptions.push({ ...entry, kind });
    }
  }

  const expected = new Map();
  for (const entry of exceptions) {
    const key = `${entry.token}\0${entry.path}\0${entry.region || ''}\0${entry.context}`;
    if (expected.has(key)) fail(`duplicate ${entry.kind} exception for ${entry.token} in ${entry.path}`);
    expected.set(key, entry);
  }
  const actual = new Map();

  for (const relative of files) {
    if (metadataPaths.has(relative)) continue;
    const text = readText(path.join(root, relative));
    if (text === null) continue;
    let region = '';
    for (const rawLine of text.split('\n')) {
      const context = rawLine.trim();
      const marker = context.match(/^# release-contract: ([a-z0-9-]+)-(begin|end)$/);
      if (marker) {
        if (marker[2] === 'begin') {
          if (region) fail(`nested compatibility region in ${relative}: ${marker[1]}`);
          region = marker[1];
        } else if (region !== marker[1]) {
          fail(`unmatched compatibility region end in ${relative}: ${marker[1]}`);
        } else {
          region = '';
        }
        continue;
      }
      for (const [token, literal] of Object.entries(TOKENS)) {
        const count = countLiteral(rawLine, literal);
        if (count > 0) {
          const key = `${token}\0${relative}\0${region}\0${context}`;
          actual.set(key, (actual.get(key) || 0) + count);
        }
      }
    }
    if (region) fail(`unclosed compatibility region in ${relative}: ${region}`);
  }

  for (const [key, count] of actual) {
    const entry = expected.get(key);
    const [token, relative, region, context] = key.split('\0');
    if (!entry) {
      fail(`unapproved ${token} reference in ${relative}${region ? ` [${region}]` : ''}: ${context}`);
    } else if (entry.expectedCount !== count) {
      fail(`${entry.kind} count mismatch for ${token} in ${relative}: expected ${entry.expectedCount}, got ${count}`);
    }
  }
  for (const [key, entry] of expected) {
    if (!actual.has(key)) {
      fail(`stale ${entry.kind} exception for ${entry.token} in ${entry.path}`);
    }
  }
}

function validateCurrentRootReferences(root, files) {
  const currentRootFiles = files.filter((relative) =>
    ['README.md', 'AGENTS.md', 'CLAUDE.md'].includes(relative) ||
    relative.startsWith('.github/workflows/') ||
    relative.startsWith('.githooks/'),
  );
  const forbidden = [
    /(^|[\s`"'(])scripts\/[a-z0-9_.\/-]+/gim,
    /(^|[\s`"'(])\.review\/schemas\/[a-z0-9_.\/-]+/gim,
    /(^|[\s`"'(])\.claude\/skills\/agent-workflow(?:\/|\b)/gim,
    /(^|[\s`"'(])docs\/agents\/(?:multi-agent-workflow|conductor-persona|visual-reviewer-persona|artifact-lifecycle|issue-reporting|workflow-trial-log)\.md/gim,
  ];
  for (const relative of currentRootFiles) {
    const text = readText(path.join(root, relative));
    if (text === null) continue;
    for (const expression of forbidden) {
      expression.lastIndex = 0;
      const match = expression.exec(text);
      if (match) fail(`legacy root product path in current ${relative}: ${match[0].trim()}`);
    }
  }
}

function withoutFencedCode(text) {
  let fence = null;
  return text.split('\n').map((line) => {
    const marker = line.match(/^\s{0,3}(```+|~~~+)/);
    if (marker) {
      if (!fence) fence = marker[1][0];
      else if (marker[1][0] === fence) fence = null;
      return '';
    }
    return fence ? '' : line;
  }).join('\n');
}

function markdownTargets(text) {
  const targets = [];
  const clean = withoutFencedCode(text);
  const reference = /^\s*\[[^\]]+\]:\s*(?:<([^>]+)>|(\S+))/gm;
  let cursor = 0;
  while ((cursor = clean.indexOf('](', cursor)) !== -1) {
    let position = cursor + 2;
    while (/\s/.test(clean[position] || '')) position += 1;
    let target = '';
    if (clean[position] === '<') {
      const close = clean.indexOf('>', position + 1);
      if (close !== -1) target = clean.slice(position + 1, close);
    } else {
      let depth = 1;
      let escaped = false;
      for (; position < clean.length; position += 1) {
        const character = clean[position];
        if (escaped) {
          target += character;
          escaped = false;
        } else if (character === '\\') {
          escaped = true;
        } else if (character === '(') {
          depth += 1;
          target += character;
        } else if (character === ')') {
          depth -= 1;
          if (depth === 0) break;
          target += character;
        } else if (/\s/.test(character) && depth === 1) {
          break;
        } else {
          target += character;
        }
      }
    }
    if (target) targets.push(target);
    cursor += 2;
  }
  let match;
  while ((match = reference.exec(clean)) !== null) targets.push(match[1] || match[2]);
  return targets;
}

function markdownAnchors(text) {
  const anchors = new Set();
  const duplicates = new Map();
  const lines = withoutFencedCode(text).split('\n');
  const addHeading = (value) => {
    const base = value
      .replace(/!?\[([^\]]+)\]\([^)]*\)/g, '$1')
      .replace(/[`*_~]/g, '')
      .toLowerCase()
      .trim()
      .replace(/[^\p{L}\p{N}\s_-]/gu, '')
      .replace(/\s+/g, '-');
    if (!base) return;
    const seen = duplicates.get(base) || 0;
    anchors.add(seen === 0 ? base : `${base}-${seen}`);
    duplicates.set(base, seen + 1);
  };
  for (let index = 0; index < lines.length; index += 1) {
    const atx = lines[index].match(/^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$/);
    if (atx) {
      addHeading(atx[1]);
      continue;
    }
    if (lines[index].trim() && /^\s{0,3}(?:=+|-+)\s*$/.test(lines[index + 1] || '')) {
      addHeading(lines[index].trim());
      index += 1;
    }
  }
  return anchors;
}

function within(candidate, boundary) {
  return candidate === boundary || candidate.startsWith(`${boundary}${path.sep}`);
}

function validateMarkdownLinks(root, relativeFiles, allowedContexts) {
  const anchorCache = new Map();
  for (const relative of relativeFiles) {
    const absolute = path.join(root, relative);
    const text = readText(absolute);
    if (text === null) continue;
    for (const original of markdownTargets(text)) {
      if (/^file:/i.test(original) || /^[a-z]:[\\/]/i.test(original)) {
        fail(`machine-absolute Markdown link in ${relative}: ${original}`);
        continue;
      }
      if (/^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(original)) continue;
      let target;
      let fragment = '';
      try {
        const hashIndex = original.indexOf('#');
        if (hashIndex >= 0) fragment = decodeURIComponent(original.slice(hashIndex + 1));
        target = decodeURIComponent(original.split(/[?#]/, 1)[0]);
      } catch (_error) {
        fail(`invalid URL encoding in ${relative}: ${original}`);
        continue;
      }
      if (!target && !fragment) continue;
      if (path.isAbsolute(target)) {
        fail(`machine-absolute Markdown link in ${relative}: ${original}`);
        continue;
      }
      const resolved = target ? path.resolve(path.dirname(absolute), target) : absolute;
      const logicalContext = allowedContexts.find((context) => within(resolved, context.logical));
      if (!logicalContext) {
        fail(`Markdown link escapes its documented context in ${relative}: ${original}`);
        continue;
      }
      if (!fs.existsSync(resolved)) {
        fail(`missing Markdown link in ${relative}: ${original}`);
        continue;
      }
      const realResolved = fs.realpathSync(resolved);
      if (!allowedContexts.some((context) => within(realResolved, context.real))) {
        fail(`Markdown link resolves outside its documented context in ${relative}: ${original}`);
        continue;
      }
      if (fragment && fs.statSync(realResolved).isFile() && path.extname(realResolved).toLowerCase() === '.md') {
        if (!anchorCache.has(realResolved)) {
          anchorCache.set(realResolved, markdownAnchors(fs.readFileSync(realResolved, 'utf8')));
        }
        if (!anchorCache.get(realResolved).has(fragment.toLowerCase())) {
          fail(`missing Markdown anchor in ${relative}: ${original}`);
        }
      }
    }
  }
}

function walkMarkdown(root, relative, allowedRealRoots, visited) {
  const absolute = path.join(root, relative);
  if (!fs.existsSync(absolute)) return [];
  const real = fs.realpathSync(absolute);
  if (!allowedRealRoots.some((allowed) => within(real, allowed))) {
    fail(`installed documentation escapes product roots: ${relative}`);
    return [];
  }
  if (visited.has(real)) return [];
  visited.add(real);
  const found = [];
  for (const entry of fs.readdirSync(absolute, { withFileTypes: true })) {
    const child = path.join(relative, entry.name);
    const childAbsolute = path.join(root, child);
    const childStat = fs.statSync(childAbsolute);
    if (childStat.isDirectory()) found.push(...walkMarkdown(root, child, allowedRealRoots, visited));
    else if (childStat.isFile() && entry.name.endsWith('.md')) found.push(child);
  }
  return found.sort();
}

const [mode, inputRoot] = process.argv.slice(2);
if (!mode || !inputRoot || !['source', 'installed'].includes(mode)) {
  process.stderr.write('usage: release-contract-check.cjs <source|installed> <root>\n');
  process.exit(2);
}

const root = fs.realpathSync(inputRoot);
if (mode === 'source') {
  const files = trackedFiles(root);
  validateLegacyReferences(root, files);
  validateCurrentRootReferences(root, files);
  const rootDocs = files.filter((relative) => relative.endsWith('.md') && (
    ['README.md', 'AGENTS.md', 'CLAUDE.md'].includes(relative) || relative.startsWith('docs/agents/')
  ));
  const productDocs = files.filter((relative) => relative.endsWith('.md') && relative.startsWith('toolkit/'));
  validateMarkdownLinks(root, rootDocs, [{ logical: root, real: root }]);
  const productRoot = path.join(root, 'toolkit');
  validateMarkdownLinks(root, productDocs, [{ logical: productRoot, real: fs.realpathSync(productRoot) }]);
} else {
  const requiredLogicalRoots = [
    path.join(root, '.agent-workflow/docs/agents'),
    path.join(root, '.claude/skills/agent-workflow'),
  ];
  const logicalRoots = requiredLogicalRoots.filter((candidate) => fs.existsSync(candidate));
  if (logicalRoots.length !== requiredLogicalRoots.length) {
    fail('installed context is missing product docs or the canonical skill');
  }
  const contexts = logicalRoots.map((logical) => ({ logical, real: fs.realpathSync(logical) }));
  const allowedRealRoots = contexts.map((context) => context.real);
  const installedDocs = logicalRoots.flatMap((logical) =>
    walkMarkdown(root, path.relative(root, logical), allowedRealRoots, new Set()),
  );
  if (installedDocs.length === 0) fail('installed context contains no Markdown authorities');
  validateMarkdownLinks(root, installedDocs, contexts);
}

if (!process.exitCode) process.stdout.write(`release-contract: ${mode} checks pass\n`);
