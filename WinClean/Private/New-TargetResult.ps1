function New-TargetResult {
    <#
    .SYNOPSIS
        Creates the per-target result record returned by the cleanup helpers.
    .PARAMETER Status
        Cleaned | WouldClean | Skipped | NotFound
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Cleaned', 'WouldClean', 'Skipped', 'NotFound')][string]$Status,
        [string]$Reason
    )

    $resultReason = $null
    if ($Reason) { $resultReason = $Reason }

    [pscustomobject]@{
        PSTypeName = 'WinClean.TargetResult'
        Label      = $Label
        Path       = $Path
        Status     = $Status
        Reason     = $resultReason
        Bytes      = 0L
        Files      = 0
    }
}
