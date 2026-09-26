# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`DonGrobione.Logging` is a PowerShell logging module used by all of the user's scripts. **`Docs/Specification.md` is the original requirements spec.** Check it before you change behavior. `README.md` is the user-facing documentation: keep its parameter table and examples in sync when the public API changes. `CHANGELOG.md` (Keep a Changelog format) records every release.

- `DonGrobione.Logging.psm1`: the whole module. Exports `Start-Log`, `Write-Log`, `Stop-Log`, `Test-LogSession`, `Get-LogSession` and `Update-DonGrobioneLogging`. All other functions are private.
- `DonGrobione.Logging.psd1`: the manifest. When you add a public function, update `FunctionsToExport` here and `Export-ModuleMember` in the `.psm1`.
- `Install.ps1`: a standalone installer meant for `irm <raw GitHub URL> | iex`. It duplicates the download, check and install logic of `Update-DonGrobioneLogging` because the module isn't available yet when it runs: its nested `ConvertFrom-ManifestText`, `Confirm-ModuleVersionFolder` and `Install-ModulePackage` are copies of the private module functions of the same name. Keep the two in sync. Unlike the updater, it never removes other versions. The body runs inside `& { param(...) ... }` so that under `iex` no variables (including `$ErrorActionPreference`) leak into the caller's session. Never use `exit` in it: under `iex` that closes the user's shell. Under `iex`, `[CmdletBinding()]` is ignored and `$PSCmdlet` is `$null`, so `-WhatIf`/`-Confirm` only work when it runs as a scriptblock; the script passes `$PSCmdlet` into the child scope as `$Cmdlet` and skips `ShouldProcess` when it is `$null`. It reports progress with `Write-Information -InformationAction Continue`, not `Write-Host`. It is also part of the release zip, so it ends up in every version folder.
- `Examples\Invoke-OrchestratorExample.ps1`: the recommended caller pattern.
- `Tests\DonGrobione.Logging.Tests.ps1`: the Pester tests for the module. `Tests\Install.Tests.ps1`: static (AST) checks of `Install.ps1`, which must never actually run in a test.

## Commands

The tests target **Pester 3.4.0**, the version bundled with Windows PowerShell 5.1. Use its syntax: `Should Be`, not `Should -Be`. Run the tests under Windows PowerShell (`powershell.exe`), not pwsh.

```powershell
# All tests
powershell -NoProfile -Command "Invoke-Pester -Script .\Tests"

# One Describe block (in Pester 3, -TestName only filters Describe names, not individual Its)
powershell -NoProfile -Command "Invoke-Pester -Script .\Tests -TestName 'Retention'"

Test-ModuleManifest .\DonGrobione.Logging.psd1
```

Each feature has its own Describe block (Formatting, Timestamp, Default configuration, Retention, Safety, Retry, Session, ShouldProcess, Manifest, Update, Installer) so it can be run alone with `-TestName`.

**CI:** `.github/workflows/test.yml` runs on every push and pull request, on `windows-latest` with `shell: powershell` (5.1). It checks the version, parses every script with the 5.1 parser, checks that the `.psm1`/`.psd1` are ASCII-only, validates the manifest, and runs the tests with Pester 3.4.0 (installing it if the runner image lacks it). `release.yml` calls it as a reusable workflow and only releases if it passes.

## Quality and release rules

- **PSScriptAnalyzer:** the code must produce zero findings with the default rule set, although CI does not run it (see the README for the command). Test helpers suppress `PSUseShouldProcessForStateChangingFunctions` and `PSUseDeclaredVarsMoreThanAssignments` with a file-level `SuppressMessageAttribute`.
- **Functions:** every function, private ones included, has `[CmdletBinding()]` and `[Parameter()]` attributes with validation. Functions with state-changing verbs (New, Set, Remove, Start, Stop, Update, ...) use `SupportsShouldProcess` and call `ShouldProcess`. Private functions inherit `-WhatIf`/`-Confirm` from their public caller, so don't also ask in the caller (that would prompt twice). No `Write-Host`: use `Write-Verbose`, `Write-Warning` or `Write-Information`. No email addresses, secrets or machine-specific paths.
- **Gallery readiness:** the project isn't published to the PowerShell Gallery, but the manifest must stay publishable: `Author = 'DonGrobione'`, an explicit `FunctionsToExport` (never `'*'`), `PowerShellVersion = '5.1'`, `Tags`, `ProjectUri`, `LicenseUri` (the GitHub URL of `LICENSE`) and `ReleaseNotes`. `README.md`, `LICENSE` and `CHANGELOG.md` stay in the root. The Manifest tests check this.
- **Releases:** SemVer. For every release-relevant change, bump `ModuleVersion`, rewrite `ReleaseNotes` (it must mention the version) and add a `## [x.y.z] - yyyy-MM-dd` section plus a compare link to `CHANGELOG.md`. A pushed version bump on `main` publishes a release.
- **Tests:** every new or changed function gets tests. New script files get their own `Tests\<Name>.Tests.ps1`.

## Architecture and constraints

