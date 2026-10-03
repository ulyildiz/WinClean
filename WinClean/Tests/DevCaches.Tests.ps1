#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinClean.psd1') -Force

    # tool overrides on the developer's machine must not leak into these tests
    $script:overrides = 'npm_config_cache', 'PIP_CACHE_DIR', 'CARGO_HOME', 'NUGET_HTTP_CACHE_PATH', 'VCPKG_DEFAULT_BINARY_CACHE', 'VCPKG_ROOT'
    $script:savedEnv = @{}
    foreach ($n in $overrides) { $savedEnv[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null) }

    function New-File([string]$Path, [string]$Content = 'x', [double]$AgeDays = 30) {
        New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
        Set-Content -LiteralPath $Path -Value $Content
        (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddDays(-$AgeDays)
    }

    # VS Code's own format: lower-case drive, ':' escaped as %3A, '/' separators, spaces as %20
    function ConvertTo-VSCodeUri([string]$Path) {
        $p = $Path.Replace('\', '/')
        'file:///' + $p.Substring(0, 1).ToLowerInvariant() + '%3A' + [Uri]::EscapeUriString($p.Substring(2))
    }

    function New-Workspace([string]$Storage, [string]$Id, $WorkspaceJson) {
        $dir = Join-Path $Storage $Id
        New-File (Join-Path $dir 'state.vscdb')
        if ($null -ne $WorkspaceJson) { New-File (Join-Path $dir 'workspace.json') $WorkspaceJson }
        $dir
    }

    function New-CacheFixture {
        $base = Join-Path $TestDrive ('dev-' + [guid]::NewGuid().Guid.Substring(0, 8))
        $fx = [ordered]@{
            Base         = $base
            LocalAppData = "$base\Local"
            AppData      = "$base\Roaming"
            UserProfile  = "$base\Profile"
            Npm          = "$base\npm-cache"
        }
        $env:npm_config_cache = $fx.Npm

        New-File "$($fx.Npm)\_cacache\content-v2\sha512\aa\old"
        New-File "$($fx.Npm)\_cacache\content-v2\sha512\bb\fresh" -AgeDays 0
        New-File "$($fx.LocalAppData)\pip\cache\http-v2\old"
        New-File "$($fx.LocalAppData)\pip\cache\http-v2\fresh" -AgeDays 0
        New-File "$($fx.UserProfile)\.cargo\registry\cache\index\serde-1.0.crate"
        New-File "$($fx.UserProfile)\.cargo\registry\src\index\serde-1.0\src\lib.rs"
        New-File "$($fx.LocalAppData)\NuGet\v3-cache\abc\list_newtonsoft.dat"
        New-File "$($fx.UserProfile)\.nuget\packages\newtonsoft.json\13.0.1\lib.dll"
        New-File "$($fx.LocalAppData)\vcpkg\archives\ab\zlib.zip"

        $code = "$($fx.AppData)\Code"
        New-File "$code\Cache\Cache_Data\f_000001"
        New-File "$code\CachedData\abc123\chrome\js\x.code"
        New-File "$code\User\settings.json"
        New-File "$code\User\History\-1a2b\entries.json"

        $project = "$base\My Projects\live app"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        $missingDrive = [char[]](90..68) | ForEach-Object { [string]$_ } | Where-Object { -not (Test-Path "$($_):\") } | Select-Object -First 1

        $storage = "$code\User\workspaceStorage"
        $fx.Live      = New-Workspace $storage 'live'      ('{ "folder": "' + (ConvertTo-VSCodeUri $project) + '" }')
        $fx.Deleted   = New-Workspace $storage 'deleted'   ('{ "folder": "' + (ConvertTo-VSCodeUri "$base\My Projects\gone app") + '" }')
        $fx.WsFile    = New-Workspace $storage 'wsfile'    ('{ "workspace": "' + (ConvertTo-VSCodeUri "$base\gone.code-workspace") + '" }')
        $fx.Remote    = New-Workspace $storage 'remote'    '{ "folder": "vscode-remote://wsl%2Bubuntu/home/me/app" }'
        $fx.Unc       = New-Workspace $storage 'unc'       '{ "folder": "file://server/share/app" }'
        $fx.NoDrive   = New-Workspace $storage 'nodrive'   ('{ "folder": "file:///' + $missingDrive.ToLowerInvariant() + '%3A/usb/app" }')
        $fx.NoJson    = New-Workspace $storage 'nojson'    $null
        $fx.Broken    = New-Workspace $storage 'broken'    '{ "folder": '
        $fx.Project   = $project
        [pscustomobject]$fx
    }

    function Get-Targets($Fx) {
        InModuleScope WinClean -Parameters @{ F = $Fx } {
            Get-DevCacheTargets -LocalAppData $F.LocalAppData -AppData $F.AppData -UserProfile $F.UserProfile
        }
    }

    function Invoke-Cleanup($Targets, [int]$AgeHours = 168, [switch]$DryRun) {
        InModuleScope WinClean -Parameters @{ T = $Targets; A = $AgeHours; D = [bool]$DryRun } {
            Invoke-DevCacheCleanup -Target $T -AgeHours $A -DryRun:$D -WarningAction SilentlyContinue
        }
    }
}

AfterAll {
    foreach ($n in $overrides) { [Environment]::SetEnvironmentVariable($n, $savedEnv[$n]) }
    Remove-Module WinClean -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertFrom-FileUri' {
    It 'converts <Uri>' -ForEach @(
        @{ Uri = 'file:///c%3A/Users/me/My%20Proj'; Expected = 'C:\Users\me\My Proj' }
        @{ Uri = 'file:///C:/Users/me/app';         Expected = 'C:\Users\me\app' }
        @{ Uri = 'file:///d%3a/src/app/';           Expected = 'D:\src\app' }
    ) {
        InModuleScope WinClean -Parameters @{ U = $Uri } { ConvertFrom-FileUri -Uri $U } | Should -BeExactly $Expected
    }

    It 'returns nothing for <Uri>' -ForEach @(
        @{ Uri = 'vscode-remote://wsl%2Bubuntu/home/me' }
        @{ Uri = 'file://server/share/app' }
        @{ Uri = 'file:///c%3A/' }
        @{ Uri = 'file:///c%3A' }
        @{ Uri = '/c:/Users/me' }
        @{ Uri = 'C:\Users\me' }
    ) {
        InModuleScope WinClean -Parameters @{ U = $Uri } { ConvertFrom-FileUri -Uri $U } | Should -BeNullOrEmpty
    }
}

Describe 'Get-DevCacheTargets' {
    BeforeAll {
        $script:fx = New-CacheFixture
        $script:targets = Get-Targets $fx
    }

    It 'finds the package-manager caches' {
        $targets.Path | Should -Contain "$($fx.Npm)\_cacache"
        $targets.Path | Should -Contain "$($fx.LocalAppData)\pip\cache"
        $targets.Path | Should -Contain "$($fx.UserProfile)\.cargo\registry\cache"
        $targets.Path | Should -Contain "$($fx.LocalAppData)\NuGet\v3-cache"
        $targets.Path | Should -Contain "$($fx.LocalAppData)\vcpkg\archives"
    }

    It 'never offers <Name>' -ForEach @(
        @{ Name = 'cargo extracted sources'; Rel = 'Profile\.cargo\registry\src' }
        @{ Name = 'NuGet global packages';   Rel = 'Profile\.nuget\packages' }
        @{ Name = 'VS Code settings';        Rel = 'Roaming\Code\User' }
        @{ Name = 'VS Code local history';   Rel = 'Roaming\Code\User\History' }
    ) {
        $targets.Path | Should -Not -Contain (Join-Path $fx.Base $Rel)
    }

    It 'finds the VS Code caches that exist' {
        $targets.Path | Should -Contain "$($fx.AppData)\Code\Cache"
        $targets.Path | Should -Contain "$($fx.AppData)\Code\CachedData"
    }

    It 'marks only workspaces whose folder is provably gone as orphaned' {
        $orphans = @($targets | Where-Object Kind -eq 'orphaned-workspace')
        @($orphans.Path | Sort-Object) | Should -Be @(@($fx.Deleted, $fx.WsFile) | Sort-Object)
    }

    It 'keeps a live workspace stored in VS Code''s c%3A format (regression)' {
        $targets.Path | Should -Not -Contain $fx.Live
    }

    It 'keeps <Name> workspaces' -ForEach @(
        @{ Name = 'remote';                  Key = 'Remote' }
        @{ Name = 'UNC';                     Key = 'Unc' }
        @{ Name = 'missing-drive';           Key = 'NoDrive' }
        @{ Name = 'workspace.json-less';     Key = 'NoJson' }
        @{ Name = 'unreadable workspace.json'; Key = 'Broken' }
    ) {
        $targets.Path | Should -Not -Contain $fx.$Key
    }

    It 'honours tool cache overrides (PIP_CACHE_DIR)' {
        $custom = Join-Path $fx.Base 'custom-pip'
        New-File "$custom\http-v2\x"
        $env:PIP_CACHE_DIR = $custom
        try { (Get-Targets $fx | Where-Object Tool -eq 'pip').Path | Should -Be $custom }
        finally { $env:PIP_CACHE_DIR = $null }
    }

    It 'only returns folders that pass Test-PathSafety on this machine' {
        $real = InModuleScope WinClean { Get-DevCacheTargets }
        foreach ($t in $real) {
            InModuleScope WinClean -Parameters @{ P = $t.Path } { Test-PathSafety -Path $P } | Should -BeTrue -Because $t.Path
        }
    }
}

Describe 'Invoke-DevCacheCleanup' {
    BeforeEach {
        $script:fx = New-CacheFixture
        Mock -ModuleName WinClean Get-ExternalToolPath { 'C:\fake\npm.cmd' } -ParameterFilter { $Name -eq 'npm' }
        Mock -ModuleName WinClean Invoke-ExternalCommand { [pscustomobject]@{ ExitCode = 0; TimedOut = $false; StdOut = ''; StdErr = ''; Started = $true } }
        $script:targets = Get-Targets $fx
    }

    It '-DryRun deletes nothing and never runs npm' {
        $before = @(Get-ChildItem -LiteralPath $fx.Base -Recurse -File -Force).Count
        $r = Invoke-Cleanup $targets -DryRun
        ($r | Where-Object Status -eq 'WouldClean').Count | Should -BeGreaterThan 5
        @(Get-ChildItem -LiteralPath $fx.Base -Recurse -File -Force).Count | Should -Be $before
        Should -Invoke -ModuleName WinClean Invoke-ExternalCommand -Times 0 -Exactly
    }

    It 'removes stale cache files and keeps fresh ones' {
        Invoke-Cleanup $targets | Out-Null
        Test-Path "$($fx.LocalAppData)\pip\cache\http-v2\old"   | Should -BeFalse
        Test-Path "$($fx.LocalAppData)\pip\cache\http-v2\fresh" | Should -BeTrue
        Test-Path "$($fx.UserProfile)\.cargo\registry\cache\index\serde-1.0.crate" | Should -BeFalse
        Test-Path "$($fx.UserProfile)\.cargo\registry\src\index\serde-1.0\src\lib.rs" | Should -BeTrue
        Test-Path "$($fx.UserProfile)\.nuget\packages\newtonsoft.json\13.0.1\lib.dll" | Should -BeTrue
        Test-Path "$($fx.AppData)\Code\User\settings.json" | Should -BeTrue
    }

    It 'removes orphaned workspace folders entirely and keeps live ones' {
        Invoke-Cleanup $targets | Out-Null
        Test-Path -LiteralPath $fx.Deleted | Should -BeFalse
        Test-Path -LiteralPath $fx.WsFile  | Should -BeFalse
        foreach ($k in 'Live', 'Remote', 'Unc', 'NoDrive', 'NoJson', 'Broken') {
            Test-Path -LiteralPath (Join-Path $fx.$k 'state.vscdb') | Should -BeTrue -Because "$k must be kept"
        }
    }

    It 'keeps an orphaned workspace that was used recently' {
        New-File (Join-Path $fx.Deleted 'recent.json') -AgeDays 0
        $r = Invoke-Cleanup $targets | Where-Object Path -eq $fx.Deleted
        $r.Status | Should -Be 'Skipped'
        Test-Path -LiteralPath (Join-Path $fx.Deleted 'state.vscdb') | Should -BeTrue
    }

    It 'runs npm cache verify before and after cleaning the npm cache' {
        Invoke-Cleanup @($targets | Where-Object Tool -eq 'npm') | Out-Null
        Should -Invoke -ModuleName WinClean Invoke-ExternalCommand -Times 2 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq 'cache verify' }
        Test-Path "$($fx.Npm)\_cacache\content-v2\sha512\aa\old"   | Should -BeFalse
        Test-Path "$($fx.Npm)\_cacache\content-v2\sha512\bb\fresh" | Should -BeTrue
    }

    It 'leaves the npm cache alone when npm cache verify fails' {
        Mock -ModuleName WinClean Invoke-ExternalCommand { [pscustomobject]@{ ExitCode = 1; TimedOut = $false; StdOut = ''; StdErr = 'EPERM'; Started = $true } }
        $r = Invoke-Cleanup @($targets | Where-Object Tool -eq 'npm')
        $r.Status | Should -Be 'Skipped'
        $r.Reason | Should -Match 'verify failed'
        Test-Path "$($fx.Npm)\_cacache\content-v2\sha512\aa\old" | Should -BeTrue
    }

    It 'leaves the npm cache alone when npm is not installed' {
        Mock -ModuleName WinClean Get-ExternalToolPath { $null } -ParameterFilter { $Name -eq 'npm' }
        $r = Invoke-Cleanup @($targets | Where-Object Tool -eq 'npm')
        $r.Status | Should -Be 'Skipped'
        Test-Path "$($fx.Npm)\_cacache\content-v2\sha512\aa\old" | Should -BeTrue
    }
}
