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

function ConvertTo-ExtendedPath {
    <#
    .SYNOPSIS
        Prefixes an absolute drive path with \\?\ so .NET bypasses the 260-character limit.
        Only for paths that are already normalized: \\?\ turns off all path normalization.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path -notmatch '^[A-Za-z]:\\') { throw "Not an absolute drive path: $Path" }
    return '\\?\' + $Path
}

function Remove-QuarantineRun {
    <#
    .SYNOPSIS
        Deletes one quarantine run folder, including paths longer than 260 characters.
    .DESCRIPTION
        Uses extended-length paths throughout, so files a normal traversal cannot even see in
        Windows PowerShell 5.1 are purged too. Junctions / symlinks are never followed (one
        inside a run means something else put it there; it is left, and so is the run).
        Folders are removed non-recursively, deepest first. With -DryRun only measures.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$DryRun
    )

    $result = [pscustomobject]@{ Bytes = 0L; Files = 0; Complete = $true }
    $root = ConvertTo-ExtendedPath -Path $Path.TrimEnd('\')
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($root)

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $dirs.Add($dir)
        try { $entries = @(([IO.DirectoryInfo]$dir).EnumerateFileSystemInfos()) }
        catch { $result.Complete = $false; continue }
        foreach ($e in $entries) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { $result.Complete = $false; continue }
            if ($e -is [IO.DirectoryInfo]) { $stack.Push($e.FullName); continue }
            $size = $e.Length
            if ($DryRun) { $result.Bytes += $size; $result.Files++; continue }
            try {
                if ($e.Attributes -band [IO.FileAttributes]::ReadOnly) { $e.Attributes = $e.Attributes -bxor [IO.FileAttributes]::ReadOnly }
                $e.Delete()
                $result.Bytes += $size
                $result.Files++
            }
            catch { $result.Complete = $false }
        }
    }

    if (-not $DryRun) {
        foreach ($d in ($dirs | Sort-Object -Property { $_.Length } -Descending)) {
            try { [IO.Directory]::Delete($d, $false) } catch { $result.Complete = $false }
        }
    }
    return $result
}

function Move-ToQuarantine {
    <#
    .SYNOPSIS
        Moves one file into a quarantine run, mirroring its original path
        (C:\a\b.tmp -> <run>\C\a\b.tmp). Returns $true on success.
    .DESCRIPTION
        Mirroring roughly doubles the path length, so a cache file with a long name (npm's
        content files are 128 characters) easily passes the 260-character MAX_PATH limit at
        the destination. Extended-length (\\?\) paths are used for the move so that still
        works in Windows PowerShell 5.1 without any system setting.

        Fails safe: a locked file or any other error leaves the original where it is. If a
        cross-volume move copied the file but could not delete the source, the stray copy is
        removed so nothing is double counted.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$QuarantinePath
    )

    if ($Source -notmatch '^[A-Za-z]:\\') { return $false }
    $destination = ConvertTo-ExtendedPath -Path (Join-Path $QuarantinePath ($Source.Substring(0, 1).ToUpperInvariant() + $Source.Substring(2)))
    $Source = ConvertTo-ExtendedPath -Path $Source
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
        $verdict = Test-PathSafety -Path $dir.FullName -Detailed
        if (-not $verdict.IsSafe) {
            New-TargetResult -Label $label -Path $dir.FullName -Status 'Skipped' -Reason $verdict.Reason -Category 'quarantine'
            continue
        }

        $removed = Remove-QuarantineRun -Path $verdict.NormalizedPath -DryRun:$DryRun
        $status = 'Cleaned'
        if ($DryRun) { $status = 'WouldClean' }
        $r = New-TargetResult -Label $label -Path $verdict.NormalizedPath -Status $status -Category 'quarantine'
        $r.Bytes = $removed.Bytes
        $r.Files = $removed.Files
        if (-not $DryRun -and -not $removed.Complete) { $r.Reason = 'some files could not be removed; will retry next run' }
        $r
    }
}
