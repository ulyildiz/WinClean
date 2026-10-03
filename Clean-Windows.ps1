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
.PARAMETER NoPause           Do not wait for Enter at the end.

.EXAMPLE
    .\Clean-Windows.ps1 -DryRun
    .\Clean-Windows.ps1
    .\Clean-Windows.ps1 -SkipBrowsers -MinAgeHours 6
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [int]$MinAgeHours = 1,
    [switch]$SkipBrowsers,
    [switch]$SkipUpdateCache,
    [switch]$SkipRam,
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- elevation
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Administrator rights are needed (Windows temp, update cache, RAM flush). Requesting elevation...'
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $relaunch += "-$k" } }
        else { $relaunch += "-$k"; $relaunch += "$v" }
    }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $relaunch
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
