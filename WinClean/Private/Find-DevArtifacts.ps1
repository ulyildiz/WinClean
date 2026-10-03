function Get-DevArtifactRules {
    <#
    .SYNOPSIS
        The explicit allowlist of build-output folders WinClean may clean.
    .DESCRIPTION
        A folder is only a candidate when it sits next to the ecosystem's marker file AND
        its own contents prove it is tool output (Evidence). Folders whose name merely
        matches ('bin', 'build') are never enough.
          dotnet  bin / obj next to *.csproj|*.fsproj|*.vbproj   - Debug/Release output or NuGet restore files
          cmake   build next to CMakeLists.txt                    - contains CMakeCache.txt
          cmake   CMakeFiles next to CMakeLists.txt               - contains cmake.check_cache
          cargo   target next to Cargo.toml                       - contains Cargo's CACHEDIR.TAG
          node    build next to package.json                      - must be git-ignored (no
                                                                    structural proof exists)
    #>
    [CmdletBinding()]
    param()

    $hasAny = {
        param([string]$Dir, [string[]]$Names)
        foreach ($n in $Names) { if (Test-Path -LiteralPath (Join-Path $Dir $n)) { return $true } }
        return $false
    }

    @(
        [pscustomobject]@{
            Ecosystem = 'dotnet'; Markers = @('*.csproj', '*.fsproj', '*.vbproj'); Folder = 'bin'; RequireGitIgnored = $false
            Evidence  = { param($d) & $hasAny $d @('Debug', 'Release') }.GetNewClosure()
        }
        [pscustomobject]@{
            Ecosystem = 'dotnet'; Markers = @('*.csproj', '*.fsproj', '*.vbproj'); Folder = 'obj'; RequireGitIgnored = $false
            Evidence  = { param($d) & $hasAny $d @('project.assets.json', 'Debug', 'Release') }.GetNewClosure()
        }
        [pscustomobject]@{
            Ecosystem = 'cmake'; Markers = @('CMakeLists.txt'); Folder = 'build'; RequireGitIgnored = $false
            Evidence  = { param($d) & $hasAny $d @('CMakeCache.txt') }.GetNewClosure()
        }
        [pscustomobject]@{
            Ecosystem = 'cmake'; Markers = @('CMakeLists.txt'); Folder = 'CMakeFiles'; RequireGitIgnored = $false
            Evidence  = { param($d) & $hasAny $d @('cmake.check_cache') }.GetNewClosure()
        }
        [pscustomobject]@{
            Ecosystem = 'cargo'; Markers = @('Cargo.toml'); Folder = 'target'; RequireGitIgnored = $false
            Evidence  = {
                param($d)
                $tag = Join-Path $d 'CACHEDIR.TAG'
                (Test-Path -LiteralPath $tag -PathType Leaf) -and
                ((Get-Content -LiteralPath $tag -TotalCount 1 -ErrorAction SilentlyContinue) -match '^Signature: 8a477f597d28d172789f06886806bc55')
            }
        }
        [pscustomobject]@{
            Ecosystem = 'node'; Markers = @('package.json'); Folder = 'build'; RequireGitIgnored = $true
            Evidence  = { param($d) $true }
        }
    )
}

