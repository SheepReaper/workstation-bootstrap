#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

grep -q 'profile|developer' "$root/bootstrap.sh"
grep -q 'ID_LIKE' "$root/bootstrap.sh"
grep -q 'opkg' "$root/bootstrap.sh"
grep -q 'chezmoi' "$root/bootstrap.sh"
grep -q 'nodejs npm' "$root/bootstrap.sh"
grep -Eq 'npx .*--yes .*skills .*install .*-g' "$root/bootstrap.sh"
test "$(grep -n 'chezmoi init --apply' "$root/bootstrap.sh" | cut -d: -f1)" -lt \
    "$(grep -n 'npx .*skills .*install' "$root/bootstrap.sh" | cut -d: -f1)"
! grep -Eq 'rm .*(\.ssh|id_(rsa|ed25519))' "$root/bootstrap.sh"
