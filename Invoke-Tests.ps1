<#
.SYNOPSIS
    Runs the WinClean Pester 5 test suite.

.DESCRIPTION
    Windows ships with Pester 3.4, which cannot run these tests. This runner uses a
    Pester 5.x already on PSModulePath if there is one; otherwise it loads (or, on first
    run, saves) Pester into .tools\Modules inside the repo, so nothing is installed
    system-wide and no writes go to Documents (works with Controlled Folder Access on).

    If TEMP contains 8.3 short names (C:\Users\RUNNER~1\..., common on CI runners and
    for long user names), it is expanded to its long form for the test run: Windows
    PowerShell 5.1's New-Item -Force cannot create nested folders below such paths.

.PARAMETER Output
    Pester output verbosity: None, Normal, Detailed, Diagnostic. Default: Detailed

.PARAMETER TestResultPath
    Also write NUnit XML results to this file (used by CI).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1

.EXAMPLE
    .\Invoke-Tests.ps1 -Output Normal -TestResultPath testResults.xml
#>
[CmdletBinding()]
param(
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Output = 'Detailed',

    [string]$TestResultPath
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
    [void][IO.Directory]::CreateDirectory($toolsDir)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # Windows PowerShell's PowerShellGet needs the NuGet provider and would otherwise stop to ask for it
    if ($PSVersionTable.PSEdition -eq 'Desktop' -and -not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue |
            Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    Save-Module -Name Pester -MinimumVersion $minimum -MaximumVersion '5.99.99' -Path $toolsDir -Repository PSGallery -Force
    $pester = Find-Pester
    if (-not $pester) { throw 'Pester 5 could not be saved. Check your internet connection / PSGallery access.' }
}

# expand 8.3 short names in TEMP / TMP for this process (and the jobs it starts)
if ("$env:TEMP$env:TMP" -match '~\d') {
    $winClean = Import-Module (Join-Path $PSScriptRoot 'WinClean\WinClean.psd1') -Force -PassThru
    foreach ($name in 'TEMP', 'TMP') {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value -match '~\d') {
            $long = & $winClean { param($p) Resolve-LongPathName -Path $p } $value
            if ($long) {
                [Environment]::SetEnvironmentVariable($name, $long)
                Write-Host "Using long-form $name for the tests: $long" -ForegroundColor DarkGray
            }
        }
    }
    Remove-Module WinClean -Force
}

Remove-Module Pester -ErrorAction SilentlyContinue
Import-Module $pester -Force
Write-Host ("Using Pester {0} on PowerShell {1} ({2})" -f (Get-Module Pester).Version, $PSVersionTable.PSVersion, $PSVersionTable.PSEdition) -ForegroundColor Cyan

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $PSScriptRoot 'WinClean\Tests'
$config.Run.Exit = $true
$config.Output.Verbosity = $Output
if ($TestResultPath) {
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestResultPath)
}
Invoke-Pester -Configuration $config