function Get-GitPathStatus {
    <#
    .SYNOPSIS
        Asks git whether a folder holds tracked files and whether it is ignored.
    .OUTPUTS
        InRepo ($false = not inside a work tree), HasTracked, IsIgnored, Error.
        Error is set when git is missing or cannot answer; callers must then fail safe.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $status = [pscustomobject]@{ InRepo = $false; HasTracked = $false; IsIgnored = $false; Error = $null }

    # Decided from the file system, not from git, so a missing or failing git can never
    # make a folder inside a repository look like an untracked one.
    $probe = Split-Path -Path $Path -Parent
    while ($probe) {
        if (Test-Path -LiteralPath (Join-Path $probe '.git')) { $status.InRepo = $true; break }
        $next = Split-Path -Path $probe -Parent
        if (-not $next -or $next -eq $probe) { break }
        $probe = $next
    }
    if (-not $status.InRepo) { return $status }

    $git = Get-ExternalToolPath -Name 'git'
    if (-not $git) { $status.Error = 'inside a git repository but git is not installed'; return $status }

    $parent = Split-Path -Path $Path -Parent
    $name = Split-Path -Path $Path -Leaf

    $tracked = Invoke-ExternalCommand -FilePath $git -ArgumentList @('-C', $parent, 'ls-files', '--', $name) -TimeoutSeconds 60
    if ($tracked.TimedOut -or $tracked.ExitCode -ne 0) {
        $detail = ''
        if ($tracked.StdErr) { $detail = ': ' + ($tracked.StdErr.Trim() -split "`n")[0] }
        $status.Error = 'git could not list tracked files' + $detail
        return $status
    }
    $status.HasTracked = -not [string]::IsNullOrWhiteSpace($tracked.StdOut)

    $ignored = Invoke-ExternalCommand -FilePath $git -ArgumentList @('-C', $parent, 'check-ignore', '-q', '--', $name) -TimeoutSeconds 30
    switch ($ignored.ExitCode) {
        0       { $status.IsIgnored = $true }
        1       { $status.IsIgnored = $false }
        default { $status.Error = 'git check-ignore failed' }
    }
    return $status
}

function Find-DevArtifacts {
    <#
    .SYNOPSIS
        Walks -Root looking for project marker files and returns the build-output folders
        next to them, each with a verdict (IsCandidate + Reason).
    .DESCRIPTION
        Discovery never follows junctions / symlinks, never descends into .git or
        node_modules, and stops at -MaxDepth. It does not delete anything.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [ValidateRange(1, 64)][int]$MaxDepth = 8
    )

    $rules = Get-DevArtifactRules
    $skipNames = @('.git', 'node_modules', '.vs', '.idea')
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push(@($Root, 0))
    while ($stack.Count -gt 0) {
        $frame = $stack.Pop()
        $dir = $frame[0]; $depth = $frame[1]
        try { $items = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop) } catch { continue }

        $files = @($items | Where-Object { -not $_.PSIsContainer } | ForEach-Object { $_.Name })
        $artifactDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

        foreach ($rule in $rules) {
            $marker = $null
            foreach ($pattern in $rule.Markers) {
                $marker = $files | Where-Object { $_ -like $pattern } | Select-Object -First 1
                if ($marker) { break }
            }
            if (-not $marker) { continue }

            $candidate = Join-Path $dir $rule.Folder
            if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
            if (-not $seen.Add($candidate)) { continue }   # e.g. 'build' claimed by both cmake and node
            [void]$artifactDirs.Add($rule.Folder)

            $artifact = [pscustomobject]@{
                PSTypeName  = 'WinClean.DevArtifact'
                Path        = $candidate
                ProjectDir  = $dir
                Marker      = $marker
                Ecosystem   = $rule.Ecosystem
                Folder      = $rule.Folder
                IsCandidate = $false
                Reason      = $null
            }

            $attributes = [IO.File]::GetAttributes($candidate)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
                $artifact.Reason = 'is a junction or symbolic link'
            }
            elseif (-not (& $rule.Evidence $candidate)) {
                $artifact.Reason = "no $($rule.Ecosystem) build evidence inside"
            }
            else {
                $git = Get-GitPathStatus -Path $candidate
                if ($git.Error)                                           { $artifact.Reason = $git.Error }
                elseif ($git.HasTracked)                                  { $artifact.Reason = 'contains files tracked by git' }
                elseif ($rule.RequireGitIgnored -and -not $git.IsIgnored) { $artifact.Reason = 'not git-ignored (cannot prove it is build output)' }
                else                                                      { $artifact.IsCandidate = $true }
            }
            $artifact
        }

        if ($depth -ge $MaxDepth) { continue }
        foreach ($item in $items) {
            if (-not $item.PSIsContainer) { continue }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($skipNames -contains $item.Name) { continue }
            if ($artifactDirs.Contains($item.Name)) { continue }   # never search inside build output
            $stack.Push(@($item.FullName, ($depth + 1)))
        }
    }
}
