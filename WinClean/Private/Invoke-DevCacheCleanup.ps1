function Invoke-DevCacheCleanup {
    <#
    .SYNOPSIS
        Cleans package-manager and editor caches returned by Get-DevCacheTargets.
    .DESCRIPTION
        Cache files are removed per file when older than -AgeHours. Orphaned VS Code
        workspace folders are judged as a whole and removed once empty. The npm cache is
        only touched after 'npm cache verify' succeeds, and verified again afterwards so
        npm's index matches what is left on disk.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Target,
        [ValidateRange(0, 87600)][int]$AgeHours = 168,
        [string]$QuarantinePath,
        [switch]$DryRun
    )

    $since = (Get-Date).AddHours(-$AgeHours)
    $category = 'dev-cache'

    foreach ($t in $Target) {
        if ($t.Kind -eq 'orphaned-workspace') {
            if ($AgeHours -gt 0 -and (Test-FolderWrittenSince -Path $t.Path -Since $since)) {
                New-TargetResult -Label $t.Label -Path $t.Path -Status 'Skipped' -Reason "used within the last $AgeHours h" -Category $category
                continue
            }
            $r = Clear-FolderContents -Path $t.Path -Label $t.Label -Category $category -QuarantinePath $QuarantinePath -DryRun:$DryRun
            if (-not $DryRun -and ($r.Status -eq 'Cleaned' -or $r.Status -eq 'Quarantined')) {
                try { [IO.Directory]::Delete($t.Path, $false) } catch { }   # only succeeds when empty
            }
            $r
            continue
        }

        if ($t.Tool -eq 'npm' -and -not $DryRun) {
            $npm = Get-ExternalToolPath -Name 'npm'
            if (-not $npm) {
                New-TargetResult -Label $t.Label -Path $t.Path -Status 'Skipped' -Reason 'npm not found (needed for npm cache verify)' -Category $category
                continue
            }
            $verify = Invoke-ExternalCommand -FilePath $npm -ArgumentList @('cache', 'verify') -TimeoutSeconds 600
            if ($verify.TimedOut -or $verify.ExitCode -ne 0) {
                $why = 'npm cache verify failed'
                if ($verify.TimedOut) { $why = 'npm cache verify timed out' }
                New-TargetResult -Label $t.Label -Path $t.Path -Status 'Skipped' -Reason $why -Category $category
                continue
            }
            Clear-FolderContents -Path $t.Path -Label $t.Label -AgeHours $AgeHours -Category $category -QuarantinePath $QuarantinePath
            [void](Invoke-ExternalCommand -FilePath $npm -ArgumentList @('cache', 'verify') -TimeoutSeconds 600)
            continue
        }

        Clear-FolderContents -Path $t.Path -Label $t.Label -AgeHours $AgeHours -Category $category -QuarantinePath $QuarantinePath -DryRun:$DryRun
    }
}
