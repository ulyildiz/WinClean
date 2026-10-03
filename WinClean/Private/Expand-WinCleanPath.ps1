function Expand-WinCleanPath {
    <#
    .SYNOPSIS
        Expands %VAR%, $env:VAR and ${env:VAR} references in a configured path.
    .DESCRIPTION
        Expansion is a single pass (values are never re-expanded). An undefined or empty
        variable throws instead of silently becoming '' - '$env:MISSING\Temp' must never
        turn into '\Temp', and 'C:\Data\%MISSING%' must never turn into 'C:\Data\'.
    .EXAMPLE
        Expand-WinCleanPath '%LOCALAPPDATA%\D3DSCache'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $regex = [regex]'\$\{env:(?<name>[^}]+)\}|\$env:(?<name>[A-Za-z_][A-Za-z0-9_]*)|%(?<name>[A-Za-z_][A-Za-z0-9_()]*)%'

    foreach ($m in $regex.Matches($Path)) {
        $name = $m.Groups['name'].Value
        if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name))) {
            throw "Environment variable '$name' is not defined"
        }
    }

    $evaluator = [Text.RegularExpressions.MatchEvaluator] {
        param($m)
        [Environment]::GetEnvironmentVariable($m.Groups['name'].Value)
    }
    return $regex.Replace($Path, $evaluator)
}
