#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeDiscovery {
    $script:hasGit = [bool](Get-Command git.exe -ErrorAction SilentlyContinue)
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinClean.psd1') -Force
    # Invoke-WinClean logs every run; keep test runs out of the real %LOCALAPPDATA% log
    Mock -ModuleName WinClean Get-RunLogPath { Join-Path $TestDrive 'run-log.json' }

    function Invoke-Git([string]$Repo) {
        # PS 5.1 turns native stderr into error records; git warnings must not abort the fixture
        $ErrorActionPreference = 'Continue'
        & git.exe -C $Repo -c user.name=WinCleanTest -c user.email=test@example.invalid -c core.autocrlf=false -c gc.auto=0 @args 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git $args failed in $Repo" }
    }

    function New-Repo([string]$Path, [int]$Commits = 20) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Invoke-Git $Path init -q
        Invoke-Git $Path config gc.auto 0          # keep the loose objects until our gc runs
        for ($i = 0; $i -lt $Commits; $i++) {
            Set-Content -LiteralPath (Join-Path $Path "file$i.txt") -Value ("content $i " * 50)
            Invoke-Git $Path add -A
            Invoke-Git $Path commit -q -m "commit $i"
        }
        $Path
    }

    function Get-LooseCount([string]$Repo) {
        $line = (& git.exe -C $Repo count-objects -v) | Where-Object { $_ -match '^count:' }
        [int]($line -replace '\D', '')
    }

    function Invoke-InModule([scriptblock]$Script, [hashtable]$Parameters = @{}) {
        InModuleScope WinClean -ScriptBlock $Script -Parameters $Parameters
    }

    function New-CmdResult([int]$ExitCode = 0, [string]$StdOut = '', [switch]$TimedOut) {
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $StdOut; StdErr = ''; TimedOut = [bool]$TimedOut; Started = $true }
    }
}

AfterAll {
    Remove-Module WinClean -Force -ErrorAction SilentlyContinue
}

Describe 'Find-GitRepositories' -Skip:(-not $hasGit) {
    BeforeAll {
        $script:root = Join-Path $TestDrive 'repos'
        New-Repo "$root\alpha" 1 | Out-Null
        New-Repo "$root\group\beta" 1 | Out-Null
        New-Repo "$root\alpha\vendor\nested" 1 | Out-Null
        New-Item -ItemType Directory -Path "$root\worktree" -Force | Out-Null
        Set-Content -LiteralPath "$root\worktree\.git" -Value 'gitdir: C:/elsewhere/.git/worktrees/w'
        New-Repo "$root\web\node_modules\pkg" 1 | Out-Null
        $script:outsideRepo = New-Repo (Join-Path $TestDrive 'outside-repo') 1
        New-Item -ItemType Junction -Path "$root\linked" -Target $outsideRepo | Out-Null
        $script:found = @(Invoke-InModule { Find-GitRepositories -Root $R } @{ R = $root } | Sort-Object)
    }
    AfterAll { [IO.Directory]::Delete("$root\linked", $false) }

    It 'finds repositories, including nested ones' {
        $found | Should -Be @("$root\alpha", "$root\alpha\vendor\nested", "$root\group\beta")
    }

    It 'ignores .git files, node_modules and junctions' {
        $found | Should -Not -Contain "$root\worktree"
        $found | Should -Not -Contain "$root\web\node_modules\pkg"
        $found | Should -Not -Contain "$root\linked"
    }
}

