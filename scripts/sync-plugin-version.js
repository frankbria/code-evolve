// npm's `version` lifecycle runs this after bumping package.json: the plugin manifests and the setup
// skill's pinned install command follow it.
// `--check` writes nothing and exits 1 naming every file that drifted (CI and the release workflow);
// `--tag <tag>` also requires the release tag to be v<version>.
const fs = require('fs');
const path = require('path');

const repoRoot = path.join(__dirname, '..');
const { version } = JSON.parse(fs.readFileSync(path.join(repoRoot, 'package.json'), 'utf8'));
const manifests = ['plugins/code-evolve/plugin.json', 'plugins/code-evolve/.claude-plugin/plugin.json'];
const setupSkill = 'plugins/code-evolve/skills/evolve-setup/SKILL.md';
const pinnedInstall = /^(npx -y code-evolve@)\S+/gm;

const flags = process.argv.slice(2);
const tagFlag = flags.indexOf('--tag');
const tag = tagFlag === -1 ? undefined : flags[tagFlag + 1];
const checkOnly = flags.includes('--check');

const synced = new Map();
for (const manifest of manifests) {
  const data = JSON.parse(fs.readFileSync(path.join(repoRoot, manifest), 'utf8'));
  data.version = version;
  synced.set(manifest, `${JSON.stringify(data, null, 2)}\n`);
}
const skillText = fs.readFileSync(path.join(repoRoot, setupSkill), 'utf8');
if (skillText.search(pinnedInstall) === -1) {
  console.error(`${setupSkill} has no \`npx -y code-evolve@<version>\` install command to pin.`);
  process.exit(1);
}
synced.set(setupSkill, skillText.replace(pinnedInstall, `$1${version}`));

if (!checkOnly) {
  for (const [file, content] of synced) fs.writeFileSync(path.join(repoRoot, file), content);
  process.exit(0);
}

const problems = [...synced]
  .filter(([file, content]) => fs.readFileSync(path.join(repoRoot, file), 'utf8') !== content)
  .map(([file]) => `${file} is not at version ${version}`);
if (tagFlag !== -1 && tag !== `v${version}`) {
  problems.push(`release tag ${tag} does not match package.json (expected v${version})`);
}
if (problems.length > 0) {
  console.error(`Version mismatch with package.json (${version}):`);
  for (const problem of problems) console.error(`  - ${problem}`);
  console.error('Change the version with `npm version <patch|minor|major>`; it rewrites these files. Never edit them by hand.');
  process.exit(1);
}
