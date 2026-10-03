#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeDiscovery {
    $userProfile = $env:USERPROFILE
    $local       = $env:LOCALAPPDATA
    $roaming     = $env:APPDATA
    $windows     = $env:SystemRoot

    $downloads = Join-Path $userProfile 'Downloads'
    try {
        $shellFolders = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -ErrorAction Stop
        if ($shellFolders.'{374DE290-123F-4565-9164-B4C4D86E8D30}') { $downloads = $shellFolders.'{374DE290-123F-4565-9164-B4C4D86E8D30}' }
    } catch { }

    $documents = [Environment]::GetFolderPath('MyDocuments')
    $desktop   = [Environment]::GetFolderPath('Desktop')

    $script:blockedSystem = @(
        @{ Name = 'drive root C:\';                    Path = 'C:\' }
        @{ Name = 'drive root D:\';                    Path = 'D:\' }
        @{ Name = 'drive root with forward slash';     Path = 'c:/' }
        @{ Name = 'Windows directory';                 Path = $windows }
        @{ Name = 'System32';                          Path = Join-Path $windows 'System32' }
        @{ Name = 'SysWOW64';                          Path = Join-Path $windows 'SysWOW64' }
        @{ Name = 'WinSxS';                            Path = Join-Path $windows 'WinSxS' }
        @{ Name = 'Prefetch';                          Path = Join-Path $windows 'Prefetch' }
        @{ Name = 'event logs';                        Path = Join-Path $windows 'System32\winevt\Logs' }
        @{ Name = 'registry hives';                    Path = Join-Path $windows 'System32\config' }
        @{ Name = 'Windows Installer cache';           Path = Join-Path $windows 'Installer' }
        @{ Name = 'SoftwareDistribution root';         Path = Join-Path $windows 'SoftwareDistribution' }
        @{ Name = 'Program Files';                     Path = $env:ProgramFiles }
        @{ Name = 'Program Files subfolder';           Path = Join-Path $env:ProgramFiles 'Common Files' }
        @{ Name = 'Program Files (x86)';               Path = ${env:ProgramFiles(x86)} }
        @{ Name = 'ProgramData';                       Path = $env:ProgramData }
        @{ Name = 'Recycle Bin';                       Path = 'C:\$Recycle.Bin' }
        @{ Name = 'Recycle Bin SID folder';            Path = 'C:\$Recycle.Bin\S-1-5-21-1000' }
        @{ Name = 'Recycle Bin on another drive';      Path = 'D:\$Recycle.Bin' }
        @{ Name = 'System Volume Information';         Path = 'C:\System Volume Information' }
        @{ Name = 'Recovery';                          Path = 'C:\Recovery\WindowsRE' }
    )

    $script:blockedUser = @(
        @{ Name = 'Users folder';                      Path = Split-Path $userProfile -Parent }
        @{ Name = 'user profile';                      Path = $userProfile }
        @{ Name = 'Desktop';                           Path = $desktop }
        @{ Name = 'Desktop subfolder';                 Path = Join-Path $desktop 'Projects' }
        @{ Name = 'Documents';                         Path = $documents }
        @{ Name = 'Documents subfolder';               Path = Join-Path $documents 'WindowsPowerShell\Modules' }
        @{ Name = 'default Documents location';        Path = Join-Path $userProfile 'Documents' }
        @{ Name = 'Downloads';                         Path = $downloads }
        @{ Name = 'Downloads subfolder';               Path = Join-Path $downloads 'Installers' }
        @{ Name = 'default Downloads location';        Path = Join-Path $userProfile 'Downloads' }
        @{ Name = 'Pictures';                          Path = [Environment]::GetFolderPath('MyPictures') }
        @{ Name = 'Roaming AppData';                   Path = $roaming }
        @{ Name = 'Local AppData';                     Path = $local }
        @{ Name = 'LocalLow AppData';                  Path = Join-Path (Split-Path $local -Parent) 'LocalLow' }
        @{ Name = 'AppData parent';                    Path = Split-Path $local -Parent }
        @{ Name = 'Public profile';                    Path = $env:PUBLIC }
    )

    $script:blockedBrowser = @(
        @{ Name = 'Chrome User Data';                  Path = Join-Path $local 'Google\Chrome\User Data' }
        @{ Name = 'Chrome install folder (ancestor)';  Path = Join-Path $local 'Google\Chrome' }
        @{ Name = 'Chrome Default profile';            Path = Join-Path $local 'Google\Chrome\User Data\Default' }
        @{ Name = 'Chrome cookies (Network)';          Path = Join-Path $local 'Google\Chrome\User Data\Default\Network' }
        @{ Name = 'Chrome extensions';                 Path = Join-Path $local 'Google\Chrome\User Data\Default\Extensions' }
        @{ Name = 'Chrome Local Storage';              Path = Join-Path $local 'Google\Chrome\User Data\Profile 1\Local Storage' }
        @{ Name = 'Edge IndexedDB';                    Path = Join-Path $local 'Microsoft\Edge\User Data\Default\IndexedDB' }
        @{ Name = 'Brave Default profile';             Path = Join-Path $local 'BraveSoftware\Brave-Browser\User Data\Default' }
        @{ Name = 'Firefox roaming profiles';          Path = Join-Path $roaming 'Mozilla\Firefox\Profiles' }
        @{ Name = 'Firefox roaming profile';           Path = Join-Path $roaming 'Mozilla\Firefox\Profiles\abcd.default-release' }
        @{ Name = 'Firefox local profile root';        Path = Join-Path $local 'Mozilla\Firefox\Profiles\abcd.default-release' }
    )

    $script:evasion = @(
        @{ Name = 'forward slashes';                    Path = ($windows + '\System32').Replace('\', '/') }
        @{ Name = 'mixed case';                        Path = ($windows + '\System32').ToLowerInvariant() }
        @{ Name = 'trailing backslash';                Path = $windows + '\System32\' }
        @{ Name = 'doubled separators';                Path = ($windows + '\System32').Replace('\', '\\') }
        @{ Name = 'parent traversal out of Temp';      Path = $windows + '\Temp\..\System32' }
        @{ Name = 'dot segments';                      Path = $windows + '\.\System32\.' }
        @{ Name = 'trailing dot (Win32 strips it)';    Path = $documents + '.' }
        @{ Name = 'trailing space (Win32 strips it)';  Path = $documents + ' ' }
        @{ Name = 'traversal from Temp to Documents';  Path = Join-Path $env:TEMP '..\..\..\Documents' }
    )

    $script:invalid = @(
        @{ Name = 'null';                              Path = $null }
        @{ Name = 'empty string';                      Path = '' }
        @{ Name = 'whitespace';                        Path = '   ' }
        @{ Name = 'bare drive letter';                 Path = 'C:' }
        @{ Name = 'drive-relative path';               Path = 'C:Windows\Temp' }
        @{ Name = 'relative path';                     Path = 'Temp' }
        @{ Name = 'dot-relative path';                 Path = '.\Temp' }
        @{ Name = 'parent-relative path';              Path = '..\Windows' }
        @{ Name = 'rooted without drive';              Path = '\Windows\Temp' }
        @{ Name = 'UNC path';                          Path = '\\server\share\temp' }
        @{ Name = 'extended-length device path';       Path = '\\?\C:\Windows\Temp' }
        @{ Name = 'device namespace path';             Path = '\\.\C:\Windows\Temp' }
        @{ Name = 'wildcard star';                     Path = 'C:\Users\*\AppData\Local\Temp' }
        @{ Name = 'wildcard question mark';            Path = 'C:\Windows\Te?p' }
        @{ Name = 'alternate data stream';             Path = 'C:\Windows\Temp:stream' }
        @{ Name = 'unexpanded %VAR%';                  Path = '%TEMP%' }
        @{ Name = 'unexpanded %VAR% inside path';      Path = 'C:\%USERNAME%\Temp' }
        @{ Name = 'unexpanded $env:';                  Path = '$env:TEMP\foo' }
        @{ Name = 'reserved device name';              Path = 'C:\Temp\NUL' }
        @{ Name = 'reserved device name with ext';     Path = 'C:\Temp\con.txt\cache' }
        @{ Name = 'unresolvable 8.3 short name';       Path = 'C:\NOTEXI~1\cache' }
    )

    $script:allowed = @(
        @{ Name = 'user temp';                         Path = $env:TEMP }
        @{ Name = 'user temp via forward slashes';     Path = $env:TEMP.Replace('\', '/') }
        @{ Name = 'Local AppData Temp';                Path = Join-Path $local 'Temp' }
        @{ Name = 'Windows temp';                      Path = Join-Path $windows 'Temp' }
        @{ Name = 'Windows Update download cache';     Path = Join-Path $windows 'SoftwareDistribution\Download' }
        @{ Name = 'INetCache';                         Path = Join-Path $local 'Microsoft\Windows\INetCache' }
        @{ Name = 'DirectX shader cache';              Path = Join-Path $local 'D3DSCache' }
        @{ Name = 'crash dumps';                       Path = Join-Path $local 'CrashDumps' }
        @{ Name = 'WER report queue';                  Path = Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue' }
        @{ Name = 'Chrome Default Cache';              Path = Join-Path $local 'Google\Chrome\User Data\Default\Cache' }
        @{ Name = 'Chrome profile Code Cache';         Path = Join-Path $local 'Google\Chrome\User Data\Profile 2\Code Cache' }
        @{ Name = 'Edge GPUCache';                     Path = Join-Path $local 'Microsoft\Edge\User Data\Default\GPUCache' }
        @{ Name = 'Firefox local cache2';              Path = Join-Path $local 'Mozilla\Firefox\Profiles\abcd.default-release\cache2' }
        @{ Name = 'non-protected depth-2 folder';      Path = 'C:\BuildCache\nuget' }
    )
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinClean.psd1') -Force

    function Get-Verdict([AllowNull()][AllowEmptyString()][string]$Path, [int]$MinDepth = 2) {
        InModuleScope WinClean -Parameters @{ Target = $Path; Depth = $MinDepth } {
            Test-PathSafety -Path $Target -MinDepth $Depth -Detailed
        }
    }
}

AfterAll {
    Remove-Module WinClean -Force -ErrorAction SilentlyContinue
}

Describe 'Test-PathSafety' {

    Context 'Hard blocklist: drive roots and system locations' {
        It 'rejects <Name> (<Path>)' -ForEach $blockedSystem {
            $v = Get-Verdict $Path
            $v.IsSafe | Should -BeFalse
            $v.Reason | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Hard blocklist: user data and profile containers' {
        It 'rejects <Name> (<Path>)' -ForEach $blockedUser {
            $v = Get-Verdict $Path
            $v.IsSafe | Should -BeFalse
            $v.Reason | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Hard blocklist: browser profile data (cookies, passwords, history, extensions)' {
        It 'rejects <Name>' -ForEach $blockedBrowser {
            $v = Get-Verdict $Path
            $v.IsSafe | Should -BeFalse
            $v.Reason | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Normalization cannot be used to sneak past the blocklist' {
        It 'rejects <Name> (<Path>)' -ForEach $evasion {
            Get-Verdict $Path | Select-Object -ExpandProperty IsSafe | Should -BeFalse
        }
    }

    Context 'Invalid or ambiguous input fails safe' {
        It 'rejects <Name>' -ForEach $invalid {
            $v = Get-Verdict $Path
            $v.IsSafe | Should -BeFalse
            $v.Reason | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Minimum depth' {
        It 'rejects a depth-1 folder by default' {
            $v = Get-Verdict 'C:\Temp'
            $v.IsSafe | Should -BeFalse
            $v.Reason | Should -Match 'depth 1 is below the minimum of 2'
        }

        It 'rejects a depth-2 folder when -MinDepth is 3' {
            (Get-Verdict 'C:\BuildCache\nuget' -MinDepth 3).IsSafe | Should -BeFalse
        }

        It 'accepts a depth-3 folder when -MinDepth is 3' {
            (Get-Verdict 'C:\BuildCache\nuget\v3' -MinDepth 3).IsSafe | Should -BeTrue
        }

        It 'counts depth after resolving ".." segments' {
            (Get-Verdict 'C:\BuildCache\nuget\..').IsSafe | Should -BeFalse
        }
    }

    Context 'Allowlisted cleanup targets' {
        It 'accepts <Name>' -ForEach $allowed {
            $v = Get-Verdict $Path
            $v.Reason | Should -BeNullOrEmpty
            $v.IsSafe | Should -BeTrue
        }

        It 'accepts a real folder under TestDrive' {
            $dir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'plain') -Force
            (Get-Verdict $dir.FullName).IsSafe | Should -BeTrue
        }
    }

    Context 'Junctions and symbolic links' {
        BeforeAll {
            $script:outside  = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'outside') -Force
            $script:junction = Join-Path $TestDrive 'link'
            New-Item -ItemType Junction -Path $junction -Target $outside.FullName | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $outside.FullName 'nested') -Force | Out-Null
        }

        AfterAll {
            # remove only the link, never what it points to
            if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction, $false) }
        }

        It 'rejects a junction itself' {
            $v = Get-Verdict $junction
            $v.IsSafe | Should -BeFalse
            $v.Reason | Should -Match 'junction or symbolic link'
        }

        It 'rejects a path that traverses a junction' {
            (Get-Verdict (Join-Path $junction 'nested')).IsSafe | Should -BeFalse
        }

        It 'still accepts the real target folder' {
            (Get-Verdict $outside.FullName).IsSafe | Should -BeTrue
        }
    }

    Context 'Output contract' {
        It 'returns a plain boolean by default' {
            $result = InModuleScope WinClean { Test-PathSafety -Path $env:TEMP }
            $result | Should -BeOfType [bool]
            $result | Should -BeTrue
        }

        It 'returns the canonical path in -Detailed mode' {
            (Get-Verdict 'c:/windows/temp/').NormalizedPath | Should -BeExactly 'C:\windows\temp'
        }

        It 'reports the resolved path when traversal is used' {
            $v = Get-Verdict ($env:SystemRoot + '\Temp\..\System32')
            $v.NormalizedPath | Should -Be (Join-Path $env:SystemRoot 'System32')
            $v.Reason | Should -Match 'Windows'
        }

        It 'accepts pipeline input' {
            $results = InModuleScope WinClean { 'C:\', $env:TEMP, 'C:\Windows\System32' | Test-PathSafety }
            $results | Should -Be @($false, $true, $false)
        }
    }
}
