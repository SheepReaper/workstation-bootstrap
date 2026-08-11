[CmdletBinding()]
param(
    [ValidateSet('core', 'developer', 'optional')]
    [Alias('Profile')]
    [string]$WorkstationProfile = 'developer',
    [string]$GitHubOwner = 'SheepReaper',
    [string]$DotfilesRepository = 'dotfiles',
    [switch]$SkipVault,
    [switch]$CoreReady,
    [switch]$ResumeAfterReboot,
    [switch]$Elevated,
    [string]$ExpectedUserProfile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repository = 'workstation-bootstrap'
$stateDirectory = Join-Path $env:LOCALAPPDATA 'WorkstationBootstrap'
$statePath = Join-Path $stateDirectory 'bootstrap-state.json'
$statusLogPath = Join-Path $stateDirectory 'bootstrap-status.log'

function Write-BootstrapStatus([string]$Message) {
    New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
    $line = '{0:o} {1}' -f [DateTimeOffset]::Now, $Message
    Add-Content -LiteralPath $statusLogPath -Value $line -Encoding utf8
}

function Get-GitHubApiHeaders {
    $headers = @{
        'Accept' = 'application/vnd.github+json'
        'User-Agent' = $repository
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $token = if ($env:GH_TOKEN) { $env:GH_TOKEN } elseif ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $null }
    if (-not $token) {
        $ghCommand = Get-Command gh.exe -ErrorAction SilentlyContinue
        $ghPath = if ($ghCommand) { $ghCommand.Source } else { $null }
        if (-not $ghPath) {
            $installedGh = Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'
            if (Test-Path -LiteralPath $installedGh) { $ghPath = $installedGh }
        }
        if ($ghPath) {
            $token = (& $ghPath auth token 2>$null | Select-Object -First 1)
            if ($LASTEXITCODE -ne 0) { $token = $null }
        }
    }
    if ($token) {
        $headers.Authorization = "Bearer $($token.Trim())"
        Write-Host '[github] Using existing authentication for the source lookup.'
    }
    return $headers
}

function Get-SourceRoot {
    if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'config'))) {
        return $PSScriptRoot
    }

    $sourceRoot = Join-Path $stateDirectory 'source'
    $archive = Join-Path $stateDirectory 'source.zip'
    New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
    try {
        $commit = Invoke-RestMethod "https://api.github.com/repos/$GitHubOwner/$repository/commits/main" -Headers (Get-GitHubApiHeaders) -UseBasicParsing
    }
    catch {
        throw "GitHub could not resolve the bootstrap revision. If this is an API rate limit, authenticate GitHub CLI with 'gh auth login' or set GH_TOKEN, then rerun. $($_.Exception.Message)"
    }
    $revision = $commit.sha
    Invoke-WebRequest "https://github.com/$GitHubOwner/$repository/archive/$revision.zip" -OutFile $archive -UseBasicParsing
    Expand-Archive -LiteralPath $archive -DestinationPath $stateDirectory -Force
    $expanded = Join-Path $stateDirectory "$repository-$revision"
    if (Test-Path $sourceRoot) { Remove-Item -LiteralPath $sourceRoot -Recurse -Force }
    Move-Item -LiteralPath $expanded -Destination $sourceRoot
    Set-Content -LiteralPath (Join-Path $sourceRoot 'source-revision.txt') -Value $revision -Encoding ascii
    Remove-Item -LiteralPath $archive -Force
    return $sourceRoot
}

