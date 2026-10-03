function Get-QuarantineRoot {
    <#
    .SYNOPSIS
        The folder that holds quarantine runs: %TEMP%\WinClean-Quarantine (8.3 names expanded).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $root = Join-Path $env:TEMP 'WinClean-Quarantine'
    try { return (ConvertTo-NormalizedPath -Path $root) } catch { return $root }
}

function New-QuarantineRun {
    <#
    .SYNOPSIS
        Creates and returns a new run folder named yyyyMMdd-HHmmss (suffixed -1, -2 ... on collision).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([datetime]$Now = (Get-Date))

    $base = Get-QuarantineRoot
    $name = $Now.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
    $path = Join-Path $base $name
    $i = 1
    while (Test-Path -LiteralPath $path) { $path = Join-Path $base ('{0}-{1}' -f $name, $i); $i++ }
    # not New-Item -Force: in Windows PowerShell 5.1 it fails to create nested folders below
    # a path that contains an 8.3 short name (e.g. C:\Users\RUNNER~1\...)
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}

function Move-ToQuarantine {
    <#
    .SYNOPSIS
        Moves one file into a quarantine run, mirroring its original path
        (C:\a\b.tmp -> <run>\C\a\b.tmp). Returns $true on success.
    .DESCRIPTION
        Fails safe: a locked file, an over-long destination or any other error leaves the
        original where it is. If a cross-volume move copied the file but could not delete
        the source, the stray copy is removed so nothing is double counted.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$QuarantinePath
    )

    if ($Source -notmatch '^[A-Za-z]:\\') { return $false }
    $destination = Join-Path $QuarantinePath ($Source.Substring(0, 1).ToUpperInvariant() + $Source.Substring(2))
    try {
        $parent = [IO.Path]::GetDirectoryName($destination)
        if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
        if ([IO.File]::Exists($destination)) { return $false }
        [IO.File]::Move($Source, $destination)
        return $true
    }
    catch {
        try {
            if ([IO.File]::Exists($destination) -and [IO.File]::Exists($Source)) { [IO.File]::Delete($destination) }
        } catch { }
        return $false
    }
}

function Invoke-QuarantinePurge {
    <#
    .SYNOPSIS
        Permanently deletes quarantine runs older than -Days.
    .DESCRIPTION
        Only folders whose name is a WinClean run timestamp (yyyyMMdd-HHmmss[-n]) are
        considered; anything else in the quarantine folder is left alone. Age comes from
        the folder name, not from file times, so moving old files in does not make a fresh
        run look expired.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(0, 3650)][int]$Days = 7,
        [switch]$DryRun,
        [datetime]$Now = (Get-Date)
    )

    $base = Get-QuarantineRoot
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { return }
    $cutoff = $Now.AddDays(-$Days)

    foreach ($dir in (Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($dir.Name -notmatch '^(?<ts>\d{8}-\d{6})(-\d+)?$') { continue }
        $stamp = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($Matches['ts'], 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref]$stamp)) { continue }
        if ($stamp -gt $cutoff) { continue }

        $label = 'Quarantine from ' + $stamp.ToString('yyyy-MM-dd HH:mm')
        $r = Clear-FolderContents -Path $dir.FullName -Label $label -Category 'quarantine' -DryRun:$DryRun
        if (-not $DryRun -and $r.Status -eq 'Cleaned') {
            try { [IO.Directory]::Delete($dir.FullName, $false) } catch { }   # only succeeds when empty
        }
        $r
    }
}
