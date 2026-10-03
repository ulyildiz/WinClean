#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinClean.psd1') -Force

    function New-TestFile([string]$Path, [int]$AgeHours = 48) {
        New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
        Set-Content -LiteralPath $Path -Value ('x' * 1024)
        (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddHours(-$AgeHours)
    }

    function Invoke-Clear([string]$Path, [int]$AgeHours = 0, [switch]$DryRun) {
        InModuleScope WinClean -Parameters @{ P = $Path; A = $AgeHours; D = [bool]$DryRun } {
            Clear-FolderContents -Path $P -Label 'test' -AgeHours $A -DryRun:$D -WarningAction SilentlyContinue
        }
    }
}

AfterAll {
    Remove-Module WinClean -Force -ErrorAction SilentlyContinue
}

Describe 'Clear-FolderContents' {

    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().Guid)
        New-TestFile (Join-Path $root 'a.tmp')
        New-TestFile (Join-Path $root 'sub\b.tmp')
        New-TestFile (Join-Path $root 'sub\deeper\c.tmp')
    }

    It '-DryRun reports what it would free and deletes nothing' {
        $r = Invoke-Clear $root -DryRun
        $r.Status | Should -Be 'WouldClean'
        $r.Files  | Should -Be 3
        $r.Bytes  | Should -BeGreaterThan 0
        (Get-ChildItem -LiteralPath $root -Recurse -File).Count | Should -Be 3
    }

    It 'deletes files and empty sub-folders but keeps the root folder' {
        $r = Invoke-Clear $root
        $r.Status | Should -Be 'Cleaned'
        $r.Files  | Should -Be 3
        Test-Path -LiteralPath $root | Should -BeTrue
        @(Get-ChildItem -LiteralPath $root -Force).Count | Should -Be 0
    }

    It 'keeps files newer than -AgeHours' {
        New-TestFile (Join-Path $root 'fresh.tmp') -AgeHours 0
        $r = Invoke-Clear $root -AgeHours 1
        $r.Files | Should -Be 3
        Test-Path -LiteralPath (Join-Path $root 'fresh.tmp') | Should -BeTrue
    }

    It 'returns NotFound for a missing folder' {
        (Invoke-Clear (Join-Path $TestDrive 'missing')).Status | Should -Be 'NotFound'
    }

    It 'refuses a blocklisted folder (checked in dry-run mode only)' {
        $r = Invoke-Clear ([Environment]::GetFolderPath('MyDocuments')) -DryRun
        $r.Status | Should -Be 'Skipped'
        $r.Reason | Should -Match 'Documents'
        $r.Files  | Should -Be 0
    }

    Context 'Junctions' {
        BeforeEach {
            $script:outside = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().Guid)
            New-TestFile (Join-Path $outside 'precious.txt')
            $script:links = @()
        }

        AfterEach {
            # remove only the links, never what they point to
            foreach ($l in $links) { if (Test-Path -LiteralPath $l) { [IO.Directory]::Delete($l, $false) } }
        }

        It 'never follows a junction inside the target' {
            $link = Join-Path $root 'sub\escape'
            New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
            $script:links += $link

            $r = Invoke-Clear $root
            $r.Files | Should -Be 3
            Test-Path -LiteralPath (Join-Path $outside 'precious.txt') | Should -BeTrue
        }

        It 'refuses a target that is itself a junction' {
            $link = Join-Path $TestDrive ('link-' + [guid]::NewGuid().Guid)
            New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
            $script:links += $link

            $r = Invoke-Clear $link
            $r.Status | Should -Be 'Skipped'
            $r.Reason | Should -Match 'junction or symbolic link'
            Test-Path -LiteralPath (Join-Path $outside 'precious.txt') | Should -BeTrue
        }
    }
}
