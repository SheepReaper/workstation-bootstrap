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

The script changes the Windows Documents known-folder pointer to the local
`%USERPROFILE%\Documents` path so PowerShell no longer loads its profile from
OneDrive. It records the previous registry value but does not move or delete any
Documents content. Sign out after bootstrap for all applications to observe it.

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
