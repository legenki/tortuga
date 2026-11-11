// Store packages, written next to package.json:
//   node scripts/package.mjs chrome   dist/ → tortuga-chrome-<version>.zip
//                                     + tortuga-chrome-<version>-unpacked.zip
//   node scripts/package.mjs firefox  dist-firefox/ → tortuga-firefox-<version>.zip
//                                     + tortuga-firefox-<version>-source.zip
//                                       (extension/ at HEAD, for AMO review)
// The Chrome Web Store sets the extension's key itself, so the store zip
// leaves out manifest.json's "key". The unpacked zip keeps it: loaded with
// Load unpacked, it gets the pinned id the helper's installers allow; without
// the key Chrome would make up an id from the folder and the helper would
// refuse it.
import { execFileSync } from 'node:child_process';
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const { version } = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
const which = process.argv[2];

function zipDir(dir, out) {
  rmSync(out, { force: true });
  execFileSync('zip', ['-qrX', out, '.'], { cwd: dir });
  console.log(out);
}

if (which === 'chrome') {
  const stage = mkdtempSync(join(tmpdir(), 'tortuga-chrome-'));
  cpSync(join(root, 'dist'), stage, { recursive: true });
  const manifest = JSON.parse(readFileSync(join(stage, 'manifest.json'), 'utf8'));
  if (!manifest.key) {
    console.error('dist/manifest.json has no "key": pin the Chrome id first (RELEASE.md)');
    process.exit(1);
  }
  zipDir(stage, join(root, `tortuga-chrome-${version}-unpacked.zip`));
  delete manifest.key;
  writeFileSync(join(stage, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  zipDir(stage, join(root, `tortuga-chrome-${version}.zip`));
  rmSync(stage, { recursive: true, force: true });
} else if (which === 'firefox') {
  zipDir(join(root, 'dist-firefox'), join(root, `tortuga-firefox-${version}.zip`));
  const source = join(root, `tortuga-firefox-${version}-source.zip`);
  // From the repository's top: run in a subfolder, git archive only takes
  // paths under it.
  const top = execFileSync('git', ['rev-parse', '--show-toplevel'], { cwd: root, encoding: 'utf8' }).trim();
  execFileSync('git', ['archive', '--format=zip', '-o', source, 'HEAD', 'extension'], { cwd: top });
  console.log(source);
} else {
  console.error('usage: node scripts/package.mjs chrome|firefox');
  process.exit(2);
}
