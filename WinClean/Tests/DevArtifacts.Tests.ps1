#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeDiscovery {
    $script:hasGit = [bool](Get-Command git.exe -ErrorAction SilentlyContinue)
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinClean.psd1') -Force
    # Invoke-WinClean logs every run; keep test runs out of the real %LOCALAPPDATA% log
    Mock -ModuleName WinClean Get-RunLogPath { Join-Path $TestDrive 'run-log.json' }
    $script:hasGit = [bool](Get-Command git.exe -ErrorAction SilentlyContinue)

    function New-File([string]$Path, [string]$Content = 'x', [int]$AgeDays = 30) {
        New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
        Set-Content -LiteralPath $Path -Value $Content
        (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddDays(-$AgeDays)
    }

    function Invoke-Git([string]$Repo) {
        # PS 5.1 turns native stderr into error records; git warnings must not abort the fixture
        $ErrorActionPreference = 'Continue'
        & git.exe -C $Repo -c user.name=WinCleanTest -c user.email=test@example.invalid -c core.autocrlf=false @args 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git $args failed in $Repo" }
    }

    # Builds a projects folder with real and fake build-output folders. Returns its path.
    function New-DevFixture {
        $root = Join-Path $TestDrive ('projects-' + [guid]::NewGuid().Guid.Substring(0, 8))
        $tag = 'Signature: 8a477f597d28d172789f06886806bc55'

        New-File "$root\dotnet\App.csproj"
        New-File "$root\dotnet\bin\Debug\app.dll"
        New-File "$root\dotnet\obj\project.assets.json"
        New-File "$root\dotnet\src\Program.cs"

        New-File "$root\no-marker\bin\tool.exe"                    # 'bin' without a project file
        New-File "$root\dotnet-no-evidence\Lib.csproj"
        New-File "$root\dotnet-no-evidence\bin\readme.txt"         # no Debug/Release inside

        New-File "$root\cmake\CMakeLists.txt"
        New-File "$root\cmake\build\CMakeCache.txt"
        New-File "$root\cmake\build\main.o"
        New-File "$root\cmake\CMakeFiles\cmake.check_cache"
        New-File "$root\cmake-hand-made\CMakeLists.txt"
        New-File "$root\cmake-hand-made\build\build-notes.md"      # a source folder named build

        New-File "$root\rust\Cargo.toml"
        New-File "$root\rust\target\CACHEDIR.TAG" $tag
        New-File "$root\rust\target\debug\app.exe"
        New-File "$root\rust-fake-tag\Cargo.toml"
        New-File "$root\rust-fake-tag\target\CACHEDIR.TAG" 'not a cache'
        New-File "$root\rust-fake-tag\target\keep.txt"

        New-File "$root\node-no-git\package.json"
        New-File "$root\node-no-git\build\app.js"

        New-File "$root\node-modules-test\node_modules\pkg\App.csproj"  # never searched
        New-File "$root\node-modules-test\node_modules\pkg\bin\Debug\x.dll"

        if ($hasGit) {
            $repo = "$root\repo"
            New-Item -ItemType Directory -Path $repo -Force | Out-Null
            Invoke-Git $repo init -q
            New-File "$repo\.gitignore" "build/`nbin/`nobj/" -AgeDays 0
            New-File "$repo\web\package.json"
            New-File "$repo\web\build\bundle.js"
            New-File "$repo\scripts\package.json"
            New-File "$repo\scripts\build\deploy.js"                # tracked build scripts
            New-File "$repo\tracked\App.csproj"
            New-File "$repo\tracked\bin\Debug\vendored.dll"         # force-added to git
            Invoke-Git $repo add .gitignore web/package.json scripts tracked/App.csproj
            Invoke-Git $repo add -f scripts/build/deploy.js tracked/bin/Debug/vendored.dll
            Invoke-Git $repo commit -q -m fixture
        }

        # a junction inside the projects folder that points at a project elsewhere
        $outside = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().Guid.Substring(0, 8))
        New-File "$outside\App.csproj"
        New-File "$outside\bin\Debug\precious.dll"
        New-Item -ItemType Junction -Path "$root\linked" -Target $outside | Out-Null

        [pscustomobject]@{ Root = $root; Outside = $outside }
    }

    function Remove-DevFixture($Fixture) {
        # drop the junction itself first so no cleanup can ever walk through it
        $link = Join-Path $Fixture.Root 'linked'
        if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link, $false) }
    }

    function Find-Artifacts([string]$Root) {
        InModuleScope WinClean -Parameters @{ R = $Root } { Find-DevArtifacts -Root $R }
    }

    function Invoke-ArtifactCleanup([string[]]$Root, [int]$AgeHours = 168, [switch]$DryRun) {
        InModuleScope WinClean -Parameters @{ R = $Root; A = $AgeHours; D = [bool]$DryRun } {
            Invoke-DevArtifactCleanup -Root $R -AgeHours $A -DryRun:$D -WarningAction SilentlyContinue
        }
    }

    function Get-Relative($Items, [string]$Root) {
        @($Items | ForEach-Object { $_.Path.Substring($Root.Length + 1) } | Sort-Object)
    }
}

