#!/usr/bin/env node

/**
 * qa-gate-enforcer.js
 * 
 * Stop hook (type: "command") that blocks Claude from stopping
 * if frontend/API changes exist but no QA gate was run.
 * 
 * Returns {"decision": "block"} to prevent Claude from completing
 * until the super-smoke-test skill is executed.
 * 
 * Install: Copy to ~/.claude/hooks/ and add to settings.json
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

let input = '';
process.stdin.setEncoding('utf-8');
process.stdin.on('data', (chunk) => { input += chunk; });
process.stdin.on('end', () => {
  try {
    const hookData = JSON.parse(input);
    
    // CRITICAL: Prevent infinite loops
    if (hookData.stop_hook_active) {
      process.exit(0);
    }

    const cwd = process.cwd();
    if (!fs.existsSync(path.join(cwd, 'package.json'))) {
      process.exit(0); // Not in a project
    }

    // --- Step 1: Check for frontend/API changes ---
    // Look at BOTH uncommitted changes AND recent commits (covers full GSD phases)
    // GSD phases make many commits — HEAD~1 only catches the last one
    const triggerPatterns = [
      /page\.(tsx|ts|jsx|js)$/,
      /layout\.(tsx|ts|jsx|js)$/,
      /route\.(tsx|ts)$/,
      /src\/components\//,
      /components\//,
      /middleware\.(ts|tsx|js)$/,
      /globals\.css/,
      /tailwind\.config/,
      /src\/lib\//,
      /src\/hooks\//,
      /src\/utils\//,
      /src\/providers\//,
      /src\/context\//,
      /src\/app\//,
      /app\//
    ];

    let changedFiles = '';
    try {
      // Check uncommitted + last 4 hours of commits (covers long GSD phases)
      const uncommitted = execSync(
        'git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null',
        { encoding: 'utf-8', timeout: 5000 }
      ).trim();

      const recentCommits = execSync(
        'git log --name-only --pretty=format: --since="4 hours ago" 2>/dev/null || git log --name-only --pretty=format: -30 2>/dev/null',
        { encoding: 'utf-8', timeout: 5000 }
      ).trim();

      changedFiles = [uncommitted, recentCommits].filter(Boolean).join('\n');
    } catch (e) {
      process.exit(0); // Git not available
    }

    if (!changedFiles) {
      process.exit(0);
    }

    // Deduplicate and filter
    const files = [...new Set(changedFiles.split('\n').filter(Boolean))];
    const hasFrontendChanges = files.some(file =>
      triggerPatterns.some(pattern => pattern.test(file))
    );

    if (!hasFrontendChanges) {
      process.exit(0); // Only backend/config/doc changes
    }

    // --- Step 2: Check if QA gate was already run ---
    const playwrightDir = path.join(cwd, '.playwright-cli');
    if (fs.existsSync(playwrightDir)) {
      try {
        const artifacts = fs.readdirSync(playwrightDir)
          .filter(f => f.endsWith('.png') || f.endsWith('.yaml'));
        
        if (artifacts.length > 0) {
          const thirtyMinAgo = Date.now() - (30 * 60 * 1000);
          const hasRecentArtifacts = artifacts.some(f => {
            const stat = fs.statSync(path.join(playwrightDir, f));
            return stat.mtimeMs > thirtyMinAgo;
          });

          if (hasRecentArtifacts) {
            process.exit(0); // QA already ran
          }
        }
      } catch (e) {
        // Continue to block
      }
    }

    // --- Step 3: Check transcript for QA evidence ---
    if (hookData.transcript_path) {
      try {
        const transcript = fs.readFileSync(hookData.transcript_path, 'utf-8');
        const lastChunk = transcript.slice(-10000);
        
        if (lastChunk.includes('QA Gate Results') || 
            lastChunk.includes('Smoke Test Results') ||
            (lastChunk.includes('smoke test') && lastChunk.includes('PASS')) ||
            lastChunk.includes('super-smoke-test')) {
          process.exit(0); // QA evidence in transcript
        }
      } catch (e) {
        // Continue to block
      }
    }

    // --- Step 4: BLOCK ---
    const frontendFiles = files.filter(file =>
      triggerPatterns.some(pattern => pattern.test(file))
    ).slice(0, 5); // Show first 5 as evidence

    const output = {
      decision: "block",
      reason: `Frontend/API changes detected but QA gate was not run. Changed files include: ${frontendFiles.join(', ')}. You MUST run the super-smoke-test skill NOW. Execute: Codex review (if available) → fix → Playwright CLI smoke test → fix → report.`
    };

    console.log(JSON.stringify(output));
    process.exit(0);

  } catch (e) {
    process.exit(0); // Fail open
  }
});
