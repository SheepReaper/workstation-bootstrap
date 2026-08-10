#!/bin/sh
set -eu

payload=${1:-developer}
github_owner=${2:-SheepReaper}
dotfiles_repository=${3:-dotfiles}
NVM_VERSION=0.40.4
export PATH="$HOME/.local/bin:$PATH"

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
    command -v pass-cli >/dev/null 2>&1 && pass-cli version >/dev/null 2>&1 && return
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

install_node_lts() {
    export NVM_DIR="$HOME/.nvm"
    if [ ! -s "$NVM_DIR/nvm.sh" ]; then
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT HUP INT TERM
        curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh" -o "$tmp/install-nvm.sh"
        PROFILE=/dev/null bash "$tmp/install-nvm.sh"
        rm -rf "$tmp"
        trap - EXIT HUP INT TERM
    fi
    # shellcheck disable=SC1090
    . "$NVM_DIR/nvm.sh"
    nvm install --lts
    nvm alias default lts
    nvm use default
}

install_profile_packages() {
    case " $os_id $os_like " in
        *" debian "*|*" ubuntu "*)
            sudo apt-get update
            sudo apt-get install -y ca-certificates curl gh git openssh-client rclone unzip
            ;;
        *" openwrt "*)
            opkg update
            opkg install ca-bundle ca-certificates curl git git-http openssh-client-utils
            ;;
        *)
            printf '%s\n' "No package mapping for $os_id ($os_like); using tools already present." >&2
            ;;
    esac
}

install_developer_packages() {
    case " $os_id $os_like " in
        *" debian "*|*" ubuntu "*)
            sudo apt-get install -y git-lfs jq ripgrep socat
            install_node_lts
            ;;
        *" openwrt "*) ;;
        *) printf '%s\n' "No developer package mapping for $os_id ($os_like); applying profile only." >&2 ;;
    esac
}

initialize_vault() {
    command -v pass-cli >/dev/null 2>&1 || return 0
    command -v rclone >/dev/null 2>&1 || return 0
    if ! rclone listremotes 2>/dev/null | grep -qx 'onedrive:'; then
        printf '%s\n' 'Configure an rclone remote named onedrive. OAuth interaction is expected.'
        rclone config
    fi
    if [ ! -f "$HOME/.pass-cli/vault.enc" ]; then
        printf '%s\n' 'Connect pass-cli to the existing onedrive:.pass-cli vault when prompted.'
        pass-cli init
    fi

    vault_config=
    for candidate in "$HOME/.pass-cli/config.yml" "$HOME/.pass-cli/config.yaml"; do
        if [ -f "$candidate" ]; then vault_config=$candidate; break; fi
    done
    if [ -z "$vault_config" ] ||
       ! grep -Eq '^[[:space:]]*enabled:[[:space:]]*true[[:space:]]*$' "$vault_config" ||
       ! grep -Eq '^[[:space:]]*remote:[[:space:]]*onedrive:\.pass-cli[[:space:]]*$' "$vault_config"; then
        printf '%s\n' 'Configure pass-cli sync for onedrive:.pass-cli when prompted.'
        pass-cli sync enable
    fi

    keychain_status=$(pass-cli keychain status 2>&1 || true)
    if printf '%s' "$keychain_status" | grep -q 'System Keychain:.*Available' &&
       ! printf '%s' "$keychain_status" | grep -q 'Password Stored:.*Yes'; then
        pass-cli keychain enable
    fi
    pass-cli doctor
}

sync_dotfiles() {
    source_path=$(chezmoi source-path)
    if [ -d "$source_path/.git" ]; then
        chezmoi git -- pull --ff-only
        chezmoi apply
    else
        chezmoi init --apply "https://github.com/${github_owner}/${dotfiles_repository}.git"
    fi
}

install_profile_packages
if [ "$payload" = developer ]; then install_developer_packages; fi

if ! command -v chezmoi >/dev/null 2>&1; then
    sh -c "$(curl -fsLS https://get.chezmoi.io/lb)"
fi

case " $os_id $os_like " in
    *" openwrt "*) printf '%s\n' 'Skipping pass-cli on OpenWrt because the upstream binary targets glibc.' >&2 ;;
    *) install_pass_cli ;;
esac
initialize_vault

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

sync_dotfiles
if [ "$payload" = developer ]; then
    if command -v npx >/dev/null 2>&1; then
        npx --yes skills install -g
    else
        printf '%s\n' 'Skipping agent skill restoration because npx is unavailable on this platform.' >&2
    fi
fi
printf '%s\n' 'Linux profile applied. Existing SSH keys and links were not changed.'
