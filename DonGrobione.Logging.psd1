@{
    RootModule        = 'DonGrobione.Logging.psm1'
    ModuleVersion     = '2.1.0'
    GUID              = 'a87bc0f6-3f00-4785-963a-ba5275f88b43'
    Author            = 'DonGrobione'
    CompanyName       = 'DonGrobione'
    Copyright         = '(c) 2026 DonGrobione. Licensed under the GNU AGPL v3.'
    Description       = 'Central logging for PowerShell scripts: one line per entry, retry on locked files (cloud sync), per-host retention. Never throws.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @('Start-Log', 'Write-Log', 'Stop-Log', 'Test-LogSession', 'Get-LogSession', 'Update-DonGrobioneLogging')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Logging', 'Log', 'LogFile', 'Retention', 'Retry', 'CloudSync', 'Windows', 'PSEdition_Desktop')
            LicenseUri   = 'https://github.com/DonGrobione/Logging/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/DonGrobione/Logging'
            ReleaseNotes = @'
2.1.0
- Start-Log and Stop-Log support -WhatIf and -Confirm. Log retention asks
  ShouldProcess for each file it deletes.
- Update-DonGrobioneLogging asks ShouldProcess for each old version it removes.
- Install.ps1 supports -WhatIf and -Confirm when run as a scriptblock and
  writes its progress with Write-Information instead of Write-Host.
- ReadMe.md is now README.md; CHANGELOG.md added.

Full history: https://github.com/DonGrobione/Logging/blob/main/CHANGELOG.md
'@
        }
    }
}
