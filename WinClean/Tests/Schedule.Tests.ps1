#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinClean.psd1') -Force
    $script:manifest = (Resolve-Path (Join-Path $PSScriptRoot '..\WinClean.psd1')).ProviderPath

    function Get-Command-Text([hashtable]$Parameters) {
        InModuleScope WinClean -Parameters @{ M = $manifest; P = $Parameters } { ConvertTo-WinCleanCommand -ModuleManifest $M -CleanParameters $P }
    }

    # the -Command "..." part of the task arguments, parsed the way powershell.exe will
    function Get-ScheduledCommand([string]$Arguments) {
        $m = [regex]::Match($Arguments, '-Command "(?<c>[^"]*)"$')
        $m.Success | Should -BeTrue -Because 'the command must be one double-quoted argument with no inner double quotes'
        $m.Groups['c'].Value
    }
}

AfterAll {
    Remove-Module WinClean -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-WinCleanCommand' {
    It 'imports this module and runs Invoke-WinClean with no options by default' {
        Get-Command-Text @{} | Should -BeExactly ("Import-Module '{0}' -Force; Invoke-WinClean" -f $manifest)
    }

    It 'renders switches, numbers, strings and arrays as plain PowerShell' {
        $text = Get-Command-Text @{ Quarantine = $true; SkipRam = $false; MinAgeHours = 6; DevRoot = @('C:\My Repos', "D:\o'brien\"); ConfigPath = 'C:\cfg\x.json' }
        $text | Should -BeLike "*Invoke-WinClean -ConfigPath 'C:\cfg\x.json' -DevRoot 'C:\My Repos','D:\o''brien\' -MinAgeHours 6 -Quarantine"
        $text | Should -Not -Match 'SkipRam'
    }

    It 'produces a command that parses and binds exactly the requested values' {
        $text = Get-Command-Text @{ IncludeDev = $true; DevRoot = @('C:\My Repos', "D:\o'brien"); QuarantineDays = 3 }
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $call = $ast.FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] }, $true) | Where-Object { $_.GetCommandName() -eq 'Invoke-WinClean' }
        $bound = [Management.Automation.Language.StaticParameterBinder]::BindCommand($call)
        $bound.BoundParameters['DevRoot'].Value.SafeGetValue() | Should -Be @('C:\My Repos', "D:\o'brien")
        $bound.BoundParameters['QuarantineDays'].ConstantValue | Should -Be 3
        $bound.BoundParameters.ContainsKey('IncludeDev') | Should -BeTrue
    }

    It 'rejects <Name>' -ForEach @(
        @{ Name = 'an unknown parameter (typo)'; P = @{ Quarantin = $true };     Match = 'not an Invoke-WinClean parameter' }
        @{ Name = '-PassThru';                   P = @{ PassThru = $true };      Match = 'not an Invoke-WinClean parameter' }
        @{ Name = 'a common parameter';          P = @{ Verbose = $true };       Match = 'not an Invoke-WinClean parameter' }
        @{ Name = 'a non-boolean switch value';  P = @{ Quarantine = 'yes' };    Match = 'is a switch' }
        @{ Name = 'a value with double quotes';  P = @{ ConfigPath = 'C:\a"b' }; Match = 'double quotes' }
    ) {
        { Get-Command-Text $P } | Should -Throw "*$Match*"
    }
}

