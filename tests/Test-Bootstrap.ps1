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

    It 'does not journal the vault phase when vault setup is skipped' {
        $script:Bootstrap | Should Match 'if \(-not \$SkipVault\) \{ Invoke-Phase ''vault'''
    }

    It 'curates npiperelay and required workstation tools' {
        $script:Packages | Should Match 'jstarks\.npiperelay'
        $script:Packages | Should Match 'twpayne\.chezmoi'
        $script:Packages | Should Match 'Rclone\.Rclone'
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

    It 'restores locked agent skills after applying dotfiles for developer profiles' {
        $script:Bootstrap | Should Match 'if \(\$Profile -in @\(''developer'', ''optional''\)\)'
        $script:Bootstrap | Should Match 'npx(?:\.cmd)?[^\r\n]*--yes[^\r\n]*skills[^\r\n]*install[^\r\n]*-g'
        $script:Bootstrap.IndexOf("Invoke-Phase 'agent-skills'") |
            Should BeGreaterThan $script:Bootstrap.IndexOf("Invoke-Phase 'dotfiles-windows'")
    }
}
