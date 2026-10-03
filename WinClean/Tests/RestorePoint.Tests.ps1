#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinClean.psd1') -Force

    function New-RestorePoint([switch]$DryRun, [bool]$IsAdmin = $true) {
        InModuleScope WinClean -Parameters @{ D = [bool]$DryRun; A = $IsAdmin } {
            New-WinCleanRestorePoint -DryRun:$D -IsAdmin $A -WarningAction SilentlyContinue
        }
    }
}

AfterAll {
    Remove-Module WinClean -Force -ErrorAction SilentlyContinue
}

Describe 'New-WinCleanRestorePoint' {
    BeforeEach {
        # nothing in these tests may ever reach the real Checkpoint-Computer
        Mock -ModuleName WinClean Invoke-RestorePointCheckpoint { @() }
        Mock -ModuleName WinClean Test-SystemRestoreEnabled { $true }
    }

    It 'creates a restore point when elevated and System Restore is on' {
        $r = New-RestorePoint
        $r.Created | Should -BeTrue
        $r.Description | Should -Match '^WinClean \d{4}-\d{2}-\d{2} \d{2}:\d{2}$'
        Should -Invoke -ModuleName WinClean Invoke-RestorePointCheckpoint -Times 1 -Exactly
    }

    It 'never creates one in a dry run' {
        $r = New-RestorePoint -DryRun
        $r.Created | Should -BeFalse
        $r.Reason  | Should -Match 'dry run'
        Should -Invoke -ModuleName WinClean Invoke-RestorePointCheckpoint -Times 0 -Exactly
    }

    It 'warns and continues when not elevated' {
        $r = New-RestorePoint -IsAdmin $false
        $r.Created | Should -BeFalse
        $r.Reason  | Should -Match 'administrator'
        Should -Invoke -ModuleName WinClean Invoke-RestorePointCheckpoint -Times 0 -Exactly
    }

    It 'warns and continues when System Restore is disabled' {
        Mock -ModuleName WinClean Test-SystemRestoreEnabled { $false }
        $warnings = InModuleScope WinClean { New-WinCleanRestorePoint -IsAdmin $true 3>&1 } | Where-Object { $_ -is [Management.Automation.WarningRecord] }
        $warnings.Message | Should -Match 'System Restore is disabled'
        Should -Invoke -ModuleName WinClean Invoke-RestorePointCheckpoint -Times 0 -Exactly
    }

    It 'still tries when the System Restore state is unknown' {
        Mock -ModuleName WinClean Test-SystemRestoreEnabled { $null }
        (New-RestorePoint).Created | Should -BeTrue
    }

    It 'reports the 24-hour throttle warning as not created' {
        Mock -ModuleName WinClean Invoke-RestorePointCheckpoint { @('A new system restore point cannot be created because one has already been created within the past 1440 minutes.') }
        $r = New-RestorePoint
        $r.Created | Should -BeFalse
        $r.Reason  | Should -Match '1440 minutes'
    }

    It 'warns and continues when Checkpoint-Computer fails' {
        Mock -ModuleName WinClean Invoke-RestorePointCheckpoint { throw 'The service cannot be started' }
        $r = New-RestorePoint
        $r.Created | Should -BeFalse
        $r.Reason  | Should -Match 'cannot be started'
    }
}

Describe 'Invoke-WinClean -CreateRestorePoint' {
    BeforeAll {
        $script:cfg = Join-Path $TestDrive 'one-target.json'
        $target = Join-Path $TestDrive 'target'
        New-Item -ItemType Directory -Path $target | Out-Null
        @{ extendDefaults = $false; targets = @(@{ label = 'T'; path = $target; ageHours = 0; category = 'temp' }) } |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $cfg
    }

    BeforeEach {
        $script:order = New-Object 'System.Collections.Generic.List[string]'
        Mock -ModuleName WinClean Write-Host { }
        Mock -ModuleName WinClean ipconfig.exe { }
        Mock -ModuleName WinClean Test-IsAdministrator { $true }
        Mock -ModuleName WinClean Test-SystemRestoreEnabled { $true }
        Mock -ModuleName WinClean Invoke-RestorePointCheckpoint { $script:order.Add('restore-point'); @() }
        Mock -ModuleName WinClean Invoke-QuarantinePurge { $script:order.Add('quarantine-purge') }
        Mock -ModuleName WinClean Clear-FolderContents {
            $script:order.Add('clean')
            [pscustomobject]@{ Label = 'T'; Category = 'temp'; Path = ''; Status = 'Cleaned'; Reason = $null; Bytes = 0L; Files = 0 }
        }
    }

    It 'creates the restore point before anything is deleted' {
        $run = Invoke-WinClean -CreateRestorePoint -ConfigPath $cfg -SkipBrowsers -SkipUpdateCache -SkipRam -PassThru
        $run.RestorePoint.Created | Should -BeTrue
        $order[0] | Should -Be 'restore-point'
        $order | Should -Contain 'quarantine-purge'
        $order | Should -Contain 'clean'
    }

    It 'continues the cleanup when the restore point fails' {
        Mock -ModuleName WinClean Invoke-RestorePointCheckpoint { $script:order.Add('restore-point'); throw 'System Restore is turned off' }
        $run = Invoke-WinClean -CreateRestorePoint -ConfigPath $cfg -SkipBrowsers -SkipUpdateCache -SkipRam -PassThru -WarningAction SilentlyContinue
        $run.RestorePoint.Created | Should -BeFalse
        $order | Should -Contain 'clean'
    }

    It 'does not touch System Restore without -CreateRestorePoint' {
        $run = Invoke-WinClean -ConfigPath $cfg -SkipBrowsers -SkipUpdateCache -SkipRam -PassThru
        $run.RestorePoint | Should -BeNullOrEmpty
        Should -Invoke -ModuleName WinClean Invoke-RestorePointCheckpoint -Times 0 -Exactly
    }
}
