#!/usr/bin/env node

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

let input = '';
process.stdin.setEncoding('utf-8');
process.stdin.on('data', (chunk) => { input += chunk; });
process.stdin.on('end', () => {
  try {
    const hookData = JSON.parse(input);
    if (hookData.stop_hook_active) { process.exit(0); }

    const cwd = process.cwd();
    if (!fs.existsSync(path.join(cwd, 'package.json'))) { process.exit(0); }

    const triggerPatterns = [
      /page\.(tsx|ts|jsx|js)$/, /layout\.(tsx|ts|jsx|js)$/, /route\.(tsx|ts)$/,
      /src\/components\//, /components\//, /middleware\.(ts|tsx|js)$/,
      /globals\.css/, /tailwind\.config/,
      /src\/lib\//, /src\/hooks\//, /src\/utils\//,
      /src\/providers\//, /src\/context\//, /src\/app\//, /app\//
    ];

    let changedFiles = '';
    try {
      // ONLY check commits from last 4 hours — not old uncommitted changes
      changedFiles = execSync(
        'git log --name-only --pretty=format: --since="4 hours ago" 2>/dev/null',
        { encoding: 'utf-8', timeout: 5000 }
      ).trim();
    } catch (e) { process.exit(0); }

    if (!changedFiles) { process.exit(0); }

    const files = [...new Set(changedFiles.split('\n').filter(Boolean))];
    const hasFrontendChanges = files.some(file =>
      triggerPatterns.some(pattern => pattern.test(file))
    );

    if (!hasFrontendChanges) { process.exit(0); }

    const playwrightDir = path.join(cwd, '.playwright-cli');
    if (fs.existsSync(playwrightDir)) {
      try {
        const artifacts = fs.readdirSync(playwrightDir)
          .filter(f => f.endsWith('.png') || f.endsWith('.yaml'));
        const thirtyMinAgo = Date.now() - (30 * 60 * 1000);
        if (artifacts.some(f => {
          const stat = fs.statSync(path.join(playwrightDir, f));
          return stat.mtimeMs > thirtyMinAgo;
        })) { process.exit(0); }
      } catch (e) {}
    }

    if (hookData.transcript_path) {
      try {
        const lastChunk = fs.readFileSync(hookData.transcript_path, 'utf-8').slice(-10000);
        if (lastChunk.includes('QA Gate Results') || lastChunk.includes('Smoke Test Results') ||
            lastChunk.includes('super-smoke-test')) { process.exit(0); }
      } catch (e) {}
    }

    const frontendFiles = files.filter(f => triggerPatterns.some(p => p.test(f))).slice(0, 5);
    console.log(JSON.stringify({
      decision: "block",
      reason: `Frontend/API changes in recent commits: ${frontendFiles.join(', ')}. Run super-smoke-test skill NOW.`
    }));
    process.exit(0);
  } catch (e) { process.exit(0); }
});
