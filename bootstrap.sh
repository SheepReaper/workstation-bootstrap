#!/bin/sh
set -eu

payload=${1:-developer}
github_owner=${2:-SheepReaper}
dotfiles_repository=${3:-dotfiles}

case "$payload" in
    profile|developer) ;;
    *) echo "usage: bootstrap.sh [profile|developer] [github-owner] [dotfiles-repository]" >&2; exit 2 ;;
esac

os_id=unknown
os_like=
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id=${ID:-unknown}
    os_like=${ID_LIKE:-}
fi

install_pass_cli() {
    command -v pass-cli >/dev/null 2>&1 && return
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) release_arch=x86_64 ;;
        aarch64|arm64) release_arch=arm64 ;;
        *) echo "pass-cli has no supported release for $arch" >&2; return 1 ;;
    esac
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT HUP INT TERM
    api=https://api.github.com/repos/reyamira/pass-cli/releases/latest
    metadata=$(curl -fsLS -H 'Accept: application/vnd.github+json' "$api")
    version=$(printf '%s' "$metadata" | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -n1)
    base="https://github.com/reyamira/pass-cli/releases/download/v${version}"
    archive="pass-cli_${version}_linux_${release_arch}.tar.gz"
    curl -fsLS "$base/$archive" -o "$tmp/$archive"
    curl -fsLS "$base/checksums.txt" -o "$tmp/checksums.txt"
    (cd "$tmp" && grep " $archive\$" checksums.txt | sha256sum -c -)
    tar -xzf "$tmp/$archive" -C "$tmp"
    mkdir -p "$HOME/.local/bin"
    find "$tmp" -type f -name pass-cli -exec cp {} "$HOME/.local/bin/pass-cli" \;
    chmod 0755 "$HOME/.local/bin/pass-cli"
    rm -rf "$tmp"
    trap - EXIT HUP INT TERM
}

if [ "$payload" = developer ]; then
    case " $os_id $os_like " in
        *" debian "*|*" ubuntu "*)
            sudo apt-get update
            sudo apt-get install -y ca-certificates curl gh git git-lfs jq openssh-client rclone ripgrep socat unzip
            ;;
        *" openwrt "*)
            opkg update
            opkg install ca-bundle ca-certificates curl git git-http openssh-client-utils
            ;;
        *) echo "No developer package mapping for $os_id ($os_like); applying profile only." >&2 ;;
    esac
fi

if ! command -v chezmoi >/dev/null 2>&1; then
    sh -c "$(curl -fsLS https://get.chezmoi.io/lb)"
fi

install_pass_cli || true

if command -v systemctl >/dev/null 2>&1 && grep -qi microsoft /proc/version 2>/dev/null; then
    sudo install -m 0644 /dev/stdin /etc/wsl.conf <<'EOF'
[boot]
systemd=true

[automount]
options="metadata,umask=22,fmask=11"
EOF
fi

if command -v gh >/dev/null 2>&1 && ! gh auth status >/dev/null 2>&1; then
    gh auth login --hostname github.com --web --git-protocol ssh
fi
command -v gh >/dev/null 2>&1 && gh auth setup-git || true

chezmoi init --apply "https://github.com/${github_owner}/${dotfiles_repository}.git"
printf '%s\n' 'Linux profile applied. Existing SSH keys and links were not changed.'
