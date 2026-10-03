#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinClean.psd1') -Force

    function Invoke-Private([scriptblock]$Script, [hashtable]$Parameters = @{}) {
        InModuleScope WinClean -ScriptBlock $Script -Parameters $Parameters
    }

    # Writes $Object as JSON (or a raw string) to a TestDrive file and returns its path.
    function New-ConfigFile($Content) {
        $file = Join-Path $TestDrive ([guid]::NewGuid().Guid + '.json')
        if ($Content -is [string]) { $text = $Content } else { $text = $Content | ConvertTo-Json -Depth 5 }
        Set-Content -LiteralPath $file -Value $text -Encoding UTF8
        $file
    }

    function ConvertTo-Target([hashtable]$Entry) {
        Invoke-Private {
            ConvertTo-WinCleanTarget -Entry ([pscustomobject]$E) -Index 0 -Source 'test' -WarningAction SilentlyContinue
        } @{ E = $Entry }
    }
}

AfterAll {
    Remove-Module WinClean -Force -ErrorAction SilentlyContinue
}

Describe 'Expand-WinCleanPath' {
    BeforeAll {
        $env:WINCLEAN_TEST_DIR = 'C:\WinCleanTest'
        ${env:WINCLEAN_TEST(X)} = 'C:\Paren'
    }
    AfterAll {
        Remove-Item Env:\WINCLEAN_TEST_DIR, 'Env:\WINCLEAN_TEST(X)' -ErrorAction SilentlyContinue
    }

    It 'expands <Syntax> syntax' -ForEach @(
        @{ Syntax = '%VAR%';      Raw = '%WINCLEAN_TEST_DIR%\cache' }
        @{ Syntax = '$env:VAR';   Raw = '$env:WINCLEAN_TEST_DIR\cache' }
        @{ Syntax = '${env:VAR}'; Raw = '${env:WINCLEAN_TEST_DIR}\cache' }
        @{ Syntax = 'lowercase';  Raw = '%winclean_test_dir%\cache' }
    ) {
        Invoke-Private { Expand-WinCleanPath -Path $R } @{ R = $Raw } | Should -Be 'C:\WinCleanTest\cache'
    }

    It 'expands variable names containing parentheses' {
        Invoke-Private { Expand-WinCleanPath -Path '%WINCLEAN_TEST(X)%\a' } | Should -Be 'C:\Paren\a'
        Invoke-Private { Expand-WinCleanPath -Path '${env:WINCLEAN_TEST(X)}\a' } | Should -Be 'C:\Paren\a'
    }

    It 'expands several variables in one path' {
        Invoke-Private { Expand-WinCleanPath -Path '%SystemDrive%\x\$env:WINCLEAN_TEST_DIR' } |
            Should -Be ($env:SystemDrive + '\x\C:\WinCleanTest')
    }

    It 'leaves paths without variables untouched' {
        Invoke-Private { Expand-WinCleanPath -Path 'C:\plain\100% done' } | Should -Be 'C:\plain\100% done'
    }

    It 'does not re-expand variable values' {
        $env:WINCLEAN_TEST_NESTED = '%WINCLEAN_TEST_DIR%'
        try { Invoke-Private { Expand-WinCleanPath -Path 'C:\a\%WINCLEAN_TEST_NESTED%' } | Should -Be 'C:\a\%WINCLEAN_TEST_DIR%' }
        finally { Remove-Item Env:\WINCLEAN_TEST_NESTED }
    }

    It 'throws on an undefined variable instead of expanding to empty (<Raw>)' -ForEach @(
        @{ Raw = '%WINCLEAN_UNDEFINED%\Temp' }
        @{ Raw = 'C:\Data\%WINCLEAN_UNDEFINED%' }
        @{ Raw = '$env:WINCLEAN_UNDEFINED\Temp' }
        @{ Raw = '${env:WINCLEAN_UNDEFINED}\Temp' }
    ) {
        { Invoke-Private { Expand-WinCleanPath -Path $R } @{ R = $Raw } } | Should -Throw '*WINCLEAN_UNDEFINED*not defined*'
    }
}

