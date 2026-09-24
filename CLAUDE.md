# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`DonGrobione.Logging` is a PowerShell logging module used by all of the user's scripts. **`Docs/Specification.md` is the original requirements spec.** Check it before you change behavior. `ReadMe.md` is the user-facing documentation: keep its parameter table and examples in sync when the public API changes.

- `DonGrobione.Logging.psm1`: the whole module. Exports `Start-Log`, `Write-Log` and `Stop-Log`. All other functions are private.
- `DonGrobione.Logging.psd1`: the manifest. When you add a public function, update `FunctionsToExport` here and `Export-ModuleMember` in the `.psm1`.
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

Each feature has its own Describe block (Formatting, Timestamp, Default configuration, Retention, Safety, Retry) so it can be run alone with `-TestName`.

## Architecture and constraints

- **Configuration:** it lives in `$script:LogConfig`, where `$null` means not initialized. `Start-Log` and the default fallback in `Write-Log` both go through `Initialize-LogSession`, so the fallback also creates the directory and applies retention. `Stop-Log` only resets `$script:LogConfig`, because no file handles are kept open.
- **Base path:** `Get-LogBasePath` returns `<MyDocuments>\Logs`. It is a separate function so tests can mock it into `$TestDrive`. In Pester 3.4 the mock body must be a literal scriptblock, because `[scriptblock]::Create` breaks Pester's closure check. `Get-Date` is mocked the same way for the timestamp test.
- **Line format:** `yyyy-MM-dd HH:mm:ss [LEVEL] Message`, built with `InvariantCulture`. Continuation lines start with `    -> ` (four spaces, then an arrow). `Format-LogEntry` builds the whole entry as one string, which is appended in a single write.
- **Cloud sync:** the log folder is synced by a cloud client that briefly locks files. Because of that:
  - Every write is a single `[IO.File]::AppendAllText` call (open, append, close), in UTF-8 with a BOM on new files.
  - Writes and directory creation go through `Invoke-WithRetry`. `RetryCount` is the total number of attempts, and the delay grows linearly (`RetryDelayMs` × attempt).
  - If all attempts fail, `Write-LogFallback` writes the full entry with `Write-Warning`.
- **Retention:** it only matches `<COMPUTERNAME>_*.log`. The underscore is deliberate, so that HOST1 never deletes HOST10's files. It keeps `RetentionCount - 1` older files plus the current session's file. Files it can't delete are skipped.
- **The module must never throw.** Public functions wrap their bodies in try/catch. `Write-LogFallback` swallows its own failure, which matters if the caller sets `$WarningPreference = 'Stop'`. `FATAL` is only a severity label: stopping the script is the caller's job (see the example).
- **Environment:** Windows PowerShell 5.1, no external modules, approved verbs, and comment-based help on every public function. Keep the `.psm1`/`.psd1` ASCII-only: 5.1 reads BOM-less files as ANSI.
- **Localized test machine:** on the user's German Windows, stack traces say `bei` instead of `at`. Test assertions must not depend on localized text.
