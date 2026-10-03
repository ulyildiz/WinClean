function Test-FolderWrittenSince {
    <#
    .SYNOPSIS
        True when any file below -Path was written after -Since. Stops at the first hit and
        never follows junctions / symlinks.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][datetime]$Since
    )

    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try { $items = Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop } catch { continue }
        foreach ($item in $items) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($item.PSIsContainer) { $stack.Push($item.FullName); continue }
            if ($item.LastWriteTime -gt $Since) { return $true }
        }
    }
    return $false
}