function Get-SourceRevision([string]$SourceRoot) {
    $revisionPath = Join-Path $SourceRoot 'source-revision.txt'
    if (Test-Path -LiteralPath $revisionPath) {
        return (Get-Content -LiteralPath $revisionPath -Raw).Trim().Substring(0, 7)
    }
    if (Get-Command git.exe -ErrorAction SilentlyContinue) {
        $revision = (& git.exe -C $SourceRoot rev-parse --short=7 HEAD 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and $revision) { return $revision.Trim() }
    }
    return 'unknown'
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedBootstrap([string]$SourceRoot) {
    $quote = { param([string]$Value) "'$($Value.Replace("'", "''"))'" }
    $bootstrapCommand = @(
        '& powershell.exe -NoProfile -ExecutionPolicy Bypass -File'
        "$(& $quote (Join-Path $SourceRoot 'bootstrap.ps1'))"
        "-WorkstationProfile $(& $quote $WorkstationProfile)"
        "-GitHubOwner $(& $quote $GitHubOwner)"
        "-DotfilesRepository $(& $quote $DotfilesRepository)"
        "-ExpectedUserProfile $(& $quote $env:USERPROFILE)"
        '-Elevated'
    )
    if ($SkipVault) { $bootstrapCommand += '-SkipVault' }
    if ($CoreReady) { $bootstrapCommand += '-CoreReady' }
    if ($ResumeAfterReboot) { $bootstrapCommand += '-ResumeAfterReboot' }
    $command = @(
        '$exitCode = 1'
        "try { $($bootstrapCommand -join ' '); `$exitCode = `$LASTEXITCODE }"
        'catch { Write-Error $_ }'
        "if (`$exitCode -ne 0) { Write-Host ''; Write-Host `"Bootstrap failed with exit code `$exitCode. Status log: $statusLogPath`" -ForegroundColor Red; Read-Host 'Press Enter to close this window' | Out-Null }"
        'exit $exitCode'
    )
    $wrapperPath = Join-Path $stateDirectory 'bootstrap-elevated.ps1'
    Set-Content -LiteralPath $wrapperPath -Value ($command -join "`r`n") -Encoding utf8
    $quotedWrapperPath = '"' + $wrapperPath + '"'
    Write-Host '[elevate] Approve the single UAC prompt for workstation and package configuration.'
    $process = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedWrapperPath
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
    Write-BootstrapStatus "phase=$Name state=started"
    try { & $Action }
    catch {
        Write-BootstrapStatus "phase=$Name state=failed type=$($_.Exception.GetType().FullName)"
        throw
    }
    $state = Get-State
    $state.CompletedPhases = @($state.CompletedPhases) + $Name | Select-Object -Unique
    Save-State $state
    Write-BootstrapStatus "phase=$Name state=completed"
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

function Initialize-ExecutionPolicy {
    $acceptablePolicies = @('RemoteSigned', 'Unrestricted', 'Bypass')
    $localMachinePolicy = (Get-ExecutionPolicy -Scope LocalMachine).ToString()
    if ($localMachinePolicy -notin $acceptablePolicies) {
        Write-Host "Setting LocalMachine execution policy from $localMachinePolicy to RemoteSigned."
        try {
            Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
        }
        catch {
            $persistedPolicy = (Get-ExecutionPolicy -Scope LocalMachine).ToString()
            if ($persistedPolicy -ne 'RemoteSigned') { throw }
            Write-Host 'LocalMachine is RemoteSigned; the current bootstrap process remains Bypass as intended.'
            Write-BootstrapStatus 'execution-policy persisted=RemoteSigned process-override=expected'
        }
        $persistedPolicy = (Get-ExecutionPolicy -Scope LocalMachine).ToString()
        if ($persistedPolicy -ne 'RemoteSigned') {
            throw "LocalMachine execution policy was not persisted as RemoteSigned (actual: $persistedPolicy)."
        }
    }

    $policyList = Get-ExecutionPolicy -List
    $enforcedPolicy = $policyList | Where-Object {
        $_.Scope -in @('MachinePolicy', 'UserPolicy') -and
        $_.ExecutionPolicy -notin @('Undefined', 'RemoteSigned', 'Unrestricted', 'Bypass')
    } | Select-Object -First 1
    if ($enforcedPolicy) {
        Write-Warning "Group Policy enforces $($enforcedPolicy.ExecutionPolicy) at $($enforcedPolicy.Scope); bootstrap did not override it."
    }
}

function Test-WinGetConfigurationV3 {
    param([string]$Path)
    & winget configure show --file $Path --disable-interactivity *> $null
    return $LASTEXITCODE -eq 0
}

function Invoke-WinGetConfiguration([string]$Path, [string]$PackageProfile) {
    # WinGet 1.29's legacy validator attempts to resolve native DSC v3 resources
    # as gallery modules and rejects Microsoft's own Microsoft.WinGet/Package.
    # The dscv3 processor performs schema/resource validation during configure.
    if (-not (Test-WinGetConfigurationV3 $Path)) {
        Write-Warning "WinGet Configuration v3 is disabled; reconciling curated packages directly for '$PackageProfile'."
        Invoke-WinGetPackageFallback $PackageProfile
        return
    }
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
        Write-Host 'Storing the vault password in Windows Credential Manager. Enter the master password when prompted.'
        pass-cli keychain enable --force
        if ($LASTEXITCODE -ne 0) { throw 'pass-cli keychain configuration failed.' }
        $keychainStatus = pass-cli keychain status 2>&1 | Out-String
        if ($keychainStatus -notmatch 'Password Stored:\s+Yes') {
            throw 'Keychain password storage is still unavailable after pass-cli keychain enable --force.'
        }
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
        gh auth login --hostname github.com --web --git-protocol ssh --skip-ssh-key
        if ($LASTEXITCODE -ne 0) { throw 'GitHub authentication failed.' }
    }
    gh auth setup-git
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI credential-helper configuration failed.' }
}

function Initialize-OpenSshAgent {
    $sshPath = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
    if (-not (Test-Path -LiteralPath $sshPath)) {
        Write-Host 'Installing the Windows OpenSSH Client capability...'
        & dism.exe /Online /Add-Capability /CapabilityName:OpenSSH.Client~~~~0.0.1.0 /NoRestart
        if ($LASTEXITCODE -ne 0) { throw "DISM failed to install OpenSSH Client (exit code $LASTEXITCODE)." }
    }
    if (-not (Test-Path -LiteralPath $sshPath)) { throw "OpenSSH Client is still unavailable: $sshPath" }

    $service = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if (-not $service) { throw 'The Windows ssh-agent service is unavailable after installing OpenSSH Client.' }
    Set-Service -Name ssh-agent -StartupType Automatic
    if ($service.Status -ne 'Running') {
        Write-Host 'Starting the Windows OpenSSH agent...'
        Start-Service -Name ssh-agent
        $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(15))
    }
}

function Restore-GitSshIdentity {
    Write-Host 'Unlocking pass-cli to restore the primary Git identity. Enter the vault master password if prompted.'
    Write-BootstrapStatus 'ssh-identity step=list-vault-identities state=started'
    $services = @(pass-cli --offline list --quiet)
    if ($LASTEXITCODE -ne 0) { throw 'Could not list SSH identities in pass-cli.' }
    Write-BootstrapStatus 'ssh-identity step=list-vault-identities state=completed'
    $gitIdentities = @($services | Where-Object { $_ -match '^ssh-key/id_ed25519_sk_rk_git-primary_' })
    if (-not $gitIdentities) {
        Write-Warning 'No primary Git YubiKey handle exists in pass-cli; GitHub login will continue without generating a replacement key.'
        return
    }

    $sshDirectory = Join-Path $HOME '.ssh'
    if (Test-Path -LiteralPath $sshDirectory) {
        $directory = Get-Item -LiteralPath $sshDirectory -Force
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Write-Warning "Preserving legacy linked SSH directory; automatic key restoration skipped: $sshDirectory"
            return
        }
    }
    else {
        New-Item -ItemType Directory -Path $sshDirectory | Out-Null
    }

    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $sshDirectory /inheritance:r /grant:r "*${userSid}:(OI)(CI)(F)" '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not restrict SSH directory permissions: $sshDirectory" }
    foreach ($serviceName in $gitIdentities) {
        $fileName = $serviceName.Substring('ssh-key/'.Length)
        $target = Join-Path $sshDirectory $fileName
        if (-not (Test-Path -LiteralPath $target)) {
            Write-Host "Restoring hardware-backed Git identity handle: $fileName"
            Write-BootstrapStatus 'ssh-identity step=read-encrypted-entry state=started'
            $encodedKey = (pass-cli --offline get $serviceName --field password --quiet --no-clipboard | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $encodedKey) { throw "Could not retrieve $serviceName from pass-cli." }
            try { [IO.File]::WriteAllBytes($target, [Convert]::FromBase64String($encodedKey)) }
            finally { $encodedKey = $null }
            Write-BootstrapStatus 'ssh-identity step=materialize-handle state=completed'
        }
        Write-BootstrapStatus 'ssh-identity step=restrict-acl state=started'
        & icacls.exe $target /inheritance:r /grant:r "*${userSid}:(F)" '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not restrict SSH identity permissions: $target" }
        Write-Host 'Loading the restored identity into Windows ssh-agent. Insert or touch the primary YubiKey if requested.'
        Write-BootstrapStatus 'ssh-identity step=ssh-add state=started'
        & (Join-Path $env:WINDIR 'System32\OpenSSH\ssh-add.exe') -S internal $target
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'Windows ssh-agent could not load the FIDO handle. The handle remains available for direct SSH use; physical resident-key recovery and agent compatibility will be validated separately.'
            Write-BootstrapStatus 'ssh-identity step=ssh-add state=unsupported'
            continue
        }
        Write-BootstrapStatus 'ssh-identity step=ssh-add state=completed'
    }
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

    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $node) { throw 'Node.js is unavailable after activating the NVM-managed LTS release.' }
    & $node.Source (Join-Path $sourceRoot 'scripts\restore-agent-skills.mjs') $lockPath
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

