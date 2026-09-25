# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`DonGrobione.Logging` is a PowerShell logging module used by all of the user's scripts. **`Docs/Specification.md` is the original requirements spec.** Check it before you change behavior. `ReadMe.md` is the user-facing documentation: keep its parameter table and examples in sync when the public API changes.

- `DonGrobione.Logging.psm1`: the whole module. Exports `Start-Log`, `Write-Log`, `Stop-Log`, `Test-LogSession` and `Update-DonGrobioneLogging`. All other functions are private.
- `DonGrobione.Logging.psd1`: the manifest. When you add a public function, update `FunctionsToExport` here and `Export-ModuleMember` in the `.psm1`.
- `Install.ps1`: a standalone installer meant for `irm <raw GitHub URL> | iex`. It duplicates the download, check and install logic of `Update-DonGrobioneLogging` because the module isn't available yet when it runs. Keep the two in sync. The body runs inside `& { param(...) ... }` so that under `iex` no variables (including `$ErrorActionPreference`) leak into the caller's session. Never use `exit` in it: under `iex` that closes the user's shell. It is not part of the release zip.
- `Examples\Invoke-OrchestratorExample.ps1`: the recommended caller pattern.
- `Tests\DonGrobione.Logging.Tests.ps1`: the Pester tests.

## Commands

The tests target **Pester 3.4.0**, the version bundled with Windows PowerShell 5.1. Use its syntax: `Should Be`, not `Should -Be`. Run the tests under Windows PowerShell (`powershell.exe`), not pwsh.

```powershell
# All tests
powershell -NoProfile -Command "Invoke-Pester -Script .\Tests"

# One Describe block (in Pester 3, -TestName only filters Describe names, not individual Its)
powershell -NoProfile -Command "Invoke-Pester -Script .\Tests -TestName 'Retention'"

Test-ModuleManifest .\DonGrobione.Logging.psd1
```

Each feature has its own Describe block (Formatting, Timestamp, Default configuration, Retention, Safety, Retry, Session, Update) so it can be run alone with `-TestName`.

**CI:** `.github/workflows/test.yml` runs on every push and pull request, on `windows-latest` with `shell: powershell` (5.1). It checks the version, parses every script with the 5.1 parser, checks that the `.psm1`/`.psd1` are ASCII-only, validates the manifest, and runs the tests with Pester 3.4.0 (installing it if the runner image lacks it). `release.yml` calls it as a reusable workflow and only releases if it passes.

## Architecture and constraints

- **Configuration:** it lives in `$script:LogConfig`, where `$null` means not initialized. `Start-Log` and the default fallback in `Write-Log` both go through `Initialize-LogSession`, so the fallback also creates the directory and applies retention. `Stop-Log` only resets `$script:LogConfig`, because no file handles are kept open. Callers must not read `$script:LogConfig`; `Test-LogSession` is the public way to ask whether a session is running.
- **Base path:** `Get-LogBasePath` returns `<MyDocuments>\Logs`. It is a separate function so tests can mock it into `$TestDrive`. In Pester 3.4 the mock body must be a literal scriptblock, because `[scriptblock]::Create` breaks Pester's closure check. `Get-Date` is mocked the same way for the timestamp test.
- **Line format:** `yyyy-MM-dd HH:mm:ss [LEVEL] Message`, built with `InvariantCulture`. Continuation lines start with `    -> ` (four spaces, then an arrow). `Format-LogEntry` builds the whole entry as one string, which is appended in a single write.
- **Cloud sync:** the log folder is synced by a cloud client that briefly locks files. Because of that:
  - Every write is a single `[IO.File]::AppendAllText` call (open, append, close), in UTF-8 with a BOM on new files.
  - Writes and directory creation go through `Invoke-WithRetry`. `RetryCount` is the total number of attempts, and the delay grows linearly (`RetryDelayMs` × attempt).
  - If all attempts fail, `Write-LogFallback` writes the full entry with `Write-Warning`.
- **Retention:** it only matches `<COMPUTERNAME>_*.log`. The underscore is deliberate, so that HOST1 never deletes HOST10's files. It keeps `RetentionCount - 1` older files plus the current session's file. Files it can't delete are skipped.
- **The logging functions must never throw.** `Start-Log`, `Write-Log` and `Stop-Log` wrap their bodies in try/catch. `Write-LogFallback` swallows its own failure, which matters if the caller sets `$WarningPreference = 'Stop'`. `FATAL` is only a severity label: stopping the script is the caller's job (see the example).
- **Updater:** `Update-DonGrobioneLogging` is the exception to the no-throw rule: it reports problems with `Write-Error` and returns a result object. It reads `releases/latest` from the GitHub API, compares the release tag with the *installed* manifest (from `Get-ModuleInstallPath`, which tests mock), and checks the zip's manifest version before copying over the files. It never deletes the install folder, and it skips a folder that contains `.git` unless `-Force` is given. The release zip layout it expects is the one `.github/workflows/release.yml` builds. Avoid `Select-Object -First` in module code: in 5.1 it leaks a `StopUpstreamCommandsException` into the caller's `-ErrorVariable`.
- **Environment:** Windows PowerShell 5.1, no external modules, approved verbs, and comment-based help on every public function. Keep the `.psm1`/`.psd1` ASCII-only: 5.1 reads BOM-less files as ANSI.
- **Localized test machine:** on the user's German Windows, stack traces say `bei` instead of `at`. Test assertions must not depend on localized text.
