# Workstation bootstrap

Public, secret-free bootstrap for a reproducible Windows or Linux development
environment. Windows packages are curated into `core`, `developer`, and
`optional` WinGet Configuration profiles; the default is `developer`.

## Windows

```powershell
irm https://raw.githubusercontent.com/SheepReaper/workstation-bootstrap/main/bootstrap.ps1 | iex
```

For a non-default profile, download the script and invoke it with
`-Profile core` or `-Profile optional`. Progress is journaled under
`%LOCALAPPDATA%\WorkstationBootstrap`; rerunning safely resumes completed phases.

The script leaves the Windows Documents known-folder pointer unchanged. It can
start under the inbox Windows PowerShell 5.1. It downloads its reviewed source,
requests one UAC approval, verifies that elevation retained the originating
user profile, installs the core tools, and then continues under PowerShell 7.
It prints the pinned seven-character Git revision as it starts. If the elevated
run fails, its window remains open and the complete transcript is retained at
`%LOCALAPPDATA%\WorkstationBootstrap\bootstrap-elevated.log`.
Chezmoi installs tiny loaders for both engines at
their resolved profile paths, regardless of whether Documents is local or
protected by OneDrive. Each loader sources the real configuration at the local
`%USERPROFILE%\.config\powershell\profile.ps1` file without modifying the
automatic `$PROFILE` variable.

## Linux

```sh
sh -c "$(curl -fsLS https://raw.githubusercontent.com/SheepReaper/workstation-bootstrap/main/bootstrap.sh)"
```

Pass `profile` for shell/Git configuration only or `developer` for the supported
Ubuntu/Debian toolset. OpenWrt receives its compatible lightweight packages and
profile; unsupported architectures skip pass-cli with a warning.

Developer restores run `npx skills install -g` after chezmoi applies the private
dotfiles repository and its `~/.agents/.skill-lock.json`. Platforms without
Node.js, including the lightweight OpenWrt path, skip dependency restoration
while still applying the portable agent files managed directly by chezmoi.
Node.js itself is installed through NVM rather than as an unversioned system
package: NVM for Windows selects LTS on Windows, and pinned `nvm-sh` selects and
aliases LTS as the default on Ubuntu/Debian.

Bootstrap is reconciliation-based. Reruns refresh every applicable phase even
when it previously completed, while each phase checks existing state before
making changes. WinGet and OS package managers converge packages; existing
dotfiles repositories are fast-forwarded and applied; existing Ubuntu WSL
distributions are reused; and pass-cli, fonts, agents, and configuration files
only repair missing or stale state. The local phase journal records successful
progress for reboot/interruption diagnosis but never permanently suppresses a
future refresh.

If a clean Windows image can validate a WinGet Configuration but its DSC
processor cannot import `Microsoft.WinGet.DSC`, bootstrap falls back to
idempotent direct `winget install` calls using the same curated package groups.
The configuration path remains preferred and is retried on the next run.

## Security boundaries

- pass-cli is the only component synchronized through OneDrive, via rclone.
- A fresh Windows user completes OneDrive OAuth once in `rclone config`; reruns
  detect the local `onedrive:` remote and skip setup. Bootstrap restricts the
  unencrypted local OAuth configuration to that user, SYSTEM, and Administrators.
- pass-cli release archives are verified against the release checksum file.
- Existing SSH keys and links are never rotated, moved, revoked, or deleted.
- The WSL SSH socket relays the Windows OpenSSH agent through npiperelay.

Bootstrap runs its Windows reconciliation under the single approved elevated
process, so package installers, WSL, NVM, and the OpenSSH agent do not each
request UAC. Bootstrap never imports keys into the agent automatically;
resident-key recovery and enrollment remain interactive operations.
