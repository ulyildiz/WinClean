function Write-TargetResult {
    <#
    .SYNOPSIS
        Prints one cleanup result line. Missing folders are not printed (same as the original script).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Result)

    switch ($Result.Status) {
        'NotFound' { }
        'Skipped'  { Write-Host ('  {0,-34} {1,12}  ({2})' -f $Result.Label, 'skipped', $Result.Reason) -ForegroundColor Yellow }
        'Info'     { Write-Host ('  {0,-34} {1}' -f $Result.Label, $Result.Reason) -ForegroundColor Gray }
        default    { Write-Host ('  {0,-34} {1,12}  ({2} files)' -f $Result.Label, (Format-Size $Result.Bytes), $Result.Files) }
    }
}
