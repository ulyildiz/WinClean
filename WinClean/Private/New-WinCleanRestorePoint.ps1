function Test-SystemRestoreEnabled {
    <#
    .SYNOPSIS
        $true / $false when the registry says whether System Restore is on, $null when unknown.
    #>
    [CmdletBinding()]
    param()

    try {
        $policy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -ErrorAction Stop
        $disable = $policy.PSObject.Properties['DisableSR']
        if ($disable -and $disable.Value -eq 1) { return $false }
    } catch { }

    try {
        $sr = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -ErrorAction Stop
        $interval = $sr.PSObject.Properties['RPSessionInterval']
        if ($interval) { return ($interval.Value -ne 0) }
    } catch { }

    return $null
}

function Invoke-RestorePointCheckpoint {
    <#
    .SYNOPSIS
        Thin wrapper around Checkpoint-Computer. Returns any warnings it produced (Windows
        refuses a second restore point within 24 hours with a warning, not an error).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Description)

    if (-not (Get-Command -Name 'Checkpoint-Computer' -ErrorAction SilentlyContinue)) {
        throw 'Checkpoint-Computer is not available in this PowerShell edition (use Windows PowerShell 5.1)'
    }
    $warnings = $null
    Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable warnings
    return @($warnings | ForEach-Object { "$_" })
}

function New-WinCleanRestorePoint {
    <#
    .SYNOPSIS
        Creates a System Restore point before a destructive run, or explains why not.
    .DESCRIPTION
        Never blocks the run: when System Restore is disabled, unavailable, throttled or
        the session is not elevated, a warning is written and the cleanup proceeds.
        Dry runs never create a restore point.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch]$DryRun,
        [bool]$IsAdmin = (Test-IsAdministrator)
    )

    $result = [pscustomobject]@{
        PSTypeName  = 'WinClean.RestorePointResult'
        Created     = $false
        Description = 'WinClean ' + (Get-Date).ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        Reason      = $null
    }

    if ($DryRun) { $result.Reason = 'dry run - no restore point created'; return $result }

    if (-not $IsAdmin) {
        $result.Reason = 'requires administrator'
        Write-Warning 'A restore point needs administrator rights - continuing without one.'
        return $result
    }

    if ((Test-SystemRestoreEnabled) -eq $false) {
        $result.Reason = 'System Restore is disabled'
        Write-Warning 'System Restore is disabled on this machine - continuing without a restore point.'
        return $result
    }

    try {
        $warnings = @(Invoke-RestorePointCheckpoint -Description $result.Description)
        if ($warnings.Count -gt 0) {
            $result.Reason = $warnings[0]
            Write-Warning "Restore point not created: $($warnings[0]) Continuing."
        }
        else {
            $result.Created = $true
        }
    }
    catch {
        $result.Reason = $_.Exception.Message
        Write-Warning "Restore point could not be created ($($_.Exception.Message)) - continuing without one."
    }
    return $result
}