Describe 'Config entry validation' {
    It 'accepts a complete entry' {
        $t = ConvertTo-Target @{ label = 'Cache'; path = '%LOCALAPPDATA%\x'; ageHours = 24; category = 'cache'; requiresAdmin = $true; enabled = $false }
        $t.Error         | Should -BeNullOrEmpty
        $t.Label         | Should -Be 'Cache'
        $t.ExpandedPath  | Should -Be (Join-Path $env:LOCALAPPDATA 'x')
        $t.AgeHours      | Should -Be 24
        $t.Category      | Should -Be 'cache'
        $t.RequiresAdmin | Should -BeTrue
        $t.Enabled       | Should -BeFalse
    }

    It 'defaults ageHours to null (follow -MinAgeHours), requiresAdmin false, enabled true' {
        $t = ConvertTo-Target @{ label = 'Temp'; path = 'C:\a\b'; category = 'temp' }
        $t.Error         | Should -BeNullOrEmpty
        $t.AgeHours      | Should -BeNullOrEmpty
        $t.RequiresAdmin | Should -BeFalse
        $t.Enabled       | Should -BeTrue
    }

    It 'rejects <Name>' -ForEach @(
        @{ Name = 'missing label';            Entry = @{ path = 'C:\a\b'; category = 'temp' };                                  Match = 'label' }
        @{ Name = 'blank label';              Entry = @{ label = ' '; path = 'C:\a\b'; category = 'temp' };                     Match = 'label' }
        @{ Name = 'missing path';             Entry = @{ label = 'x'; category = 'temp' };                                      Match = 'path' }
        @{ Name = 'non-string path';          Entry = @{ label = 'x'; path = 5; category = 'temp' };                            Match = 'path' }
        @{ Name = 'missing category';         Entry = @{ label = 'x'; path = 'C:\a\b' };                                        Match = 'category' }
        @{ Name = 'uppercase category';       Entry = @{ label = 'x'; path = 'C:\a\b'; category = 'Temp' };                     Match = 'category' }
        @{ Name = 'negative ageHours';        Entry = @{ label = 'x'; path = 'C:\a\b'; category = 'temp'; ageHours = -1 };      Match = 'ageHours' }
        @{ Name = 'too large ageHours';       Entry = @{ label = 'x'; path = 'C:\a\b'; category = 'temp'; ageHours = 9000 };    Match = 'ageHours' }
        @{ Name = 'string ageHours';          Entry = @{ label = 'x'; path = 'C:\a\b'; category = 'temp'; ageHours = '24' };    Match = 'ageHours' }
        @{ Name = 'fractional ageHours';      Entry = @{ label = 'x'; path = 'C:\a\b'; category = 'temp'; ageHours = 1.5 };     Match = 'ageHours' }
        @{ Name = 'string requiresAdmin';     Entry = @{ label = 'x'; path = 'C:\a\b'; category = 'temp'; requiresAdmin = 'yes' }; Match = 'requiresAdmin' }
        @{ Name = 'numeric enabled';          Entry = @{ label = 'x'; path = 'C:\a\b'; category = 'temp'; enabled = 0 };        Match = 'enabled' }
        @{ Name = 'undefined env variable';   Entry = @{ label = 'x'; path = '%WINCLEAN_UNDEFINED%\a'; category = 'temp' };     Match = 'not defined' }
    ) {
        $t = ConvertTo-Target $Entry
        $t.Error | Should -Match $Match
    }

    It 'warns about unknown properties (catches typos like "agehour")' {
        $warnings = Invoke-Private {
            ConvertTo-WinCleanTarget -Entry ([pscustomobject]@{ label = 'x'; path = 'C:\a\b'; category = 'temp'; agehour = 5 }) -Index 0 -Source 'test' 3>&1
        } | Where-Object { $_ -is [Management.Automation.WarningRecord] }
        $warnings.Message | Should -Match "unknown property 'agehour'"
    }
}

Describe 'Config file loading' {
    It 'throws when the file does not exist' {
        { Invoke-Private { Read-WinCleanConfigFile -Path 'C:\nope\missing.json' -Source 'test' } } | Should -Throw '*not found*'
    }

    It 'throws on invalid JSON' {
        $f = New-ConfigFile '{ "targets": [ { "label": "x", '
        { Invoke-Private { Read-WinCleanConfigFile -Path $F -Source 'test' } @{ F = $f } } | Should -Throw '*not valid JSON*'
    }

    It 'throws when <Name>' -ForEach @(
        @{ Name = 'targets is missing';       Json = '{ "version": 1 }' }
        @{ Name = 'targets is an object';     Json = '{ "targets": { "label": "x" } }' }
        @{ Name = 'targets is a string';      Json = '{ "targets": "C:\\Temp" }' }
        @{ Name = 'the root is an array';     Json = '[ { "label": "x" } ]' }
        @{ Name = 'the version is unknown';   Json = '{ "version": 2, "targets": [] }' }
    ) {
        $f = New-ConfigFile $Json
        { Invoke-Private { Read-WinCleanConfigFile -Path $F -Source 'test' } @{ F = $f } } | Should -Throw
    }

    It 'loads a single-entry targets array' {
        $f = New-ConfigFile '{ "targets": [ { "label": "Only", "path": "C:\\a\\b", "category": "temp" } ] }'
        $cfg = Invoke-Private { Read-WinCleanConfigFile -Path $F -Source 'test' } @{ F = $f }
        @($cfg.Targets).Count | Should -Be 1
        $cfg.Targets[0].Label | Should -Be 'Only'
    }

    It 'marks duplicate labels (case-insensitive) as errors, keeping the first' {
        $f = New-ConfigFile '{ "targets": [
            { "label": "Dup", "path": "C:\\a\\b", "category": "temp" },
            { "label": "dup", "path": "C:\\a\\c", "category": "temp" } ] }'
        $cfg = Invoke-Private { Read-WinCleanConfigFile -Path $F -Source 'test' } @{ F = $f }
        $cfg.Targets[0].Error | Should -BeNullOrEmpty
        $cfg.Targets[1].Error | Should -Match 'Duplicate label'
    }
}

