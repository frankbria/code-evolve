import { execSync } from 'child_process';
import fs from 'fs';
import path from 'path';

/**
 * Extract feature-like lines from markdown content using regex patterns.
 * Looks for bullet/numbered list items that describe capabilities.
 */
export function extractFeaturesRegex(content: string): string[] {
  const features: string[] = [];
  const lines = content.split('\n');

  // Track whether we're inside a feature-like section
  let inFeatureSection = false;

  for (const line of lines) {
    const trimmed = line.trim();

    // Detect feature-related headings
    if (/^#+\s/.test(trimmed)) {
      inFeatureSection = /\b(?:features?|capabilities|functionality|requirements|user\s+stories|deliverables)\b/i.test(trimmed);
      continue;
    }

    // Match bullet points: - item, * item, or numbered: 1. item
    const listMatch = trimmed.match(/^(?:[-*]|\d+\.)\s+(.+)/);
    if (!listMatch) continue;

    const text = listMatch[1];

    // Skip very short items, links-only lines, or meta items
    if (text.length < 10) continue;
    if (/^\[.*\]\(.*\)$/.test(text)) continue;
    if (/^(?:see |note:|todo:|fixme:|hack:)/i.test(text)) continue;

    // If we're in a feature section, include all list items
    if (inFeatureSection) {
      const cleaned = text.replace(/^\[[ x~]\]\s*/, '');
      features.push(cleaned);
      continue;
    }

    // Outside feature sections, use heuristics
    const featurePatterns = [
      /\b(?:support|allow|enable|add|implement|provide|create|build|handle|manage|display|show|send|receive|process|validate|authenticate|authorize|generate|export|import|configure|customize|integrate|optimize|cache|log|monitor|track|deploy|install|update|delete|remove|search|filter|sort|paginate|upload|download)\b/i,
      /\b(?:endpoint|api|route|page|component|service|module|command|plugin|middleware|hook|handler|controller|model|schema|migration|test|workflow)\b/i,
      /`[^`]+`/, // Contains inline code — likely a command or feature name
    ];

    if (featurePatterns.some((p) => p.test(text))) {
      const cleaned = text.replace(/^\[[ x~]\]\s*/, '');
      features.push(cleaned);
    }
  }

  return features;
}

/**
 * Build a spec.md from extracted features and source content.
 */
export function buildSpecMarkdown(features: string[]): string {
  const featureList = features.length > 0
    ? features.map((f) => `- [ ] ${f}`).join('\n')
    : '- [ ] (no features extracted — add your features here)';

  return `# Specification

## Tech Stack
<!-- Detected from source — verify and update -->

## Architecture
<!-- Describe the system architecture -->

## Features (Priority Order)
${featureList}

## Data Model
<!-- Describe data structures and storage -->

## Testing
<!-- Describe testing strategy and targets -->
`;
}

/**
 * Build a vision.md from source content by extracting relevant sections.
 */
export function buildVisionMarkdown(sourceContent: string): string {
  const sections: Record<string, string> = {};
  const sectionPatterns: Record<string, RegExp> = {
    problem: /^#+\s*(?:the\s+)?(?:problem|motivation|background|why)/im,
    users: /^#+\s*(?:target\s+users?|audience|who|users?)/im,
    success: /^#+\s*(?:success|goals?|objectives?|outcomes?|kpis?|metrics?)/im,
  };

  for (const [key, pattern] of Object.entries(sectionPatterns)) {
    const match = pattern.exec(sourceContent);
    if (match && match.index !== undefined) {
      const start = match.index + match[0].length;
      const nextHeading = sourceContent.slice(start).search(/^#+\s/m);
      const end = nextHeading === -1 ? undefined : start + nextHeading;
      sections[key] = sourceContent.slice(start, end).trim();
    }
  }

  return `# Vision

## Problem
${sections.problem || '<!-- What problem does this project solve? -->'}

## Target Users
${sections.users || '<!-- Who is this for? -->'}

## Success Criteria
${sections.success || '<!-- What does success look like? -->'}
`;
}

/**
 * Spawn the claude CLI binary with a prompt and return the output.
 */
export function generateWithClaude(prompt: string): string {
  try {
    const result = execSync('claude -p --output-format text', {
      input: prompt,
      encoding: 'utf8',
      timeout: 120_000,
      maxBuffer: 1024 * 1024,
    });
    return result.trim();
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    throw new Error(`Claude CLI failed: ${message}`);
  }
}

/**
 * Build the AI prompt for spec conversion.
 */
export function buildAiSpecPrompt(sourceContent: string, codebaseFiles: string[]): string {
  const fileList = codebaseFiles.length > 0
    ? codebaseFiles.join('\n')
    : '(no project files yet)';

  return `Convert the following document into a spec.md for the code-evolve framework.

Output ONLY the markdown content (no explanations, no code fences wrapping the whole output).

Required sections:
## Tech Stack
## Architecture
## Features (Priority Order)
## Data Model
## Testing

For Features, use this checkbox format:
- [ ] Not started
- [~] In progress
- [x] Complete

Cross-reference the codebase file list below. If a feature appears to already be implemented based on the filenames, mark it [x]. If partially implemented, mark it [~]. Otherwise mark it [ ].

=== SOURCE DOCUMENT ===
${sourceContent}

=== CODEBASE FILES ===
${fileList}`;
}

/**
 * Build the AI prompt for vision conversion.
 */
export function buildAiVisionPrompt(sourceContent: string): string {
  return `Convert the following document into a vision.md for the code-evolve framework.

Output ONLY the markdown content (no explanations, no code fences wrapping the whole output).

Required sections:
# Vision
## Problem
## Target Users
## Success Criteria

Keep it concise (1-2 pages max). Focus on the "why" and "what", not the "how".

=== SOURCE DOCUMENT ===
${sourceContent}`;
}

/**
 * Gather project file paths for codebase cross-referencing.
 */
export function gatherCodebaseFiles(projectRoot: string): string[] {
  const ignore = ['.evolve', 'node_modules', 'dist', '.git', '__pycache__', '.next', 'target', '.venv'];

  function walk(dir: string, prefix: string): string[] {
    const results: string[] = [];
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return results;
    }

    for (const entry of entries) {
      if (ignore.includes(entry.name)) continue;
      if (entry.name.startsWith('.')) continue;
      if (entry.isSymbolicLink()) continue;
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        results.push(...walk(path.join(dir, entry.name), rel));
      } else {
        results.push(rel);
      }
    }
    return results;
  }

  const allFiles = walk(projectRoot, '');
  if (allFiles.length > 200) {
    console.log(`Note: codebase file list truncated to 200 of ${allFiles.length} files.`);
  }
  return allFiles.slice(0, 200);
}
