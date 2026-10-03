function Find-GitRepositories {
    <#
    .SYNOPSIS
        Lists folders under -Root that contain a .git directory. Never follows junctions /
        symlinks and never searches node_modules or .git itself.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [ValidateRange(1, 64)][int]$MaxDepth = 8
    )

    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push(@($Root, 0))
    while ($stack.Count -gt 0) {
        $frame = $stack.Pop()
        $dir = $frame[0]; $depth = $frame[1]

        $dotGit = Join-Path $dir '.git'
        if (Test-Path -LiteralPath $dotGit -PathType Container) {
            if (-not ([IO.File]::GetAttributes($dotGit) -band [IO.FileAttributes]::ReparsePoint)) { $dir }
        }
        if ($depth -ge $MaxDepth) { continue }

        try { $children = @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction Stop) } catch { continue }
        foreach ($c in $children) {
            if ($c.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($c.Name -eq '.git' -or $c.Name -eq 'node_modules') { continue }
            $stack.Push(@($c.FullName, ($depth + 1)))
        }
    }
}

function Get-GitObjectBytes {
    <#
    .SYNOPSIS
        Object storage size of a repository (loose + packed + garbage) from 'git count-objects -v'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Git, [Parameter(Mandatory)][string]$Repo)

    $r = Invoke-ExternalCommand -FilePath $Git -ArgumentList @('-C', $Repo, 'count-objects', '-v') -TimeoutSeconds 120
    if ($r.ExitCode -ne 0) { return $null }
    $kib = 0L
    $count = 0L
    foreach ($line in ($r.StdOut -split "`r?`n")) {
        if ($line -match '^(size|size-pack|size-garbage):\s*(\d+)$') { $kib += [long]$Matches[2] }
        if ($line -match '^count:\s*(\d+)$') { $count = [long]$Matches[1] }
    }
    [pscustomobject]@{ Bytes = $kib * 1KB; LooseObjects = $count }
}

function Invoke-GitMaintenance {
    <#
    .SYNOPSIS
        Runs a plain 'git gc' in every repository under -Root.
    .DESCRIPTION
        Plain gc only: no --aggressive, no --prune=now, so git's own safety windows for
        unreachable objects and the reflog still apply. A repository with a git operation in
        progress (index.lock, rebase, merge, cherry-pick, bisect) is skipped.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string[]]$Root,
        [switch]$DryRun
    )

    $category = 'git'
    $git = Get-ExternalToolPath -Name 'git'
    if (-not $git) {
        New-TargetResult -Label 'git gc' -Status 'Skipped' -Reason 'git is not installed' -Category $category
        return
    }

    $busyMarkers = 'index.lock', 'rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_LOG'

    foreach ($r in $Root) {
        if (-not (Test-Path -LiteralPath $r -PathType Container)) {
            New-TargetResult -Label "Project root $r" -Path $r -Status 'Skipped' -Reason 'folder not found' -Category $category
            continue
        }
        $full = (Resolve-Path -LiteralPath $r).ProviderPath.TrimEnd('\')
        if ($full -match '^[A-Za-z]:$') {
            New-TargetResult -Label "Project root $r" -Path $r -Status 'Skipped' -Reason 'a drive root is too broad - point -DevRoot at your projects folder' -Category $category
            continue
        }

        foreach ($repo in (Find-GitRepositories -Root $full)) {
            $label = 'git gc ' + $repo.Substring([Math]::Min($full.Length + 1, $repo.Length))
            if ($repo -eq $full) { $label = 'git gc ' + (Split-Path $repo -Leaf) }

            # gc rewrites .git, so the repository must be somewhere WinClean may modify at all
            # (a repo under Desktop / Documents / Downloads is refused like any other target)
            $verdict = Test-PathSafety -Path (Join-Path $repo '.git') -Detailed
            if (-not $verdict.IsSafe) {
                New-TargetResult -Label $label -Path $repo -Status 'Skipped' -Reason $verdict.Reason -Category $category
                continue
            }

            $busy = $busyMarkers | Where-Object { Test-Path -LiteralPath (Join-Path $repo ".git\$_") } | Select-Object -First 1
            if ($busy) {
                New-TargetResult -Label $label -Path $repo -Status 'Skipped' -Reason "git operation in progress ($busy)" -Category $category
                continue
            }

            $before = Get-GitObjectBytes -Git $git -Repo $repo
            if (-not $before) {
                New-TargetResult -Label $label -Path $repo -Status 'Skipped' -Reason 'git could not read the repository' -Category $category
                continue
            }

            if ($DryRun) {
                New-TargetResult -Label $label -Path $repo -Status 'Info' -Category $category -Reason (
                    'would run git gc ({0} loose objects, {1} in object storage)' -f $before.LooseObjects, (Format-Size $before.Bytes))
                continue
            }

            $gc = Invoke-ExternalCommand -FilePath $git -ArgumentList @('-C', $repo, 'gc', '--quiet') -TimeoutSeconds 1800
            if ($gc.TimedOut -or $gc.ExitCode -ne 0) {
                $why = 'git gc failed'
                if ($gc.TimedOut) { $why = 'git gc timed out' }
                elseif ($gc.StdErr) { $why += ': ' + ($gc.StdErr.Trim() -split "`n")[0] }
                New-TargetResult -Label $label -Path $repo -Status 'Skipped' -Reason $why -Category $category
                continue
            }

            $after = Get-GitObjectBytes -Git $git -Repo $repo
            $result = New-TargetResult -Label $label -Path $repo -Status 'Cleaned' -Category $category
            if ($after) { $result.Bytes = [Math]::Max(0L, $before.Bytes - $after.Bytes) }
            $result
        }
    }
}
