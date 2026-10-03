function Register-WinCleanSchedule {
    <#
    .SYNOPSIS
        Registers a weekly Task Scheduler task that runs Invoke-WinClean.

    .DESCRIPTION
        The task lives in its own Task Scheduler folder (\WinClean\), runs as the current
        user only while that user is logged on (no password is stored), starts late if the
        computer was off at the scheduled time, and stops after 2 hours. The command it runs
        is plain, readable text - check it in Task Scheduler under Actions.

        The task points at this module's current location; register again after moving
        the WinClean folder.

    .PARAMETER DayOfWeek
        Day to run. Default: Sunday

    .PARAMETER At
        Time of day to run. Default: 03:00

    .PARAMETER CleanParameters
        Invoke-WinClean parameters for the scheduled run, e.g.
        @{ Quarantine = $true; IncludeDev = $true; DevRoot = 'C:\src' }.
        Unknown names are rejected.

    .PARAMETER Elevated
        Run with administrator rights (Windows temp, Update cache and RAM flush are
        skipped otherwise). Registering an elevated task needs an elevated session.

    .PARAMETER TaskName
        Name of the task inside the \WinClean\ folder. Default: WinClean

    .PARAMETER Force
        Replace an existing task with the same name.

    .EXAMPLE
        Register-WinCleanSchedule -WhatIf

    .EXAMPLE
        Register-WinCleanSchedule -DayOfWeek Saturday -At 21:00 -CleanParameters @{ Quarantine = $true }

    .EXAMPLE
        Register-WinCleanSchedule -Elevated -CleanParameters @{ IncludeDev = $true; DevRoot = 'C:\src' } -Force
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [DayOfWeek]$DayOfWeek = [DayOfWeek]::Sunday,

        [datetime]$At = '03:00',

        [hashtable]$CleanParameters = @{},

        [switch]$Elevated,

        [ValidatePattern('^[\w .-]+$')]
        [string]$TaskName = 'WinClean',

        [switch]$Force
    )

    $taskPath = '\WinClean\'

    if ($Elevated -and -not (Test-IsAdministrator)) {
        throw 'Registering an -Elevated task needs an elevated PowerShell session (Run as administrator).'
    }

    $existing = Get-ScheduledTask -TaskPath $taskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing -and -not $Force) {
        throw "A scheduled task '$taskPath$TaskName' already exists. Use -Force to replace it."
    }

    $manifest = Join-Path $script:ModuleRoot 'WinClean.psd1'
    $command = ConvertTo-WinCleanCommand -ModuleManifest $manifest -CleanParameters $CleanParameters
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command "' + $command + '"'

    $runLevel = 'Limited'
    if ($Elevated) { $runLevel = 'Highest' }

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $trigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $At
    # New-ScheduledTaskTrigger stores the start in UTC ('...Z'), which makes the task drift by
    # an hour across daylight-saving changes. A boundary without offset is local wall-clock time.
    $trigger.StartBoundary = $At.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    $principal = New-ScheduledTaskPrincipal -UserId ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel $runLevel
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    $when = '{0}s at {1:HH:mm}' -f $DayOfWeek, $At
    if ($PSCmdlet.ShouldProcess("$taskPath$TaskName ($when, run level $runLevel)", 'Register scheduled task')) {
        $params = @{
            TaskPath    = $taskPath
            TaskName    = $TaskName
            Action      = $action
            Trigger     = $trigger
            Principal   = $principal
            Settings    = $settings
            Description = "WinClean weekly cleanup ($when). Created by Register-WinCleanSchedule. Runs: powershell.exe $arguments"
        }
        if ($existing) { $params['Force'] = $true }
        Register-ScheduledTask @params
    }
}