function Register-BootstrapResume {
    $arguments = @(
        '-NoProfile'
        '-ExecutionPolicy Bypass'
        "-File `"$(Join-Path $sourceRoot 'bootstrap.ps1')`""
        "-WorkstationProfile $WorkstationProfile"
        "-GitHubOwner $GitHubOwner"
        "-DotfilesRepository $DotfilesRepository"
    )
    if ($SkipVault) { $arguments += '-SkipVault' }
    $arguments += '-ResumeAfterReboot'
    $command = 'powershell.exe ' + ($arguments -join ' ')
    $runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    New-Item -Path $runOncePath -Force | Out-Null
    Set-ItemProperty -Path $runOncePath -Name WorkstationBootstrapResume -Value $command
    Write-BootstrapStatus 'wsl-prerequisites resume=registered'
}

function Initialize-WslPrerequisites {
    $restartRequired = $false
    foreach ($featureName in 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform') {
        $featureInfo = @(& dism.exe /online /get-featureinfo "/featurename:$featureName" /English)
        if ($LASTEXITCODE -ne 0) {
            throw "DISM could not query $featureName (exit code $LASTEXITCODE)."
        }
        $stateMatch = $featureInfo | Select-String '^\s*State\s*:\s*(.+)\s*$' | Select-Object -First 1
        if (-not $stateMatch) { throw "DISM did not report the state of $featureName." }
        $featureState = $stateMatch.Matches[0].Groups[1].Value.Trim()
        if ($featureState -eq 'Enabled') { continue }
        if ($featureState -eq 'Enable Pending') {
            $restartRequired = $true
            continue
        }

        Write-Host "Enabling required Windows feature: $featureName"
        & dism.exe /online /enable-feature "/featurename:$featureName" /all /norestart
        if ($LASTEXITCODE -notin @(0, 3010)) {
            throw "DISM could not enable $featureName (exit code $LASTEXITCODE)."
        }
        $restartRequired = $true
    }

    $componentServicingReboot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    if (Test-Path -LiteralPath $componentServicingReboot) {
        Write-Host 'Windows component servicing reports a pending restart.'
        $restartRequired = $true
    }

    if (-not $restartRequired) {
        $hypervisorPresent = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
        $firmwareVirtualization = @(Get-CimInstance Win32_Processor) |
            Where-Object VirtualizationFirmwareEnabled | Select-Object -First 1
        if (-not $hypervisorPresent -and -not $firmwareVirtualization) {
            throw 'WSL 2 hardware virtualization is disabled. Enable Intel VT-x/AMD-V in firmware (or nested virtualization in the VM host), then rerun bootstrap.'
        }
    }
    return $restartRequired
}

function Get-OrCreate-WslUser([string]$Distribution) {
    $currentUser = (& wsl.exe -d $Distribution -- sh -lc 'id -un').Trim()
    if ($LASTEXITCODE -ne 0) { throw "Could not determine the default user for $Distribution." }
    if ($currentUser -ne 'root') { return $currentUser }

    $uid1000User = (& wsl.exe -d $Distribution --user root -- sh -lc "getent passwd 1000 | cut -d: -f1").Trim()
    if ($LASTEXITCODE -eq 0 -and $uid1000User) { return $uid1000User }

    $suggestedUser = (Split-Path -Leaf $env:USERPROFILE).ToLowerInvariant() -replace '[^a-z0-9_-]', ''
    if ($suggestedUser -notmatch '^[a-z_][a-z0-9_-]*$') { $suggestedUser = 'developer' }
    $linuxUser = Read-Host "Ubuntu needs a non-root Linux account. Username [$suggestedUser]"
    if (-not $linuxUser) { $linuxUser = $suggestedUser }
    if ($linuxUser -notmatch '^[a-z_][a-z0-9_-]*$') {
        throw "Invalid Linux username '$linuxUser'. Use lowercase letters, digits, underscores, and hyphens."
    }

    & wsl.exe -d $Distribution --user root -- useradd --create-home --shell /bin/bash $linuxUser
    if ($LASTEXITCODE -ne 0) { throw "Could not create Linux user $linuxUser in $Distribution." }
    & wsl.exe -d $Distribution --user root -- usermod --append --groups sudo $linuxUser
    if ($LASTEXITCODE -ne 0) { throw "Could not grant sudo access to Linux user $linuxUser." }
    Write-Host "Set the sudo password for Linux user $linuxUser."
    & wsl.exe -d $Distribution --user root -- passwd $linuxUser
    if ($LASTEXITCODE -ne 0) { throw "Could not set the password for Linux user $linuxUser." }
    return $linuxUser
}

$sourceRoot = Get-SourceRoot
$sourceRevision = Get-SourceRevision $sourceRoot
Write-Host "[version] workstation-bootstrap @$sourceRevision"

if (-not (Test-IsAdministrator)) {
    if ($Elevated) { throw 'The elevated bootstrap did not receive an administrator token.' }
    Invoke-ElevatedBootstrap $sourceRoot
}
if ($ExpectedUserProfile -and -not [string]::Equals($env:USERPROFILE, $ExpectedUserProfile, [StringComparison]::OrdinalIgnoreCase)) {
    throw "UAC elevation changed the user profile from '$ExpectedUserProfile' to '$env:USERPROFILE'. Sign in with an administrator account instead of supplying another account at UAC."
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    if (-not $ResumeAfterReboot) {
        Invoke-Phase 'execution-policy' { Initialize-ExecutionPolicy }
        if (-not $CoreReady) {
            Invoke-Phase 'packages-core' { Invoke-WinGetConfiguration (Join-Path $sourceRoot 'config\winget\core.dsc.winget') 'core' }
        }
    }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sourceRoot 'bootstrap.ps1') -WorkstationProfile $WorkstationProfile -GitHubOwner $GitHubOwner -DotfilesRepository $DotfilesRepository -SkipVault:$SkipVault -CoreReady -ResumeAfterReboot:$ResumeAfterReboot -Elevated -ExpectedUserProfile $env:USERPROFILE
    if ($LASTEXITCODE -ne 0) { throw "PowerShell 7 bootstrap continuation failed with exit code $LASTEXITCODE." }
    return
}
if (-not $ResumeAfterReboot) {
    Invoke-Phase 'execution-policy' { Initialize-ExecutionPolicy }
    if ($WorkstationProfile -in @('developer', 'optional')) {
        Invoke-Phase 'packages-developer' { Invoke-WinGetConfiguration (Join-Path $sourceRoot 'config\winget\developer.dsc.winget') 'developer' }
        Invoke-Phase 'node-lts' { Initialize-NodeLts }
    }
    if ($WorkstationProfile -eq 'optional') {
        Invoke-Phase 'packages-optional' { Invoke-WinGetConfiguration (Join-Path $sourceRoot 'config\winget\optional.dsc.winget') 'optional' }
    }
    Invoke-Phase 'pass-cli' { Install-PassCli }
    if (-not $SkipVault) { Invoke-Phase 'vault' { Initialize-Vault } }
    Invoke-Phase 'openssh-agent' { Initialize-OpenSshAgent }
    if (-not $SkipVault) { Invoke-Phase 'ssh-identity' { Restore-GitSshIdentity } }
    Invoke-Phase 'github' { Initialize-GitHub }
    Invoke-Phase 'dotfiles-windows' { Sync-Dotfiles }
    if ($WorkstationProfile -in @('developer', 'optional')) {
        Invoke-Phase 'agent-skills' { Restore-AgentSkills }
    }
    Invoke-Phase 'windows-config' {
    Copy-Item (Join-Path $sourceRoot 'config\wslconfig') (Join-Path $HOME '.wslconfig') -Force
    # Ordinary Cascadia Code ships with Windows/Terminal but does not contain
    # the Nerd Font glyphs requested by the managed Terminal settings.
    $fontInstalled = Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\Windows\Fonts\*", "$env:WINDIR\Fonts\*" -Include 'CaskaydiaCoveNerdFont*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $fontInstalled -and (Get-Command oh-my-posh -ErrorAction SilentlyContinue)) {
        oh-my-posh font install CascadiaCode
        if ($LASTEXITCODE -ne 0) { throw 'Prompt font installation failed.' }
    }
    Get-Content (Join-Path $sourceRoot 'config\vscode-extensions.txt') | ForEach-Object {
        code --install-extension $_ --force
        if ($LASTEXITCODE -ne 0) { throw "VS Code extension installation failed: $_" }
    }
    }
}
    if ($WorkstationProfile -in @('developer', 'optional')) {
        $script:wslRestartRequired = $false
        Invoke-Phase 'wsl-prerequisites' {
            $script:wslRestartRequired = Initialize-WslPrerequisites
        }
        if ($script:wslRestartRequired) {
            Write-Host 'Windows must restart before Ubuntu can be installed.' -ForegroundColor Yellow
            $restartNow = Read-Host 'Restart now and resume bootstrap after sign-in? [y/N]'
            if ($restartNow -match '^(?i)y(?:es)?$') {
                Register-BootstrapResume
                Write-Host 'Restarting in 15 seconds. Bootstrap will relaunch after you sign in.'
                & shutdown.exe /r /t 15 /c 'Restarting to finish WSL 2 prerequisites'
                if ($LASTEXITCODE -ne 0) { throw 'Windows restart scheduling failed.' }
            }
            else {
                Write-Host 'Restart Windows, then rerun the bootstrap command to continue.' -ForegroundColor Yellow
            }
            return
        }
        Invoke-Phase 'wsl-linux' {
        $ubuntuDistribution = @(wsl.exe --list --quiet) | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^Ubuntu(?:-|$)' } | Select-Object -First 1
        $ubuntuInstalled = [bool]$ubuntuDistribution
        if (-not $ubuntuInstalled) {
            wsl --install -d Ubuntu --no-launch
            if ($LASTEXITCODE -ne 0) { throw 'Ubuntu installation failed or requires a reboot; rerun bootstrap afterward.' }
            $ubuntuDistribution = 'Ubuntu'
        }
        $linuxUser = Get-OrCreate-WslUser $ubuntuDistribution
        $payload = if ($WorkstationProfile -eq 'core') { 'profile' } else { 'developer' }
        wsl -d $ubuntuDistribution --user $linuxUser -- sh -lc "curl -fsLS https://raw.githubusercontent.com/$GitHubOwner/$repository/main/bootstrap.sh | sh -s -- $payload $GitHubOwner $DotfilesRepository"
        if ($LASTEXITCODE -ne 0) { throw "Linux bootstrap failed in WSL distribution $ubuntuDistribution." }
    }
}

Write-Host 'Workstation bootstrap is complete. Existing SSH keys and links were not changed.'
