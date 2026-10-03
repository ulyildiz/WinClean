function Clear-UpdateCache {
    <#
    .SYNOPSIS
        Empties the Windows Update download cache, pausing wuauserv/BITS and restoring them afterwards.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$QuarantinePath,
        [switch]$DryRun
    )

    $label = 'Windows Update downloads'
    $path  = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'

    if (Get-Process -Name 'TiWorker', 'TrustedInstaller' -ErrorAction SilentlyContinue) {
        return New-TargetResult -Label $label -Path $path -Status 'Skipped' -Reason 'Windows Update is busy installing' -Category 'update'
    }

    $running = @()
    foreach ($n in 'wuauserv', 'bits') {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Running') { $running += $n }
    }

    try {
        if (-not $DryRun) {
            foreach ($n in $running) { Stop-Service -Name $n -Force -ErrorAction SilentlyContinue }
        }
        Clear-FolderContents -Path $path -Label $label -Category 'update' -QuarantinePath $QuarantinePath -DryRun:$DryRun
    }
    finally {
        # put services back exactly as they were
        if (-not $DryRun) {
            foreach ($n in $running) { Start-Service -Name $n -ErrorAction SilentlyContinue }
        }
    }
}
