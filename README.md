# Workstation bootstrap

Public, secret-free bootstrap for a reproducible Windows or Linux development
environment. Windows packages are curated into `core`, `developer`, and
`optional` WinGet Configuration profiles; the default is `developer`.

## Windows

```powershell
irm https://raw.githubusercontent.com/SheepReaper/workstation-bootstrap/main/bootstrap.ps1 | iex
```

For a non-default profile, download the script and invoke it with
`-WorkstationProfile core` or `-WorkstationProfile optional` (`-Profile` remains
a compatibility alias). Progress is journaled under
`%LOCALAPPDATA%\WorkstationBootstrap`; rerunning safely resumes completed phases.

The script leaves the Windows Documents known-folder pointer unchanged. It can
start under the inbox Windows PowerShell 5.1. It downloads its reviewed source,
requests one UAC approval, verifies that elevation retained the originating
user profile, ensures the machine execution policy is at least `RemoteSigned`,
installs the core tools, and then continues under PowerShell 7. Existing
`RemoteSigned`, `Unrestricted`, or `Bypass` machine policies are preserved, and
bootstrap does not override domain Group Policy.
It prints the pinned seven-character Git revision as it starts. If the elevated
run fails, its window remains open so the error can be inspected. Interactive
secret and OAuth setup is deliberately not transcribed. A secret-free phase and
step journal is retained at
`%LOCALAPPDATA%\WorkstationBootstrap\bootstrap-status.log`.
Chezmoi installs tiny loaders for both engines at
their resolved profile paths, regardless of whether Documents is local or
protected by OneDrive. Each loader sources the real configuration at the local
`%USERPROFILE%\.config\powershell\profile.ps1` file without modifying the
automatic `$PROFILE` variable.
For the initial GitHub source lookup, bootstrap automatically reuses `GH_TOKEN`,
`GITHUB_TOKEN`, or an existing authenticated GitHub CLI session. It remains
anonymous when none is available; authentication is not required on a fresh machine.

## Linux

```sh
sh -c "$(curl -fsLS https://raw.githubusercontent.com/SheepReaper/workstation-bootstrap/main/bootstrap.sh)"
```

Pass `profile` for shell/Git configuration only or `developer` for the supported
Ubuntu/Debian toolset. OpenWrt receives its compatible lightweight packages and
profile; unsupported architectures skip pass-cli with a warning.

Developer restores install missing sources and skill names from the managed global skill
lock after chezmoi applies the private dotfiles repository and its
`~/.agents/.skill-lock.json`. Platforms without
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

Before installing Ubuntu, bootstrap enables the Windows Subsystem for Linux and
Virtual Machine Platform optional components. When Windows requires a restart,
bootstrap offers to schedule a restart and registers a one-time continuation for
the next sign-in; declining leaves the machine ready for a manual restart and rerun.
The one-time post-reboot launch resumes at WSL reconciliation instead of replaying
the already completed Windows setup. A manually initiated rerun still performs a
full reconciliation.
After installing Ubuntu with no initial launch, bootstrap creates a regular Linux
user when the distribution still defaults to `root`; the username and sudo-password
prompts are the one-time equivalent of Ubuntu's first-launch setup. Existing regular
default users are reused.

Bootstrap probes each curated configuration with the non-mutating `winget
configure show` command. Clients that can parse and resolve native DSC v3 apply
the file; other clients use idempotent direct `winget install` calls with the
same curated package groups. The configuration path is retried automatically
after WinGet is upgraded.

## Security boundaries

- pass-cli is the only component synchronized through OneDrive, via rclone.
- A fresh Windows user completes OneDrive OAuth once in `rclone config`; reruns
  detect the local `onedrive:` remote and skip setup. Bootstrap restricts the
  unencrypted local OAuth configuration to that user, SYSTEM, and Administrators.
- pass-cli release archives are verified against the release checksum file.
- Existing SSH keys and links are never rotated, moved, revoked, or deleted.
- On a native local `.ssh` directory, bootstrap restores the primary Git
  YubiKey resident-key handle from pass-cli, restricts its ACL, and loads it
  into the Windows OpenSSH agent before GitHub authentication when supported.
  Legacy linked
  `.ssh` directories are detected and left untouched. Hardware-backed files are
  credential handles, not exportable private keys. If the Windows service agent
  cannot load a FIDO handle, bootstrap warns and continues; the canonical
  physical-key recovery operation is `ssh-keygen -K` with the intended YubiKey
  attached, followed by explicit authentication testing.
- The WSL SSH socket relays the Windows OpenSSH agent through npiperelay.

Bootstrap runs its Windows reconciliation under the single approved elevated
process, so package installers, WSL, NVM, and the OpenSSH agent do not each
request UAC. Bootstrap never imports keys into the agent automatically;
resident-key recovery and enrollment remain interactive operations.
