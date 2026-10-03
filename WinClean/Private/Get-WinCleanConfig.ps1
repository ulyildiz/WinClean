function ConvertTo-WinCleanTarget {
    <#
    .SYNOPSIS
        Validates one config entry. Never throws: an invalid entry comes back with .Error set,
        so it is reported as a skipped target instead of being guessed at or aborting the run.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Entry,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$Source
    )

    $target = [pscustomobject]@{
        PSTypeName    = 'WinClean.Target'
        Label         = "targets[$Index]"
        Path          = $null
        ExpandedPath  = $null
        AgeHours      = $null
        Category      = $null
        RequiresAdmin = $false
        Enabled       = $true
        Source        = $Source
        Error         = $null
    }

    if ($Entry -isnot [pscustomobject]) {
        $target.Error = 'Config entry is not a JSON object'
        return $target
    }

    $known = 'label', 'path', 'ageHours', 'category', 'requiresAdmin', 'enabled'
    $props = $Entry.PSObject.Properties
    foreach ($p in $props) {
        if ($known -notcontains $p.Name) { Write-Warning ("WinClean config ({0}) targets[{1}]: unknown property '{2}' ignored" -f $Source, $Index, $p.Name) }
    }

    $label = $props['label']
    if ($label -and $label.Value -is [string] -and -not [string]::IsNullOrWhiteSpace($label.Value)) { $target.Label = $label.Value.Trim() }
    else { $target.Error = "'label' must be a non-empty string"; return $target }

    $path = $props['path']
    if ($path -and $path.Value -is [string] -and -not [string]::IsNullOrWhiteSpace($path.Value)) { $target.Path = $path.Value }
    else { $target.Error = "'path' must be a non-empty string"; return $target }

    $category = $props['category']
    if ($category -and $category.Value -is [string] -and $category.Value -cmatch '^[a-z][a-z0-9-]*$') { $target.Category = $category.Value }
    else { $target.Error = "'category' must be a lowercase word such as 'temp' or 'cache'"; return $target }

    $age = $props['ageHours']
    if ($age -and $null -ne $age.Value) {
        $isInteger = ($age.Value -is [int]) -or ($age.Value -is [long])
        if (-not $isInteger -or $age.Value -lt 0 -or $age.Value -gt 8760) {
            $target.Error = "'ageHours' must be null or a whole number from 0 to 8760"
            return $target
        }
        $target.AgeHours = [int]$age.Value
    }

    foreach ($flag in 'requiresAdmin', 'enabled') {
        $p = $props[$flag]
        if ($p -and $null -ne $p.Value) {
            if ($p.Value -isnot [bool]) { $target.Error = "'$flag' must be true or false"; return $target }
            $target.$flag = $p.Value
        }
    }

    try { $target.ExpandedPath = Expand-WinCleanPath -Path $target.Path }
    catch { $target.Error = $_.Exception.Message }

    return $target
}

function Read-WinCleanConfigFile {
    <#
    .SYNOPSIS
        Parses one config file. Throws when the file itself is unusable (missing, bad JSON,
        wrong shape) so the run stops before anything is deleted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Source
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "WinClean config file not found: $Path" }

    try { $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "WinClean config file is not valid JSON: $Path ($($_.Exception.Message))" }

    if ($json -isnot [pscustomobject]) { throw "WinClean config file must contain a JSON object: $Path" }

    $version = $json.PSObject.Properties['version']
    if ($version -and $version.Value -ne 1) { throw "WinClean config file has unsupported version '$($version.Value)': $Path" }

    $targetsProp = $json.PSObject.Properties['targets']
    if (-not $targetsProp -or $targetsProp.Value -isnot [array]) {
        throw "WinClean config file must contain a 'targets' array: $Path"
    }

    $targets = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $i = 0
    foreach ($entry in @($targetsProp.Value)) {
        $t = ConvertTo-WinCleanTarget -Entry $entry -Index $i -Source $Source
        $key = $t.Label.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            $t.Error = "Duplicate label '$($t.Label)' in $Source config"
        }
        $seen[$key] = $true
        $targets.Add($t)
        $i++
    }

    [pscustomobject]@{
        Path    = $Path
        Json    = $json
        Targets = $targets.ToArray()
    }
}

function Get-WinCleanConfig {
    <#
    .SYNOPSIS
        Loads the cleanup targets from Config\winclean.config.json.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $defaultPath = Join-Path $script:ModuleRoot 'Config\winclean.config.json'
    $default = Read-WinCleanConfigFile -Path $defaultPath -Source 'default'

    [pscustomobject]@{
        PSTypeName  = 'WinClean.Config'
        DefaultPath = $defaultPath
        Targets     = $default.Targets
    }
}
