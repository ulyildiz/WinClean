function Clear-FolderContents {
    <#
    .SYNOPSIS
        Deletes the files inside a folder (never the folder itself) and returns what it freed.
    .DESCRIPTION
        The folder must pass Test-PathSafety first. Junctions and symlinks are never followed,
        files newer than -AgeHours are kept, and locked / in-use files are silently skipped.
        Emptied sub-folders are removed afterwards with a non-recursive delete.
        With -QuarantinePath files are moved into that quarantine run instead of deleted.
        The quarantine folder itself is never entered, so cleaning %TEMP% cannot empty it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Label,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$AgeHours = 0,

        [string]$Category,

        [string]$QuarantinePath,

        [switch]$DryRun
    )

    $result = New-TargetResult -Label $Label -Path $Path -Status 'NotFound' -Category $Category
    if ([string]::IsNullOrWhiteSpace($Path)) { return $result }

    $verdict = Test-PathSafety -Path $Path -Detailed
    if (-not $verdict.IsSafe) {
        Write-Warning ("Refusing '{0}' ({1}): {2}" -f $Label, $Path, $verdict.Reason)
        $result.Status = 'Skipped'
        $result.Reason = $verdict.Reason
        return $result
    }

    $root = $verdict.NormalizedPath
    $result.Path = $root
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $result }

    $ignoreCase = [StringComparison]::OrdinalIgnoreCase
    # compared against long-name paths from the traversal, so expand 8.3 names first
    $moduleRoot = $script:ModuleRoot
    try { $moduleRoot = ConvertTo-NormalizedPath -Path $moduleRoot } catch { }
    $neverEnter = @($moduleRoot.TrimEnd('\'), (Get-QuarantineRoot).TrimEnd('\'))
    $cutoff = (Get-Date).AddHours(-$AgeHours)
    $freed = 0L
    $count = 0
    $dirs  = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($root)

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $dirs.Add($dir)
        try { $items = Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop } catch { continue }

        foreach ($item in $items) {
            # never follow junctions / symlinks
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($item.PSIsContainer) {
                # never descend into WinClean's own install folder or the quarantine
                $full = $item.FullName.TrimEnd('\')
                if (@($neverEnter | Where-Object { [string]::Equals($full, $_, $ignoreCase) }).Count -gt 0) { continue }
                $stack.Push($item.FullName)
                continue
            }
            if ($AgeHours -gt 0 -and $item.LastWriteTime -gt $cutoff) { continue }

            $size = $item.Length
            if ($DryRun) { $freed += $size; $count++; continue }
            if ($QuarantinePath) {
                if (Move-ToQuarantine -Source $item.FullName -QuarantinePath $QuarantinePath) { $freed += $size; $count++ }
                continue
            }
            try {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
                $freed += $size
                $count++
            } catch { }   # in use / locked: leave it alone
        }
    }

    # remove now-empty sub-folders, deepest first (children are always longer than parents).
    # Directory.Delete(path, $false) is non-recursive: it fails on anything non-empty and
    # removes only the link itself if a folder was swapped for a junction meanwhile.
    if (-not $DryRun) {
        $dirs | Where-Object { $_ -ne $root } | Sort-Object -Property { $_.Length } -Descending | ForEach-Object {
            try {
                if ([IO.File]::GetAttributes($_) -band [IO.FileAttributes]::ReparsePoint) { return }
                if (-not (Get-ChildItem -LiteralPath $_ -Force -ErrorAction Stop | Select-Object -First 1)) {
                    [IO.Directory]::Delete($_, $false)
                }
            } catch { }
        }
    }

    if ($DryRun) { $result.Status = 'WouldClean' }
    elseif ($QuarantinePath) { $result.Status = 'Quarantined' }
    else { $result.Status = 'Cleaned' }
    $result.Bytes = $freed
    $result.Files = $count
    return $result
}
