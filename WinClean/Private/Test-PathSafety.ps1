function Resolve-LongPathName {
    <#
    .SYNOPSIS
        Expands 8.3 short names (e.g. C:\PROGRA~1) to long names. Returns $null when impossible.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not ('WinClean.NativePath' -as [type])) {
        Add-Type -Namespace WinClean -Name NativePath -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern uint GetLongPathName(string shortPath, System.Text.StringBuilder longPath, uint bufferLength);
'@
    }

    $buffer = New-Object System.Text.StringBuilder 32768
    $length = [WinClean.NativePath]::GetLongPathName($Path, $buffer, [uint32]$buffer.Capacity)
    if ($length -eq 0 -or $length -gt $buffer.Capacity) { return $null }
    return $buffer.ToString()
}

function ConvertTo-NormalizedPath {
    <#
    .SYNOPSIS
        Canonicalizes an absolute drive path, or throws with the reason it is not acceptable.
    .DESCRIPTION
        Forward slashes become backslashes, duplicate separators collapse, '.' and '..' are
        resolved, and trailing dots/spaces are stripped from each segment the same way Win32
        does (so 'Documents.' cannot sneak past a comparison against 'Documents'). Anything
        ambiguous - UNC/device paths, relative paths, wildcards, streams, unexpanded variables,
        reserved device names, unresolvable 8.3 names - is rejected rather than guessed at.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $p = $Path.Trim().Replace('/', '\')

    if ($p.StartsWith('\\'))                         { throw 'UNC and device paths (\\server\share, \\?\, \\.\) are not supported' }
    if ($p -notmatch '^[A-Za-z]:\\')                 { throw 'Path is not an absolute drive path (e.g. C:\folder)' }
    if ($p -match '%[^%\\]+%' -or $p -match '\$env:') { throw 'Path contains an unexpanded environment variable' }
    if ($p.IndexOfAny([char[]]'*?"<>|') -ge 0)       { throw 'Path contains wildcard or invalid characters' }
    if ($p.IndexOf(':', 2) -ge 0)                    { throw 'Path contains an alternate data stream or stray colon' }
    if ($p -match '[\x00-\x1F]')                     { throw 'Path contains control characters' }
    # checked before GetFullPath, which rewrites e.g. C:\Temp\CON into the device path \\.\CON
    foreach ($segment in $p.Split('\')) {
        if ($segment.TrimEnd('.', ' ') -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\.|$)') { throw "Path contains reserved device name '$segment'" }
    }

    $p = $p -replace '\\{2,}', '\'
    try { $p = [IO.Path]::GetFullPath($p) }
    catch { throw "Path could not be resolved: $($_.Exception.Message)" }

    $segments = $p.TrimEnd('\').Split('\')
    $clean = New-Object 'System.Collections.Generic.List[string]'
    $clean.Add($segments[0].ToUpperInvariant())
    for ($i = 1; $i -lt $segments.Count; $i++) {
        $segment = $segments[$i].TrimEnd('.', ' ')
        if ($segment.Length -eq 0) { throw "Path segment '$($segments[$i])' is ambiguous" }
        $clean.Add($segment)
    }
    if ($clean.Count -eq 1) { return $clean[0] + '\' }
    $p = $clean -join '\'

    if ($p -match '~\d') {
        $long = Resolve-LongPathName -Path $p
        if (-not $long) { throw 'Path contains an 8.3 short name that could not be expanded' }
        $p = $long.Substring(0, 1).ToUpperInvariant() + $long.Substring(1).TrimEnd('\')
    }
    return $p
}

function Get-PathSafetyRules {
    <#
    .SYNOPSIS
        Builds the hard blocklist used by Test-PathSafety from the current machine's known folders.
    .DESCRIPTION
        Each rule has a Mode:
          Exact   - the folder itself (and any ancestor of it) may never be cleaned,
                    but explicitly targeted descendants may (e.g. %LOCALAPPDATA%\Temp).
          Subtree - the folder and everything below it is off limits, except descendants
                    whose relative path matches the rule's Allow regex.
        Patterns are regexes matched against the whole normalized path (any drive).
        Rules are rebuilt on every call so there is no cached state to go stale.
    #>
    [CmdletBinding()]
    param()

    $rules = New-Object 'System.Collections.Generic.List[object]'
    $add = {
        param([string]$Name, [string]$Root, [string]$Mode, [string]$Allow)
        if ([string]::IsNullOrWhiteSpace($Root)) { return }
        try { $normalized = ConvertTo-NormalizedPath -Path $Root }
        catch { Write-Verbose "Path safety rule '$Name' ignored: $_"; return }
        $rules.Add([pscustomobject]@{ Name = $Name; Root = $normalized; Mode = $Mode; Allow = $Allow })
    }

    $userProfile = $env:USERPROFILE
    $local       = $env:LOCALAPPDATA
    $roaming     = $env:APPDATA

    # ---- containers: never a target themselves, descendants may be allowlisted elsewhere
    if ($userProfile) { & $add 'Users folder' (Split-Path -Path $userProfile -Parent) 'Exact' }
    & $add 'User profile'     $userProfile    'Exact'
    & $add 'Public profile'   $env:PUBLIC     'Exact'
    & $add 'Roaming AppData'  $roaming        'Exact'
    & $add 'Local AppData'    $local          'Exact'
    if ($local) { & $add 'LocalLow AppData' (Join-Path (Split-Path -Path $local -Parent) 'LocalLow') 'Exact' }
    & $add 'ProgramData'      $env:ProgramData 'Exact'

    # ---- operating system and installed programs
    # Only Temp and the Update download cache may be touched under Windows. WinSxS, Prefetch,
    # System32 (event logs, registry hives), Installer, servicing etc. are all covered.
    & $add 'Windows'                 $env:SystemRoot             'Subtree' '^(Temp|SoftwareDistribution\\Download)(\\.*)?$'
    & $add 'Program Files'           $env:ProgramFiles           'Subtree'
    & $add 'Program Files (x86)'     ${env:ProgramFiles(x86)}    'Subtree'
    & $add 'Program Files (64-bit)'  $env:ProgramW6432           'Subtree'

    # ---- personal data (both the redirected known-folder location and the default one)
    $known = @(
        @{ Name = 'Desktop';   Folder = 'Desktop';     Default = 'Desktop' },
        @{ Name = 'Documents'; Folder = 'MyDocuments'; Default = 'Documents' },
        @{ Name = 'Pictures';  Folder = 'MyPictures';  Default = 'Pictures' },
        @{ Name = 'Music';     Folder = 'MyMusic';     Default = 'Music' },
        @{ Name = 'Videos';    Folder = 'MyVideos';    Default = 'Videos' },
        @{ Name = 'Favorites'; Folder = 'Favorites';   Default = 'Favorites' }
    )
    foreach ($k in $known) {
        & $add $k.Name ([Environment]::GetFolderPath($k.Folder)) 'Subtree'
        if ($userProfile) { & $add $k.Name (Join-Path $userProfile $k.Default) 'Subtree' }
    }
    if ($userProfile) {
        foreach ($name in 'Downloads', 'Saved Games', 'Contacts', 'Links', 'Searches') {
            & $add $name (Join-Path $userProfile $name) 'Subtree'
        }
    }
    $downloads = $null
    try {
        $shellFolders = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -ErrorAction Stop
        $downloads = $shellFolders.'{374DE290-123F-4565-9164-B4C4D86E8D30}'
    } catch { }
    & $add 'Downloads' $downloads 'Subtree'

    & $add 'OneDrive'              $env:OneDrive           'Subtree'
    & $add 'OneDrive (personal)'   $env:OneDriveConsumer   'Subtree'
    & $add 'OneDrive (work)'       $env:OneDriveCommercial 'Subtree'
    & $add 'Public Desktop'        ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Subtree'
    & $add 'Public Documents'      ([Environment]::GetFolderPath('CommonDocuments'))        'Subtree'
    if ($env:PUBLIC) { & $add 'Public Downloads' (Join-Path $env:PUBLIC 'Downloads') 'Subtree' }

    # ---- browser profiles: cookies, passwords, history, bookmarks, extensions live here.
    # Only the disposable cache folders inside a profile are allowed.
    if ($local) {
        $chromiumCache = '^(Default|Profile [^\\]+)\\(Cache|Code Cache|GPUCache)(\\.*)?$'
        & $add 'Chrome profile data' (Join-Path $local 'Google\Chrome\User Data')               'Subtree' $chromiumCache
        & $add 'Edge profile data'   (Join-Path $local 'Microsoft\Edge\User Data')              'Subtree' $chromiumCache
        & $add 'Brave profile data'  (Join-Path $local 'BraveSoftware\Brave-Browser\User Data') 'Subtree' $chromiumCache
        & $add 'Firefox local profiles' (Join-Path $local 'Mozilla\Firefox\Profiles')           'Subtree' '^[^\\]+\\cache2(\\.*)?$'
    }
    if ($roaming) { & $add 'Firefox profile data' (Join-Path $roaming 'Mozilla\Firefox') 'Subtree' }

    $patterns = @(
        [pscustomobject]@{ Name = 'Recycle Bin';                                Pattern = '^[A-Z]:\\\$Recycle\.Bin(\\|$)' },
        [pscustomobject]@{ Name = 'System Volume Information (restore points)'; Pattern = '^[A-Z]:\\System Volume Information(\\|$)' },
        [pscustomobject]@{ Name = 'Recovery environment';                       Pattern = '^[A-Z]:\\Recovery(\\|$)' },
        [pscustomobject]@{ Name = 'Boot files';                                 Pattern = '^[A-Z]:\\(Boot|EFI)(\\|$)' }
    )

    [pscustomobject]@{
        Roots    = $rules.ToArray()
        Patterns = $patterns
    }
}

function Test-PathSafety {
    <#
    .SYNOPSIS
        Decides whether a folder is safe for WinClean to empty.
    .DESCRIPTION
        Central gate that every cleanup target must pass before anything is enumerated or
        deleted. A path is rejected when it:
          - is empty, relative, UNC/device, wildcarded or otherwise ambiguous;
          - is a drive root or shallower than -MinDepth segments;
          - is, contains, or sits inside a protected location (Windows, Program Files,
            Desktop/Documents/Downloads, user profile, browser profile data, Recycle Bin,
            System Volume Information, ...), unless explicitly allowlisted for that location;
          - passes through a junction or symbolic link (checked when the path exists).
        Rejection is the default for anything that cannot be proven safe.
    .PARAMETER Path
        Absolute folder path to check. Forward slashes are accepted.
    .PARAMETER MinDepth
        Minimum number of folder segments below the drive root. Default 2 (e.g. C:\Windows\Temp).
    .PARAMETER Detailed
        Return a verdict object (IsSafe, NormalizedPath, Reason) instead of a boolean.
    .EXAMPLE
        Test-PathSafety -Path $env:TEMP
    .EXAMPLE
        Test-PathSafety -Path 'C:\Windows\System32' -Detailed
    #>
    [CmdletBinding()]
    [OutputType([bool], [pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path,

        [ValidateRange(1, 64)]
        [int]$MinDepth = 2,

        [switch]$Detailed
    )

    process {
        $verdict = [pscustomobject]@{
            PSTypeName     = 'WinClean.PathSafetyVerdict'
            Path           = $Path
            NormalizedPath = $null
            IsSafe         = $false
            Reason         = $null
        }

        $verdict.Reason = & {
            if ([string]::IsNullOrWhiteSpace($Path)) { return 'Path is empty' }

            try { $n = ConvertTo-NormalizedPath -Path $Path }
            catch { return $_.Exception.Message }
            $verdict.NormalizedPath = $n

            if ($n -match '^[A-Z]:\\$') { return 'Path is a drive root' }

            $depth = $n.Split('\').Count - 1
            if ($depth -lt $MinDepth) { return "Path depth $depth is below the minimum of $MinDepth" }

            $rules = Get-PathSafetyRules
            foreach ($p in $rules.Patterns) {
                if ($n -match $p.Pattern) { return "Protected location: $($p.Name)" }
            }

            $ignoreCase = [StringComparison]::OrdinalIgnoreCase
            foreach ($r in $rules.Roots) {
                $rootPrefix = $r.Root.TrimEnd('\') + '\'
                if ([string]::Equals($n, $r.Root, $ignoreCase)) {
                    return "Protected location: $($r.Name) ($($r.Root))"
                }
                if ($r.Root.StartsWith($n + '\', $ignoreCase)) {
                    return "Path contains protected location: $($r.Name) ($($r.Root))"
                }
                if ($r.Mode -eq 'Subtree' -and $n.StartsWith($rootPrefix, $ignoreCase)) {
                    $relative = $n.Substring($rootPrefix.Length)
                    if (-not $r.Allow -or $relative -notmatch $r.Allow) {
                        return "Path is inside protected location: $($r.Name) ($($r.Root))"
                    }
                }
            }

            # Never follow junctions / symlinks: a reparse point anywhere on the way down could
            # redirect a harmless-looking path into a protected one.
            if (Test-Path -LiteralPath $n) {
                $segments = $n.Split('\')
                $current = $segments[0]
                for ($i = 1; $i -lt $segments.Count; $i++) {
                    $current = $current + '\' + $segments[$i]
                    try { $attributes = [IO.File]::GetAttributes($current) }
                    catch { return "Path could not be inspected at '$current'" }
                    if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
                        return "Path passes through a junction or symbolic link at '$current'"
                    }
                }
            }

            return $null
        }

        $verdict.IsSafe = ($null -eq $verdict.Reason)
        if (-not $verdict.IsSafe) { Write-Verbose ("Test-PathSafety rejected '{0}': {1}" -f $Path, $verdict.Reason) }

        if ($Detailed) { $verdict } else { $verdict.IsSafe }
    }
}
