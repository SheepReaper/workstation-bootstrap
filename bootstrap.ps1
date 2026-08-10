[CmdletBinding()]
param(
    [ValidateSet('core', 'developer', 'optional')]
    [string]$Profile = 'developer',
    [string]$GitHubOwner = 'SheepReaper',
    [string]$DotfilesRepository = 'dotfiles',
    [switch]$SkipVault,
    [switch]$CoreReady,
    [switch]$Elevated,
    [string]$ExpectedUserProfile
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
    Invoke-WebRequest "https://github.com/$GitHubOwner/$repository/archive/refs/heads/main.zip" -OutFile $archive -UseBasicParsing
    Expand-Archive -LiteralPath $archive -DestinationPath $stateDirectory -Force
    $expanded = Join-Path $stateDirectory "$repository-main"
    if (Test-Path $sourceRoot) { Remove-Item -LiteralPath $sourceRoot -Recurse -Force }
    Move-Item -LiteralPath $expanded -Destination $sourceRoot
    Remove-Item -LiteralPath $archive -Force
    return $sourceRoot
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedBootstrap([string]$SourceRoot) {
    $quote = { param([string]$Value) "'$($Value.Replace("'", "''"))'" }
    $command = @(
        "& $(& $quote (Join-Path $SourceRoot 'bootstrap.ps1'))"
        "-Profile $(& $quote $Profile)"
        "-GitHubOwner $(& $quote $GitHubOwner)"
        "-DotfilesRepository $(& $quote $DotfilesRepository)"
        "-ExpectedUserProfile $(& $quote $env:USERPROFILE)"
        '-Elevated'
    )
    if ($SkipVault) { $command += '-SkipVault' }
    if ($CoreReady) { $command += '-CoreReady' }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($command -join ' ')))
    Write-Host '[elevate] Approve the single UAC prompt for workstation and package configuration.'
    $process = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
    exit $process.ExitCode
}

function Get-State {
    if (Test-Path $statePath) {
        try { return Get-Content -Raw $statePath | ConvertFrom-Json }
        catch { Write-Warning "Ignoring unreadable bootstrap state: $statePath" }
    }
    return [pscustomobject]@{ CompletedPhases = @() }
}

function Save-State([object]$State) {
    New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
    $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding utf8
}

function Invoke-Phase([string]$Name, [scriptblock]$Action) {
    $state = Get-State
    $label = if ($state.CompletedPhases -contains $Name) { 'refresh' } else { 'run ' }
    Write-Host "[$label] $Name"
    & $Action
    $state = Get-State
    $state.CompletedPhases = @($state.CompletedPhases) + $Name | Select-Object -Unique
    Save-State $state
}

function Invoke-WinGetPackageFallback([string]$PackageProfile) {
    $manifest = Import-PowerShellDataFile (Join-Path $sourceRoot 'config\packages.psd1')
    foreach ($packageId in $manifest[$PackageProfile]) {
        if ($packageId -eq 'CoreyButler.NVMforWindows') {
            winget install --id $packageId --exact --version 1.2.2 --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
        }
        else {
            winget install --id $packageId --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
        }
        if ($LASTEXITCODE -ne 0) {
            winget list --id $packageId --exact --source winget --accept-source-agreements | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "WinGet fallback installation failed: $packageId" }
        }
    }
}

function Invoke-WinGetConfiguration([string]$Path, [string]$PackageProfile) {
    & winget configure validate --file $Path
    if ($LASTEXITCODE -ne 0) { throw "Invalid WinGet configuration: $Path" }
    & winget configure --file $Path --accept-configuration-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "WinGet Configuration failed; reconciling curated packages directly for '$PackageProfile'."
        Invoke-WinGetPackageFallback $PackageProfile
    }
}

