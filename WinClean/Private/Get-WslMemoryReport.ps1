function Get-WslMemoryReport {
    <#
    .SYNOPSIS
        Reports how much memory the WSL 2 / Docker Desktop VM holds and how to reclaim it.
    .DESCRIPTION
        Report only: WinClean never runs 'wsl --shutdown', which would stop every running
        distro and Docker Desktop's WSL engine.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$WslConfigPath = (Join-Path $env:USERPROFILE '.wslconfig'))

    $report = [pscustomobject]@{
        PSTypeName            = 'WinClean.WslReport'
        Running               = $false
        Process               = $null
        Bytes                 = 0L
        AutoReclaimConfigured = $false
        Steps                 = @()
    }

    $vm = @(Get-Process -Name 'vmmemWSL', 'vmmem' -ErrorAction SilentlyContinue) | Select-Object -First 1
    if (-not $vm) { return $report }

    $report.Running = $true
    $report.Process = $vm.Name
    try { $report.Bytes = [long]$vm.WorkingSet64 } catch { }

    if (Test-Path -LiteralPath $WslConfigPath -PathType Leaf) {
        $content = Get-Content -LiteralPath $WslConfigPath -Raw -ErrorAction SilentlyContinue
        $report.AutoReclaimConfigured = [bool]($content -match '(?im)^\s*autoMemoryReclaim\s*=\s*(gradual|dropcache)\s*$')
    }

    $steps = @('wsl --shutdown releases it immediately (stops all distros and Docker Desktop''s WSL engine)')
    if (-not $report.AutoReclaimConfigured) {
        $steps += ("add 'autoMemoryReclaim=gradual' under [experimental] in {0} so idle memory is returned automatically" -f $WslConfigPath)
    }
    $report.Steps = $steps
    return $report
}
