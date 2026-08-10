[CmdletBinding()]
param(
    [ValidateSet('core', 'developer', 'optional')]
    [string]$Profile = 'developer',
    [string]$GitHubOwner = 'SheepReaper',
    [string]$DotfilesRepository = 'dotfiles',
    [switch]$SkipVault
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repository = 'workstation-bootstrap'
$stateDirectory = Join-Path $env:LOCALAPPDATA 'WorkstationBootstrap'
$statePath = Join-Path $stateDirectory 'bootstrap-state.json'

function Get-SourceRoot {
    if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'config'))) {
        return $PSScriptRoot
    }

    $sourceRoot = Join-Path $stateDirectory 'source'
    $archive = Join-Path $stateDirectory 'source.zip'
    New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
    Invoke-WebRequest "https://github.com/$GitHubOwner/$repository/archive/refs/heads/main.zip" -OutFile $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $stateDirectory -Force
    $expanded = Join-Path $stateDirectory "$repository-main"
    if (Test-Path $sourceRoot) { Remove-Item -LiteralPath $sourceRoot -Recurse -Force }
    Move-Item -LiteralPath $expanded -Destination $sourceRoot
    Remove-Item -LiteralPath $archive -Force
    return $sourceRoot
}

function Get-State {
    if (Test-Path $statePath) {
        return Get-Content -Raw $statePath | ConvertFrom-Json
    }
    return [pscustomobject]@{ CompletedPhases = @() }
}

function Save-State([object]$State) {
    New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
    $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding utf8
}

function Invoke-Phase([string]$Name, [scriptblock]$Action) {
    $state = Get-State
    if ($state.CompletedPhases -contains $Name) {
        Write-Host "[skip] $Name"
        return
    }
    Write-Host "[run ] $Name"
    & $Action
    $state = Get-State
    $state.CompletedPhases = @($state.CompletedPhases) + $Name | Select-Object -Unique
    Save-State $state
}

function Invoke-WinGetConfiguration([string]$Path) {
    & winget configure validate --file $Path
    if ($LASTEXITCODE -ne 0) { throw "Invalid WinGet configuration: $Path" }
    & winget configure --file $Path --accept-configuration-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw "WinGet configuration failed: $Path" }
}

function Install-PassCli {
    if (Get-Command pass-cli -ErrorAction SilentlyContinue) { return }

    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'workstation-bootstrap' }
    $release = Invoke-RestMethod 'https://api.github.com/repos/reyamira/pass-cli/releases/latest' -Headers $headers
    $architecture = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'x86_64' }
    $asset = $release.assets | Where-Object name -Match "windows_${architecture}\.tar\.gz$" | Select-Object -First 1
    $checksums = $release.assets | Where-Object name -EQ 'checksums.txt' | Select-Object -First 1
    if (-not $asset -or -not $checksums) { throw 'The pass-cli release is missing a Windows archive or checksums.' }

    $temporary = Join-Path ([IO.Path]::GetTempPath()) "pass-cli-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $temporary | Out-Null
    try {
        $archive = Join-Path $temporary $asset.name
        $checksumFile = Join-Path $temporary 'checksums.txt'
        Invoke-WebRequest $asset.browser_download_url -OutFile $archive
        Invoke-WebRequest $checksums.browser_download_url -OutFile $checksumFile
        $expected = (Get-Content $checksumFile | Where-Object { $_ -match [regex]::Escape($asset.name) } | Select-Object -First 1).Split()[0]
        $actual = (Get-FileHash -Algorithm SHA256 $archive).Hash
        if (-not $expected -or $actual -ne $expected) { throw 'pass-cli checksum verification failed.' }
        tar -xzf $archive -C $temporary
        $binary = Get-ChildItem $temporary -Filter 'pass-cli.exe' -Recurse | Select-Object -First 1
        $bin = Join-Path $env:LOCALAPPDATA 'Programs\pass-cli'
        New-Item -ItemType Directory -Force -Path $bin | Out-Null
        Copy-Item $binary.FullName (Join-Path $bin 'pass-cli.exe') -Force
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (($userPath -split ';') -notcontains $bin) {
            [Environment]::SetEnvironmentVariable('Path', (($userPath.TrimEnd(';'), $bin) -join ';'), 'User')
        }
        $env:Path = "$bin;$env:Path"
    }
    finally {
        if (Test-Path $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

function Initialize-Vault {
    if ($SkipVault) { return }
    if (-not (rclone listremotes 2>$null | Select-String '^onedrive:$')) {
        Write-Host 'Configure an rclone remote named onedrive. OAuth interaction is expected.'
        rclone config
    }
    if (-not (Test-Path (Join-Path $HOME '.pass-cli\vault.enc'))) {
        Write-Host 'Connect pass-cli to the existing onedrive:.pass-cli vault when prompted.'
        pass-cli init
    }
    pass-cli doctor
}

function Initialize-GitHub {
    gh auth status 2>$null
    if ($LASTEXITCODE -ne 0) { gh auth login --hostname github.com --web --git-protocol ssh }
    gh auth setup-git
}

$sourceRoot = Get-SourceRoot

Invoke-Phase 'packages-core' { Invoke-WinGetConfiguration (Join-Path $sourceRoot 'config\winget\core.dsc.winget') }
if ($Profile -in @('developer', 'optional')) {
    Invoke-Phase 'packages-developer' { Invoke-WinGetConfiguration (Join-Path $sourceRoot 'config\winget\developer.dsc.winget') }
}
if ($Profile -eq 'optional') {
    Invoke-Phase 'packages-optional' { Invoke-WinGetConfiguration (Join-Path $sourceRoot 'config\winget\optional.dsc.winget') }
}
Invoke-Phase 'pass-cli' { Install-PassCli }
Invoke-Phase 'vault' { Initialize-Vault }
Invoke-Phase 'github' { Initialize-GitHub }
Invoke-Phase 'dotfiles-windows' {
    chezmoi init --apply "https://github.com/$GitHubOwner/$DotfilesRepository.git"
}
Invoke-Phase 'windows-config' {
    Copy-Item (Join-Path $sourceRoot 'config\wslconfig') (Join-Path $HOME '.wslconfig') -Force
    if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) { oh-my-posh font install CascadiaCode }
    Get-Content (Join-Path $sourceRoot 'config\vscode-extensions.txt') | ForEach-Object { code --install-extension $_ --force }
}
if ($Profile -in @('developer', 'optional')) {
    Invoke-Phase 'wsl-linux' {
        wsl --install -d Ubuntu --no-launch
        $payload = if ($Profile -eq 'core') { 'profile' } else { 'developer' }
        wsl -d Ubuntu -- sh -lc "curl -fsLS https://raw.githubusercontent.com/$GitHubOwner/$repository/main/bootstrap.sh | sh -s -- $payload $GitHubOwner $DotfilesRepository"
    }
}

Write-Host 'Workstation bootstrap is complete. Existing SSH keys and links were not changed.'
