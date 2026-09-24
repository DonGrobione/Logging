# DonGrobione.Logging

A PowerShell module that gives all your scripts the same log format and log location.

- One timestamped line per entry. Multi-line messages and error details continue on lines indented with `    -> `.
- Logs go to `<Documents>\Logs\<Project>\<HOSTNAME>_yyyy-MM-dd_HHmmss.log`.
- Writes are retried when a cloud sync client briefly locks the file.
- Old log files are cleaned up automatically, and only files from the current computer are touched.
- **The module never throws.** If a log entry can't be written, it is shown as a console warning instead, and your script keeps running.

Requires Windows PowerShell 5.1 or later. No other modules are needed.

```
2026-09-17 14:50:58 [INFO] Sync started
2026-09-17 14:50:58 [ERROR] Sync-ADUsers failed
    -> Exception: Connection to domain controller unavailable
    -> StackTrace: at Connect-DC, C:\Scripts\Sync-ADUsers.ps1: line 42
```

## Installation

1. Download `DonGrobione.Logging-<version>.zip` from the [latest release](https://github.com/DonGrobione/Logging/releases/latest).
2. Extract it into your module folder. The zip already contains the `DonGrobione.Logging` folder:

```powershell
$modules = "$([Environment]::GetFolderPath('MyDocuments'))\WindowsPowerShell\Modules"
Expand-Archive -Path "$HOME\Downloads\DonGrobione.Logging-*.zip" -DestinationPath $modules -Force
Get-ChildItem "$modules\DonGrobione.Logging" | Unblock-File   # remove the "downloaded from the internet" mark
```

After that, `Import-Module DonGrobione.Logging` works from any script. You can also import the module directly by path, without installing it:

```powershell
Import-Module 'C:\Path\To\DonGrobione.Logging\DonGrobione.Logging.psd1'
```

**From git instead:** the folder must be named `DonGrobione.Logging`, the same as the module. A plain clone creates a folder called `Logging`, so give the name explicitly. Update a clone with `git pull`, not with `Update-DonGrobioneLogging`.

```powershell
git clone https://github.com/DonGrobione/Logging.git "$([Environment]::GetFolderPath('MyDocuments'))\WindowsPowerShell\Modules\DonGrobione.Logging"
```

## Updating

`Update-DonGrobioneLogging` checks the latest GitHub release and compares its version with the version installed in the default module folder. If the release is newer, it downloads the zip and overwrites the installed module files.

```powershell
Update-DonGrobioneLogging            # update if a newer release exists
Update-DonGrobioneLogging -WhatIf    # only show whether an update is available
Update-DonGrobioneLogging -Force     # reinstall even if the version is current
```

```
InstalledVersion LatestVersion Path                                                         Updated
---------------- ------------- ----                                                         -------
1.0.0            1.1.0         C:\Users\me\Documents\WindowsPowerShell\Modules\DonGrobione.Logging True
```

- **Where it installs:** `Documents\WindowsPowerShell\Modules\DonGrobione.Logging` (or `Documents\PowerShell\Modules` in PowerShell 7). Use `-Scope AllUsers` for `Program Files\...\Modules`; that needs an administrator session.
- **First install:** if the module isn't installed there yet, it installs it. So you can also import the module by path once and run `Update-DonGrobioneLogging` to install it.
- **Safety:** the downloaded package is checked before anything is overwritten. A folder that is a git clone is left alone unless you add `-Force`.
- **After updating:** your current PowerShell session still uses the old version. Open a new session, or run `Import-Module DonGrobione.Logging -Force`.
- **Errors:** unlike the logging functions, the updater reports problems (for example, no internet connection) as normal PowerShell errors.

## Initializing logging in a script

Call `Start-Log` once at the top of the script. All settings are optional.

**Minimal.** Logs to `<Documents>\Logs\Sync-ADUsers\<HOSTNAME>_<timestamp>.log`:

```powershell
Import-Module DonGrobione.Logging
Start-Log -LogDirectory 'Sync-ADUsers'
Write-Log 'Sync started'
```

**All options:**

```powershell
Start-Log -LogDirectory   'Sync-ADUsers' `
          -LogFileName    'Sync.log' `
          -RetentionCount 10 `
          -MinimumLevel   DEBUG `
          -RetryCount     5 `
          -RetryDelayMs   250
```

| Parameter         | Default                             | Meaning |
|-------------------|-------------------------------------|---------|
| `-LogDirectory`   | `Default`                           | Subfolder under `<Documents>\Logs`, usually the project name. |
| `-LogFileName`    | `<HOSTNAME>_yyyy-MM-dd_HHmmss.log`  | Name of the log file. |
| `-RetentionCount` | `5`                                 | How many `<HOSTNAME>_*.log` files to keep in the folder, including the current one. Files from other computers are never deleted. |
| `-MinimumLevel`   | `INFO`                              | Entries below this level are not written. Order: `DEBUG` < `INFO` < `WARN` < `ERROR` < `FATAL`. |
| `-RetryCount`     | `3`                                 | Total number of attempts per write. |
| `-RetryDelayMs`   | `500`                               | Wait before the first retry. Each later retry waits longer (500 ms, then 1000 ms, and so on). |

**Without initialization.** If you call `Write-Log` without `Start-Log`, it logs to `<Documents>\Logs\Default\` with the default settings:

```powershell
Import-Module DonGrobione.Logging
Write-Log 'Quick one-off message'
```

## Writing log entries

```powershell
Write-Log 'Sync started'                                  # Level INFO
Write-Log -Level DEBUG -Message "Found $($users.Count) users"
Write-Log -Level WARN  -Message "User $sam has no mailbox"

# Line breaks in the message become continuation lines
Write-Log "Processing batch`r`nItems: 42`r`nSource: DC01"

# Pass the caught error to log its exception message and stack trace
try {
    Connect-DC -Server 'DC01'
}
catch {
    Write-Log -Level ERROR -Message 'Sync-ADUsers failed' -ErrorRecord $_
}
```

## Recommended script structure

`FATAL` only labels the entry. The module never stops your script. Stopping it is the script's job:

```powershell
$ErrorActionPreference = 'Stop'

Import-Module DonGrobione.Logging
Start-Log -LogDirectory 'Sync-ADUsers'

$exitCode = 0
try {
    Write-Log 'Script started'

    # ... your work ...

    Write-Log 'Script finished successfully'
}
catch {
    Write-Log -Level FATAL -Message 'Script aborted' -ErrorRecord $_
    $exitCode = 1
}
finally {
    Stop-Log
}

exit $exitCode
```

A runnable version is in [Examples/Invoke-OrchestratorExample.ps1](Examples/Invoke-OrchestratorExample.ps1).

## Running the tests

The tests use Pester 3.4, which comes with Windows PowerShell 5.1:

```powershell
powershell -NoProfile -Command "Invoke-Pester -Script .\Tests"
```

## License

GNU Affero General Public License v3.0. See [LICENSE](LICENSE).
