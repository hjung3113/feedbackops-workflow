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
      if (!entry.reason || !Number.isInteger(entry.expectedCount) || entry.expectedCount < 1) {
        fail(`invalid ${kind} entry for ${entry.path || '<missing>'}`);
        continue;
      }
      exceptions.push({ ...entry, kind });
    }
  }

  const expected = new Map(
    exceptions.map((entry) => [`${entry.token}\0${entry.path}`, entry]),
  );
  const actual = new Map();

  for (const relative of files) {
    if (metadataPaths.has(relative)) continue;
    const text = readText(path.join(root, relative));
    if (text === null) continue;
    for (const [token, literal] of Object.entries(TOKENS)) {
      const count = countLiteral(text, literal);
      if (count > 0) actual.set(`${token}\0${relative}`, count);
    }
  }

  for (const [key, count] of actual) {
    const entry = expected.get(key);
    const [token, relative] = key.split('\0');
    if (!entry) {
      fail(`unapproved ${token} reference in ${relative} (${count})`);
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
  const inline = /!?\[[^\]]*\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+[^)]*)?\)/g;
  const reference = /^\s*\[[^\]]+\]:\s*(?:<([^>]+)>|(\S+))/gm;
  for (const expression of [inline, reference]) {
    let match;
    while ((match = expression.exec(clean)) !== null) targets.push(match[1] || match[2]);
  }
  return targets;
}

function validateMarkdownLinks(root, relativeFiles) {
  for (const relative of relativeFiles) {
    const absolute = path.join(root, relative);
    const text = readText(absolute);
    if (text === null) continue;
    for (const original of markdownTargets(text)) {
      if (/^(?:[a-z][a-z0-9+.-]*:|\/\/|#)/i.test(original)) continue;
      let target;
      try {
        target = decodeURIComponent(original.split(/[?#]/, 1)[0]);
      } catch (_error) {
        fail(`invalid URL encoding in ${relative}: ${original}`);
        continue;
      }
      if (!target) continue;
      if (path.isAbsolute(target)) {
        fail(`machine-absolute Markdown link in ${relative}: ${original}`);
        continue;
      }
      const resolved = path.resolve(path.dirname(absolute), target);
      if (resolved !== root && !resolved.startsWith(`${root}${path.sep}`)) {
        fail(`Markdown link escapes its documented context in ${relative}: ${original}`);
        continue;
      }
      if (!fs.existsSync(resolved)) fail(`missing Markdown link in ${relative}: ${original}`);
    }
  }
}

function walkMarkdown(root, relative) {
  const absolute = path.join(root, relative);
  if (!fs.existsSync(absolute)) return [];
  const found = [];
  for (const entry of fs.readdirSync(absolute, { withFileTypes: true })) {
    const child = path.join(relative, entry.name);
    if (entry.isDirectory()) found.push(...walkMarkdown(root, child));
    else if (entry.isFile() && entry.name.endsWith('.md')) found.push(child);
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
  const currentDocs = files.filter((relative) =>
    relative.endsWith('.md') && (
      ['README.md', 'AGENTS.md', 'CLAUDE.md'].includes(relative) ||
      relative.startsWith('docs/agents/') ||
      relative.startsWith('toolkit/')
    ),
  );
  validateMarkdownLinks(root, currentDocs);
} else {
  const installedDocs = [
    ...walkMarkdown(root, '.agent-workflow/docs'),
    ...walkMarkdown(root, '.claude/skills/agent-workflow'),
  ];
  validateMarkdownLinks(root, installedDocs);
}

if (!process.exitCode) process.stdout.write(`release-contract: ${mode} checks pass\n`);