Describe 'Invoke-GitMaintenance' -Skip:(-not $hasGit) {
    BeforeEach {
        $script:root = Join-Path $TestDrive ('gc-' + [guid]::NewGuid().Guid.Substring(0, 8))
        $script:repo = New-Repo "$root\app"
    }

    It '-DryRun reports the repository without touching it' {
        $loose = Get-LooseCount $repo
        $loose | Should -BeGreaterThan 0
        $r = Invoke-InModule { Invoke-GitMaintenance -Root $R -DryRun } @{ R = $root }
        $r.Status | Should -Be 'Info'
        $r.Reason | Should -Match "would run git gc \($loose loose objects"
        Get-LooseCount $repo | Should -Be $loose
    }

    It 'packs loose objects with a plain git gc' {
        $r = Invoke-InModule { Invoke-GitMaintenance -Root $R } @{ R = $root }
        $r.Status | Should -Be 'Cleaned'
        Get-LooseCount $repo | Should -Be 0
        & git.exe -C $repo log --oneline | Should -HaveCount 20
    }

    It 'never uses --aggressive or --prune=now' {
        Mock -ModuleName WinClean Invoke-ExternalCommand { New-CmdResult -StdOut "count: 1`nsize: 4`nsize-pack: 0`nsize-garbage: 0" }
        Invoke-InModule { Invoke-GitMaintenance -Root $R } @{ R = $root } | Out-Null
        Should -Invoke -ModuleName WinClean Invoke-ExternalCommand -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains 'gc' }
        Should -Invoke -ModuleName WinClean Invoke-ExternalCommand -Times 0 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match 'aggressive|prune' }
    }

    It 'skips a repository with <Marker> (operation in progress)' -ForEach @(
        @{ Marker = 'index.lock' }
        @{ Marker = 'MERGE_HEAD' }
        @{ Marker = 'rebase-merge' }
    ) {
        $loose = Get-LooseCount $repo
        if ($Marker -eq 'rebase-merge') { New-Item -ItemType Directory -Path "$repo\.git\$Marker" | Out-Null }
        else { Set-Content -LiteralPath "$repo\.git\$Marker" -Value '' }
        $r = Invoke-InModule { Invoke-GitMaintenance -Root $R } @{ R = $root }
        $r.Status | Should -Be 'Skipped'
        $r.Reason | Should -Match $Marker
        Get-LooseCount $repo | Should -Be $loose
    }

    It 'refuses repositories in protected locations (e.g. Desktop) without running gc' {
        Mock -ModuleName WinClean Test-PathSafety { [pscustomobject]@{ IsSafe = $false; Reason = 'Path is inside protected location: Desktop' } }
        Mock -ModuleName WinClean Invoke-ExternalCommand { New-CmdResult }
        $r = Invoke-InModule { Invoke-GitMaintenance -Root $R } @{ R = $root }
        $r.Status | Should -Be 'Skipped'
        $r.Reason | Should -Match 'Desktop'
        Should -Invoke -ModuleName WinClean Invoke-ExternalCommand -Times 0 -Exactly
    }

    It 'checks the real Desktop location with Test-PathSafety' {
        $desktopRepo = Join-Path ([Environment]::GetFolderPath('Desktop')) 'some-repo\.git'
        (Invoke-InModule { Test-PathSafety -Path $P } @{ P = $desktopRepo }) | Should -BeFalse
    }

    It 'reports a missing git instead of failing' {
        Mock -ModuleName WinClean Get-ExternalToolPath { $null }
        $r = Invoke-InModule { Invoke-GitMaintenance -Root $R } @{ R = $root }
        $r.Status | Should -Be 'Skipped'
        $r.Reason | Should -Match 'not installed'
    }

    It 'refuses a drive root' {
        (Invoke-InModule { Invoke-GitMaintenance -Root 'C:\' -DryRun }).Reason | Should -Match 'drive root'
    }
}

Describe 'ConvertFrom-DockerSize' {
    It 'parses <Text>' -ForEach @(
        @{ Text = '0B';      Bytes = 0 }
        @{ Text = '512B';    Bytes = 512 }
        @{ Text = '12.3kB';  Bytes = 12300 }
        @{ Text = '456MB';   Bytes = 456000000 }
        @{ Text = '1.23GB';  Bytes = 1230000000 }
        @{ Text = ' 2TB ';   Bytes = 2000000000000 }
    ) {
        Invoke-InModule { ConvertFrom-DockerSize -Text $T } @{ T = $Text } | Should -Be $Bytes
    }

    It 'returns nothing for <Text>' -ForEach @(@{ Text = '' }, @{ Text = 'N/A' }, @{ Text = '12 parsecs' }) {
        Invoke-InModule { ConvertFrom-DockerSize -Text $T } @{ T = $Text } | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DockerMaintenance' {
    BeforeEach {
        Mock -ModuleName WinClean Get-ExternalToolPath { 'C:\fake\docker.exe' } -ParameterFilter { $Name -eq 'docker' }
        Mock -ModuleName WinClean Invoke-ExternalCommand { New-CmdResult -StdOut '27.1.1' }                    -ParameterFilter { $ArgumentList[0] -eq 'version' }
        Mock -ModuleName WinClean Invoke-ExternalCommand { New-CmdResult -StdOut "aaa|1.5GB`nbbb|500MB`n" }    -ParameterFilter { $ArgumentList[0] -eq 'image' -and $ArgumentList[1] -eq 'ls' }
        Mock -ModuleName WinClean Invoke-ExternalCommand { New-CmdResult -StdOut "Deleted Images:`ndeleted: sha256:aaa`n`nTotal reclaimed space: 1.9GB" } -ParameterFilter { $ArgumentList[1] -eq 'prune' }
    }

    It 'only reports without -Prune' {
        $r = Invoke-InModule { Invoke-DockerMaintenance }
        $r.Status | Should -Be 'Info'
        # 1.5GB + 500MB in Docker's decimal units = 2e9 bytes = 1.86 GB in Format-Size's binary units
        $r.Reason | Should -Match '2 dangling image\(s\), up to 1\.86 GB.*-ConfirmDockerPrune'
        Should -Invoke -ModuleName WinClean Invoke-ExternalCommand -Times 0 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'prune' }
    }

    It 'does not prune in a dry run, even with -Prune' {
        $r = Invoke-InModule { Invoke-DockerMaintenance -Prune -DryRun }
        $r.Status | Should -Be 'Info'
        $r.Reason | Should -Match 'would run docker image prune'
        Should -Invoke -ModuleName WinClean Invoke-ExternalCommand -Times 0 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'prune' }
    }

    It 'prunes dangling images only (never --all) and reports the reclaimed space' {
        $r = Invoke-InModule { Invoke-DockerMaintenance -Prune }
        $r.Status | Should -Be 'Cleaned'
        $r.Bytes  | Should -Be 1900000000
        Should -Invoke -ModuleName WinClean Invoke-ExternalCommand -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq 'image prune --force' }
    }

    It 'does nothing when the daemon <Name>' -ForEach @(
        @{ Name = 'times out';     Result = { New-CmdResult -TimedOut } }
        @{ Name = 'returns error'; Result = { New-CmdResult -ExitCode 1 } }
        @{ Name = 'gives no version'; Result = { New-CmdResult -StdOut '' } }
    ) {
        Mock -ModuleName WinClean Invoke-ExternalCommand $Result -ParameterFilter { $ArgumentList[0] -eq 'version' }
        $r = Invoke-InModule { Invoke-DockerMaintenance -Prune }
        $r.Status | Should -Be 'Skipped'
        $r.Reason | Should -Match 'not responding'
        Should -Invoke -ModuleName WinClean Invoke-ExternalCommand -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'image' }
    }

    It 'stays silent when docker is not installed, unless pruning was requested' {
        Mock -ModuleName WinClean Get-ExternalToolPath { $null } -ParameterFilter { $Name -eq 'docker' }
        Invoke-InModule { Invoke-DockerMaintenance } | Should -BeNullOrEmpty
        (Invoke-InModule { Invoke-DockerMaintenance -Prune }).Reason | Should -Match 'not found'
    }

    It 'reports when there is nothing to prune' {
        Mock -ModuleName WinClean Invoke-ExternalCommand { New-CmdResult -StdOut '' } -ParameterFilter { $ArgumentList[0] -eq 'image' -and $ArgumentList[1] -eq 'ls' }
        $r = Invoke-InModule { Invoke-DockerMaintenance -Prune }
        $r.Reason | Should -Be 'none found'
        Should -Invoke -ModuleName WinClean Invoke-ExternalCommand -Times 0 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'prune' }
    }
}

