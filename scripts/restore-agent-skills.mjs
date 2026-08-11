import { existsSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';

const lockPath = process.argv[2];
if (!lockPath) throw new Error('Usage: restore-agent-skills.mjs <global-skill-lock>');

const lock = JSON.parse(readFileSync(lockPath, 'utf8'));
const skills = Object.entries(lock.skills ?? {});
if (skills.length === 0) throw new Error(`No skills are recorded in ${lockPath}`);

const sources = new Map();
for (const [name, entry] of skills) {
  if (!entry?.source) throw new Error(`Skill ${name} has no source in ${lockPath}`);
  const names = sources.get(entry.source) ?? [];
  names.push(name);
  sources.set(entry.source, names);
}

const npxCli = process.env.SKILLS_NPX_CLI ??
  join(dirname(process.execPath), 'node_modules', 'npm', 'bin', 'npx-cli.js');
for (const [source, names] of sources) {
  const args = ['--yes', 'skills', 'add', source, '-g', '-y', '--agent', 'codex'];
  for (const name of names) args.push('--skill', name);
  console.log(`[skills] ${source}: ${names.join(', ')}`);
  if (process.platform === 'win32') {
    if (!existsSync(npxCli)) throw new Error(`npm's npx CLI was not found: ${npxCli}`);
  }
  const result = process.platform === 'win32'
    ? spawnSync(process.execPath, [npxCli, ...args], { stdio: 'inherit', shell: false })
    : spawnSync('npx', args, { stdio: 'inherit', shell: false });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
