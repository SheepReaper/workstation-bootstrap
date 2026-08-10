$ErrorActionPreference = 'Stop'

Describe 'bootstrap contract' {
    BeforeAll {
        $script:Root = Split-Path -Parent $PSScriptRoot
        $script:Bootstrap = Get-Content -Raw (Join-Path $script:Root 'bootstrap.ps1')
        $script:Packages = Get-Content -Raw (Join-Path $script:Root 'config/packages.psd1')
    }

    It 'defaults to the developer profile and validates supported profiles' {
        $script:Bootstrap | Should Match "ValidateSet\('core', 'developer', 'optional'\)"
        $script:Bootstrap | Should Match '\[string\]\$Profile = ''developer'''
    }

    It 'uses local resumable state without storing secrets' {
        $script:Bootstrap | Should Match 'bootstrap-state.json'
        $script:Bootstrap | Should Match 'CompletedPhases'
        $script:Bootstrap | Should Not Match 'GITHUB_TOKEN\s*='
    }

    It 'reconciles completed phases instead of permanently skipping them' {
        $script:Bootstrap | Should Match 'CompletedPhases -contains \$Name\) \{ ''refresh'' \}'
        $script:Bootstrap | Should Not Match '\[skip\]'
        $script:Bootstrap | Should Not Match 'CompletedPhases -contains \$Name\)[^}]+return'
    }

    It 'does not journal the vault phase when vault setup is skipped' {
        $script:Bootstrap | Should Match 'if \(-not \$SkipVault\) \{ Invoke-Phase ''vault'''
    }

    It 'curates npiperelay and required workstation tools' {
        $script:Packages | Should Match 'jstarks\.npiperelay'
        $script:Packages | Should Match 'twpayne\.chezmoi'
        $script:Packages | Should Match 'Rclone\.Rclone'
    }

    It 'falls back to curated direct WinGet installs when DSC cannot load' {
        $script:Bootstrap | Should Match 'Invoke-WinGetPackageFallback'
        $script:Bootstrap | Should Match 'WinGet Configuration failed; reconciling curated packages directly'
        $script:Bootstrap | Should Match 'winget install --id \$packageId --exact'
        $script:Packages | Should Match 'CoreyButler\.NVMforWindows'
        $script:Packages | Should Not Match 'OpenJS\.NodeJS|Microsoft\.OpenSSH\.Beta'
    }

    It 'installs and activates LTS Node through NVM for Windows' {
        $developer = Get-Content -Raw (Join-Path $script:Root 'config/winget/developer.dsc.winget')
        $developer | Should Match 'CoreyButler\.NVMforWindows'
        $developer | Should Not Match 'OpenJS\.NodeJS'
        $script:Bootstrap | Should Match 'nvm(?:\.exe)?[^\r\n]*install[^\r\n]*lts'
        $script:Bootstrap | Should Match 'nvm(?:\.exe)?[^\r\n]*use[^\r\n]*lts'
    }

    It 'never mutates or removes legacy ssh keys' {
        $script:Bootstrap | Should Not Match 'Remove-Item[^\r\n]*\.ssh'
        $script:Bootstrap | Should Not Match 'ssh-keygen[^\r\n]*-[Rr]'
    }

    It 'does not redirect the Windows Documents known folder' {
        $script:Bootstrap | Should Not Match 'User Shell Folders|Set-ItemProperty[^\r\n]*Personal'
    }

    It 'bootstraps from Windows PowerShell and then relaunches under PowerShell 7' {
        $script:Bootstrap | Should Match '\$PSVersionTable\.PSVersion\.Major -lt 7'
        $script:Bootstrap | Should Match 'pwsh[^\r\n]*-NoProfile[^\r\n]*-File'
        $script:Bootstrap | Should Match 'Invoke-WebRequest[^\r\n]*-UseBasicParsing'
    }

    It 'requests elevation once and preserves the originating user profile' {
        $script:Bootstrap | Should Match 'function Test-IsAdministrator'
        $script:Bootstrap | Should Match 'Start-Process powershell\.exe -Verb RunAs'
        $script:Bootstrap | Should Match "ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand'"
        $script:Bootstrap | Should Match 'pwsh[^\r\n]*-ExecutionPolicy Bypass[^\r\n]*-File'
        ([regex]::Matches($script:Bootstrap, '-Verb RunAs')).Count | Should Be 1
        $script:Bootstrap | Should Match 'ExpectedUserProfile'
        $script:Bootstrap | Should Match 'UAC elevation changed the user profile'
    }

    It 'restores locked agent skills after applying dotfiles for developer profiles' {
        $script:Bootstrap | Should Match 'if \(\$Profile -in @\(''developer'', ''optional''\)\)'
        $script:Bootstrap | Should Match 'npx(?:\.cmd)?[^\r\n]*--yes[^\r\n]*skills[^\r\n]*install[^\r\n]*-g'
        $script:Bootstrap.IndexOf("Invoke-Phase 'agent-skills'") |
            Should BeGreaterThan $script:Bootstrap.IndexOf("Invoke-Phase 'dotfiles-windows'")
    }

    It 'updates an existing chezmoi checkout before applying it' {
        $script:Bootstrap | Should Match 'chezmoi source-path'
        $script:Bootstrap | Should Match 'chezmoi git -- pull --ff-only'
        $script:Bootstrap | Should Match 'chezmoi apply'
    }

    It 'does not reinstall an existing Ubuntu distribution' {
        $script:Bootstrap | Should Match 'wsl[^\r\n]*--list[^\r\n]*--quiet'
        $script:Bootstrap | Should Match 'if \(-not \$ubuntuInstalled\)'
    }

    It 'repairs incomplete pass-cli sync and keychain configuration' {
        $script:Bootstrap | Should Match 'pass-cli sync enable'
        $script:Bootstrap | Should Match 'pass-cli keychain enable'
        $script:Bootstrap | Should Match 'onedrive:\.pass-cli'
    }

    It 'configures the rclone remote once and restricts its local OAuth config' {
        $script:Bootstrap | Should Match 'rclone listremotes'
        $script:Bootstrap | Should Match "Select-String '\^onedrive:\$'"
        $script:Bootstrap | Should Match 'One-time setup: create an rclone remote named onedrive'
        $script:Bootstrap | Should Match 'function Protect-RcloneConfig'
        $script:Bootstrap | Should Match 'rclone config file'
        $script:Bootstrap | Should Match 'icacls\.exe'
    }

    It 'only installs the prompt font when it is absent' {
        $script:Bootstrap | Should Match 'CascadiaCode[^\r\n]*-ErrorAction SilentlyContinue'
    }

    It 'propagates failures from external reconciliation commands' {
        $script:Bootstrap | Should Match 'GitHub CLI credential-helper configuration failed'
        $script:Bootstrap | Should Match 'VS Code extension installation failed'
        $script:Bootstrap | Should Match 'Linux bootstrap failed in WSL'
    }
}