function Install-PassCli {
    $bin = Join-Path $env:LOCALAPPDATA 'Programs\pass-cli'
    $installedBinary = Join-Path $bin 'pass-cli.exe'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $bin) {
        $updatedPath = @(if ($userPath) { $userPath.TrimEnd(';') }; $bin) | Where-Object { $_ }
        [Environment]::SetEnvironmentVariable('Path', ($updatedPath -join ';'), 'User')
    }
    if (($env:Path -split ';') -notcontains $bin) { $env:Path = "$bin;$env:Path" }
    if (Test-Path -LiteralPath $installedBinary) {
        & $installedBinary version *> $null
        if ($LASTEXITCODE -eq 0) { return }
    }
    $otherPassCli = Get-Command pass-cli -ErrorAction SilentlyContinue
    if ($otherPassCli -and $otherPassCli.Source -ne $installedBinary) {
        & $otherPassCli.Source version *> $null
        if ($LASTEXITCODE -eq 0) { return }
    }

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
        Invoke-WebRequest $asset.browser_download_url -OutFile $archive -UseBasicParsing
        Invoke-WebRequest $checksums.browser_download_url -OutFile $checksumFile -UseBasicParsing
        $expected = (Get-Content $checksumFile | Where-Object { $_ -match [regex]::Escape($asset.name) } | Select-Object -First 1).Split()[0]
        $actual = (Get-FileHash -Algorithm SHA256 $archive).Hash
        if (-not $expected -or $actual -ne $expected) { throw 'pass-cli checksum verification failed.' }
        tar -xzf $archive -C $temporary
        $binary = Get-ChildItem $temporary -Filter 'pass-cli.exe' -Recurse | Select-Object -First 1
        New-Item -ItemType Directory -Force -Path $bin | Out-Null
        Copy-Item $binary.FullName (Join-Path $bin 'pass-cli.exe') -Force
    }
    finally {
        if (Test-Path $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

function Protect-RcloneConfig {
    $configOutput = @(rclone config file 2>$null)
    $configPath = $configOutput | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Last 1
    if (-not $configPath) { throw 'Could not locate the rclone configuration file.' }

    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $configPath /inheritance:r | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not disable inherited access on rclone.conf.' }
    & icacls.exe $configPath /grant:r "*${userSid}:(F)" '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not restrict access to rclone.conf.' }
}

function Initialize-Vault {
    if ($SkipVault) { return }
    if (-not (rclone listremotes 2>$null | Select-String '^onedrive:$')) {
        Write-Host 'One-time setup: create an rclone remote named onedrive. OAuth interaction is expected.'
        rclone config
        if (-not (rclone listremotes 2>$null | Select-String '^onedrive:$')) { throw 'The required onedrive rclone remote is still missing.' }
    }
    Protect-RcloneConfig
    if (-not (Test-Path (Join-Path $HOME '.pass-cli\vault.enc'))) {
        Write-Host 'Connect pass-cli to the existing onedrive:.pass-cli vault when prompted.'
        pass-cli init
        if ($LASTEXITCODE -ne 0) { throw 'pass-cli vault initialization failed.' }
    }
    $vaultConfig = @(
        (Join-Path $HOME '.pass-cli\config.yml')
        (Join-Path $HOME '.pass-cli\config.yaml')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $syncConfigured = $vaultConfig -and
        (Select-String -LiteralPath $vaultConfig -Pattern '^\s*enabled:\s*true\s*$' -Quiet) -and
        (Select-String -LiteralPath $vaultConfig -Pattern '^\s*remote:\s*onedrive:\.pass-cli\s*$' -Quiet)
    if (-not $syncConfigured) {
        Write-Host 'Configure pass-cli sync for onedrive:.pass-cli when prompted.'
        pass-cli sync enable
        if ($LASTEXITCODE -ne 0) { throw 'pass-cli sync configuration failed.' }
    }
    $keychainStatus = pass-cli keychain status 2>&1 | Out-String
    if ($keychainStatus -notmatch 'Password Stored:\s+Yes') {
        pass-cli keychain enable
        if ($LASTEXITCODE -ne 0) { throw 'pass-cli keychain configuration failed.' }
    }
    pass-cli doctor
    if ($LASTEXITCODE -ne 0) { throw 'pass-cli health validation failed.' }
}

function Sync-Dotfiles {
    $sourcePath = (chezmoi source-path).Trim()
    if (Test-Path -LiteralPath (Join-Path $sourcePath '.git')) {
        chezmoi git -- pull --ff-only
        if ($LASTEXITCODE -ne 0) { throw 'Could not refresh the dotfiles repository.' }
        chezmoi apply
        if ($LASTEXITCODE -ne 0) { throw 'Could not apply the refreshed dotfiles repository.' }
        return
    }
    chezmoi init --apply "https://github.com/$GitHubOwner/$DotfilesRepository.git"
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the dotfiles repository.' }
}

function Initialize-GitHub {
    gh auth status 2>$null
    if ($LASTEXITCODE -ne 0) {
        gh auth login --hostname github.com --web --git-protocol ssh
        if ($LASTEXITCODE -ne 0) { throw 'GitHub authentication failed.' }
    }
    gh auth setup-git
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI credential-helper configuration failed.' }
}

function Initialize-OpenSshAgent {
    $client = Get-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0'
    $needsClient = $client.State -ne 'Installed'
    $service = Get-Service ssh-agent -ErrorAction SilentlyContinue
    $needsService = -not $service -or $service.StartType -eq 'Disabled' -or $service.Status -ne 'Running'
    if (-not $needsClient -and -not $needsService) { return }

    if ($needsClient) { Add-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0' | Out-Null }
    Set-Service -Name ssh-agent -StartupType Automatic
    Start-Service -Name ssh-agent
}

function Restore-AgentSkills {
    $lockPath = Join-Path $HOME '.agents\.skill-lock.json'
    if (-not (Test-Path -LiteralPath $lockPath)) {
        throw "Agent skill lockfile was not applied by chezmoi: $lockPath"
    }

    $npx = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if (-not $npx) {
        $env:Path = @(
            [Environment]::GetEnvironmentVariable('Path', 'Machine')
            [Environment]::GetEnvironmentVariable('Path', 'User')
        ) -join ';'
        $npx = Get-Command npx.cmd -ErrorAction SilentlyContinue
    }
    if (-not $npx) { throw 'npx is unavailable after installing the developer package profile.' }

    & $npx.Source --yes skills install -g
    if ($LASTEXITCODE -ne 0) { throw 'Agent skill restoration failed.' }
}

function Initialize-NodeLts {
    foreach ($name in 'NVM_HOME', 'NVM_SYMLINK') {
        $value = [Environment]::GetEnvironmentVariable($name, 'User')
        if (-not $value) { $value = [Environment]::GetEnvironmentVariable($name, 'Machine') }
        if ($value) { Set-Item -LiteralPath "env:$name" -Value $value }
    }
    $env:Path = [Environment]::ExpandEnvironmentVariables((@(
        [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::GetEnvironmentVariable('Path', 'User')
    ) -join ';'))

    $nvm = Get-Command nvm.exe -ErrorAction SilentlyContinue
    if (-not $nvm) { throw 'NVM for Windows is unavailable after the developer package phase.' }

    & $nvm.Source install lts
    if ($LASTEXITCODE -ne 0) { throw 'NVM failed to install the current Node.js LTS release.' }
    & $nvm.Source use lts
    if ($LASTEXITCODE -ne 0) { throw 'NVM failed to activate the current Node.js LTS release.' }
}

$sourceRoot = Get-SourceRoot

if (-not (Test-IsAdministrator)) {
    if ($Elevated) { throw 'The elevated bootstrap did not receive an administrator token.' }
    Invoke-ElevatedBootstrap $sourceRoot
}
if ($ExpectedUserProfile -and -not [string]::Equals($env:USERPROFILE, $ExpectedUserProfile, [StringComparison]::OrdinalIgnoreCase)) {
    throw "UAC elevation changed the user profile from '$ExpectedUserProfile' to '$env:USERPROFILE'. Sign in with an administrator account instead of supplying another account at UAC."
}

if (-not $CoreReady) {
    Invoke-Phase 'packages-core' { Invoke-WinGetConfiguration (Join-Path $sourceRoot 'config\winget\core.dsc.winget') 'core' }
}
if ($PSVersionTable.PSVersion.Major -lt 7) {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sourceRoot 'bootstrap.ps1') -Profile $Profile -GitHubOwner $GitHubOwner -DotfilesRepository $DotfilesRepository -SkipVault:$SkipVault -CoreReady -Elevated -ExpectedUserProfile $env:USERPROFILE
    exit $LASTEXITCODE
}
if ($Profile -in @('developer', 'optional')) {
    Invoke-Phase 'packages-developer' { Invoke-WinGetConfiguration (Join-Path $sourceRoot 'config\winget\developer.dsc.winget') 'developer' }
    Invoke-Phase 'node-lts' { Initialize-NodeLts }
}
if ($Profile -eq 'optional') {
    Invoke-Phase 'packages-optional' { Invoke-WinGetConfiguration (Join-Path $sourceRoot 'config\winget\optional.dsc.winget') 'optional' }
}
Invoke-Phase 'pass-cli' { Install-PassCli }
if (-not $SkipVault) { Invoke-Phase 'vault' { Initialize-Vault } }
Invoke-Phase 'github' { Initialize-GitHub }
Invoke-Phase 'openssh-agent' { Initialize-OpenSshAgent }
Invoke-Phase 'dotfiles-windows' {
    Sync-Dotfiles
}
if ($Profile -in @('developer', 'optional')) {
    Invoke-Phase 'agent-skills' { Restore-AgentSkills }
}
Invoke-Phase 'windows-config' {
    Copy-Item (Join-Path $sourceRoot 'config\wslconfig') (Join-Path $HOME '.wslconfig') -Force
    $fontInstalled = Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\Windows\Fonts\*", "$env:WINDIR\Fonts\*" -Include 'CascadiaCode*', 'CaskaydiaCove*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $fontInstalled -and (Get-Command oh-my-posh -ErrorAction SilentlyContinue)) {
        oh-my-posh font install CascadiaCode
        if ($LASTEXITCODE -ne 0) { throw 'Prompt font installation failed.' }
    }
    Get-Content (Join-Path $sourceRoot 'config\vscode-extensions.txt') | ForEach-Object {
        code --install-extension $_ --force
        if ($LASTEXITCODE -ne 0) { throw "VS Code extension installation failed: $_" }
    }
}
if ($Profile -in @('developer', 'optional')) {
    Invoke-Phase 'wsl-linux' {
        $ubuntuDistribution = @(wsl.exe --list --quiet) | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^Ubuntu(?:-|$)' } | Select-Object -First 1
        $ubuntuInstalled = [bool]$ubuntuDistribution
        if (-not $ubuntuInstalled) {
            wsl --install -d Ubuntu --no-launch
            if ($LASTEXITCODE -ne 0) { throw 'Ubuntu installation failed or requires a reboot; rerun bootstrap afterward.' }
            $ubuntuDistribution = 'Ubuntu'
        }
        $payload = if ($Profile -eq 'core') { 'profile' } else { 'developer' }
        wsl -d $ubuntuDistribution -- sh -lc "curl -fsLS https://raw.githubusercontent.com/$GitHubOwner/$repository/main/bootstrap.sh | sh -s -- $payload $GitHubOwner $DotfilesRepository"
        if ($LASTEXITCODE -ne 0) { throw "Linux bootstrap failed in WSL distribution $ubuntuDistribution." }
    }
}

Write-Host 'Workstation bootstrap is complete. Existing SSH keys and links were not changed.'