AfterAll {
    Remove-Module WinClean -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ArgumentString' {
    It 'quotes <Name>' -ForEach @(
        @{ Name = 'plain arguments';        In = @('gc', '--quiet');              Out = 'gc --quiet' }
        @{ Name = 'spaces';                 In = @('-C', 'C:\My Repos\a b');      Out = '-C "C:\My Repos\a b"' }
        @{ Name = 'empty argument';         In = @('a', '');                      Out = 'a ""' }
        @{ Name = 'embedded quotes';        In = @('say "hi"');                   Out = '"say \"hi\""' }
        @{ Name = 'trailing backslash';     In = @('C:\a b\');                    Out = '"C:\a b\\"' }
        @{ Name = 'backslash before quote'; In = @('a\"b c');                     Out = '"a\\\"b c"' }
    ) {
        InModuleScope WinClean -Parameters @{ A = $In } { ConvertTo-ArgumentString -ArgumentList $A } | Should -BeExactly $Out
    }
}

Describe 'Invoke-ExternalCommand' {
    It 'captures output and exit code' {
        $r = InModuleScope WinClean { Invoke-ExternalCommand -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList @('/c', 'echo hello & exit 3') }
        $r.StdOut.Trim() | Should -Be 'hello'
        $r.ExitCode | Should -Be 3
        $r.TimedOut | Should -BeFalse
    }

    It 'kills a process that exceeds the timeout' {
        $r = InModuleScope WinClean { Invoke-ExternalCommand -FilePath "$env:SystemRoot\System32\PING.EXE" -ArgumentList @('-n', '30', '127.0.0.1') -TimeoutSeconds 1 }
        $r.TimedOut | Should -BeTrue
        $r.ExitCode | Should -BeNullOrEmpty
    }

    It 'reports a missing program instead of throwing' {
        $r = InModuleScope WinClean { Invoke-ExternalCommand -FilePath 'C:\nope\missing-tool.exe' }
        $r.Started | Should -BeFalse
        $r.Error   | Should -Not -BeNullOrEmpty
    }
}

Describe 'Find-DevArtifacts' {
    BeforeAll {
        $script:fx = New-DevFixture
        $script:found = Find-Artifacts $fx.Root
    }
    AfterAll { Remove-DevFixture $fx }

    It 'accepts only folders that are provably build output' {
        $expected = @('cmake\build', 'cmake\CMakeFiles', 'dotnet\bin', 'dotnet\obj', 'rust\target')
        if ($hasGit) { $expected += 'repo\web\build' }
        Get-Relative ($found | Where-Object IsCandidate) $fx.Root | Should -Be @($expected | Sort-Object)
    }

    It 'rejects <Folder>: <Reason>' -ForEach @(
        @{ Folder = 'dotnet-no-evidence\bin'; Reason = 'no dotnet build evidence' }
        @{ Folder = 'cmake-hand-made\build';  Reason = 'no cmake build evidence' }
        @{ Folder = 'rust-fake-tag\target';   Reason = 'no cargo build evidence' }
        @{ Folder = 'node-no-git\build';      Reason = 'not git-ignored' }
    ) {
        $a = $found | Where-Object { $_.Path -eq (Join-Path $fx.Root $Folder) }
        $a | Should -Not -BeNullOrEmpty
        $a.IsCandidate | Should -BeFalse
        $a.Reason | Should -Match $Reason
    }

    It 'rejects build folders that contain git-tracked files (<Folder>)' -Skip:(-not $hasGit) -ForEach @(
        @{ Folder = 'repo\scripts\build' }
        @{ Folder = 'repo\tracked\bin' }
    ) {
        $a = $found | Where-Object { $_.Path -eq (Join-Path $fx.Root $Folder) }
        $a.IsCandidate | Should -BeFalse
        $a.Reason | Should -Match 'tracked by git'
    }

    It 'ignores folders named like build output when there is no project marker' {
        $found.Path | Should -Not -Contain (Join-Path $fx.Root 'no-marker\bin')
    }

    It 'never searches node_modules' {
        $found.Path | Where-Object { $_ -like '*node_modules*' } | Should -BeNullOrEmpty
    }

    It 'never follows a junction during discovery' {
        $found.Path | Where-Object { $_ -like '*\linked\*' } | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DevArtifactCleanup' {
    BeforeEach { $script:fx = New-DevFixture }
    AfterEach  { Remove-DevFixture $fx }

    It '-DryRun reports the candidates and deletes nothing' {
        $before = @(Get-ChildItem -LiteralPath $fx.Root -Recurse -File -Force).Count
        $results = Invoke-ArtifactCleanup $fx.Root -DryRun
        ($results | Where-Object Status -eq 'WouldClean').Count | Should -BeGreaterOrEqual 5
        @(Get-ChildItem -LiteralPath $fx.Root -Recurse -File -Force).Count | Should -Be $before
    }

    It 'empties the candidates and leaves everything else alone' {
        Invoke-ArtifactCleanup $fx.Root | Out-Null

        foreach ($gone in 'dotnet\bin\Debug\app.dll', 'dotnet\obj\project.assets.json', 'cmake\build\main.o', 'rust\target\debug\app.exe') {
            Test-Path -LiteralPath (Join-Path $fx.Root $gone) | Should -BeFalse -Because "$gone is build output"
        }
        foreach ($kept in 'dotnet\App.csproj', 'dotnet\src\Program.cs', 'no-marker\bin\tool.exe', 'dotnet-no-evidence\bin\readme.txt',
                          'cmake-hand-made\build\build-notes.md', 'rust-fake-tag\target\keep.txt', 'node-no-git\build\app.js') {
            Test-Path -LiteralPath (Join-Path $fx.Root $kept) | Should -BeTrue -Because "$kept is not provably build output"
        }
        Test-Path -LiteralPath (Join-Path $fx.Outside 'bin\Debug\precious.dll') | Should -BeTrue -Because 'junction targets are never touched'
    }

    It 'never deletes git-tracked files and cleans git-ignored npm output' -Skip:(-not $hasGit) {
        Invoke-ArtifactCleanup $fx.Root | Out-Null
        Test-Path -LiteralPath (Join-Path $fx.Root 'repo\scripts\build\deploy.js') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fx.Root 'repo\tracked\bin\Debug\vendored.dll') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fx.Root 'repo\web\build\bundle.js') | Should -BeFalse
    }

    It 'leaves a whole artifact folder alone when anything in it is recent' {
        New-File (Join-Path $fx.Root 'dotnet\obj\fresh.cache') -AgeDays 0
        $r = Invoke-ArtifactCleanup $fx.Root | Where-Object { $_.Path -eq (Join-Path $fx.Root 'dotnet\obj') }
        $r.Status | Should -Be 'Skipped'
        $r.Reason | Should -Match 'built within'
        Test-Path -LiteralPath (Join-Path $fx.Root 'dotnet\obj\project.assets.json') | Should -BeTrue
    }

    It 'refuses a drive root as project root' {
        $r = Invoke-ArtifactCleanup 'C:\' -DryRun
        $r.Status | Should -Be 'Skipped'
        $r.Reason | Should -Match 'drive root'
    }

    It 'refuses a junction as project root' {
        $r = Invoke-ArtifactCleanup (Join-Path $fx.Root 'linked') -DryRun
        $r.Status | Should -Be 'Skipped'
        $r.Reason | Should -Match 'junction'
    }

    It 'reports a missing project root' {
        (Invoke-ArtifactCleanup (Join-Path $TestDrive 'nope') -DryRun).Reason | Should -Match 'not found'
    }
}

Describe 'Invoke-WinClean -IncludeDev (build artifacts)' {
    BeforeAll {
        Mock -ModuleName WinClean Write-Host { }
        $script:emptyConfig = Join-Path $TestDrive 'empty.json'
        Set-Content -LiteralPath $emptyConfig -Value '{ "extendDefaults": false, "targets": [] }'
    }
    BeforeEach { $script:fx = New-DevFixture }
    AfterEach  { Remove-DevFixture $fx }

    It 'includes stale build output in a dry run' {
        $run = Invoke-WinClean -DryRun -IncludeDev -DevRoot $fx.Root -ConfigPath $emptyConfig -SkipBrowsers -SkipUpdateCache -SkipRam -PassThru
        $art = @($run.Targets | Where-Object Category -eq 'dev-artifact')
        ($art | Where-Object Status -eq 'WouldClean').Count | Should -BeGreaterOrEqual 5
        $run.FilesRemoved | Should -BeGreaterThan 0
    }

    It 'does nothing with build output unless -IncludeDev is given' {
        $run = Invoke-WinClean -DryRun -DevRoot $fx.Root -ConfigPath $emptyConfig -SkipBrowsers -SkipUpdateCache -SkipRam -PassThru
        $run.Targets | Where-Object Category -eq 'dev-artifact' | Should -BeNullOrEmpty
    }

    It 'skips build output with a hint when -DevRoot is missing' {
        $run = Invoke-WinClean -DryRun -IncludeDev -ConfigPath $emptyConfig -SkipBrowsers -SkipUpdateCache -SkipRam -PassThru
        $run.Targets | Where-Object Category -eq 'dev-artifact' | Should -BeNullOrEmpty
        Should -Invoke -ModuleName WinClean Write-Host -ParameterFilter { "$Object" -match '-DevRoot' }
    }
}
