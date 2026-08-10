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
start under the inbox Windows PowerShell 5.1, installs the core tools, and then
continues under PowerShell 7. Chezmoi installs tiny loaders for both engines at
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

## Security boundaries

- pass-cli is the only component synchronized through OneDrive, via rclone.
- pass-cli release archives are verified against the release checksum file.
- Existing SSH keys and links are never rotated, moved, revoked, or deleted.
- The WSL SSH socket relays the Windows OpenSSH agent through npiperelay.

The OpenSSH agent service is enabled through a narrowly scoped elevated
PowerShell process. Bootstrap never imports keys into the agent automatically;
resident-key recovery and enrollment remain interactive operations.
