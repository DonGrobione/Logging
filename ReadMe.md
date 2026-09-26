# DonGrobione.Logging

A PowerShell module that gives all your scripts the same log format and log location.

- One timestamped line per entry. Multi-line messages and error details continue on lines indented with `    -> `.
- Logs go to `<Documents>\Logs\<Project>\<HOSTNAME>_yyyy-MM-dd_HH-mm-ss.log`.
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

Run this in PowerShell. It downloads the latest release and installs it into a version folder of your module folder (`Documents\WindowsPowerShell\Modules\DonGrobione.Logging\<version>`, or `Documents\PowerShell\Modules\...` in PowerShell 7):

```powershell
irm https://raw.githubusercontent.com/DonGrobione/Logging/main/Install.ps1 | iex
```

To pass options, run the script as a scriptblock instead. `-Scope AllUsers` installs to Program Files (needs an administrator session):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/DonGrobione/Logging/main/Install.ps1))) -Scope AllUsers
```

The installer only adds the new version folder and never touches other installed versions; PowerShell loads the newest one. It checks the package before writing anything and verifies the installed folder afterwards (folder name, `ModuleVersion` and `Import-Module` must match). If that version's folder already exists, it stops with an error: to reinstall, delete that folder first. It leaves a git clone alone. To remove older versions as well, use `Update-DonGrobioneLogging`.

**Manual installation:** the zip contains a `DonGrobione.Logging` folder with the module files and `Install.ps1`. Copy them into a folder named exactly like the `ModuleVersion` in the manifest, otherwise PowerShell ignores them:

```powershell
$zip     = Get-Item "$HOME\Downloads\DonGrobione.Logging-*.zip"   # from the latest release
$version = $zip.BaseName -replace '^DonGrobione\.Logging-'
$target  = "$([Environment]::GetFolderPath('MyDocuments'))\WindowsPowerShell\Modules\DonGrobione.Logging\$version"
$temp    = Join-Path $env:TEMP "DonGrobione.Logging-$version"
Expand-Archive -Path $zip -DestinationPath $temp -Force
New-Item -ItemType Directory -Path $target | Out-Null
Copy-Item "$temp\DonGrobione.Logging\*" $target
Get-ChildItem $target | Unblock-File   # remove the "downloaded from the internet" mark
```

After that, `Import-Module DonGrobione.Logging` works from any script. You can also import the module directly by path, without installing it:

```powershell
Import-Module 'C:\Path\To\DonGrobione.Logging\DonGrobione.Logging.psd1'
```

**From git instead:** the folder must be named `DonGrobione.Logging`, the same as the module. A plain clone creates a folder called `Logging`, so give the name explicitly. Update a clone with `git pull`; `Update-DonGrobioneLogging` and the installer leave it alone. Don't mix a clone with version folders: PowerShell always prefers a version folder over files directly in `DonGrobione.Logging`.

```powershell
git clone https://github.com/DonGrobione/Logging.git "$([Environment]::GetFolderPath('MyDocuments'))\WindowsPowerShell\Modules\DonGrobione.Logging"
```

## Updating

`Update-DonGrobioneLogging` checks the latest GitHub release and compares its version with the newest version installed in the default module folder. If the release is newer, it installs it into its own version folder, verifies it, and only then removes the older versions.

```powershell
Update-DonGrobioneLogging            # update if a newer release exists
Update-DonGrobioneLogging -WhatIf    # only show whether an update is available
```

```
InstalledVersion LatestVersion Path                                                                Updated
---------------- ------------- ----                                                                -------
1.2.1            1.3.0         C:\Users\me\Documents\WindowsPowerShell\Modules\DonGrobione.Logging\1.3.0 True
```

- **Where it installs:** `Documents\WindowsPowerShell\Modules\DonGrobione.Logging\<version>` (or `Documents\PowerShell\Modules\...` in PowerShell 7). Use `-Scope AllUsers` for `Program Files\...\Modules`; that needs an administrator session.
- **First install:** if the module isn't installed there yet, it installs it. So you can also import the module by path once and run `Update-DonGrobioneLogging` to install it.
- **Safety:** the package's version is checked before anything is written. The new version folder must pass the same checks as with the installer; if it doesn't, it is removed again and the installed version stays as it was. A git clone is left alone.
- **Old versions:** after a successful update, all older versions in that module folder are removed. If one of their files is in use (for example by another session or the sync client), that version stays and you get a warning; close the other sessions and run `Update-DonGrobioneLogging` again to remove it.
- **Existing version folder:** if the folder for the latest version already exists but isn't a valid installation, the update stops with an error. Delete that folder and run it again.
- **After updating:** if your session loaded the module from the folder that was updated, the new version is loaded in its place. That ends a running logging session, as `Stop-Log` does, so update before `Start-Log`. Other open sessions keep the old version until they are restarted.
- **Errors:** unlike the logging functions, the updater reports problems (for example, no internet connection) as normal PowerShell errors. On a failed update, `-ErrorVariable` can hold more than one record; the last one is the updater's summary.

**Upgrading from 1.2.1 or older:** those versions installed the files directly into `Modules\DonGrobione.Logging`, without a version folder. Nothing needs to be done by hand:

1. Run `Update-DonGrobioneLogging` as usual. The old updater still understands the release zip, so it installs the new version in the old layout.
2. Run `Update-DonGrobioneLogging` once more, in a new session. The new updater finds the old layout, installs the latest release into its version folder, verifies it, and then deletes only the old module files (`DonGrobione.Logging.psd1`, `.psm1`, `LICENSE`, `ReadMe.md`, `Install.ps1`) from `Modules\DonGrobione.Logging`.

Running the installer on an old installation also works: it adds the version folder, which PowerShell prefers from then on, and warns that the old files are still there until the next `Update-DonGrobioneLogging` removes them.

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
| `-LogFileName`    | `<HOSTNAME>_yyyy-MM-dd_HH-mm-ss.log`  | Name of the log file. |
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

## Checking for a running session

`Test-LogSession` returns `$true` while a session is active and `$false` otherwise. A sub-script can use it to log into its caller's session when there is one, and to start its own when it runs alone:

```powershell
$ownSession = -not (Test-LogSession)
if ($ownSession) {
    Start-Log -LogDirectory 'Sync-ADUsers'
}
try {
    Write-Log 'Sub-script started'
    # ...
}
finally {
    # Only end the session this script started, not the caller's.
    if ($ownSession) { Stop-Log }
}
```

A `Write-Log` call without `Start-Log` also starts a session (with the default configuration), so `Test-LogSession` returns `$true` after it.

## Reading the session settings

`Get-LogSession` returns the settings of the running session: `Directory`, `FilePath`, `RetentionCount`, `MinimumLevel`, `RetryCount` and `RetryDelayMs`.
It returns `$null` when no session is running, and it never starts one.
The result is a copy, so changing it does not change the session.

For example, to write a report next to the log files:

```powershell
$session = Get-LogSession
if ($session) {
    $users | Export-Csv -Path (Join-Path $session.Directory 'Users.csv') -NoTypeInformation
}
```

Retention only deletes `<HOSTNAME>_*.log` files, so other files in the log directory are kept.

## Running the tests

The tests use Pester 3.4, which comes with Windows PowerShell 5.1:

```powershell
powershell -NoProfile -Command "Invoke-Pester -Script .\Tests"
```

GitHub Actions runs the same tests on Windows PowerShell 5.1 for every push and pull request. A release is only published if they pass.

## License

GNU Affero General Public License v3.0. See [LICENSE](LICENSE).
