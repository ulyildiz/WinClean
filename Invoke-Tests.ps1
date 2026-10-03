<#
.SYNOPSIS
    Runs the WinClean Pester 5 test suite.

.DESCRIPTION
    Windows ships with Pester 3.4, which cannot run these tests. This runner uses a
    Pester 5.x already on PSModulePath if there is one; otherwise it loads (or, on first
    run, saves) Pester into .tools\Modules inside the repo, so nothing is installed
    system-wide and no writes go to Documents (works with Controlled Folder Access on).

.PARAMETER Output
    Pester output verbosity: None, Normal, Detailed, Diagnostic. Default: Detailed

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Output = 'Detailed'
)

$ErrorActionPreference = 'Stop'
$minimum = [version]'5.5.0'
$toolsDir = Join-Path $PSScriptRoot '.tools\Modules'

function Find-Pester {
    $local = @(Get-ChildItem -Path (Join-Path $toolsDir 'Pester') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -as [version] -and [version]$_.Name -ge $minimum -and [version]$_.Name -lt [version]'6.0' } |
        Sort-Object { [version]$_.Name } -Descending)
    if ($local) { return (Join-Path $local[0].FullName 'Pester.psd1') }

    $installed = Get-Module -ListAvailable -Name Pester |
        Where-Object { $_.Version -ge $minimum -and $_.Version.Major -eq 5 } |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($installed) { return $installed.Path }
    return $null
}

$pester = Find-Pester
if (-not $pester) {
    Write-Host "Pester $minimum+ not found. Saving Pester 5.x to $toolsDir ..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Save-Module -Name Pester -MinimumVersion $minimum -MaximumVersion '5.99.99' -Path $toolsDir -Repository PSGallery -Force
    $pester = Find-Pester
    if (-not $pester) { throw 'Pester 5 could not be saved. Check your internet connection / PSGallery access.' }
}

Remove-Module Pester -ErrorAction SilentlyContinue
Import-Module $pester -Force
Write-Host ("Using Pester {0}" -f (Get-Module Pester).Version) -ForegroundColor Cyan

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $PSScriptRoot 'WinClean\Tests'
$config.Run.Exit = $true
$config.Output.Verbosity = $Output
Invoke-Pester -Configuration $config
