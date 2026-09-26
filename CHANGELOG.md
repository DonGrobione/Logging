# Changelog

All notable changes to DonGrobione.Logging are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [2.1.0] - 2026-09-26

### Added

- `Start-Log` and `Stop-Log` support `-WhatIf` and `-Confirm`. `Start-Log -WhatIf` changes nothing: no session is started, no directory is created and no old log file is deleted.
- Log retention asks `ShouldProcess` before it deletes each old log file.
- `Install.ps1` supports `-WhatIf` and `-Confirm` when run as a scriptblock.
- `CHANGELOG.md`, and `ReleaseNotes` in the module manifest.
- Tests for the manifest's Gallery metadata and static checks of `Install.ps1`.

### Changed

- `Update-DonGrobioneLogging` asks `ShouldProcess` for each old version inside the removal step. Its `-WhatIf` and `-Confirm` behavior is unchanged.
- `Install.ps1` writes its progress with `Write-Information` instead of `Write-Host`, so it can be redirected or captured.
- `ReadMe.md` is renamed to `README.md`.
- The manifest's `LicenseUri` points to the `LICENSE` file on GitHub.
- All functions use `[CmdletBinding()]` and `[Parameter()]` attributes with validation. The code produces no PSScriptAnalyzer warnings.

## [2.0.0] - 2026-09-26

### Changed

- `Update-DonGrobioneLogging` and `Install.ps1` install into versioned module folders (`<Modules>\DonGrobione.Logging\<version>\`) instead of the flat module folder. The package's manifest version is checked before anything is written, and the new folder is verified (folder name, `ModuleVersion` and `Import-Module` in a separate runspace) and removed again if that fails.
- The updater removes older versions only after the new one is verified, skips versions whose files are in use (the next run retries), migrates the flat layout of 1.2.1 and older, and reloads the module if the session ran a copy it replaced.
- The installer never touches other versions and stops if the version folder already exists.
- `Install.ps1` is part of the release zip.

### Removed

- `-Force` on `Update-DonGrobioneLogging` and `Install.ps1`. An existing version folder is always an error, and a git clone is never changed.

## [1.2.1] - 2026-09-25

### Changed

- The default log file name is `<COMPUTERNAME>_yyyy-MM-dd_HH-mm-ss.log` instead of `<COMPUTERNAME>_yyyy-MM-dd_HHmmss.log`. Retention still matches the old names.

## [1.2.0] - 2026-09-25

### Added

- `Get-LogSession` returns a copy of the running session's settings, or `$null` when no session is running, without starting one.

## [1.1.0] - 2026-09-25

### Added

- `Test-LogSession` tells whether a logging session is running.

## [1.0.0] - 2026-09-24

### Added

- `Start-Log`, `Write-Log` and `Stop-Log`: one line per entry, continuation lines for multi-line messages and error records, retry on locked files, per-host retention. The logging functions never throw.
- `Update-DonGrobioneLogging` installs the latest GitHub release.
- `Install.ps1` for one-line installation from GitHub.
- GitHub Actions: tests on Windows PowerShell 5.1, and a release zip whenever `ModuleVersion` changes.

[2.1.0]: https://github.com/DonGrobione/Logging/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/DonGrobione/Logging/compare/v1.2.1...v2.0.0
[1.2.1]: https://github.com/DonGrobione/Logging/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/DonGrobione/Logging/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/DonGrobione/Logging/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/DonGrobione/Logging/releases/tag/v1.0.0