Describe 'Get-WslMemoryReport' {
    BeforeEach {
        Mock -ModuleName WinClean Invoke-ExternalCommand { throw 'no external command may run' }
    }

    It 'reports nothing when the WSL VM is not running' {
        Mock -ModuleName WinClean Get-Process { }
        (Invoke-InModule { Get-WslMemoryReport -WslConfigPath 'C:\nope\.wslconfig' }).Running | Should -BeFalse
    }

    It 'reports the VM memory and suggests autoMemoryReclaim when it is not configured' {
        Mock -ModuleName WinClean Get-Process { [pscustomobject]@{ Name = 'vmmemWSL'; WorkingSet64 = 3GB } }
        $r = Invoke-InModule { Get-WslMemoryReport -WslConfigPath 'C:\nope\.wslconfig' }
        $r.Running | Should -BeTrue
        $r.Bytes   | Should -Be 3GB
        $r.Steps -join ' ' | Should -Match 'wsl --shutdown'
        $r.Steps -join ' ' | Should -Match 'autoMemoryReclaim=gradual'
    }

    It 'does not suggest autoMemoryReclaim when .wslconfig already sets it' {
        Mock -ModuleName WinClean Get-Process { [pscustomobject]@{ Name = 'vmmemWSL'; WorkingSet64 = 1GB } }
        $cfg = Join-Path $TestDrive '.wslconfig'
        Set-Content -LiteralPath $cfg -Value "[wsl2]`nmemory=8GB`n[experimental]`nautoMemoryReclaim = gradual"
        $r = Invoke-InModule { Get-WslMemoryReport -WslConfigPath $C } @{ C = $cfg }
        $r.AutoReclaimConfigured | Should -BeTrue
        $r.Steps -join ' ' | Should -Not -Match 'autoMemoryReclaim'
    }
}

