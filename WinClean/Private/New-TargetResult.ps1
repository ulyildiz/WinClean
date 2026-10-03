function New-TargetResult {
    <#
    .SYNOPSIS
        Creates the per-target result record returned by the cleanup helpers.
    .PARAMETER Status
        Cleaned | WouldClean | Skipped | NotFound | Info (a report line; never counted as freed)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Cleaned', 'WouldClean', 'Skipped', 'NotFound', 'Info')][string]$Status,
        [string]$Reason,
        [string]$Category
    )

    $resultReason = $null
    if ($Reason) { $resultReason = $Reason }
    $resultCategory = $null
    if ($Category) { $resultCategory = $Category }

    [pscustomobject]@{
        PSTypeName = 'WinClean.TargetResult'
        Label      = $Label
        Category   = $resultCategory
        Path       = $Path
        Status     = $Status
        Reason     = $resultReason
        Bytes      = 0L
        Files      = 0
    }
}
