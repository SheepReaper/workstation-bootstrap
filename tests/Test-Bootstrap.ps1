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
}
