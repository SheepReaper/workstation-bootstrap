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
  let result;
  if (process.platform === 'win32') {
    // CreateProcess cannot execute .cmd files directly. Build one quoted cmd
    // command so names containing spaces remain a single --skill value.
    const quote = (value) => {
      if (!/^[A-Za-z0-9._ /@:+-]+$/.test(value)) {
        throw new Error(`Unsafe character in skill restore argument: ${value}`);
      }
      return value.includes(' ') ? `"${value}"` : value;
    };
    const command = [npx, ...args].map(quote).join(' ');
    result = spawnSync(process.env.ComSpec ?? 'cmd.exe', ['/d', '/s', '/c', command], {
      stdio: 'inherit',
      shell: false,
    });
  } else {
    result = spawnSync(npx, args, { stdio: 'inherit', shell: false });
  }
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
