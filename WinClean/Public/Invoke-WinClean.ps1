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

        The temp / cache folders are listed in Config\winclean.config.json. Each
        entry is an explicit allowlist item - there is no wildcard matching:
            label          display name, unique per file (required)
            path           folder; %VAR%, $env:VAR and ${env:VAR} are expanded (required)
            category       lowercase tag, e.g. temp, cache, crash (required)
            ageHours       keep files newer than this; null = use -MinAgeHours
            requiresAdmin  skip on non-elevated real runs (default false)
            enabled        false = ignore the entry (default true)
        An invalid entry or an undefined variable skips that target; an unreadable
        config file stops the run before anything is deleted.

        Without administrator rights a real run skips the targets that need
        elevation (Windows temp, error reports, Update cache, RAM flush) instead
        of failing on them. -DryRun works without elevation.

    .PARAMETER ConfigPath
        A user config file in the same format. By default it extends the built-in
        targets: an entry with the same label as a built-in one replaces it (e.g. to
        change ageHours or set "enabled": false) and new labels are added. Put
        "extendDefaults": false at the top level to use only the user file's targets.

    .PARAMETER IncludeDev
        Also clean developer data: npm (between two 'npm cache verify' runs), pip,
        cargo registry downloads, NuGet HTTP cache and vcpkg archive caches; VS Code
        caches and workspace storage of workspaces that no longer exist. Tool cache
        overrides (npm_config_cache, PIP_CACHE_DIR, CARGO_HOME, NUGET_HTTP_CACHE_PATH,
        VCPKG_DEFAULT_BINARY_CACHE, VCPKG_ROOT) are honoured.
        With -DevRoot this also includes build output folders
        (bin/obj next to a .NET project, CMake build/CMakeFiles, Cargo target, git-ignored
        npm build), each only when its contents prove it is tool output, it holds no
        git-tracked files, and nothing in it was written within -DevAgeHours.

    .PARAMETER DevRoot
        Folder(s) to search for projects, e.g. $env:USERPROFILE\source\repos. Projects
        under Documents / Desktop / Downloads are still refused by Test-PathSafety.

    .PARAMETER DevAgeHours
        Developer data written within this many hours is kept. Default: 168 (7 days)

    .PARAMETER GitGc
        Run a plain 'git gc' (no --aggressive, no --prune=now) in every repository
        under -DevRoot. Repositories with a git operation in progress are skipped.

    .PARAMETER ConfirmDockerPrune
        Remove dangling Docker images ('docker image prune --force', never --all).
        Without it, -IncludeDev only reports them. Nothing runs unless the Docker
        daemon responds within 15 seconds. -IncludeDev also reports the memory held
        by the WSL 2 VM and how to reclaim it; WinClean never runs 'wsl --shutdown'.

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
        Invoke-WinClean -DryRun -ConfigPath .\my-targets.json

        Start from Config\my-targets.example.json. A minimal my-targets.json:
        {
          "targets": [
            { "label": "User temp", "path": "%TEMP%", "ageHours": 48, "category": "temp" },
            { "label": "Gradle build cache", "path": "%USERPROFILE%\\.gradle\\caches\\build-cache-1", "ageHours": 168, "category": "cache" }
          ]
        }

    .EXAMPLE
        Invoke-WinClean -DryRun -IncludeDev -DevRoot "$env:USERPROFILE\source\repos"

    .EXAMPLE
        Invoke-WinClean -IncludeDev -DevRoot D:\src -GitGc -ConfirmDockerPrune

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

        [ValidateNotNullOrEmpty()]
        [string]$ConfigPath,

        [switch]$IncludeDev,

        [ValidateNotNullOrEmpty()]
        [string[]]$DevRoot,

        [ValidateRange(0, 87600)]
        [int]$DevAgeHours = 168,

        [switch]$GitGc,
        [switch]$ConfirmDockerPrune,

        [switch]$PassThru
    )

    # load before printing anything: a broken config stops the run before any deletion
    $config = Get-WinCleanConfig -ConfigPath $ConfigPath

    $startTime = Get-Date
    $isAdmin = Test-IsAdministrator
    $limited = (-not $DryRun) -and (-not $isAdmin)
    $results = New-Object 'System.Collections.Generic.List[object]'
    $ram = $null
    $wsl = $null

    Write-Host ''
    if ($DryRun) { Write-Host '=== Windows cleanup (DRY RUN - nothing will be deleted) ===' -ForegroundColor Yellow }
    else         { Write-Host '=== Windows cleanup ===' -ForegroundColor Green }

    if ($limited) {
        Write-Warning 'Not running as administrator: Windows temp, error reports, the Update cache and the RAM flush will be skipped. Run from an elevated PowerShell for a full clean.'
    }

    Write-Host ''
    Write-Host 'Temp files and caches' -ForegroundColor Cyan

    foreach ($t in $config.Targets) {
        if (-not $t.Enabled) { continue }
        if ($t.Error) {
            $r = New-TargetResult -Label $t.Label -Path $t.Path -Status 'Skipped' -Reason $t.Error -Category $t.Category
        }
        elseif ($t.RequiresAdmin -and $limited) {
            $r = New-TargetResult -Label $t.Label -Path $t.ExpandedPath -Status 'Skipped' -Reason 'requires administrator' -Category $t.Category
        }
        else {
            # ageHours null in the config = follow -MinAgeHours
            $age = $MinAgeHours
            if ($null -ne $t.AgeHours) { $age = $t.AgeHours }
            $r = Clear-FolderContents -Path $t.ExpandedPath -Label $t.Label -AgeHours $age -Category $t.Category -DryRun:$DryRun
        }
        $results.Add($r)
        Write-TargetResult -Result $r
    }

    if (-not $SkipBrowsers) {
        Write-Host ''
        Write-Host 'Browser caches (close browsers first for best results)' -ForegroundColor Cyan
        foreach ($b in (Get-BrowserCachePaths)) {
            $r = Clear-FolderContents -Path $b.Path -Label $b.Label -Category 'browser' -DryRun:$DryRun
            $results.Add($r)
            Write-TargetResult -Result $r
        }
    }

    if (-not $SkipUpdateCache) {
        Write-Host ''
        Write-Host 'Windows Update cache' -ForegroundColor Cyan
        if ($limited) {
            $r = New-TargetResult -Label 'Windows Update downloads' -Path (Join-Path $env:SystemRoot 'SoftwareDistribution\Download') -Status 'Skipped' -Reason 'requires administrator' -Category 'update'
        }
        else {
            $r = Clear-UpdateCache -DryRun:$DryRun
        }
        $results.Add($r)
        Write-TargetResult -Result $r
    }

    if ($IncludeDev) {
        Write-Host ''
        Write-Host 'Developer caches (close editors / package managers first for best results)' -ForegroundColor Cyan
        foreach ($r in (Invoke-DevCacheCleanup -Target @(Get-DevCacheTargets) -AgeHours $DevAgeHours -DryRun:$DryRun)) {
            $results.Add($r)
            Write-TargetResult -Result $r
        }

        Write-Host ''
        Write-Host 'Build artifacts' -ForegroundColor Cyan
        if ($DevRoot) {
            foreach ($r in (Invoke-DevArtifactCleanup -Root $DevRoot -AgeHours $DevAgeHours -DryRun:$DryRun)) {
                $results.Add($r)
                Write-TargetResult -Result $r
            }
        }
        else {
            Write-Host '  skipped (pass -DevRoot <projects folder> to scan for build output)' -ForegroundColor Yellow
        }
    }

    if ($GitGc) {
        Write-Host ''
        Write-Host 'Git maintenance' -ForegroundColor Cyan
        if ($DevRoot) {
            foreach ($r in (Invoke-GitMaintenance -Root $DevRoot -DryRun:$DryRun)) {
                $results.Add($r)
                Write-TargetResult -Result $r
            }
        }
        else {
            Write-Host '  skipped (-GitGc needs -DevRoot <projects folder>)' -ForegroundColor Yellow
        }
    }

    if ($IncludeDev -or $ConfirmDockerPrune) {
        Write-Host ''
        Write-Host 'Docker / WSL' -ForegroundColor Cyan
        foreach ($r in (Invoke-DockerMaintenance -Prune:$ConfirmDockerPrune -DryRun:$DryRun)) {
            $results.Add($r)
            Write-TargetResult -Result $r
        }
        if ($IncludeDev) {
            $wsl = Get-WslMemoryReport
            if ($wsl.Running) {
                Write-Host ('  {0,-34} {1}' -f 'WSL VM memory', ('{0} held by {1}' -f (Format-Size $wsl.Bytes), $wsl.Process)) -ForegroundColor Gray
                foreach ($s in $wsl.Steps) { Write-Host "    - $s" -ForegroundColor Gray }
            }
        }
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
    foreach ($r in $results) {
        if ($r.Status -ne 'Cleaned' -and $r.Status -ne 'WouldClean') { continue }   # Info lines are reports, not savings
        $totalBytes += $r.Bytes
        $totalFiles += $r.Files
    }

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
            ConfigPath   = $config.UserPath
            BytesFreed   = $totalBytes
            FilesRemoved = $totalFiles
            Targets      = $results.ToArray()
            Ram          = $ram
            Wsl          = $wsl
        }
    }
}
