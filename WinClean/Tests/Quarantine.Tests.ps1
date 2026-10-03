#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinClean.psd1') -Force

    function New-File([string]$Path, [string]$Content = 'xxxx', [double]$AgeDays = 3) {
        New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
        Set-Content -LiteralPath $Path -Value $Content
        (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddDays(-$AgeDays)
    }

    function Invoke-InModule([scriptblock]$Script, [hashtable]$Parameters = @{}) {
        InModuleScope WinClean -ScriptBlock $Script -Parameters $Parameters
    }

    # mirrors how Move-ToQuarantine lays out a file inside a run
    function Get-QuarantinedPath([string]$Run, [string]$Original) {
        Join-Path $Run ($Original.Substring(0, 1).ToUpperInvariant() + $Original.Substring(2))
    }
}

AfterAll {
    Remove-Module WinClean -Force -ErrorAction SilentlyContinue
}

Describe 'Quarantine' {
    BeforeEach {
        # every test gets its own temp folder with its own quarantine root inside it,
        # exactly like %TEMP%\WinClean-Quarantine - never the real one
        $script:temp = Join-Path $TestDrive ('temp-' + [guid]::NewGuid().Guid.Substring(0, 8))
        $script:qroot = Join-Path $temp 'WinClean-Quarantine'
        New-Item -ItemType Directory -Path $qroot -Force | Out-Null
        Mock -ModuleName WinClean Get-QuarantineRoot { $qroot }

        New-File "$temp\a.tmp"
        New-File "$temp\sub\b.tmp"
    }

    Context 'Clear-FolderContents -QuarantinePath' {
        It 'moves files into the run, mirroring their original path' {
            $run = Invoke-InModule { New-QuarantineRun }
            $r = Invoke-InModule { Clear-FolderContents -Path $T -Label 'temp' -QuarantinePath $Q } @{ T = $temp; Q = $run }

            $r.Status | Should -Be 'Quarantined'
            $r.Files  | Should -Be 2
            Test-Path "$temp\a.tmp"     | Should -BeFalse
            Test-Path "$temp\sub\b.tmp" | Should -BeFalse
            Get-Content (Get-QuarantinedPath $run "$temp\a.tmp")     | Should -Be 'xxxx'
            Get-Content (Get-QuarantinedPath $run "$temp\sub\b.tmp") | Should -Be 'xxxx'
        }

        It 'never enters the quarantine folder, so cleaning TEMP cannot empty it' {
            New-File "$qroot\20200101-000000\C\old\kept.tmp"
            $r = Invoke-InModule { Clear-FolderContents -Path $T -Label 'temp' } @{ T = $temp }
            $r.Files | Should -Be 2
            Test-Path "$qroot\20200101-000000\C\old\kept.tmp" | Should -BeTrue
        }

        It 'leaves a locked file in place and does not count it' {
            $run = Invoke-InModule { New-QuarantineRun }
            $stream = [IO.File]::Open("$temp\a.tmp", 'Open', 'Read', 'None')
            try {
                $r = Invoke-InModule { Clear-FolderContents -Path $T -Label 'temp' -QuarantinePath $Q } @{ T = $temp; Q = $run }
            }
            finally { $stream.Dispose() }
            $r.Files | Should -Be 1
            Test-Path "$temp\a.tmp" | Should -BeTrue
            Test-Path (Get-QuarantinedPath $run "$temp\a.tmp") | Should -BeFalse
        }

        It '-DryRun moves nothing' {
            $run = Invoke-InModule { New-QuarantineRun }
            $r = Invoke-InModule { Clear-FolderContents -Path $T -Label 'temp' -QuarantinePath $Q -DryRun } @{ T = $temp; Q = $run }
            $r.Status | Should -Be 'WouldClean'
            Test-Path "$temp\a.tmp" | Should -BeTrue
            @(Get-ChildItem -LiteralPath $run -Recurse -File).Count | Should -Be 0
        }
    }

    Context 'New-QuarantineRun' {
        It 'names runs by timestamp and never reuses a folder' {
            $now = [datetime]'2026-10-03 14:05:09'
            $first  = Invoke-InModule { New-QuarantineRun -Now $N } @{ N = $now }
            $second = Invoke-InModule { New-QuarantineRun -Now $N } @{ N = $now }
            Split-Path $first -Leaf  | Should -Be '20261003-140509'
            Split-Path $second -Leaf | Should -Be '20261003-140509-1'
        }
    }

    Context 'Invoke-QuarantinePurge' {
        BeforeEach {
            $script:now = [datetime]'2026-10-03 12:00:00'
            New-File "$qroot\20260920-080000\C\x\old.tmp"          # 13 days old
            New-File "$qroot\20260920-080000-1\C\x\old2.tmp"       # same second, collision suffix
            New-File "$qroot\20261001-090000\C\x\recent.tmp"       # 2 days old
            New-File "$qroot\my-notes\keep.txt"                    # not a WinClean run
            New-File "$qroot\readme.txt"
        }

        It 'deletes runs older than -Days entirely and keeps everything else' {
            $r = @(Invoke-InModule { Invoke-QuarantinePurge -Days 7 -Now $N } @{ N = $now })
            $r.Count | Should -Be 2
            Test-Path "$qroot\20260920-080000"   | Should -BeFalse
            Test-Path "$qroot\20260920-080000-1" | Should -BeFalse
            Test-Path "$qroot\20261001-090000\C\x\recent.tmp" | Should -BeTrue
            Test-Path "$qroot\my-notes\keep.txt" | Should -BeTrue
            Test-Path "$qroot\readme.txt"        | Should -BeTrue
        }

        It 'judges age by the run name, not by file times' {
            (Get-Item "$qroot\20261001-090000\C\x\recent.tmp").LastWriteTime = $now.AddYears(-5)
            Invoke-InModule { Invoke-QuarantinePurge -Days 7 -Now $N } @{ N = $now } | Out-Null
            Test-Path "$qroot\20261001-090000\C\x\recent.tmp" | Should -BeTrue
        }

        It '-DryRun reports expired runs without deleting them' {
            $r = @(Invoke-InModule { Invoke-QuarantinePurge -Days 7 -Now $N -DryRun } @{ N = $now })
            $r.Status | Should -Be @('WouldClean', 'WouldClean')
            Test-Path "$qroot\20260920-080000\C\x\old.tmp" | Should -BeTrue
        }

        It '-Days 0 purges every run' {
            Invoke-InModule { Invoke-QuarantinePurge -Days 0 -Now $N } @{ N = $now } | Out-Null
            @(Get-ChildItem -LiteralPath $qroot -Directory).Name | Should -Be @('my-notes')
        }

        It 'does nothing when there is no quarantine folder' {
            Mock -ModuleName WinClean Get-QuarantineRoot { Join-Path $TestDrive 'nope' }
            Invoke-InModule { Invoke-QuarantinePurge -Days 0 } | Should -BeNullOrEmpty
        }
    }

    Context 'Invoke-WinClean -Quarantine' {
        BeforeEach {
            Mock -ModuleName WinClean Write-Host { }
            Mock -ModuleName WinClean Invoke-DockerMaintenance { }
            Mock -ModuleName WinClean Get-WslMemoryReport { [pscustomobject]@{ Running = $false } }
            $script:cfg = Join-Path $TestDrive ([guid]::NewGuid().Guid + '.json')
            @{ extendDefaults = $false; targets = @(@{ label = 'Test temp'; path = $temp; ageHours = 1; category = 'temp' }) } |
                ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $cfg
            # the real run below also flushes DNS; keep the test from touching the machine
            Mock -ModuleName WinClean ipconfig.exe { }
        }

        It 'moves the files instead of deleting them and reports the run' {
            $run = Invoke-WinClean -Quarantine -ConfigPath $cfg -SkipBrowsers -SkipUpdateCache -SkipRam -WarningAction SilentlyContinue -PassThru
            $run.Quarantine       | Should -BeTrue
            $run.FilesQuarantined | Should -Be 2
            $run.FilesRemoved     | Should -Be 0
            $run.QuarantinePath   | Should -BeLike "$qroot\*"
            Test-Path (Get-QuarantinedPath $run.QuarantinePath "$temp\sub\b.tmp") | Should -BeTrue
            Test-Path "$temp\sub\b.tmp" | Should -BeFalse
        }

        It 'removes the run folder again when nothing was quarantined' {
            Remove-Item "$temp\a.tmp", "$temp\sub\b.tmp"
            $run = Invoke-WinClean -Quarantine -ConfigPath $cfg -SkipBrowsers -SkipUpdateCache -SkipRam -WarningAction SilentlyContinue -PassThru
            $run.FilesQuarantined | Should -Be 0
            Test-Path -LiteralPath $run.QuarantinePath | Should -BeFalse
        }

        It 'does not create a run folder in a dry run' {
            $run = Invoke-WinClean -DryRun -Quarantine -ConfigPath $cfg -SkipBrowsers -SkipUpdateCache -SkipRam -WarningAction SilentlyContinue -PassThru
            $run.QuarantinePath | Should -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath $qroot).Count | Should -Be 0
            Test-Path "$temp\a.tmp" | Should -BeTrue
        }

        It 'downgrades docker prune to a report, because images cannot be quarantined' {
            Invoke-WinClean -Quarantine -ConfirmDockerPrune -ConfigPath $cfg -SkipBrowsers -SkipUpdateCache -SkipRam -WarningAction SilentlyContinue | Out-Null
            Should -Invoke -ModuleName WinClean Invoke-DockerMaintenance -Times 1 -Exactly -ParameterFilter { -not $Prune }
        }

        It 'purges expired runs at the start of a normal run' {
            New-File "$qroot\20000101-000000\C\x\ancient.tmp"
            $run = Invoke-WinClean -DryRun -ConfigPath $cfg -SkipBrowsers -SkipUpdateCache -SkipRam -WarningAction SilentlyContinue -PassThru
            ($run.Targets | Where-Object Category -eq 'quarantine').Status | Should -Be 'WouldClean'
        }
    }
}
