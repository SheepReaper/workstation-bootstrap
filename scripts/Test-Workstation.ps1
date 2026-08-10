[CmdletBinding()]
param([string]$DotfilesSource = (Join-Path $HOME '.local\share\chezmoi'))

$ErrorActionPreference = 'Stop'
$failures = [Collections.Generic.List[string]]::new()

foreach ($command in 'git', 'gh', 'chezmoi', 'rclone', 'pass-cli', 'npiperelay.exe') {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { $failures.Add("missing command: $command") }
}

if (Test-Path $DotfilesSource) {
    $suspicious = Get-ChildItem $DotfilesSource -Recurse -File | Where-Object {
        $_.Name -match '^(id_rsa|id_ed25519|known_hosts)$' -or $_.Extension -in '.pem', '.key'
    }
    if ($suspicious) { $failures.Add('dotfiles source contains forbidden credential material') }
}

$profileSamples = 1..5 | ForEach-Object {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    pwsh -NoLogo -Command exit
    $watch.Stop()
    $watch.Elapsed.TotalMilliseconds
}
$warm = ($profileSamples | Select-Object -Skip 1 | Measure-Object -Average).Average
if ($warm -gt 750) { $failures.Add("PowerShell warm startup is $([math]::Round($warm))ms (limit: 750ms)") }

if ($failures.Count) { throw ($failures -join [Environment]::NewLine) }
Write-Host "Workstation validation passed; PowerShell warm average: $([math]::Round($warm))ms"
