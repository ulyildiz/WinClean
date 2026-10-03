#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinClean.psd1') -Force

    function New-Bytes([string]$Path, [int]$Size) {
        New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
        [IO.File]::WriteAllBytes($Path, (New-Object byte[] $Size))
    }

    function Invoke-InModule([scriptblock]$Script, [hashtable]$Parameters = @{}) {
        InModuleScope WinClean -ScriptBlock $Script -Parameters $Parameters
    }

    # 5850 bytes in total; the junction's 1 MB must never be counted
    function New-SizeFixture {
        $root = Join-Path $TestDrive ('scan-' + [guid]::NewGuid().Guid.Substring(0, 8))
        New-Bytes "$root\big\a.bin" 1000
        New-Bytes "$root\big\b.bin" 1000
        New-Bytes "$root\big\c.bin" 1000
        New-Bytes "$root\big\deeper\d.bin" 2000
        New-Bytes "$root\small\e.bin" 100
        New-Bytes "$root\level1\level2\level3\level4\f.bin" 700
        New-Bytes "$root\root.bin" 50
        $outside = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().Guid.Substring(0, 8))
        New-Bytes "$outside\huge.bin" 1048576
        New-Item -ItemType Junction -Path "$root\linked" -Target $outside | Out-Null
        $root
    }

    # every file with size + write time, every folder by path. Folder timestamps are left out:
    # NTFS updates them lazily right after the fixture is created, which is not a change made
    # by the report.
    function Get-Snapshot([string]$Root) {
        Get-ChildItem -LiteralPath $Root -Recurse -Force |
            ForEach-Object { if ($_.PSIsContainer) { "$($_.FullName)|dir" } else { '{0}|{1}|{2:o}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc } }
    }

    function New-FakeProcess([string]$Name, [long]$WorkingSet, [string]$Path = $null, [double]$Cpu = 1, [long]$Private = 0) {
        [pscustomobject]@{ ProcessName = $Name; Path = $Path; WorkingSet64 = $WorkingSet; PrivateMemorySize64 = $Private
                           TotalProcessorTime = [timespan]::FromSeconds($Cpu) }
    }
}

AfterAll {
    Remove-Module WinClean -Force -ErrorAction SilentlyContinue
}

Describe 'Get-FolderSizeReport' {
    BeforeAll {
        $script:root = New-SizeFixture
        $script:r = Invoke-InModule { Get-FolderSizeReport -Root $R -MaxDepth 3 -Top 100 } @{ R = $root }
        function Get-Folder([string]$Rel) { $r.Folders | Where-Object Path -eq (Join-Path $root $Rel) }
    }
    AfterAll { [IO.Directory]::Delete("$root\linked", $false) }

    It 'measures the whole tree exactly, without following the junction' {
        $r.Scans[0].TotalBytes | Should -Be 5850
        $r.Scans[0].TotalFiles | Should -Be 7
        $r.Scans[0].ReparsePointsSkipped | Should -BeGreaterOrEqual 1
    }

    It 'includes nested folders in each parent''s total' {
        (Get-Folder 'big').Bytes        | Should -Be 5000
        (Get-Folder 'big').Files        | Should -Be 4
        (Get-Folder 'big\deeper').Bytes | Should -Be 2000
    }

    It 'lists folders down to -MaxDepth and counts deeper files in the deepest listed folder' {
        (Get-Folder 'level1\level2\level3').Bytes | Should -Be 700
        Get-Folder 'level1\level2\level3\level4' | Should -BeNullOrEmpty
        ($r.Folders.Depth | Measure-Object -Maximum).Maximum | Should -Be 3
    }

    It 'never lists the junction' {
        Get-Folder 'linked' | Should -BeNullOrEmpty
    }

    It 'returns the -Top largest folders, largest first' {
        $top = Invoke-InModule { Get-FolderSizeReport -Root $R -Top 2 } @{ R = $root }
        $top.Folders.Path | Should -Be @((Join-Path $root 'big'), (Join-Path $root 'big\deeper'))
    }

    It 'reports a missing root instead of failing' {
        $missing = Invoke-InModule { Get-FolderSizeReport -Root 'C:\nope\missing' }
        $missing.Scans[0].Error | Should -Be 'folder not found'
        $missing.Folders | Should -BeNullOrEmpty
    }
}

Describe 'Get-ProcessMemoryReport' {
    It 'groups processes by application and sorts by working set' {
        $procs = @(
            New-FakeProcess 'chrome' 100MB -Private 50MB
            New-FakeProcess 'chrome' 100MB -Private 50MB
            New-FakeProcess 'chrome' 100MB -Private 50MB
            New-FakeProcess 'code' 500MB
            New-FakeProcess 'notepad' 10MB
        )
        $r = Invoke-InModule { Get-ProcessMemoryReport -Top 2 -Process $P } @{ P = $procs }
        $r.Processes.Name | Should -Be @('code', 'chrome')
        $chrome = $r.Processes | Where-Object Name -eq 'chrome'
        $chrome.Instances       | Should -Be 3
        $chrome.WorkingSetBytes | Should -Be 300MB
        $chrome.PrivateBytes    | Should -Be 150MB
    }

    It 'reports total and available RAM' {
        $m = (Invoke-InModule { Get-ProcessMemoryReport -Process @() }).Memory
        $m.TotalBytes | Should -BeGreaterThan 0
        $m.UsedPercent | Should -BeGreaterThan 0
    }
}

Describe 'Startup inspection helpers' {
    It 'extracts the program from <Command>' -ForEach @(
        @{ Command = '"C:\Program Files\App\app.exe" --minimized'; Expected = 'C:\Program Files\App\app.exe' }
        @{ Command = 'C:\Program Files\App\app.exe -min';          Expected = 'C:\Program Files\App\app.exe' }
        @{ Command = 'C:\Tools\run.cmd /quiet';                    Expected = 'C:\Tools\run.cmd' }
        @{ Command = 'rundll32.exe C:\x\y.dll,Entry';              Expected = 'rundll32.exe' }
        @{ Command = '%SystemRoot%\system32\SecurityHealthSystray.exe'; Expected = "$env:SystemRoot\system32\SecurityHealthSystray.exe" }
    ) {
        Invoke-InModule { ConvertTo-StartupExecutable -Command $C } @{ C = $Command } | Should -Be $Expected
    }

    It 'reads the Task Manager enabled flag (<Hex>)' -ForEach @(
        @{ Hex = '02'; Expected = $true }
        @{ Hex = '06'; Expected = $true }
        @{ Hex = '03'; Expected = $false }
        @{ Hex = '07'; Expected = $false }
    ) {
        $approved = @{ 'App' = [byte[]]@([Convert]::ToByte($Hex, 16), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
        Invoke-InModule { Test-StartupApproved -Approved $A -Name 'App' } @{ A = $approved } | Should -Be $Expected
    }

    It 'treats a missing StartupApproved record as unknown (enabled by default)' {
        Invoke-InModule { Test-StartupApproved -Approved @{} -Name 'App' } | Should -BeNullOrEmpty
    }

    It 'estimates impact <Expected> for <Case>' -ForEach @(
        @{ Case = 'a disabled entry';        Enabled = $false; Running = $true;  Ws = 500MB; Cpu = 100; Expected = 'Disabled' }
        @{ Case = 'an idle entry';           Enabled = $true;  Running = $false; Ws = 0;     Cpu = 0;   Expected = 'Not running' }
        @{ Case = 'heavy memory';            Enabled = $true;  Running = $true;  Ws = 200MB; Cpu = 1;   Expected = 'High' }
        @{ Case = 'heavy CPU';               Enabled = $null;  Running = $true;  Ws = 5MB;   Cpu = 90;  Expected = 'High' }
        @{ Case = 'moderate use';            Enabled = $true;  Running = $true;  Ws = 60MB;  Cpu = 1;   Expected = 'Medium' }
        @{ Case = 'light use';               Enabled = $true;  Running = $true;  Ws = 10MB;  Cpu = 1;   Expected = 'Low' }
    ) {
        Invoke-InModule { Get-StartupImpactEstimate -Enabled $E -Running $R -WorkingSetBytes $W -CpuSeconds $C } @{ E = $Enabled; R = $Running; W = [long]$Ws; C = [double]$Cpu } |
            Should -Be $Expected
    }
}

Describe 'Get-StartupApps' {
    BeforeAll {
        Mock -ModuleName WinClean Get-RegistryValueTable { @{} }
        Mock -ModuleName WinClean Get-RegistryValueTable { @{ 'App' = '"C:\Apps\app.exe" --min'; 'Off' = 'C:\Apps\off.exe' } } -ParameterFilter { $Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }
        Mock -ModuleName WinClean Get-RegistryValueTable { @{ 'Off' = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) } } -ParameterFilter { $Path -like 'HKCU:*StartupApproved\Run' }

        $script:startup = Join-Path $TestDrive 'Startup'
        New-Item -ItemType Directory -Path $startup | Out-Null
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut((Join-Path $startup 'Tool.lnk'))
        $lnk.TargetPath = 'C:\Tools\tool.exe'
        $lnk.Arguments = '/tray'
        $lnk.Save()
        Set-Content -LiteralPath (Join-Path $startup 'desktop.ini') -Value '[.ShellClassInfo]'

        $procs = @(
            New-FakeProcess 'app' 200MB -Path 'C:\Apps\app.exe' -Cpu 5
            New-FakeProcess 'tool' 10MB -Cpu 1                       # no Path: matched by name
            New-FakeProcess 'app' 999MB -Path 'D:\Other\app.exe'     # same name, different program
        )
        $script:apps = @(Invoke-InModule { Get-StartupApps -Process $P -UserStartupFolder $U -CommonStartupFolder 'C:\nope' } @{ P = $procs; U = $startup })
        function Get-App([string]$Name) { $apps | Where-Object Name -eq $Name }
    }

    It 'lists Run-key entries and Startup-folder shortcuts, ignoring desktop.ini' {
        @($apps.Name | Sort-Object) | Should -Be @('App', 'Off', 'Tool')
    }

    It 'matches running processes by full path and ignores same-named programs elsewhere' {
        $a = Get-App 'App'
        $a.Running         | Should -BeTrue
        $a.Instances       | Should -Be 1
        $a.WorkingSetBytes | Should -Be 200MB
        $a.ImpactEstimate  | Should -Be 'High'
    }

    It 'resolves .lnk targets and falls back to matching by name' {
        $t = Get-App 'Tool'
        $t.Source     | Should -Be 'Startup folder (user)'
        $t.Executable | Should -Be 'C:\Tools\tool.exe'
        $t.Command    | Should -Match '/tray'
        $t.Running    | Should -BeTrue
        $t.ImpactEstimate | Should -Be 'Low'
    }

    It 'shows entries disabled in Task Manager as disabled' {
        $o = Get-App 'Off'
        $o.Enabled        | Should -BeFalse
        $o.ImpactEstimate | Should -Be 'Disabled'
    }
}

Describe 'Get-WinCleanReport' {
    BeforeAll {
        $script:root = New-SizeFixture
        Mock -ModuleName WinClean Get-StartupApps {
            [pscustomobject]@{ Name = 'App'; Source = 'Registry (user)'; Enabled = $true; Command = 'app.exe'; Executable = 'C:\Apps\app.exe'
                               Running = $true; Instances = 1; WorkingSetBytes = 20MB; CpuSeconds = 1; ImpactEstimate = 'Low' }
        }
    }
    AfterAll { [IO.Directory]::Delete("$root\linked", $false) }

    It 'is exported by the module' {
        Get-Command Get-WinCleanReport -Module WinClean | Should -Not -BeNullOrEmpty
    }

    It 'changes nothing on disk and never calls any cleanup code' {
        Mock -ModuleName WinClean Clear-FolderContents { }
        Mock -ModuleName WinClean Move-ToQuarantine { }
        Mock -ModuleName WinClean Remove-Item { }
        $before = Get-Snapshot $root
        Get-WinCleanReport -ScanRoot $root -OutputFormat object | Out-Null
        Get-Snapshot $root | Should -Be $before
        Should -Invoke -ModuleName WinClean Clear-FolderContents -Times 0 -Exactly
        Should -Invoke -ModuleName WinClean Move-ToQuarantine -Times 0 -Exactly
        Should -Invoke -ModuleName WinClean Remove-Item -Times 0 -Exactly
    }

    It 'returns a structured object' {
        $r = Get-WinCleanReport -ScanRoot $root -OutputFormat object
        $r.PSObject.TypeNames[0] | Should -Be 'WinClean.Report'
        $r.Folders[0].Path | Should -Be (Join-Path $root 'big')
        $r.Processes.Count | Should -BeGreaterThan 0
        $r.Startup[0].Name | Should -Be 'App'
    }

    It 'only runs the requested sections' {
        $r = Get-WinCleanReport -ScanRoot $root -Section Folders -OutputFormat object
        $r.Folders.Count | Should -BeGreaterThan 0
        $r.Processes | Should -BeNullOrEmpty
        Should -Invoke -ModuleName WinClean Get-StartupApps -Times 0 -Exactly
    }

    It 'renders JSON with an ISO timestamp' {
        $json = Get-WinCleanReport -ScanRoot $root -Top 3 -OutputFormat json | ConvertFrom-Json
        [datetime]::Parse($json.GeneratedAt) | Should -BeOfType [datetime]
        $json.Folders.Count | Should -Be 3
        $json.Startup.Name  | Should -Be 'App'
        $json.FolderScans[0].TotalBytes | Should -Be 5850
    }

    It 'renders one flat CSV with a Section column' {
        $rows = Get-WinCleanReport -ScanRoot $root -Top 3 -OutputFormat csv | ConvertFrom-Csv
        @($rows | Where-Object Section -eq 'Folder').Count | Should -Be 3
        @($rows | Where-Object Section -eq 'Process').Count | Should -Be 3
        ($rows | Where-Object Section -eq 'Startup').Impact | Should -Be 'Low'
        ($rows | Where-Object Section -eq 'Folder')[0].Bytes | Should -Be '5000'
    }

    It 'renders a readable table by default' {
        $text = Get-WinCleanReport -ScanRoot $root -Top 3
        $text | Should -BeOfType [string]
        $text | Should -Match 'Largest folders'
        $text | Should -Match 'Memory by application'
        $text | Should -Match 'Startup programs \(impact is an estimate'
        $text | Should -Match ([regex]::Escape((Join-Path $root 'big')))
    }
}
