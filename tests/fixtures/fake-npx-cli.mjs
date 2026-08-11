const expected = [
  '--yes', 'skills', 'add', 'github/gh-aw', '-g', '-y',
  '--agent', 'codex', '--skill', 'GitHub Agentic Workflows',
];
if (JSON.stringify(process.argv.slice(2)) !== JSON.stringify(expected)) {
  console.error(JSON.stringify(process.argv.slice(2)));
  process.exit(9);
}