Describe 'Register-WinCleanSchedule' {
    BeforeEach {
        Mock -ModuleName WinClean Get-ScheduledTask { }
        Mock -ModuleName WinClean Register-ScheduledTask { }
        Mock -ModuleName WinClean Test-IsAdministrator { $false }
    }

    It 'registers a weekly task in the \WinClean\ folder running as the current user' {
        Register-WinCleanSchedule -DayOfWeek Saturday -At '21:30' -CleanParameters @{ Quarantine = $true }
        Should -Invoke -ModuleName WinClean Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskPath -eq '\WinClean\' -and $TaskName -eq 'WinClean' -and
            $Action.Execute -eq 'powershell.exe' -and
            $Action.Arguments -match '-NonInteractive' -and $Action.Arguments -match 'Invoke-WinClean -Quarantine"$' -and
            $Trigger.DaysOfWeek -eq 64 -and $Trigger.StartBoundary -match 'T21:30:00$' -and
            $Principal.UserId -eq ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME) -and
            $Principal.LogonType -eq 'Interactive' -and $Principal.RunLevel -eq 'Limited' -and
            $Settings.StartWhenAvailable -and $Settings.ExecutionTimeLimit -eq 'PT2H' -and
            $Description -match 'Invoke-WinClean -Quarantine'
        }
    }

    It 'stores the start time as local wall-clock time (no UTC drift across DST changes)' {
        Register-WinCleanSchedule -At '03:00'
        Should -Invoke -ModuleName WinClean Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $Trigger.StartBoundary -match '^\d{4}-\d{2}-\d{2}T03:00:00$'
        }
    }

    It 'passes a task command that powershell.exe can run' {
        Register-WinCleanSchedule -CleanParameters @{ DevRoot = 'C:\My Repos'; IncludeDev = $true }
        Should -Invoke -ModuleName WinClean Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $cmd = Get-ScheduledCommand $Action.Arguments
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseInput($cmd, [ref]$null, [ref]$errors)
            -not $errors -and $cmd -match "-DevRoot 'C:\\My Repos'"
        }
    }

    It 'refuses to replace an existing task without -Force' {
        Mock -ModuleName WinClean Get-ScheduledTask { [pscustomobject]@{ TaskName = 'WinClean' } }
        { Register-WinCleanSchedule } | Should -Throw '*already exists*-Force*'
        Should -Invoke -ModuleName WinClean Register-ScheduledTask -Times 0 -Exactly
    }

    It 'replaces an existing task with -Force' {
        Mock -ModuleName WinClean Get-ScheduledTask { [pscustomobject]@{ TaskName = 'WinClean' } }
        Register-WinCleanSchedule -Force
        Should -Invoke -ModuleName WinClean Register-ScheduledTask -Times 1 -Exactly -ParameterFilter { $Force }
    }

    It 'changes nothing with -WhatIf' {
        Register-WinCleanSchedule -WhatIf
        Should -Invoke -ModuleName WinClean Register-ScheduledTask -Times 0 -Exactly
    }

    It 'requires an elevated session for -Elevated' {
        { Register-WinCleanSchedule -Elevated } | Should -Throw '*elevated PowerShell session*'
        Should -Invoke -ModuleName WinClean Register-ScheduledTask -Times 0 -Exactly
    }

    It 'registers with the highest run level for -Elevated' {
        Mock -ModuleName WinClean Test-IsAdministrator { $true }
        Register-WinCleanSchedule -Elevated
        Should -Invoke -ModuleName WinClean Register-ScheduledTask -Times 1 -Exactly -ParameterFilter { $Principal.RunLevel -eq 'Highest' }
    }

    It 'rejects a bad -CleanParameters key before touching Task Scheduler' {
        { Register-WinCleanSchedule -CleanParameters @{ DryRunn = $true } } | Should -Throw '*not an Invoke-WinClean parameter*'
        Should -Invoke -ModuleName WinClean Register-ScheduledTask -Times 0 -Exactly
    }

    It 'rejects task names that could escape the \WinClean\ folder' {
        { Register-WinCleanSchedule -TaskName '..\Microsoft\Windows\Defrag' } | Should -Throw
        Should -Invoke -ModuleName WinClean Register-ScheduledTask -Times 0 -Exactly
    }
}

Describe 'Unregister-WinCleanSchedule' {
    BeforeEach {
        Mock -ModuleName WinClean Unregister-ScheduledTask { }
    }

    It 'removes the task from the \WinClean\ folder only' {
        Mock -ModuleName WinClean Get-ScheduledTask { [pscustomobject]@{ TaskName = 'WinClean' } } -ParameterFilter { $TaskPath -eq '\WinClean\' }
        Unregister-WinCleanSchedule
        Should -Invoke -ModuleName WinClean Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskPath -eq '\WinClean\' -and $TaskName -eq 'WinClean' }
    }

    It 'warns when there is nothing to remove' {
        Mock -ModuleName WinClean Get-ScheduledTask { }
        $w = Unregister-WinCleanSchedule 3>&1
        "$w" | Should -Match 'No WinClean scheduled task'
        Should -Invoke -ModuleName WinClean Unregister-ScheduledTask -Times 0 -Exactly
    }

    It 'changes nothing with -WhatIf' {
        Mock -ModuleName WinClean Get-ScheduledTask { [pscustomobject]@{ TaskName = 'WinClean' } }
        Unregister-WinCleanSchedule -WhatIf
        Should -Invoke -ModuleName WinClean Unregister-ScheduledTask -Times 0 -Exactly
    }

    It 'rejects task names that could escape the \WinClean\ folder' {
        { Unregister-WinCleanSchedule -TaskName '..\Microsoft\Windows\Defrag' } | Should -Throw
        Should -Invoke -ModuleName WinClean Unregister-ScheduledTask -Times 0 -Exactly
    }
}
