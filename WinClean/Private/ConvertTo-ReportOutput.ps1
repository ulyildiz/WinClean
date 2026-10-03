function ConvertTo-ReportOutput {
    <#
    .SYNOPSIS
        Renders a WinClean.Report as table text, JSON, flat CSV, or passes the object through.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Report,
        [Parameter(Mandatory)][ValidateSet('table', 'json', 'csv', 'object')][string]$Format
    )

    switch ($Format) {
        'object' { return $Report }

        'json' {
            # ISO 8601 instead of Windows PowerShell's "\/Date(...)\/" so other tools can read it
            $copy = [ordered]@{}
            foreach ($p in $Report.PSObject.Properties) { $copy[$p.Name] = $p.Value }
            $copy['GeneratedAt'] = $Report.GeneratedAt.ToString('o')
            return ([pscustomobject]$copy | ConvertTo-Json -Depth 6)
        }

        'csv' {
            $rows = @(
                foreach ($f in $Report.Folders) {
                    [pscustomobject]@{ Section = 'Folder'; Name = $f.Name; Path = $f.Path; Bytes = $f.Bytes; Count = $f.Files
                                       Source = $f.Root; Status = ''; Impact = ''; Depth = $f.Depth }
                }
                foreach ($p in $Report.Processes) {
                    [pscustomobject]@{ Section = 'Process'; Name = $p.Name; Path = ''; Bytes = $p.WorkingSetBytes; Count = $p.Instances
                                       Source = ''; Status = ''; Impact = ''; Depth = '' }
                }
                foreach ($s in $Report.Startup) {
                    $status = 'Disabled'
                    if ($s.Enabled -and $s.Running) { $status = 'Running' } elseif ($s.Enabled) { $status = 'Enabled' }
                    [pscustomobject]@{ Section = 'Startup'; Name = $s.Name; Path = $s.Executable; Bytes = $s.WorkingSetBytes; Count = $s.Instances
                                       Source = $s.Source; Status = $status; Impact = $s.ImpactEstimate; Depth = '' }
                }
            )
            return ($rows | ConvertTo-Csv -NoTypeInformation)
        }

        'table' {
            $out = New-Object System.Text.StringBuilder
            [void]$out.AppendLine(('WinClean report - {0} - {1}' -f $Report.ComputerName, $Report.GeneratedAt.ToString('yyyy-MM-dd HH:mm')))

            if ($Report.FolderScans.Count -gt 0) {
                [void]$out.AppendLine('')
                [void]$out.AppendLine('Largest folders')
                foreach ($s in $Report.FolderScans) {
                    if ($s.Error) { [void]$out.AppendLine(('  {0}: {1}' -f $s.Root, $s.Error)); continue }
                    $note = ''
                    if ($s.Inaccessible -gt 0) { $note = " ($($s.Inaccessible) folders could not be read)" }
                    [void]$out.AppendLine(('  {0}: {1} in {2:N0} files{3}' -f $s.Root, (Format-Size $s.TotalBytes), $s.TotalFiles, $note))
                }
                if ($Report.Folders.Count -gt 0) {
                    [void]$out.Append(($Report.Folders | Format-Table -AutoSize -Property `
                        @{ n = 'Size'; e = { Format-Size $_.Bytes }; a = 'right' },
                        @{ n = 'Files'; e = { '{0:N0}' -f $_.Files }; a = 'right' },
                        Path | Out-String -Width 220))
                }
            }

            if ($Report.Memory -or $Report.Processes.Count -gt 0) {
                [void]$out.AppendLine('Memory by application')
                if ($Report.Memory -and $Report.Memory.TotalBytes) {
                    [void]$out.AppendLine(('  {0} of {1} in use ({2}%)' -f
                        (Format-Size ($Report.Memory.TotalBytes - $Report.Memory.AvailableBytes)), (Format-Size $Report.Memory.TotalBytes), $Report.Memory.UsedPercent))
                }
                [void]$out.Append(($Report.Processes | Format-Table -AutoSize -Property Name,
                    @{ n = 'Instances'; e = { $_.Instances }; a = 'right' },
                    @{ n = 'Working set'; e = { Format-Size $_.WorkingSetBytes }; a = 'right' },
                    @{ n = 'Private'; e = { Format-Size $_.PrivateBytes }; a = 'right' } | Out-String -Width 220))
            }

            if ($Report.Startup.Count -gt 0) {
                [void]$out.AppendLine('Startup programs (impact is an estimate from current use)')
                [void]$out.Append(($Report.Startup | Format-Table -AutoSize -Property Name, Source,
                    @{ n = 'Enabled'; e = { $_.Enabled } },
                    @{ n = 'Memory'; e = { if ($_.Running) { Format-Size $_.WorkingSetBytes } else { '-' } }; a = 'right' },
                    @{ n = 'Impact'; e = { $_.ImpactEstimate } } | Out-String -Width 220))
            }
            return $out.ToString().TrimEnd()
        }
    }
}
