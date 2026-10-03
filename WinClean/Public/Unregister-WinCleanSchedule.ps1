function Unregister-WinCleanSchedule {
    <#
    .SYNOPSIS
        Removes a WinClean scheduled task.

    .DESCRIPTION
        Only tasks inside the \WinClean\ Task Scheduler folder are ever touched, so no
        other scheduled task can be removed by mistake. A missing task is reported, not
        treated as an error.

    .PARAMETER TaskName
        Name of the task inside \WinClean\. Default: WinClean

    .EXAMPLE
        Unregister-WinCleanSchedule -WhatIf

    .EXAMPLE
        Unregister-WinCleanSchedule
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [ValidatePattern('^[\w .-]+$')]
        [string]$TaskName = 'WinClean'
    )

    $taskPath = '\WinClean\'
    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Warning "No WinClean scheduled task named '$taskPath$TaskName' was found."
        return
    }

    if ($PSCmdlet.ShouldProcess("$taskPath$TaskName", 'Unregister scheduled task')) {
        Unregister-ScheduledTask -TaskPath $taskPath -TaskName $TaskName -Confirm:$false
    }
}
