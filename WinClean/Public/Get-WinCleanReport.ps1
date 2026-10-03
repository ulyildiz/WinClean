function Get-WinCleanReport {
    <#
    .SYNOPSIS
        Non-destructive system inspection: largest folders, memory per app, startup programs.

    .DESCRIPTION
        Analysis only - nothing is deleted, moved or changed (the registry is only read).
          Folders    the -Top largest folders under -ScanRoot, any level down to -MaxDepth.
                     Junctions / symlinks and OneDrive online-only files are not counted.
          Processes  memory per application (processes grouped by name) and RAM totals.
          Startup    Run keys and Startup folders, enabled state as shown in Task Manager,
                     and current resource use. ImpactEstimate is a heuristic from current
                     memory / CPU use; Task Manager's own figure comes from boot traces that
                     scripts cannot read.

    .PARAMETER ScanRoot
        Folder(s) to measure. Default: your user profile.

    .PARAMETER Top
        How many folders and applications to list. Default: 10

    .PARAMETER MaxDepth
        How many levels below each scan root take part in the folder ranking. Default: 3

    .PARAMETER Section
        Which sections to include: Folders, Processes, Startup. Default: all.

    .PARAMETER OutputFormat
        table (default, for reading), json, csv (one flat table with a Section column),
        or object (the raw WinClean.Report object for scripting).

    .EXAMPLE
        Get-WinCleanReport

    .EXAMPLE
        Get-WinCleanReport -ScanRoot C:\src, D:\ -Top 20 -OutputFormat json | Set-Content report.json

    .EXAMPLE
        (Get-WinCleanReport -Section Startup -OutputFormat object).Startup | Where-Object Enabled
    #>
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()]
        [string[]]$ScanRoot = @($env:USERPROFILE),

        [ValidateRange(1, 1000)]
        [int]$Top = 10,

        [ValidateRange(1, 64)]
        [int]$MaxDepth = 3,

        [ValidateSet('Folders', 'Processes', 'Startup')]
        [string[]]$Section = @('Folders', 'Processes', 'Startup'),

        [ValidateSet('table', 'json', 'csv', 'object')]
        [string]$OutputFormat = 'table'
    )

    $report = [pscustomobject]@{
        PSTypeName   = 'WinClean.Report'
        GeneratedAt  = Get-Date
        ComputerName = $env:COMPUTERNAME
        Memory       = $null
        FolderScans  = @()
        Folders      = @()
        Processes    = @()
        Startup      = @()
    }

    $processes = $null
    if ($Section -contains 'Processes' -or $Section -contains 'Startup') { $processes = @(Get-Process) }

    if ($Section -contains 'Folders') {
        $f = Get-FolderSizeReport -Root $ScanRoot -MaxDepth $MaxDepth -Top $Top
        $report.FolderScans = $f.Scans
        $report.Folders = $f.Folders
    }
    if ($Section -contains 'Processes') {
        $p = Get-ProcessMemoryReport -Top $Top -Process $processes
        $report.Memory = $p.Memory
        $report.Processes = $p.Processes
    }
    if ($Section -contains 'Startup') {
        $report.Startup = @(Get-StartupApps -Process $processes)
    }

    ConvertTo-ReportOutput -Report $report -Format $OutputFormat
}