- **Configuration:** it lives in `$script:LogConfig`, where `$null` means not initialized. `Start-Log` and the default fallback in `Write-Log` both go through `Initialize-LogSession`, so the fallback also creates the directory and applies retention. `Stop-Log` only resets `$script:LogConfig`, because no file handles are kept open. Callers must not read `$script:LogConfig`; `Test-LogSession` is the public way to ask whether a session is running, and `Get-LogSession` returns a copy of its settings.
- **Base path:** `Get-LogBasePath` returns `<MyDocuments>\Logs`. It is a separate function so tests can mock it into `$TestDrive`. In Pester 3.4 the mock body must be a literal scriptblock, because `[scriptblock]::Create` breaks Pester's closure check. `Get-Date` is mocked the same way for the timestamp test.
- **Line format:** `yyyy-MM-dd HH:mm:ss [LEVEL] Message`, built with `InvariantCulture`. Continuation lines start with `    -> ` (four spaces, then an arrow). `Format-LogEntry` builds the whole entry as one string, which is appended in a single write.
- **Cloud sync:** the log folder is synced by a cloud client that briefly locks files. Because of that:
  - Every write is a single `[IO.File]::AppendAllText` call (open, append, close), in UTF-8 with a BOM on new files.
  - Writes and directory creation go through `Invoke-WithRetry`. `RetryCount` is the total number of attempts, and the delay grows linearly (`RetryDelayMs` × attempt).
  - If all attempts fail, `Write-LogFallback` writes the full entry with `Write-Warning`.
- **Retention:** it only matches `<COMPUTERNAME>_*.log`. The underscore is deliberate, so that HOST1 never deletes HOST10's files. It keeps `RetentionCount - 1` older files plus the current session's file. Files it can't delete are skipped. `Invoke-LogRetention` asks `ShouldProcess` for each file.
- **ShouldProcess:** `Start-Log -WhatIf` changes nothing (no session, no directory, no deletion). A `ShouldProcess` call throws if the user halts at a `-Confirm` prompt, so it sits inside try/catch like everything else in the logging functions. `Start-Log` passes its parameters to `Initialize-LogSession` explicitly: splatting `$PSBoundParameters` would forward `-WhatIf`/`-Confirm`.
- **The logging functions must never throw.** `Start-Log`, `Write-Log` and `Stop-Log` wrap their bodies in try/catch. `Write-LogFallback` swallows its own failure, which matters if the caller sets `$WarningPreference = 'Stop'`. `FATAL` is only a severity label: stopping the script is the caller's job (see the example).
- **Updater:** `Update-DonGrobioneLogging` is the exception to the no-throw rule: it reports problems with `Write-Error` and returns a result object. It uses the standard versioned layout `<Modules>\DonGrobione.Logging\<version>\`. `Get-ModuleInstallPath` (which tests mock) returns the module base folder, and `Get-InstalledModuleVersion` lists its version folders plus the legacy flat layout of versions up to 1.2.1 (manifest directly in the base folder). The updater reads `releases/latest` from the GitHub API and compares versions as `[version]`, never as strings (5.1 has no `[semver]`). `Install-ModulePackage` checks the zip's manifest in memory, creates the version folder (it refuses if the folder exists) and extracts directly into it, with no staging folder. `Confirm-ModuleVersionFolder` then checks that the folder name, the manifest's `ModuleVersion` and an `Import-Module` in a separate runspace all agree. Only after that are older versions removed; for the legacy layout that means only the files in `$script:LegacyFiles` (which lists `README.md`: Windows paths are case-insensitive, so it also matches the `ReadMe.md` that versions up to 2.0.0 shipped). When you add a file to the release zip, add it there too: the 1.2.1 updater installs a new release in the flat layout, so every file in the zip can end up in the base folder. `Get-LockedFile` skips a version whose files are in use; the next run retries. At the end the updater reloads the module (import the new version first, then remove the old one) if the session ran a copy that was just replaced. It never changes a base folder that contains `.git`. The release zip layout (one top-level `DonGrobione.Logging` folder, built by `.github/workflows/release.yml`) must stay as it is: the 1.2.1 updater in existing flat installs depends on it to update to the version that migrates them. Avoid `Select-Object -First` in module code: in 5.1 it leaks a `StopUpstreamCommandsException` into the caller's `-ErrorVariable`. More generally, 5.1 records every exception caught below a call in that call's `-ErrorVariable`, so success paths must not throw and catch internally.
- **Never let a test or experiment reach the real module folder.** The user's module folder is under `D:\HiDrive\Eigene Dokumente\WindowsPowerShell\Modules`. After a reload in the updater, the freshly imported module has none of the mocks or overrides of the old one, so a second call goes to the real folder.
- **Environment:** Windows PowerShell 5.1, no external modules, approved verbs, and comment-based help on every public function. Keep the `.psm1`/`.psd1` ASCII-only: 5.1 reads BOM-less files as ANSI.
- **Localized test machine:** on the user's German Windows, stack traces say `bei` instead of `at`. Test assertions must not depend on localized text.
