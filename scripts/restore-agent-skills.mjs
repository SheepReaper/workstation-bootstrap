import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

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

const npx = process.platform === 'win32' ? 'npx.cmd' : 'npx';
for (const [source, names] of sources) {
  const args = ['--yes', 'skills', 'add', source, '-g', '-y'];
  for (const name of names) args.push('--skill', name);
  console.log(`[skills] ${source}: ${names.join(', ')}`);
  // Windows cannot execute npm's .cmd shim directly through CreateProcess.
  const result = spawnSync(npx, args, {
    stdio: 'inherit',
    shell: process.platform === 'win32',
  });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
