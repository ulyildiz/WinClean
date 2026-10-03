function Get-ProcessMemoryReport {
    <#
    .SYNOPSIS
        Memory use per application (processes grouped by name) plus the machine's RAM totals.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 1000)][int]$Top = 10,
        [object[]]$Process = @(Get-Process)
    )

    $apps = foreach ($g in ($Process | Group-Object -Property ProcessName)) {
        $ws = 0L; $private = 0L
        foreach ($p in $g.Group) {
            try { $ws += [long]$p.WorkingSet64 } catch { }
            try { $private += [long]$p.PrivateMemorySize64 } catch { }
        }
        [pscustomobject]@{
            PSTypeName      = 'WinClean.ProcessMemory'
            Name            = $g.Name
            Instances       = $g.Count
            WorkingSetBytes = $ws
            PrivateBytes    = $private
        }
    }

    $memory = [pscustomobject]@{ TotalBytes = $null; AvailableBytes = $null; UsedPercent = $null }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $memory.TotalBytes = [long]$os.TotalVisibleMemorySize * 1KB
        $memory.AvailableBytes = [long]$os.FreePhysicalMemory * 1KB
        if ($memory.TotalBytes -gt 0) {
            $memory.UsedPercent = [Math]::Round(100 * (1 - $memory.AvailableBytes / $memory.TotalBytes), 1)
        }
    } catch { }

    [pscustomobject]@{
        Memory    = $memory
        Processes = @($apps | Sort-Object -Property WorkingSetBytes -Descending | Select-Object -First $Top)
    }
}
