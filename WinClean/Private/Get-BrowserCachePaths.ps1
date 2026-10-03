function Get-BrowserCachePaths {
    <#
    .SYNOPSIS
        Lists browser cache folders only - never cookies, logins, history, bookmarks or extensions.
    #>
    [CmdletBinding()]
    param()

    $result = @()
    $la = $env:LOCALAPPDATA
    if (-not $la) { return $result }

    # Chromium family: only cache folders, never cookies / logins / history
    $chromium = @(
        @{ Name = 'Chrome'; Root = (Join-Path $la 'Google\Chrome\User Data') },
        @{ Name = 'Edge';   Root = (Join-Path $la 'Microsoft\Edge\User Data') },
        @{ Name = 'Brave';  Root = (Join-Path $la 'BraveSoftware\Brave-Browser\User Data') }
    )
    foreach ($b in $chromium) {
        if (-not (Test-Path -LiteralPath $b.Root)) { continue }
        Get-ChildItem -LiteralPath $b.Root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } |
            ForEach-Object {
                foreach ($sub in 'Cache', 'Code Cache', 'GPUCache') {
                    $p = Join-Path $_.FullName $sub
                    if (Test-Path -LiteralPath $p) {
                        $result += @{ Label = ('{0} {1} - {2}' -f $b.Name, $_.Name, $sub); Path = $p }
                    }
                }
            }
    }

    # Firefox: cache2 only
    $ff = Join-Path $la 'Mozilla\Firefox\Profiles'
    if (Test-Path -LiteralPath $ff) {
        Get-ChildItem -LiteralPath $ff -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Join-Path $_.FullName 'cache2'
            if (Test-Path -LiteralPath $p) { $result += @{ Label = 'Firefox cache'; Path = $p } }
        }
    }
    return $result
}
