function ConvertFrom-FileUri {
    <#
    .SYNOPSIS
        Converts a local file:// URI to an X:\ path, or $null for anything else.
    .DESCRIPTION
        VS Code writes 'file:///c%3A/Users/me/proj'. [Uri]::LocalPath leaves that as
        '/c:/Users/me/proj', which never exists - treating it as a path would make every
        live workspace look deleted. The drive form is therefore parsed explicitly.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Uri)

    $m = [regex]::Match($Uri, '^file:///(?<drive>[A-Za-z])(:|%3[Aa])(?<rest>/.*)?$')
    if (-not $m.Success) { return $null }

    $rest = ''
    if ($m.Groups['rest'].Success) { $rest = [Uri]::UnescapeDataString($m.Groups['rest'].Value).Replace('/', '\') }
    $path = $m.Groups['drive'].Value.ToUpperInvariant() + ':' + $rest
    if ($path.Length -le 3) { return $null }   # a bare drive is never a workspace we would judge
    if ($path -notmatch '^[A-Z]:\\[^\\]') { return $null }
    return $path.TrimEnd('\')
}

function Get-VSCodeOrphanedWorkspaces {
    <#
    .SYNOPSIS
        Lists VS Code workspaceStorage entries whose workspace folder no longer exists.
    .DESCRIPTION
        workspaceStorage holds per-workspace state (open editors, extension data, chat
        history), so only entries that are provably orphaned are returned. An entry is kept
        when its workspace.json is missing or unreadable, when it points at a remote / UNC
        location, or when its drive is not currently present (an unplugged USB disk is not
        a deleted project).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StorageRoot)

    if (-not (Test-Path -LiteralPath $StorageRoot -PathType Container)) { return }

    foreach ($dir in (Get-ChildItem -LiteralPath $StorageRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $json = Join-Path $dir.FullName 'workspace.json'
        if (-not (Test-Path -LiteralPath $json -PathType Leaf)) { continue }

        try { $ws = Get-Content -LiteralPath $json -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { continue }

        $uriText = $null
        foreach ($name in 'folder', 'workspace', 'configuration') {
            $p = $ws.PSObject.Properties[$name]
            if ($p -and $p.Value -is [string]) { $uriText = $p.Value; break }
        }
        if (-not $uriText) { continue }

        $local = ConvertFrom-FileUri -Uri $uriText
        if (-not $local) { continue }   # remote, UNC or unrecognised: keep
        if (-not (Test-Path -LiteralPath ($local.Substring(0, 3)))) { continue }   # drive not present
        if (Test-Path -LiteralPath $local) { continue }

        [pscustomobject]@{ Path = $dir.FullName; Workspace = $local }
    }
}

function Get-DevCacheTargets {
    <#
    .SYNOPSIS
        Lists existing package-manager and editor cache folders (explicit allowlist).
    .DESCRIPTION
        Tool-documented environment overrides are honoured. Deliberately NOT included:
          ~/.nuget/packages     a half-deleted package breaks builds until a full restore
          cargo registry/src    extracted files keep old archive timestamps while the
                                '.cargo-ok' marker is new, so age-based cleanup could leave
                                crates that look extracted but are missing files
          vcpkg buildtrees      same timestamp problem during a running build
    #>
    [CmdletBinding()]
    param(
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [string]$AppData      = $env:APPDATA,
        [string]$UserProfile  = $env:USERPROFILE
    )

    $list = New-Object 'System.Collections.Generic.List[object]'
    $add = {
        param([string]$Tool, [string]$Label, [string]$Path, [string]$Kind = 'cache')
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
        $list.Add([pscustomobject]@{ PSTypeName = 'WinClean.DevCacheTarget'; Tool = $Tool; Label = $Label; Path = $Path; Kind = $Kind })
    }

    # npm: content-addressable cache; cleaned between two 'npm cache verify' runs
    $npmCache = $env:npm_config_cache
    if (-not $npmCache) {
        $npm = Get-ExternalToolPath -Name 'npm'
        if ($npm) {
            $r = Invoke-ExternalCommand -FilePath $npm -ArgumentList @('config', 'get', 'cache') -TimeoutSeconds 30
            if ($r.ExitCode -eq 0 -and $r.StdOut.Trim()) { $npmCache = $r.StdOut.Trim() }
        }
    }
    if (-not $npmCache -and $LocalAppData) { $npmCache = Join-Path $LocalAppData 'npm-cache' }
    if ($npmCache) { & $add 'npm' 'npm cache' (Join-Path $npmCache '_cacache') }

    # pip: http + wheel cache
    $pip = $env:PIP_CACHE_DIR
    if (-not $pip -and $LocalAppData) { $pip = Join-Path $LocalAppData 'pip\cache' }
    & $add 'pip' 'pip cache' $pip

    # cargo: downloaded .crate archives only
    $cargo = $env:CARGO_HOME
    if (-not $cargo -and $UserProfile) { $cargo = Join-Path $UserProfile '.cargo' }
    if ($cargo) { & $add 'cargo' 'cargo registry downloads' (Join-Path $cargo 'registry\cache') }

    # NuGet: HTTP response cache only
    $nuget = $env:NUGET_HTTP_CACHE_PATH
    if (-not $nuget -and $LocalAppData) { $nuget = Join-Path $LocalAppData 'NuGet\v3-cache' }
    & $add 'nuget' 'NuGet HTTP cache' $nuget

    # vcpkg: binary cache archives and downloaded source archives
    $vcpkgArchives = $env:VCPKG_DEFAULT_BINARY_CACHE
    if (-not $vcpkgArchives -and $LocalAppData) { $vcpkgArchives = Join-Path $LocalAppData 'vcpkg\archives' }
    & $add 'vcpkg' 'vcpkg binary cache' $vcpkgArchives
    if ($env:VCPKG_ROOT) { & $add 'vcpkg' 'vcpkg downloads' (Join-Path $env:VCPKG_ROOT 'downloads') }

    # VS Code (stable + Insiders): Chromium caches and orphaned workspace storage
    if ($AppData) {
        foreach ($edition in 'Code', 'Code - Insiders') {
            $base = Join-Path $AppData $edition
            if (-not (Test-Path -LiteralPath $base -PathType Container)) { continue }
            foreach ($sub in 'Cache', 'CachedData', 'CachedExtensionVSIXs', 'Code Cache', 'GPUCache') {
                & $add 'vscode' "$edition - $sub" (Join-Path $base $sub)
            }
            foreach ($orphan in (Get-VSCodeOrphanedWorkspaces -StorageRoot (Join-Path $base 'User\workspaceStorage'))) {
                & $add 'vscode' "$edition workspace (deleted: $($orphan.Workspace))" $orphan.Path 'orphaned-workspace'
            }
        }
    }

    return $list.ToArray()
}
