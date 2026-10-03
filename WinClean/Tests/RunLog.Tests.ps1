#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinClean.psd1') -Force
    $script:manifest = (Resolve-Path (Join-Path $PSScriptRoot '..\WinClean.psd1')).ProviderPath

    function New-RunResult([long]$Bytes = 1000, [int]$Files = 3, [switch]$DryRun, [datetime]$Start = (Get-Date)) {
        [pscustomobject]@{
            StartTime = $Start; EndTime = $Start.AddSeconds(12.34); DryRun = [bool]$DryRun; IsAdmin = $false
            BytesFreed = $Bytes; FilesRemoved = $Files; Quarantine = $false; BytesQuarantined = 0; FilesQuarantined = 0
            Targets = @([pscustomobject]@{ Status = 'Cleaned' }, [pscustomobject]@{ Status = 'Skipped' })
        }
    }

    function Write-Log($Result, [string]$Path, [int]$Max = 500) {
        InModuleScope WinClean -Parameters @{ R = $Result; P = $Path; M = $Max } { Write-WinCleanRunLog -Result $R -Path $P -MaxEntries $M -WarningAction SilentlyContinue }
    }

    # always an array, even with a single entry: the leading comma stops PowerShell from
    # unrolling it (a lone PSCustomObject has no .Count in Windows PowerShell 5.1)
    function Read-Log([string]$Path) { , @((Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)) }
}

AfterAll {
    Remove-Module WinClean -Force -ErrorAction SilentlyContinue
}

Describe 'Write-WinCleanRunLog' {
    BeforeEach {
        $script:log = Join-Path $TestDrive ([guid]::NewGuid().Guid + '\WinClean\run-log.json')
    }

    It 'creates the folder and a JSON array with the required fields' {
        $start = [datetime]'2026-10-03T03:00:00'
        Write-Log (New-RunResult -Bytes 2048 -Files 7 -Start $start) $log
        Get-Content -LiteralPath $log -Raw | Should -Match '^\s*\['
        $e = (Read-Log $log)[0]
        $e.timestamp    | Should -Be $start.ToString('o')
        $e.bytesFreed   | Should -Be 2048
        $e.filesRemoved | Should -Be 7
        $e.dryRun       | Should -BeFalse
    }

    It 'records quarantine figures, skipped targets, duration and module version' {
        Write-Log (New-RunResult) $log
        $e = (Read-Log $log)[0]
        $e.skippedTargets  | Should -Be 1
        $e.durationSeconds | Should -Be 12.3
        $e.moduleVersion   | Should -Be (Test-ModuleManifest $manifest).Version.ToString()
        $e.PSObject.Properties.Name | Should -Contain 'bytesQuarantined'
    }

    It 'appends to existing entries in order' {
        Write-Log (New-RunResult -Bytes 1) $log
        Write-Log (New-RunResult -Bytes 2 -DryRun) $log
        $entries = Read-Log $log
        $entries.Count | Should -Be 2
        $entries.bytesFreed | Should -Be @(1, 2)
        $entries[1].dryRun | Should -BeTrue
    }

    It 'keeps only the newest -MaxEntries runs' {
        1..5 | ForEach-Object { Write-Log (New-RunResult -Bytes $_) $log 3 }
        (Read-Log $log).bytesFreed | Should -Be @(3, 4, 5)
    }

    It 'sets an unreadable log aside instead of overwriting it (<Name>)' -ForEach @(
        @{ Name = 'not JSON';      Content = 'garbage {' }
        @{ Name = 'not an array';  Content = '{ "timestamp": "x" }' }
    ) {
        New-Item -ItemType Directory -Path (Split-Path $log -Parent) -Force | Out-Null
        Set-Content -LiteralPath $log -Value $Content -NoNewline
        Write-Log (New-RunResult) $log
        (Read-Log $log).Count | Should -Be 1
        $aside = @(Get-ChildItem -LiteralPath (Split-Path $log -Parent) -Filter 'run-log.corrupt-*.json')
        $aside.Count | Should -Be 1
        Get-Content -LiteralPath $aside[0].FullName -Raw | Should -Be $Content
    }

    It 'leaves no temp file behind' {
        Write-Log (New-RunResult) $log
        Test-Path -LiteralPath "$log.tmp" | Should -BeFalse
    }

    It 'does not lose entries when two processes write at the same time' {
        $jobs = 1..2 | ForEach-Object {
            Start-Job -ArgumentList $manifest, $log -ScriptBlock {
                param($Manifest, $Log)
                Import-Module $Manifest -Force
                & (Get-Module WinClean) {
                    param($Log)
                    $start = Get-Date
                    $r = [pscustomobject]@{ StartTime = $start; EndTime = $start; DryRun = $true; IsAdmin = $false; BytesFreed = 1; FilesRemoved = 1
                                            Quarantine = $false; BytesQuarantined = 0; FilesQuarantined = 0; Targets = @() }
                    1..15 | ForEach-Object { Write-WinCleanRunLog -Result $r -Path $Log }
                } $Log
            }
        }
        $jobs | Wait-Job -Timeout 120 | Out-Null
        $errors = $jobs | Receive-Job -ErrorVariable jobErrors 2>&1
        $jobs | Remove-Job -Force
        $jobErrors | Should -BeNullOrEmpty
        (Read-Log $log).Count | Should -Be 30
    }
}

Describe 'Invoke-WinClean run logging' {
    BeforeAll {
        Mock -ModuleName WinClean Write-Host { }
        $script:cfg = Join-Path $TestDrive 'empty.json'
        Set-Content -LiteralPath $cfg -Value '{ "extendDefaults": false, "targets": [] }'
    }
    BeforeEach {
        $script:log = Join-Path $TestDrive ([guid]::NewGuid().Guid + '\run-log.json')
        Mock -ModuleName WinClean Get-RunLogPath { $log }
    }

    It 'logs every run, dry runs included' {
        $run = Invoke-WinClean -DryRun -ConfigPath $cfg -SkipBrowsers -SkipUpdateCache -SkipRam -PassThru
        $e = (Read-Log $log)[0]
        $e.dryRun       | Should -BeTrue
        $e.bytesFreed   | Should -Be $run.BytesFreed
        $e.filesRemoved | Should -Be $run.FilesRemoved
    }

    It 'writes nothing with -NoLog' {
        Invoke-WinClean -DryRun -NoLog -ConfigPath $cfg -SkipBrowsers -SkipUpdateCache -SkipRam
        Test-Path -LiteralPath $log | Should -BeFalse
    }

    It 'never lets a logging failure break the cleanup' {
        Mock -ModuleName WinClean Write-WinCleanRunLog { throw 'disk full' }
        $out = Invoke-WinClean -DryRun -ConfigPath $cfg -SkipBrowsers -SkipUpdateCache -SkipRam -PassThru 3>&1
        $warning = $out | Where-Object { $_ -is [Management.Automation.WarningRecord] }
        $result  = $out | Where-Object { $_ -isnot [Management.Automation.WarningRecord] }
        $warning.Message | Should -Match 'run log could not be written: disk full'
        $result.DryRun | Should -BeTrue
    }

    It 'writes to %LOCALAPPDATA%\WinClean\run-log.json by default' {
        InModuleScope WinClean { Get-RunLogPath } | Should -Not -BeNullOrEmpty
        Remove-Module WinClean -Force; Import-Module $manifest -Force   # drop this file's mock
        InModuleScope WinClean { Get-RunLogPath } | Should -Be (Join-Path $env:LOCALAPPDATA 'WinClean\run-log.json')
    }
}
