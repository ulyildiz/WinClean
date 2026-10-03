function ConvertTo-PSLiteral {
    <#
    .SYNOPSIS
        Renders a value as a PowerShell literal using single quotes only, so the result can be
        embedded in a double-quoted -Command argument without any escaping problems.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()]$Value)

    if ($Value -is [array]) { return (@($Value | ForEach-Object { ConvertTo-PSLiteral -Value $_ }) -join ',') }
    if ($Value -is [bool])  { if ($Value) { return '$true' } else { return '$false' } }
    if ($Value -is [int] -or $Value -is [long]) { return [string]$Value }
    $text = [string]$Value
    if ($text.Contains('"')) { throw "Values containing double quotes cannot be scheduled: $text" }
    return "'" + $text.Replace("'", "''") + "'"
}

function ConvertTo-WinCleanCommand {
    <#
    .SYNOPSIS
        Builds the readable command line a scheduled task uses to run Invoke-WinClean.
    .DESCRIPTION
        Every key must be a real Invoke-WinClean parameter; anything else (typos, common
        parameters, -PassThru) is rejected instead of being silently ignored by the task.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ModuleManifest,
        [hashtable]$CleanParameters = @{}
    )

    $allowed = (Get-Command -Name Invoke-WinClean).Parameters.Keys |
        Where-Object { [Management.Automation.PSCmdlet]::CommonParameters -notcontains $_ -and [Management.Automation.PSCmdlet]::OptionalCommonParameters -notcontains $_ -and $_ -ne 'PassThru' }

    $command = 'Import-Module ' + (ConvertTo-PSLiteral -Value $ModuleManifest) + ' -Force; Invoke-WinClean'
    foreach ($key in ($CleanParameters.Keys | Sort-Object)) {
        $name = $allowed | Where-Object { $_ -eq $key } | Select-Object -First 1
        if (-not $name) { throw "'$key' is not an Invoke-WinClean parameter that can be scheduled" }
        $value = $CleanParameters[$key]
        if ($value -is [switch]) { $value = $value.IsPresent }
        if ((Get-Command Invoke-WinClean).Parameters[$name].ParameterType -eq [switch]) {
            # a wrong value here would only surface as a failed run at 3 AM - reject it now
            if ($value -isnot [bool]) { throw "'$name' is a switch: use `$true or `$false" }
            if ($value) { $command += " -$name" }
            continue
        }
        $command += " -$name " + (ConvertTo-PSLiteral -Value $value)
    }
    return $command
}
