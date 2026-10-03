function Invoke-DevArtifactCleanup {
    <#
    .SYNOPSIS
        Cleans stale build-output folders found under one or more project roots.
    .DESCRIPTION
        An artifact folder is treated as a whole: if any file in it was written within
        -AgeHours the project is considered active and the folder is left alone, so a
        build is never left half-deleted.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string[]]$Root,
        [ValidateRange(0, 87600)][int]$AgeHours = 168,
        [string]$QuarantinePath,
        [switch]$DryRun
    )

    $since = (Get-Date).AddHours(-$AgeHours)

    foreach ($r in $Root) {
        $label = "Project root $r"
        if (-not (Test-Path -LiteralPath $r -PathType Container)) {
            New-TargetResult -Label $label -Path $r -Status 'Skipped' -Reason 'folder not found' -Category 'dev-artifact'
            continue
        }
        $full = (Resolve-Path -LiteralPath $r).ProviderPath.TrimEnd('\')
        if ($full -match '^[A-Za-z]:$') {
            New-TargetResult -Label $label -Path $r -Status 'Skipped' -Reason 'a drive root is too broad - point -DevRoot at your projects folder' -Category 'dev-artifact'
            continue
        }
        if ([IO.File]::GetAttributes($full) -band [IO.FileAttributes]::ReparsePoint) {
            New-TargetResult -Label $label -Path $r -Status 'Skipped' -Reason 'is a junction or symbolic link' -Category 'dev-artifact'
            continue
        }

        foreach ($a in (Find-DevArtifacts -Root $full)) {
            $relative = $a.Path.Substring($full.Length).TrimStart('\')
            $itemLabel = '{0} ({1})' -f $relative, $a.Ecosystem
            if (-not $a.IsCandidate) {
                New-TargetResult -Label $itemLabel -Path $a.Path -Status 'Skipped' -Reason $a.Reason -Category 'dev-artifact'
                continue
            }
            if ($AgeHours -gt 0 -and (Test-FolderWrittenSince -Path $a.Path -Since $since)) {
                New-TargetResult -Label $itemLabel -Path $a.Path -Status 'Skipped' -Reason "built within the last $AgeHours h" -Category 'dev-artifact'
                continue
            }
            Clear-FolderContents -Path $a.Path -Label $itemLabel -Category 'dev-artifact' -QuarantinePath $QuarantinePath -DryRun:$DryRun
        }
    }
}
