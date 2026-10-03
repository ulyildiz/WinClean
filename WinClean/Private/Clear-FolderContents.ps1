function Clear-FolderContents {
    <#
    .SYNOPSIS
        Deletes the files inside a folder (never the folder itself) and returns what it freed.
    .DESCRIPTION
        The folder must pass Test-PathSafety first. Junctions and symlinks are never followed,
        files newer than -AgeHours are kept, and locked / in-use files are silently skipped.
        Emptied sub-folders are removed afterwards with a non-recursive delete.
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

        [switch]$DryRun
    )

    $result = New-TargetResult -Label $Label -Path $Path -Status 'NotFound'
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
                # never descend into WinClean's own install folder
                if ([string]::Equals($item.FullName.TrimEnd('\'), $script:ModuleRoot.TrimEnd('\'), $ignoreCase)) { continue }
                $stack.Push($item.FullName)
                continue
            }
            if ($AgeHours -gt 0 -and $item.LastWriteTime -gt $cutoff) { continue }

            $size = $item.Length
            if ($DryRun) { $freed += $size; $count++; continue }
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

    if ($DryRun) { $result.Status = 'WouldClean' } else { $result.Status = 'Cleaned' }
    $result.Bytes = $freed
    $result.Files = $count
    return $result
}
