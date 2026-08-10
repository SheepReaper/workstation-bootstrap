#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

grep -q 'profile|developer' "$root/bootstrap.sh"
grep -q 'ID_LIKE' "$root/bootstrap.sh"
grep -q 'opkg' "$root/bootstrap.sh"
grep -q 'chezmoi' "$root/bootstrap.sh"
! grep -Eq 'rm .*(\.ssh|id_(rsa|ed25519))' "$root/bootstrap.sh"
