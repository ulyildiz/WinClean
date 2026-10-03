function Invoke-WinClean {
    <#
    .SYNOPSIS
        Safe Windows cache / temp cleaner + RAM cache (standby list) flush.

    .DESCRIPTION
        Removes only disposable data: temp folders, internet/app caches, browser
        caches, shader caches, error-report queues and the Windows Update download
        cache. Then flushes the RAM cache (working sets, modified list, standby list).

        It NEVER touches: Documents, Downloads, Desktop, Recycle Bin, browser
        cookies / passwords / history / bookmarks / extensions, System Restore
        points, Prefetch, WinSxS, event logs, or the registry.
        Junctions and symlinks are skipped, never followed. Every target folder
        must pass Test-PathSafety before anything inside it is touched.

        Without administrator rights a real run skips the targets that need
        elevation (Windows temp, error reports, Update cache, RAM flush) instead
        of failing on them. -DryRun works without elevation.

    .PARAMETER DryRun
        Show what would be removed and how much space it would free. Deletes nothing.

    .PARAMETER MinAgeHours
        Files in the Temp folders newer than this many hours are left alone, so
        running installers / apps are not disturbed. Default: 1

    .PARAMETER SkipBrowsers
        Do not clean browser caches.

    .PARAMETER SkipUpdateCache
        Do not clean the Windows Update download cache.

    .PARAMETER SkipRam
        Do not flush the RAM cache.

    .PARAMETER PassThru
        Return a WinClean.RunResult object with per-target details.

    .EXAMPLE
        Invoke-WinClean -DryRun

    .EXAMPLE
        Invoke-WinClean -SkipBrowsers -MinAgeHours 6

    .EXAMPLE
        $run = Invoke-WinClean -DryRun -SkipRam -PassThru
        $run.Targets | Sort-Object Bytes -Descending | Format-Table Label, Bytes, Files
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch]$DryRun,

        [ValidateRange(0, 8760)]
        [int]$MinAgeHours = 1,

        [switch]$SkipBrowsers,
        [switch]$SkipUpdateCache,
        [switch]$SkipRam,
        [switch]$PassThru
    )

    $startTime = Get-Date
    $isAdmin = Test-IsAdministrator
    $limited = (-not $DryRun) -and (-not $isAdmin)
    $results = New-Object 'System.Collections.Generic.List[object]'
    $ram = $null

    Write-Host ''
    if ($DryRun) { Write-Host '=== Windows cleanup (DRY RUN - nothing will be deleted) ===' -ForegroundColor Yellow }
    else         { Write-Host '=== Windows cleanup ===' -ForegroundColor Green }

    if ($limited) {
        Write-Warning 'Not running as administrator: Windows temp, error reports, the Update cache and the RAM flush will be skipped. Run from an elevated PowerShell for a full clean.'
    }

    Write-Host ''
    Write-Host 'Temp files and caches' -ForegroundColor Cyan

    $targets = @(
        @{ Label = 'User temp';                Path = $env:TEMP;                                                          Age = $MinAgeHours; Admin = $false },
        @{ Label = 'Windows temp';             Path = (Join-Path $env:SystemRoot 'Temp');                                 Age = $MinAgeHours; Admin = $true },
        @{ Label = 'Internet cache';           Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache');        Age = 0;            Admin = $false },
        @{ Label = 'DirectX shader cache';     Path = (Join-Path $env:LOCALAPPDATA 'D3DSCache');                          Age = 0;            Admin = $false },
        @{ Label = 'App crash dumps';          Path = (Join-Path $env:LOCALAPPDATA 'CrashDumps');                         Age = 0;            Admin = $false },
        @{ Label = 'Error reporting queue';    Path = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue');   Age = 0;            Admin = $true },
        @{ Label = 'Error reporting archive';  Path = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'); Age = 0;            Admin = $true }
    )
    foreach ($t in $targets) {
        if ($t.Admin -and $limited) {
            $r = New-TargetResult -Label $t.Label -Path $t.Path -Status 'Skipped' -Reason 'requires administrator'
        }
        else {
            $r = Clear-FolderContents -Path $t.Path -Label $t.Label -AgeHours ([int]$t.Age) -DryRun:$DryRun
        }
        $results.Add($r)
        Write-TargetResult -Result $r
    }

    if (-not $SkipBrowsers) {
        Write-Host ''
        Write-Host 'Browser caches (close browsers first for best results)' -ForegroundColor Cyan
        foreach ($b in (Get-BrowserCachePaths)) {
            $r = Clear-FolderContents -Path $b.Path -Label $b.Label -DryRun:$DryRun
            $results.Add($r)
            Write-TargetResult -Result $r
        }
    }

    if (-not $SkipUpdateCache) {
        Write-Host ''
        Write-Host 'Windows Update cache' -ForegroundColor Cyan
        if ($limited) {
            $r = New-TargetResult -Label 'Windows Update downloads' -Path (Join-Path $env:SystemRoot 'SoftwareDistribution\Download') -Status 'Skipped' -Reason 'requires administrator'
        }
        else {
            $r = Clear-UpdateCache -DryRun:$DryRun
        }
        $results.Add($r)
        Write-TargetResult -Result $r
    }

    if (-not $DryRun) {
        & ipconfig.exe /flushdns | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host ''
            Write-Host 'DNS cache flushed.'
        }
    }

    if (-not $SkipRam) {
        Write-Host ''
        Write-Host 'RAM cache' -ForegroundColor Cyan
        if ($limited) {
            Write-Host '  skipped (requires administrator)' -ForegroundColor Yellow
        }
        else {
            $ram = Clear-RamCache -DryRun:$DryRun
            Write-Host ('  Before : free {0}, standby cache {1}' -f (Format-Size $ram.Before.Free), (Format-Size $ram.Before.Standby))
            if ($DryRun) {
                Write-Host '  (dry run) not flushed.'
            }
            else {
                foreach ($f in $ram.Failures) { Write-Warning "  $f" }
                Write-Host ('  After  : free {0}, standby cache {1}' -f (Format-Size $ram.After.Free), (Format-Size $ram.After.Standby))
            }
        }
    }

    $totalBytes = 0L
    $totalFiles = 0
    foreach ($r in $results) { $totalBytes += $r.Bytes; $totalFiles += $r.Files }

    Write-Host ''
    $verb = 'Freed'
    if ($DryRun) { $verb = 'Would free' }
    Write-Host ('{0}: {1} in {2} files' -f $verb, (Format-Size $totalBytes), $totalFiles) -ForegroundColor Green
    Write-Host ''

    if ($PassThru) {
        [pscustomobject]@{
            PSTypeName   = 'WinClean.RunResult'
            StartTime    = $startTime
            EndTime      = Get-Date
            DryRun       = [bool]$DryRun
            IsAdmin      = $isAdmin
            BytesFreed   = $totalBytes
            FilesRemoved = $totalFiles
            Targets      = $results.ToArray()
            Ram          = $ram
        }
    }
}
