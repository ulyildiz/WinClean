<#
.SYNOPSIS
    Backward-compatible launcher for the WinClean module.

.DESCRIPTION
    Keeps the original Clean-Windows.ps1 experience (self-elevation, pause at the
    end) while all logic lives in the WinClean module. See:
        Get-Help Invoke-WinClean -Full

.PARAMETER DryRun            Show what would be removed. Deletes nothing.
.PARAMETER MinAgeHours       Keep temp files newer than this many hours. Default: 1
.PARAMETER SkipBrowsers      Do not clean browser caches.
.PARAMETER SkipUpdateCache   Do not clean the Windows Update download cache.
.PARAMETER SkipRam           Do not flush the RAM cache.
.PARAMETER ConfigPath        User config file that extends / overrides the default targets.
.PARAMETER IncludeDev        Also clean developer caches and (with -DevRoot) stale build output.
.PARAMETER DevRoot           Folder(s) to scan for projects.
.PARAMETER DevAgeHours       Keep developer data written within this many hours. Default: 168
.PARAMETER GitGc             Run 'git gc' in repositories under -DevRoot.
.PARAMETER ConfirmDockerPrune  Remove dangling Docker images (never --all).
.PARAMETER NoPause           Do not wait for Enter at the end.

.EXAMPLE
    .\Clean-Windows.ps1 -DryRun
    .\Clean-Windows.ps1
    .\Clean-Windows.ps1 -SkipBrowsers -MinAgeHours 6
    .\Clean-Windows.ps1 -DryRun -ConfigPath .\my-targets.json
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [int]$MinAgeHours = 1,
    [switch]$SkipBrowsers,
    [switch]$SkipUpdateCache,
    [switch]$SkipRam,
    [string]$ConfigPath,
    [switch]$IncludeDev,
    [string[]]$DevRoot,
    [int]$DevAgeHours = 168,
    [switch]$GitGc,
    [switch]$ConfirmDockerPrune,
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'

# the elevated relaunch starts in System32, so relative paths must be made absolute first
if ($ConfigPath) {
    $resolved = Resolve-Path -LiteralPath $ConfigPath -ErrorAction SilentlyContinue
    if (-not $resolved) { Write-Error "Config file not found: $ConfigPath"; exit 1 }
    $ConfigPath = $resolved.ProviderPath
    $PSBoundParameters['ConfigPath'] = $ConfigPath
}
if ($DevRoot) {
    $DevRoot = @($DevRoot | ForEach-Object { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($_) })
    $PSBoundParameters['DevRoot'] = $DevRoot
}

# ---------------------------------------------------------------- elevation
function ConvertTo-PSLiteral($Value) {
    if ($Value -is [array]) { return (@($Value | ForEach-Object { ConvertTo-PSLiteral $_ }) -join ',') }
    if ($Value -is [int])   { return [string]$Value }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Administrator rights are needed (Windows temp, update cache, RAM flush). Requesting elevation...'
    # rebuild the call as a PowerShell command and pass it encoded: no command-line quoting
    # pitfalls for paths with spaces, quotes or arrays such as -DevRoot a, b
    $command = '& ' + (ConvertTo-PSLiteral $PSCommandPath)
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $command += " -$k" } }
        else { $command += " -$k " + (ConvertTo-PSLiteral $v) }
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    exit
}

# --------------------------------------------------------------------- main
Import-Module (Join-Path $PSScriptRoot 'WinClean\WinClean.psd1') -Force

$cleanParams = @{}
foreach ($k in $PSBoundParameters.Keys) {
    if ($k -ne 'NoPause') { $cleanParams[$k] = $PSBoundParameters[$k] }
}
Invoke-WinClean @cleanParams

if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
