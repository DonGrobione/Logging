@{
    RootModule        = 'DonGrobione.Logging.psm1'
    ModuleVersion     = '1.2.1'
    GUID              = 'a87bc0f6-3f00-4785-963a-ba5275f88b43'
    Author            = 'DonGrobione'
    Copyright         = '(c) 2026 DonGrobione. Licensed under the GNU AGPL v3.'
    Description       = 'Central logging for PowerShell scripts: one line per entry, retry on locked files (cloud sync), per-host retention. Never throws.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @('Start-Log', 'Write-Log', 'Stop-Log', 'Test-LogSession', 'Get-LogSession', 'Update-DonGrobioneLogging')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Logging', 'Log')
            LicenseUri = 'https://www.gnu.org/licenses/agpl-3.0.html'
            ProjectUri = 'https://github.com/DonGrobione/Logging'
        }
    }
}
