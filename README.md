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

The script leaves the Windows Documents known-folder pointer unchanged. Chezmoi
installs a tiny loader at the profile paths reported by PowerShell, regardless of
whether Documents is local or protected by OneDrive. The loader redirects the
session's `$PROFILE` value and loads the real configuration from the local
`%USERPROFILE%\.config\powershell\profile.ps1` file.

## Linux

```sh
sh -c "$(curl -fsLS https://raw.githubusercontent.com/SheepReaper/workstation-bootstrap/main/bootstrap.sh)"
```

Pass `profile` for shell/Git configuration only or `developer` for the supported
Ubuntu/Debian toolset. OpenWrt receives its compatible lightweight packages and
profile; unsupported architectures skip pass-cli with a warning.

## Security boundaries

- pass-cli is the only component synchronized through OneDrive, via rclone.
- pass-cli release archives are verified against the release checksum file.
- Existing SSH keys and links are never rotated, moved, revoked, or deleted.
- The WSL SSH socket relays the Windows OpenSSH agent through npiperelay.

The OpenSSH agent service is enabled through a narrowly scoped elevated
PowerShell process. Bootstrap never imports keys into the agent automatically;
resident-key recovery and enrollment remain interactive operations.
