function ConvertFrom-DockerSize {
    <#
    .SYNOPSIS
        Parses Docker's human-readable sizes ('1.23GB', '456MB', '12.3kB', '0B'). Docker uses
        decimal units (1 kB = 1000 B). Returns $null for anything unrecognised.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param([AllowEmptyString()][string]$Text)

    $m = [regex]::Match($Text.Trim(), '^(?<n>\d+(\.\d+)?)\s*(?<u>B|kB|KB|MB|GB|TB)$')
    if (-not $m.Success) { return $null }
    # hashtable keys are case-insensitive, so 'kB' also matches 'KB'
    $factor = @{ 'B' = 1; 'kB' = 1e3; 'MB' = 1e6; 'GB' = 1e9; 'TB' = 1e12 }[$m.Groups['u'].Value]
    return [long]([double]::Parse($m.Groups['n'].Value, [Globalization.CultureInfo]::InvariantCulture) * $factor)
}

function Invoke-DockerMaintenance {
    <#
    .SYNOPSIS
        Reports dangling Docker images and, only with -Prune, removes them.
    .DESCRIPTION
        Runs 'docker image prune --force' - dangling (untagged, unreferenced) images only,
        never '--all', never volumes, containers or networks. Nothing is attempted unless the
        Docker daemon answers within 15 seconds.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch]$Prune,
        [switch]$DryRun
    )

    $category = 'docker'
    $label = 'Docker dangling images'

    $docker = Get-ExternalToolPath -Name 'docker'
    if (-not $docker) {
        if ($Prune) { New-TargetResult -Label $label -Status 'Skipped' -Reason 'docker CLI not found' -Category $category }
        return
    }

    $ping = Invoke-ExternalCommand -FilePath $docker -ArgumentList @('version', '--format', '{{.Server.Version}}') -TimeoutSeconds 15
    if ($ping.TimedOut -or $ping.ExitCode -ne 0 -or -not $ping.StdOut.Trim()) {
        New-TargetResult -Label $label -Status 'Skipped' -Reason 'Docker daemon is not responding (is Docker Desktop running?)' -Category $category
        return
    }

    $list = Invoke-ExternalCommand -FilePath $docker -ArgumentList @('image', 'ls', '--filter', 'dangling=true', '--format', '{{.ID}}|{{.Size}}') -TimeoutSeconds 60
    if ($list.ExitCode -ne 0) {
        New-TargetResult -Label $label -Status 'Skipped' -Reason 'docker image ls failed' -Category $category
        return
    }
    $lines = @($list.StdOut -split "`r?`n" | Where-Object { $_.Trim() })
    $estimate = 0L
    foreach ($l in $lines) {
        $size = ConvertFrom-DockerSize -Text (($l -split '\|', 2)[-1])
        if ($size) { $estimate += $size }
    }

    if ($lines.Count -eq 0) {
        return New-TargetResult -Label $label -Status 'Info' -Reason 'none found' -Category $category
    }
    $summary = '{0} dangling image(s), up to {1}' -f $lines.Count, (Format-Size $estimate)
    if (-not $Prune) {
        return New-TargetResult -Label $label -Status 'Info' -Reason "$summary - add -ConfirmDockerPrune to remove them" -Category $category
    }
    if ($DryRun) {
        return New-TargetResult -Label $label -Status 'Info' -Reason "$summary - would run docker image prune" -Category $category
    }

    $run = Invoke-ExternalCommand -FilePath $docker -ArgumentList @('image', 'prune', '--force') -TimeoutSeconds 600
    if ($run.TimedOut -or $run.ExitCode -ne 0) {
        return New-TargetResult -Label $label -Status 'Skipped' -Reason 'docker image prune failed' -Category $category
    }
    $result = New-TargetResult -Label $label -Status 'Cleaned' -Category $category
    $m = [regex]::Match($run.StdOut, 'Total reclaimed space:\s*(?<s>\S+)')
    if ($m.Success) {
        $bytes = ConvertFrom-DockerSize -Text $m.Groups['s'].Value
        if ($bytes) { $result.Bytes = $bytes }
    }
    return $result
}
