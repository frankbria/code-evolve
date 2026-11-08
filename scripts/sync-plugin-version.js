// npm's `version` lifecycle runs this after bumping package.json: both plugin manifests follow it.
const fs = require('fs');
const path = require('path');

const repoRoot = path.join(__dirname, '..');
const { version } = JSON.parse(fs.readFileSync(path.join(repoRoot, 'package.json'), 'utf8'));
const manifests = ['plugins/code-evolve/plugin.json', 'plugins/code-evolve/.claude-plugin/plugin.json'];

for (const manifest of manifests) {
  const file = path.join(repoRoot, manifest);
  const data = JSON.parse(fs.readFileSync(file, 'utf8'));
  data.version = version;
  fs.writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`);
}
