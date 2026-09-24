#Requires -Version 5.1
<#
.SYNOPSIS
    Recommended caller pattern for DonGrobione.Logging.

.DESCRIPTION
    - $ErrorActionPreference = 'Stop' turns every error into a terminating one,
      so it lands in the catch block.
    - The module never throws. Stopping the script is the caller's job: log
      FATAL with the caught ErrorRecord, then exit 1.
    - Stop-Log runs in finally, whether or not the script failed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Once the module folder is in $env:PSModulePath (e.g. Documents\WindowsPowerShell\Modules\DonGrobione.Logging),
# 'Import-Module DonGrobione.Logging' is enough.
Import-Module (Join-Path $PSScriptRoot '..\DonGrobione.Logging.psd1')

Start-Log -LogDirectory 'OrchestratorExample'

$exitCode = 0
try {
    Write-Log 'Script started'

    Write-Log -Level DEBUG -Message 'Not written: below the default MinimumLevel INFO'
    Write-Log "Processing batch`r`nItems: 42`r`nSource: DC01.mydomain.local"

    # Simulated failure - replace with the real work.
    Get-Item -Path 'C:\does\not\exist'

    Write-Log 'Script finished successfully'
}
catch {
    # -ErrorRecord adds the exception message and stack trace as continuation lines.
    Write-Log -Level FATAL -Message 'Script aborted' -ErrorRecord $_
    $exitCode = 1
}
finally {
    Stop-Log
}

exit $exitCode
