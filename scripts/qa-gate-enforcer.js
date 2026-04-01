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

// Read stdin for hook input
let input = '';
process.stdin.setEncoding('utf-8');
process.stdin.on('data', (chunk) => { input += chunk; });
process.stdin.on('end', () => {
  try {
    const hookData = JSON.parse(input);
    
    // CRITICAL: Prevent infinite loops
    // If stop_hook_active is true, Claude is already being forced to continue
    if (hookData.stop_hook_active) {
      process.exit(0); // Allow stop
    }

    // Find the project root (look for package.json)
    const cwd = process.cwd();
    if (!fs.existsSync(path.join(cwd, 'package.json'))) {
      // Not in a project directory — allow stop
      process.exit(0);
    }

    // Step 1: Check if there are frontend/API changes
    const triggerPatterns = [
      'page\\.tsx', 'page\\.ts', 'page\\.jsx', 'page\\.js',
      'layout\\.tsx', 'layout\\.ts',
      'route\\.tsx', 'route\\.ts',
      'src/components/', 'components/',
      'middleware\\.ts',
      'globals\\.css', 'tailwind\\.config',
      'src/lib/', 'src/hooks/', 'src/utils/',
      'src/providers/', 'src/context/'
    ];

    let changedFiles = '';
    try {
      changedFiles = execSync('git diff --name-only HEAD~1 2>/dev/null || git status --porcelain | awk \'{print $2}\'', {
        encoding: 'utf-8',
        timeout: 5000
      }).trim();
    } catch (e) {
      // Git not available or not a repo — allow stop
      process.exit(0);
    }

    if (!changedFiles) {
      process.exit(0); // No changes at all
    }

    // Check if any changed file matches trigger patterns
    const files = changedFiles.split('\n').filter(Boolean);
    const hasFrontendChanges = files.some(file =>
      triggerPatterns.some(pattern => new RegExp(pattern).test(file))
    );

    if (!hasFrontendChanges) {
      process.exit(0); // Only backend/config changes — allow stop
    }

    // Step 2: Check if QA gate was already run (look for recent screenshots)
    const playwrightDir = path.join(cwd, '.playwright-cli');
    if (fs.existsSync(playwrightDir)) {
      try {
        const screenshots = fs.readdirSync(playwrightDir)
          .filter(f => f.endsWith('.png') || f.endsWith('.yaml'));
        
        if (screenshots.length > 0) {
          // Check if any screenshot is from the last 15 minutes
          const fifteenMinAgo = Date.now() - (15 * 60 * 1000);
          const hasRecentScreenshots = screenshots.some(f => {
            const stat = fs.statSync(path.join(playwrightDir, f));
            return stat.mtimeMs > fifteenMinAgo;
          });

          if (hasRecentScreenshots) {
            process.exit(0); // QA gate was already run — allow stop
          }
        }
      } catch (e) {
        // Can't read directory — continue to block
      }
    }

    // Step 3: Also check if smoke-test results are in recent transcript
    // Look for the QA report markers in the transcript
    if (hookData.transcript_path) {
      try {
        const transcript = fs.readFileSync(hookData.transcript_path, 'utf-8');
        const lastChunk = transcript.slice(-5000); // Check last ~5000 chars
        
        if (lastChunk.includes('QA Gate Results') || 
            lastChunk.includes('Smoke Test Results') ||
            lastChunk.includes('smoke test') && lastChunk.includes('PASS')) {
          process.exit(0); // QA results found in transcript — allow stop
        }
      } catch (e) {
        // Can't read transcript — continue to block
      }
    }

    // Step 4: Frontend changes exist + no QA evidence → BLOCK
    const output = {
      decision: "block",
      reason: "Frontend/API changes detected but QA gate was not run. You MUST run the super-smoke-test skill NOW before presenting results. Execute the full QA pipeline: Codex review (if available) → fix → Playwright CLI smoke test → fix → report."
    };

    console.log(JSON.stringify(output));
    process.exit(0);

  } catch (e) {
    // If anything fails, don't block — allow stop
    process.exit(0);
  }
});