Describe 'Default config (Config\winclean.config.json)' {
    BeforeAll {
        $script:defaults = Invoke-Private { (Get-WinCleanConfig).Targets }
    }

    It 'contains the original cleanup targets, in order' {
        $defaults.Label | Should -Be @(
            'User temp', 'Windows temp', 'Internet cache', 'DirectX shader cache',
            'App crash dumps', 'Error reporting queue', 'Error reporting archive')
    }

    It 'has no invalid entries' {
        $defaults | Where-Object Error | Should -BeNullOrEmpty
    }

    It 'lets the temp folders follow -MinAgeHours and cleans caches regardless of age' {
        $temp = @($defaults | Where-Object Category -eq 'temp')
        $temp.Count | Should -Be 2
        $temp | Where-Object { $null -ne $_.AgeHours } | Should -BeNullOrEmpty
        ($defaults | Where-Object Category -ne 'temp').AgeHours | Should -Be @(0, 0, 0, 0, 0)
    }

    It 'marks the machine-wide folders as requiring administrator' {
        ($defaults | Where-Object RequiresAdmin).Label |
            Should -Be @('Windows temp', 'Error reporting queue', 'Error reporting archive')
    }

    It 'expands <_.Label> to a path accepted by Test-PathSafety' -ForEach @(
        Invoke-Command {
            Import-Module (Join-Path $PSScriptRoot '..\WinClean.psd1') -Force
            InModuleScope WinClean { (Get-WinCleanConfig).Targets }
        }
    ) {
        $verdict = Invoke-Private { Test-PathSafety -Path $P -Detailed } @{ P = $_.ExpandedPath }
        $verdict.Reason | Should -BeNullOrEmpty
        $verdict.IsSafe | Should -BeTrue
    }
}

