@{
    RootModule           = 'WinClean.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '30884e9f-2b8e-4a1e-8197-96396ae02da0'
    Author               = 'Ulaş Berke Yıldız'
    Copyright            = '(c) 2026 Ulaş Berke Yıldız. All rights reserved.'
    Description          = 'Safe Windows temp, cache and RAM standby-list cleaner. Allowlist-driven, dry-runnable, never follows junctions or symlinks.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport    = @('Invoke-WinClean', 'Get-WinCleanReport')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags         = @('Windows', 'Cleanup', 'Temp', 'Cache', 'Maintenance', 'PSEdition_Desktop', 'PSEdition_Core')
            ReleaseNotes = '0.1.0 - Module scaffold, centralized Test-PathSafety guard, Pester test suite.'
        }
    }
}
