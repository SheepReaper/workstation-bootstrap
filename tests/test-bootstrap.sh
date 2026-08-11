#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

grep -q 'profile|developer' "$root/bootstrap.sh"
grep -q 'ID_LIKE' "$root/bootstrap.sh"
grep -q 'opkg' "$root/bootstrap.sh"
grep -q 'chezmoi' "$root/bootstrap.sh"
grep -q 'chezmoi git -- pull --ff-only' "$root/bootstrap.sh"
grep -q 'chezmoi apply' "$root/bootstrap.sh"
grep -q 'pass-cli sync enable' "$root/bootstrap.sh"
grep -q 'pass-cli keychain enable' "$root/bootstrap.sh"
grep -q 'install_profile_packages' "$root/bootstrap.sh"
grep -q '^install_profile_packages$' "$root/bootstrap.sh"
! grep -q 'install_pass_cli || true' "$root/bootstrap.sh"
grep -q 'NVM_VERSION=0.40.4' "$root/bootstrap.sh"
grep -q 'nvm-sh/nvm/v${NVM_VERSION}/install.sh' "$root/bootstrap.sh"
grep -q 'nvm install --lts' "$root/bootstrap.sh"
grep -q "nvm alias default 'lts/\*'" "$root/bootstrap.sh"
grep -q 'default=\$wsl_user' "$root/bootstrap.sh"
grep -q 'get.chezmoi.io).*-- -b "\$HOME/.local/bin"' "$root/bootstrap.sh"
! grep -Eq 'apt-get install .*\b(nodejs|npm)\b' "$root/bootstrap.sh"
grep -q 'JSON.parse' "$root/scripts/restore-agent-skills.mjs"
grep -q "'--yes', 'skills', 'add', source, '-g', '-y'" "$root/scripts/restore-agent-skills.mjs"
grep -q "'--agent', 'codex'" "$root/scripts/restore-agent-skills.mjs"
! grep -Eq 'skills .*install .*-g' "$root/bootstrap.sh"
test "$(grep -n 'chezmoi init --apply' "$root/bootstrap.sh" | cut -d: -f1)" -lt \
    "$(grep -n 'restore-agent-skills' "$root/bootstrap.sh" | cut -d: -f1)"
! grep -Eq 'rm .*(\.ssh|id_(rsa|ed25519))' "$root/bootstrap.sh"
