function Get-RegistryValueTable {
    <#
    .SYNOPSIS
        Reads all values of a registry key into a hashtable (read-only; empty when the key is missing).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $table = @{}
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        foreach ($name in $key.GetValueNames()) {
            if ($name) { $table[$name] = $key.GetValue($name) }
        }
    } catch { }
    return $table
}

function ConvertTo-StartupExecutable {
    <#
    .SYNOPSIS
        Extracts the program path from a startup command line.
    .EXAMPLE
        '"C:\Program Files\App\app.exe" --minimized'  ->  C:\Program Files\App\app.exe
        'C:\Program Files\App\app.exe -min'           ->  C:\Program Files\App\app.exe
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $c = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -gt 1) { return $c.Substring(1, $end - 1) }
    }
    $m = [regex]::Match($c, '^(.+?\.(exe|com|bat|cmd))(\s|$)', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value }
    return ($c -split '\s+')[0]
}

function Test-StartupApproved {
    <#
    .SYNOPSIS
        Reads Task Manager's enabled/disabled flag (StartupApproved). $null = no record (enabled by default).
    #>
    [CmdletBinding()]
    param([hashtable]$Approved, [string]$Name)

    if (-not $Approved -or -not $Approved.ContainsKey($Name)) { return $null }
    $bytes = $Approved[$Name]
    if ($bytes -isnot [byte[]] -or $bytes.Length -eq 0) { return $null }
    return (($bytes[0] -band 1) -eq 0)   # 0x02 / 0x06 enabled, 0x03 / 0x07 disabled
}

function Get-StartupImpactEstimate {
    <#
    .SYNOPSIS
        Heuristic impact from current resource use. Task Manager's real figure comes from
        boot-time traces scripts cannot read, so this is labelled an estimate everywhere.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Enabled, [bool]$Running, [long]$WorkingSetBytes, [double]$CpuSeconds)

    if ($Enabled -eq $false) { return 'Disabled' }
    if (-not $Running) { return 'Not running' }
    if ($WorkingSetBytes -ge 150MB -or $CpuSeconds -ge 60) { return 'High' }
    if ($WorkingSetBytes -ge 50MB -or $CpuSeconds -ge 10) { return 'Medium' }
    return 'Low'
}

function Get-StartupApps {
    <#
    .SYNOPSIS
        Lists programs started at logon (Run keys and Startup folders) with their state and
        current resource use. Read-only.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Process = @(Get-Process),
        [string]$UserStartupFolder = [Environment]::GetFolderPath('Startup'),
        [string]$CommonStartupFolder = [Environment]::GetFolderPath('CommonStartup')
    )

    $approvedRoot = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $sources = @(
        @{ Source = 'Registry (user)';          Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             Approved = "HKCU:\$approvedRoot\Run" }
        @{ Source = 'Registry (machine)';       Key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             Approved = "HKLM:\$approvedRoot\Run" }
        @{ Source = 'Registry (machine 32-bit)'; Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$approvedRoot\Run32" }
    )

    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $sources) {
        $approved = Get-RegistryValueTable -Path $s.Approved
        $values = Get-RegistryValueTable -Path $s.Key
        foreach ($name in ($values.Keys | Sort-Object)) {
            $entries.Add(@{ Name = $name; Source = $s.Source; Command = [string]$values[$name]; Enabled = (Test-StartupApproved -Approved $approved -Name $name) })
        }
    }

    $folders = @(
        @{ Source = 'Startup folder (user)';      Path = $UserStartupFolder;   Approved = "HKCU:\$approvedRoot\StartupFolder" }
        @{ Source = 'Startup folder (all users)'; Path = $CommonStartupFolder; Approved = "HKLM:\$approvedRoot\StartupFolder" }
    )
    $shell = $null
    foreach ($f in $folders) {
        if (-not $f.Path -or -not (Test-Path -LiteralPath $f.Path -PathType Container)) { continue }
        $approved = Get-RegistryValueTable -Path $f.Approved
        foreach ($file in (Get-ChildItem -LiteralPath $f.Path -File -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if ($file.Name -eq 'desktop.ini') { continue }
            $command = $file.FullName
            if ($file.Extension -eq '.lnk') {
                try {
                    if (-not $shell) { $shell = New-Object -ComObject WScript.Shell }
                    $link = $shell.CreateShortcut($file.FullName)   # reads the .lnk; nothing is saved
                    if ($link.TargetPath) { $command = ('"{0}" {1}' -f $link.TargetPath, $link.Arguments).Trim() }
                } catch { }
            }
            $entries.Add(@{ Name = $file.BaseName; Source = $f.Source; Command = $command; Enabled = (Test-StartupApproved -Approved $approved -Name $file.Name) })
        }
    }

    foreach ($e in $entries) {
        $exe = ConvertTo-StartupExecutable -Command $e.Command
        $exeName = $null
        if ($exe) { $exeName = [IO.Path]::GetFileNameWithoutExtension($exe) }

        $matched = @($Process | Where-Object {
            $p = $null
            try { $p = $_.Path } catch { }
            if ($p -and $exe) { [string]::Equals($p, $exe, [StringComparison]::OrdinalIgnoreCase) }
            else { $exeName -and [string]::Equals($_.ProcessName, $exeName, [StringComparison]::OrdinalIgnoreCase) }
        })

        $ws = 0L; $cpu = 0.0
        foreach ($p in $matched) {
            try { $ws += [long]$p.WorkingSet64 } catch { }
            try { $cpu += $p.TotalProcessorTime.TotalSeconds } catch { }
        }
        $running = $matched.Count -gt 0

        [pscustomobject]@{
            PSTypeName      = 'WinClean.StartupApp'
            Name            = $e.Name
            Source          = $e.Source
            Enabled         = ($e.Enabled -ne $false)
            Command         = $e.Command
            Executable      = $exe
            Running         = $running
            Instances       = $matched.Count
            WorkingSetBytes = $ws
            CpuSeconds      = [Math]::Round($cpu, 1)
            ImpactEstimate  = Get-StartupImpactEstimate -Enabled $e.Enabled -Running $running -WorkingSetBytes $ws -CpuSeconds $cpu
        }
    }
}
