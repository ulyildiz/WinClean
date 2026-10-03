function Get-RunLogPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path $env:LOCALAPPDATA 'WinClean\run-log.json'
}

function Write-WinCleanRunLog {
    <#
    .SYNOPSIS
        Appends one run's metrics to the local run log (a JSON array). Local only - nothing
        is ever sent anywhere.
    .DESCRIPTION
        A named mutex serialises writers, so a scheduled run and a manual run cannot lose each
        other's entries. The file is written to a temp file and swapped in, so a crash never
        leaves half-written JSON. A log that cannot be parsed is renamed aside (never
        overwritten) and a fresh one is started. Only the newest -MaxEntries runs are kept.
        Throws on failure; the caller decides that logging must not break a cleanup.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Result,
        [string]$Path = (Get-RunLogPath),
        [ValidateRange(1, 100000)][int]$MaxEntries = 500
    )

    $skipped = @($Result.Targets | Where-Object { $_.Status -eq 'Skipped' }).Count
    $version = $null
    if ($MyInvocation.MyCommand.Module) { $version = $MyInvocation.MyCommand.Module.Version.ToString() }

    $entry = [pscustomobject][ordered]@{
        timestamp        = $Result.StartTime.ToString('o')
        bytesFreed       = [long]$Result.BytesFreed
        filesRemoved     = [long]$Result.FilesRemoved
        dryRun           = [bool]$Result.DryRun
        quarantine       = [bool]$Result.Quarantine
        bytesQuarantined = [long]$Result.BytesQuarantined
        filesQuarantined = [long]$Result.FilesQuarantined
        skippedTargets   = $skipped
        isAdmin          = [bool]$Result.IsAdmin
        durationSeconds  = [Math]::Round(($Result.EndTime - $Result.StartTime).TotalSeconds, 1)
        moduleVersion    = $version
    }

    $mutex = New-Object System.Threading.Mutex($false, 'Local\WinClean.RunLog')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(15000) }
        catch [System.Threading.AbandonedMutexException] { $owned = $true }   # previous writer died; we own it now
        if (-not $owned) { throw 'the run log is locked by another WinClean run' }

        $dir = Split-Path -Path $Path -Parent
        [void][IO.Directory]::CreateDirectory($dir)   # also safe below 8.3 short-name paths

        $entries = @()
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $text = [IO.File]::ReadAllText($Path)
            if ($text.Trim()) {
                $parsed = $null
                $valid = $text.TrimStart().StartsWith('[')
                if ($valid) {
                    try { $parsed = $text | ConvertFrom-Json -ErrorAction Stop } catch { $valid = $false }
                }
                if ($valid) {
                    $entries = @($parsed)
                }
                else {
                    $aside = Join-Path $dir ('run-log.corrupt-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                    Move-Item -LiteralPath $Path -Destination $aside
                    Write-Warning "The WinClean run log could not be read; it was kept as $aside and a new log was started."
                }
            }
        }

        $entries = @($entries) + $entry
        if ($entries.Count -gt $MaxEntries) { $entries = @($entries | Select-Object -Last $MaxEntries) }

        $json = ConvertTo-Json -InputObject $entries -Depth 3
        $tmp = "$Path.tmp"
        [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
        # [NullString]: PowerShell would pass $null to a .NET string parameter as ''
        if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($tmp, $Path) }
    }
    finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