Describe 'Get-WinCleanConfig -ConfigPath' {
    BeforeAll {
        $script:defaultCount = @(Invoke-Private { (Get-WinCleanConfig).Targets }).Count
        function Get-Merged([string]$File) { Invoke-Private { Get-WinCleanConfig -ConfigPath $F } @{ F = $File } }
    }

    It 'appends new targets after the defaults' {
        $f = New-ConfigFile '{ "targets": [ { "label": "My cache", "path": "C:\\Cache\\mine", "category": "cache" } ] }'
        $cfg = Get-Merged $f
        $cfg.ExtendDefaults | Should -BeTrue
        @($cfg.Targets).Count | Should -Be ($defaultCount + 1)
        $cfg.Targets[-1].Label  | Should -Be 'My cache'
        $cfg.Targets[-1].Source | Should -Be 'user'
        $cfg.UserPath | Should -Be $f
    }

    It 'overrides a default target by label (case-insensitive) and keeps its position' {
        $f = New-ConfigFile '{ "targets": [ { "label": "user TEMP", "path": "%TEMP%", "ageHours": 48, "category": "temp" } ] }'
        $cfg = Get-Merged $f
        @($cfg.Targets).Count | Should -Be $defaultCount
        $cfg.Targets[0].AgeHours | Should -Be 48
        $cfg.Targets[0].Source   | Should -Be 'user'
    }

    It 'can disable a default target' {
        $f = New-ConfigFile '{ "targets": [ { "label": "App crash dumps", "path": "%LOCALAPPDATA%\\CrashDumps", "category": "crash", "enabled": false } ] }'
        ((Get-Merged $f).Targets | Where-Object Label -eq 'App crash dumps').Enabled | Should -BeFalse
    }

    It 'replaces the defaults when extendDefaults is false' {
        $f = New-ConfigFile '{ "extendDefaults": false, "targets": [ { "label": "Only", "path": "C:\\Cache\\only", "category": "cache" } ] }'
        $cfg = Get-Merged $f
        $cfg.ExtendDefaults | Should -BeFalse
        $cfg.Targets.Label  | Should -Be 'Only'
    }

    It 'throws when extendDefaults is not a boolean' {
        $f = New-ConfigFile '{ "extendDefaults": "no", "targets": [] }'
        { Get-Merged $f } | Should -Throw '*extendDefaults*'
    }

    It 'throws when the user config file does not exist' {
        { Get-Merged (Join-Path $TestDrive 'missing.json') } | Should -Throw '*not found*'
    }

    It 'resolves a relative -ConfigPath' {
        $f = New-ConfigFile '{ "targets": [] }'
        Push-Location (Split-Path $f -Parent)
        try { (Get-Merged ('.\' + (Split-Path $f -Leaf))).UserPath | Should -Be $f }
        finally { Pop-Location }
    }
}

Describe 'Invoke-WinClean -ConfigPath' {
    BeforeAll {
        Mock -ModuleName WinClean Write-Host { }

        function Invoke-DryRun([string]$File) {
            Invoke-WinClean -DryRun -SkipBrowsers -SkipUpdateCache -SkipRam -PassThru -ConfigPath $File -WarningAction SilentlyContinue
        }
    }

    BeforeEach {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid().Guid)
        New-Item -ItemType Directory -Path $dir | Out-Null
        foreach ($n in 'old1.tmp', 'old2.tmp', 'new.tmp') { Set-Content -LiteralPath (Join-Path $dir $n) -Value 'x' }
        foreach ($n in 'old1.tmp', 'old2.tmp') { (Get-Item -LiteralPath (Join-Path $dir $n)).LastWriteTime = (Get-Date).AddDays(-3) }
        $script:json = @{ extendDefaults = $false; targets = @(@{ label = 'Test target'; path = $dir; ageHours = 24; category = 'test' }) }
    }

    It 'dry-runs only the user targets, honours ageHours and deletes nothing' {
        $run = Invoke-DryRun (New-ConfigFile $json)
        @($run.Targets).Count     | Should -Be 1
        $run.Targets[0].Status    | Should -Be 'WouldClean'
        $run.Targets[0].Category  | Should -Be 'test'
        $run.Targets[0].Files     | Should -Be 2
        $run.ConfigPath           | Should -Not -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $dir).Count | Should -Be 3
    }

    It 'falls back to -MinAgeHours when ageHours is null' {
        $json.targets[0].ageHours = $null
        $run = Invoke-WinClean -DryRun -SkipBrowsers -SkipUpdateCache -SkipRam -PassThru -MinAgeHours 0 -ConfigPath (New-ConfigFile $json)
        $run.Targets[0].Files | Should -Be 3
    }

    It 'expands environment variables in user paths' {
        $env:WINCLEAN_TEST_TARGET = $dir
        try {
            $json.targets[0].path = '%WINCLEAN_TEST_TARGET%'
            (Invoke-DryRun (New-ConfigFile $json)).Targets[0].Path | Should -Be $dir
        }
        finally { Remove-Item Env:\WINCLEAN_TEST_TARGET }
    }

    It 'refuses a user target that points at a protected folder' {
        $json.targets[0].path = '%USERPROFILE%\Documents'
        $r = (Invoke-DryRun (New-ConfigFile $json)).Targets[0]
        $r.Status | Should -Be 'Skipped'
        $r.Reason | Should -Match 'Documents'
    }

    It 'skips (and never widens) a target with an undefined variable' {
        $json.targets[0].path = 'C:\Data\%WINCLEAN_UNDEFINED%'
        $r = (Invoke-DryRun (New-ConfigFile $json)).Targets[0]
        $r.Status | Should -Be 'Skipped'
        $r.Reason | Should -Match 'not defined'
    }

    It 'skips disabled targets entirely' {
        $json.targets[0].enabled = $false
        @((Invoke-DryRun (New-ConfigFile $json)).Targets).Count | Should -Be 0
    }

    It 'stops before touching any folder when the config file is broken' {
        Mock -ModuleName WinClean Clear-FolderContents { }
        { Invoke-WinClean -ConfigPath (New-ConfigFile '{ "targets": [ ') -SkipRam } | Should -Throw '*not valid JSON*'
        Should -Invoke -ModuleName WinClean Clear-FolderContents -Times 0 -Exactly
    }
}