Describe 'Invoke-WinClean dev maintenance switches' {
    BeforeAll {
        Mock -ModuleName WinClean Write-Host { }
        $script:emptyConfig = Join-Path $TestDrive 'empty.json'
        Set-Content -LiteralPath $emptyConfig -Value '{ "extendDefaults": false, "targets": [] }'
    }

    It '-GitGc without -DevRoot skips with a hint' {
        Mock -ModuleName WinClean Invoke-GitMaintenance { }
        Invoke-WinClean -DryRun -GitGc -ConfigPath $emptyConfig -SkipBrowsers -SkipUpdateCache -SkipRam
        Should -Invoke -ModuleName WinClean Invoke-GitMaintenance -Times 0 -Exactly
        Should -Invoke -ModuleName WinClean Write-Host -ParameterFilter { "$Object" -match 'needs -DevRoot' }
    }

    It 'does not count report-only lines as freed space' {
        Mock -ModuleName WinClean Invoke-DockerMaintenance {
            [pscustomobject]@{ Label = 'Docker'; Category = 'docker'; Path = ''; Status = 'Info'; Reason = 'x'; Bytes = 5GB; Files = 3 }
        }
        Mock -ModuleName WinClean Get-WslMemoryReport { [pscustomobject]@{ Running = $false } }
        $run = Invoke-WinClean -DryRun -ConfirmDockerPrune -ConfigPath $emptyConfig -SkipBrowsers -SkipUpdateCache -SkipRam -PassThru
        $run.BytesFreed | Should -Be 0
    }
}
