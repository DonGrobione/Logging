#Requires -Version 5.1
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Module state
# ---------------------------------------------------------------------------

# Active session configuration. $null means "not initialized"; Write-Log then
# initializes the default configuration on first use.
$script:LogConfig = $null

$script:LevelRank = @{
    DEBUG = 0
    INFO  = 1
    WARN  = 2
    ERROR = 3
    FATAL = 4
}

$script:ContinuationPrefix = '    -> '
$script:TimestampFormat    = 'yyyy-MM-dd HH:mm:ss'

# UTF-8 with BOM: StreamWriter only emits the BOM when the file is new, and the
# BOM lets Windows PowerShell 5.1 (Get-Content) read non-ASCII text correctly.
$script:LogEncoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true

$script:ModuleName    = 'DonGrobione.Logging'
$script:ReleaseApiUrl = 'https://api.github.com/repos/DonGrobione/Logging/releases/latest'

# Files of the legacy flat layout, installed directly into the module base
# folder. Versions up to 1.2.1 installed the first four; Install.ps1 comes
# along when the 1.2.1 updater installs a newer release in that layout. Only
# these are removed when migrating. Windows paths are case-insensitive, so
# 'README.md' also matches the 'ReadMe.md' of older versions.
$script:LegacyFiles = @("$script:ModuleName.psd1", "$script:ModuleName.psm1", 'LICENSE', 'README.md', 'Install.ps1')

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

function Get-LogBasePath {
    # Separate function so tests can mock the base path.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $documents = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($documents)) {
        # Some service accounts have no Documents folder.
        $documents = [System.IO.Path]::GetTempPath()
    }
    [System.IO.Path]::Combine($documents, 'Logs')
}

function Get-LogTimestamp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Format = $script:TimestampFormat
    )


    # InvariantCulture: ':' in a .NET format string is the culture's time separator.
    (Get-Date).ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-DefaultLogFileName {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    '{0}_{1}.log' -f $env:COMPUTERNAME, (Get-LogTimestamp -Format 'yyyy-MM-dd_HH-mm-ss')
}

function Write-LogFallback {
    # Last-resort console output. Must never throw, even if the caller set
    # $WarningPreference = 'Stop'.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    try {
        Write-Warning -Message "DonGrobione.Logging: $Text"
    }
    catch {
        # Nothing left to fall back to; discard the error on purpose.
        $null = $_
    }
}

function Invoke-WithRetry {
    # Runs $Action up to $RetryCount times with a linearly increasing delay
    # (RetryDelayMs, 2x, 3x, ...). Returns an object with Success and Error.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [scriptblock]$Action,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 100)]
        [int]$RetryCount,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 60000)]
        [int]$RetryDelayMs
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            $null = & $Action
            return [pscustomobject]@{ Success = $true; Error = $null }
        }
        catch {
            $lastError = $_.Exception
            Write-Verbose -Message "Attempt $attempt of $RetryCount failed: $($lastError.Message)"
            if ($attempt -lt $RetryCount -and $RetryDelayMs -gt 0) {
                Start-Sleep -Milliseconds ($RetryDelayMs * $attempt)
            }
        }
    }
    [pscustomobject]@{ Success = $false; Error = $lastError }
}

function Confirm-LogDirectory {
    # Ensures the log directory exists (with retry). Returns the retry result.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [pscustomobject]$Config
    )

    if ([System.IO.Directory]::Exists($Config.Directory)) {
        return [pscustomobject]@{ Success = $true; Error = $null }
    }
    $targetDirectory = $Config.Directory
    Invoke-WithRetry -RetryCount $Config.RetryCount -RetryDelayMs $Config.RetryDelayMs -Action {
        [System.IO.Directory]::CreateDirectory($targetDirectory)
    }
}

function Invoke-LogRetention {
    # Deletes the oldest log files of the CURRENT host so that, together with
    # the session's own log file, at most RetentionCount remain. Files that
    # cannot be deleted (e.g. locked by the sync client) are skipped. Honors
    # -WhatIf/-Confirm, also when inherited from Start-Log.
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [pscustomobject]$Config
    )

    if (-not [System.IO.Directory]::Exists($Config.Directory)) {
        return
    }

    # "<HOST>_*" rather than "<HOST>*" so that HOST1 never touches HOST10's files.
    $pattern     = '{0}_*.log' -f $env:COMPUTERNAME
    $currentName = [System.IO.Path]::GetFileName($Config.FilePath)

    # The extra -like guards against -Filter matching 8.3 short names (*.log -> *.logx).
    $candidates = @(
        Get-ChildItem -LiteralPath $Config.Directory -Filter $pattern -File -ErrorAction Stop |
            Where-Object { $_.Name -like $pattern -and $_.Name -ne $currentName } |
            Sort-Object -Property LastWriteTime -Descending
    )

    $keep = $Config.RetentionCount - 1
    if ($candidates.Count -le $keep) {
        return
    }

    foreach ($file in $candidates[$keep..($candidates.Count - 1)]) {
        if (-not $PSCmdlet.ShouldProcess($file.FullName, 'Delete old log file')) {
            continue
        }
        try {
            [System.IO.File]::Delete($file.FullName)
            Write-Verbose -Message "Retention: deleted '$($file.FullName)'."
        }
        catch {
            Write-Verbose -Message "Retention: skipped '$($file.FullName)': $($_.Exception.Message)"
        }
    }
}

function Initialize-LogSession {
    # Builds and activates a configuration, creates the directory and applies
    # retention. Shared by Start-Log and the Write-Log default fallback.
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogDirectory = 'Default',

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LogFileName,

        [Parameter()]
        [ValidateRange(1, 10000)]
        [int]$RetentionCount = 5,

        [Parameter()]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL')]
        [string]$MinimumLevel = 'INFO',

        [Parameter()]
        [ValidateRange(1, 100)]
        [int]$RetryCount = 3,

        [Parameter()]
        [ValidateRange(0, 60000)]
        [int]$RetryDelayMs = 500
    )

    if ([string]::IsNullOrWhiteSpace($LogFileName)) {
        $LogFileName = Get-DefaultLogFileName
    }

    # GetFullPath throws on invalid path characters, before any state changes.
    $directory = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-LogBasePath), $LogDirectory))
    $filePath  = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($directory, $LogFileName))

    $script:LogConfig = [pscustomobject]@{
        Directory      = $directory
        FilePath       = $filePath
        RetentionCount = $RetentionCount
        MinimumLevel   = $MinimumLevel
        RetryCount     = $RetryCount
        RetryDelayMs   = $RetryDelayMs
    }

    $result = Confirm-LogDirectory -Config $script:LogConfig
    if (-not $result.Success) {
        Write-LogFallback "Could not create log directory '$directory' after $RetryCount attempt(s): $($result.Error.Message)"
        return
    }

    try {
        Invoke-LogRetention -Config $script:LogConfig
    }
    catch {
        Write-LogFallback "Log retention in '$directory' failed: $($_.Exception.Message)"
    }
}

function Format-LogEntry {
    # Returns the complete entry (all lines, trailing newline) as one string so
    # it can be appended in a single write.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL')]
        [string]$Level,

        [Parameter()]
        [AllowNull()]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $lines = New-Object -TypeName 'System.Collections.Generic.List[string]'

    $messageLines = @($Message.TrimEnd("`r", "`n") -split "`r`n|`r|`n")
    $lines.Add(('{0} [{1}] {2}' -f (Get-LogTimestamp), $Level, $messageLines[0]))
    for ($i = 1; $i -lt $messageLines.Count; $i++) {
        $lines.Add($script:ContinuationPrefix + $messageLines[$i])
    }

    if ($null -ne $ErrorRecord) {
        $details = @(
            @{ Label = 'Exception';  Text = $(if ($ErrorRecord.Exception) { $ErrorRecord.Exception.Message }) }
            @{ Label = 'StackTrace'; Text = $ErrorRecord.ScriptStackTrace }
        )
        foreach ($detail in $details) {
            if ([string]::IsNullOrWhiteSpace($detail.Text)) {
                continue
            }
            $detailLines = @($detail.Text.TrimEnd("`r", "`n") -split "`r`n|`r|`n")
            $lines.Add(('{0}{1}: {2}' -f $script:ContinuationPrefix, $detail.Label, $detailLines[0]))
            for ($i = 1; $i -lt $detailLines.Count; $i++) {
                $lines.Add($script:ContinuationPrefix + $detailLines[$i])
            }
        }
    }

    ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-ModuleInstallPath {
    # Module base folder of the running edition, <Modules>\DonGrobione.Logging,
    # which holds one subfolder per installed version. Separate function so
    # tests can mock the install location.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('CurrentUser', 'AllUsers')]
        [string]$Scope
    )

    $editionFolder = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
    $root = if ($Scope -eq 'AllUsers') { $env:ProgramFiles } else { [Environment]::GetFolderPath('MyDocuments') }
    [System.IO.Path]::Combine($root, $editionFolder, 'Modules', $script:ModuleName)
}

function Get-InstalledModuleVersion {
    # Lists the installed copies below the module base folder: one entry per
    # version folder (<base>\<version>\) and one for the legacy flat layout
    # (manifest directly in <base>) that versions up to 1.2.1 installed.
    # PowerShell ignores a version folder whose manifest version differs from
    # the folder name, so such a folder is skipped here too.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ModuleRoot
    )

    if (-not [System.IO.Directory]::Exists($ModuleRoot)) {
        return
    }

    $legacyManifest = Join-Path $ModuleRoot "$script:ModuleName.psd1"
    if (Test-Path -LiteralPath $legacyManifest) {
        try {
            [pscustomobject]@{
                Version  = [version](Import-PowerShellDataFile -LiteralPath $legacyManifest -ErrorAction Stop).ModuleVersion
                Path     = $ModuleRoot
                IsLegacy = $true
            }
        }
        catch {
            Write-Warning "Could not read the installed version from '$legacyManifest': $($_.Exception.Message)"
        }
    }

    foreach ($folder in Get-ChildItem -LiteralPath $ModuleRoot -Directory) {
        $folderVersion = $null
        if (-not [version]::TryParse($folder.Name, [ref]$folderVersion)) {
            continue
        }
        $manifest = Join-Path $folder.FullName "$script:ModuleName.psd1"
        try {
            $manifestVersion = [version](Import-PowerShellDataFile -LiteralPath $manifest -ErrorAction Stop).ModuleVersion
        }
        catch {
            Write-Warning "Skipped '$($folder.FullName)': could not read its manifest: $($_.Exception.Message)"
            continue
        }
        if ($manifestVersion -ne $folderVersion) {
            Write-Warning "Skipped '$($folder.FullName)': its manifest has ModuleVersion $manifestVersion."
            continue
        }
        [pscustomobject]@{
            Version  = $folderVersion
            Path     = $folder.FullName
            IsLegacy = $false
        }
    }
}

function ConvertFrom-ManifestText {
    # Parses manifest text the way Import-PowerShellDataFile does (constant
    # values only), so a manifest inside a zip can be checked in memory.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $tokens      = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "The manifest is not valid PowerShell: $($parseErrors[0].Message)"
    }
    $hashtableAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $false)
    if ($null -eq $hashtableAst) {
        throw 'The manifest does not contain a hashtable.'
    }
    $hashtableAst.SafeGetValue()
}

function Confirm-ModuleVersionFolder {
    # Throws unless <Path> is a working copy of version <ExpectedVersion>: the
    # folder name, the manifest's ModuleVersion and the imported module's
    # version must all match, and Import-Module must succeed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [version]$ExpectedVersion
    )

    $folderName = Split-Path -Path $Path -Leaf
    if ($folderName -ne $ExpectedVersion.ToString()) {
        throw "The folder name '$folderName' does not match version $ExpectedVersion."
    }

    $manifestPath = Join-Path $Path "$script:ModuleName.psd1"
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
    $manifestVersion = $null
    if (-not [version]::TryParse([string]$manifest.ModuleVersion, [ref]$manifestVersion) -or $manifestVersion -ne $ExpectedVersion) {
        throw "The manifest has ModuleVersion '$($manifest.ModuleVersion)', expected $ExpectedVersion to match the folder name."
    }
    if ($manifest.RootModule -and -not (Test-Path -LiteralPath (Join-Path $Path $manifest.RootModule))) {
        throw "The RootModule '$($manifest.RootModule)' named in the manifest is missing."
    }

    # A separate runspace, because this session may already have another
    # version of the module loaded.
    $ps = [powershell]::Create()
    try {
        $null = $ps.AddCommand('Import-Module').AddParameter('Name', $manifestPath).AddParameter('PassThru').AddParameter('ErrorAction', 'Stop')
        $imported = @($ps.Invoke())
    }
    catch {
        $reason = $_.Exception
        if ($null -ne $reason.InnerException) {
            $reason = $reason.InnerException
        }
        throw "Import-Module failed: $($reason.Message)"
    }
    finally {
        $ps.Dispose()
    }
    if ($imported.Count -ne 1 -or $imported[0].Version -ne $ExpectedVersion) {
        throw "Import-Module did not load version $ExpectedVersion."
    }
}

function Install-ModulePackage {
    # Extracts the module from the release zip directly into
    # <ModuleRoot>\<version>\ (no staging folder) and verifies it. The zip has
    # one top-level folder named like the module (built by release.yml). The
    # version folder must not exist yet. If anything fails after it was
    # created, it is removed again; other version folders are never touched.
    # Returns the path of the new version folder. The caller asks
    # ShouldProcess before calling it.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ZipPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ModuleRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [version]$ExpectedVersion
    )

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $prefix     = "$script:ModuleName/"
    $targetPath = $null
    $created    = $false
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            # Compress-Archive in 5.1 writes '\' as the separator.
            $entries = @($archive.Entries | Where-Object {
                ($_.FullName -replace '\\', '/').StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
            })
            $manifestEntries = @($entries | Where-Object { ($_.FullName -replace '\\', '/') -eq "$prefix$script:ModuleName.psd1" })
            if ($manifestEntries.Count -eq 0) {
                throw "The package does not contain '$script:ModuleName\$script:ModuleName.psd1'."
            }

            # Check the version before anything is written.
            $reader = New-Object -TypeName System.IO.StreamReader -ArgumentList $manifestEntries[0].Open()
            try {
                $manifest = ConvertFrom-ManifestText -Text $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }
            $packageVersion = $null
            if (-not [version]::TryParse([string]$manifest.ModuleVersion, [ref]$packageVersion)) {
                throw "The package manifest has no valid ModuleVersion."
            }
            if ($packageVersion -ne $ExpectedVersion) {
                throw "The package contains version $packageVersion, expected $ExpectedVersion."
            }

            $targetPath = [System.IO.Path]::Combine($ModuleRoot, $packageVersion.ToString())
            if (Test-Path -LiteralPath $targetPath) {
                throw "'$targetPath' already exists. Remove that folder first, or release a higher ModuleVersion."
            }
            # Without -Force, New-Item fails if the folder appeared in the meantime.
            $null = New-Item -ItemType Directory -Path $targetPath -ErrorAction Stop
            $created = $true

            $targetPrefix = [System.IO.Path]::GetFullPath($targetPath).TrimEnd('\') + '\'
            foreach ($entry in $entries) {
                $relative = ($entry.FullName -replace '\\', '/').Substring($prefix.Length)
                if ($relative -eq '') {
                    continue
                }
                $destination = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($targetPath, $relative))
                if (-not $destination.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "The package contains an invalid path '$($entry.FullName)'."
                }
                if ($relative.EndsWith('/')) {
                    $null = [System.IO.Directory]::CreateDirectory($destination)
                    continue
                }
                $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destination))
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $false)
            }
        }
        finally {
            $archive.Dispose()
        }

        Confirm-ModuleVersionFolder -Path $targetPath -ExpectedVersion $ExpectedVersion
    }
    catch {
        if ($created) {
            Remove-Item -LiteralPath $targetPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    $targetPath
}

function Get-LockedFile {
    # Returns the first file below the given files or folders that another
    # process has open, or $null. A loaded script module holds no handle on
    # its .psm1, but a loaded DLL, an editor or the sync client does.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Path
    )

    foreach ($item in $Path) {
        foreach ($file in @(Get-ChildItem -LiteralPath $item -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            try {
                $stream = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'None')
                $stream.Dispose()
            }
            catch {
                return $file.FullName
            }
        }
    }
    $null
}

function Remove-InstalledModuleVersion {
    # Removes one entry from Get-InstalledModuleVersion: a version folder, or
    # only the module files of the legacy flat layout (never the base folder,
    # which holds the version folders). Returns $true on success. If a file is
    # in use nothing is removed; the next Update-DonGrobioneLogging retries.
    # Returns $false if ShouldProcess declines; -WhatIf/-Confirm are inherited
    # from Update-DonGrobioneLogging.
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [pscustomobject]$Installed
    )

    $what = if ($Installed.IsLegacy) { "Remove version $($Installed.Version) (legacy layout without a version folder)" } else { "Remove version $($Installed.Version)" }
    if (-not $PSCmdlet.ShouldProcess($Installed.Path, $what)) {
        return $false
    }

    if ($Installed.IsLegacy) {
        $targets = @($script:LegacyFiles | ForEach-Object { Join-Path $Installed.Path $_ } | Where-Object { Test-Path -LiteralPath $_ })
    }
    else {
        $targets = @($Installed.Path)
    }
    $hint = "Close all PowerShell sessions that use $script:ModuleName and run Update-DonGrobioneLogging again, or delete it by hand."

    $locked = Get-LockedFile -Path $targets
    if ($null -ne $locked) {
        Write-Warning "Version $($Installed.Version) in '$($Installed.Path)' was not removed because '$locked' is in use. $hint"
        return $false
    }

    $result = Invoke-WithRetry -RetryCount 3 -RetryDelayMs 500 -Action {
        foreach ($target in $targets) {
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
            }
        }
    }
    if (-not $result.Success) {
        Write-Warning "Version $($Installed.Version) in '$($Installed.Path)' was not fully removed: $($result.Error.Message) $hint"
        return $false
    }
    Write-Verbose -Message "Removed version $($Installed.Version) from '$($Installed.Path)'."
    $true
}

# ---------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------

function Start-Log {
    <#
    .SYNOPSIS
        Initializes logging for the current script.

    .DESCRIPTION
        Stores the logging configuration in the module's session state, creates
        the log directory under <MyDocuments>\Logs\<LogDirectory> and applies log
        retention for the current host.

        Call once at script start. Calling Start-Log is optional: Write-Log
        falls back to the default configuration if it was never called.

        Start-Log never throws. If the given configuration cannot be applied, a
        warning is written and the default configuration is used instead.

        Supports -WhatIf and -Confirm. With -WhatIf, nothing changes: no
        session is started, no directory is created and no old log file is
        deleted. With -Confirm, each old log file is confirmed before it is
        deleted.

    .PARAMETER LogDirectory
        Project/application subfolder under <MyDocuments>\Logs. Default: 'Default'.

    .PARAMETER LogFileName
        Log file name. Default: '<HOSTNAME>_yyyy-MM-dd_HH-mm-ss.log'.

    .PARAMETER RetentionCount
        Maximum number of '<HOSTNAME>_*.log' files kept in the log directory,
        including the current one. Files of other hosts are never touched.
        Default: 5.

    .PARAMETER MinimumLevel
        Entries below this level are not written. Default: 'INFO'.

    .PARAMETER RetryCount
        Total number of attempts for each write and for creating the log
        directory. Default: 3.

    .PARAMETER RetryDelayMs
        Base delay between attempts in milliseconds. The delay grows linearly
        (1x, 2x, 3x, ...). Default: 500.

    .EXAMPLE
        Start-Log -LogDirectory 'Sync-ADUsers'

        Logs to <MyDocuments>\Logs\Sync-ADUsers\<HOSTNAME>_<timestamp>.log.

    .EXAMPLE
        Start-Log -LogDirectory 'Backup' -MinimumLevel DEBUG -RetentionCount 10

    .EXAMPLE
        Start-Log -LogDirectory 'Backup' -RetentionCount 2 -WhatIf

        Shows which log session would be started, without changing anything.

    .LINK
        Write-Log

    .LINK
        Stop-Log
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogDirectory = 'Default',

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LogFileName,

        [Parameter()]
        [ValidateRange(1, 10000)]
        [int]$RetentionCount = 5,

        [Parameter()]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL')]
        [string]$MinimumLevel = 'INFO',

        [Parameter()]
        [ValidateRange(1, 100)]
        [int]$RetryCount = 3,

        [Parameter()]
        [ValidateRange(0, 60000)]
        [int]$RetryDelayMs = 500
    )

    try {
        if (-not $PSCmdlet.ShouldProcess("LogDirectory '$LogDirectory'", 'Start logging session')) {
            return
        }
    }
    catch {
        # ShouldProcess throws if the user halts at a -Confirm prompt; that
        # must not start the default configuration either.
        Write-LogFallback "Start-Log failed: $($_.Exception.Message)"
        return
    }

    try {
        $settings = @{
            LogDirectory   = $LogDirectory
            LogFileName    = $LogFileName
            RetentionCount = $RetentionCount
            MinimumLevel   = $MinimumLevel
            RetryCount     = $RetryCount
            RetryDelayMs   = $RetryDelayMs
        }
        Initialize-LogSession @settings
    }
    catch {
        Write-LogFallback "Start-Log failed ($($_.Exception.Message)). Falling back to the default configuration."
        try {
            Initialize-LogSession
        }
        catch {
            $script:LogConfig = $null
            Write-LogFallback "Default configuration failed as well: $($_.Exception.Message)"
        }
    }
}

function Write-Log {
    <#
    .SYNOPSIS
        Writes an entry to the log file.

    .DESCRIPTION
        Appends an entry in the format 'yyyy-MM-dd HH:mm:ss [LEVEL] Message'
        (local time, 24-hour clock). The file is opened, appended and closed
        for every entry.

        Multi-line messages are split on CRLF, CR and LF. Every line after the
        first is prefixed with '    -> ' so each entry starts on exactly one
        timestamped line. When -ErrorRecord is given, its exception message and
        script stack trace are added as continuation lines.

        If Start-Log was never called, the default configuration is used.

        Failed writes (e.g. a file locked by a sync client) are retried. If all
        attempts fail, the entry is written to the console with Write-Warning.
        Write-Log never throws; FATAL is a severity label only and does not
        stop the calling script.

    .PARAMETER Message
        The message. May contain line breaks.

    .PARAMETER Level
        DEBUG, INFO, WARN, ERROR or FATAL. Default: INFO.

    .PARAMETER ErrorRecord
        Optional error record, typically $_ in a catch block.

    .EXAMPLE
        Write-Log 'Sync started'

    .EXAMPLE
        Write-Log -Level WARN -Message "User $sam has no mailbox"

    .EXAMPLE
        try { Connect-DC } catch { Write-Log -Level ERROR -Message 'Sync-ADUsers failed' -ErrorRecord $_ }

    .LINK
        Start-Log
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter()]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL')]
        [string]$Level = 'INFO',

        [Parameter()]
        [AllowNull()]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $entry = $null
    try {
        if ($null -eq $script:LogConfig) {
            Initialize-LogSession
        }
        $config = $script:LogConfig

        if ($script:LevelRank[$Level] -lt $script:LevelRank[$config.MinimumLevel]) {
            return
        }

        $entry = Format-LogEntry -Message $Message -Level $Level -ErrorRecord $ErrorRecord

        $result = Confirm-LogDirectory -Config $config
        if ($result.Success) {
            $targetFile = $config.FilePath
            $result = Invoke-WithRetry -RetryCount $config.RetryCount -RetryDelayMs $config.RetryDelayMs -Action {
                [System.IO.File]::AppendAllText($targetFile, $entry, $script:LogEncoding)
            }
        }

        if (-not $result.Success) {
            Write-LogFallback ("Could not write to '{0}' after {1} attempt(s): {2}`r`n{3}" -f
                $config.FilePath, $config.RetryCount, $result.Error.Message, $entry.TrimEnd())
        }
    }
    catch {
        if ($null -eq $entry) {
            $entry = "[$Level] $Message"
        }
        Write-LogFallback ("Write-Log failed: {0}`r`n{1}" -f $_.Exception.Message, $entry.TrimEnd())
    }
}

function Stop-Log {
    <#
    .SYNOPSIS
        Ends the current logging session.

    .DESCRIPTION
        Clears the configuration set by Start-Log. The module keeps no file
        handles open (each entry is opened, appended and closed), so nothing
        needs flushing. A later Write-Log without Start-Log uses the default
        configuration again.

        Call it in the finally block of the calling script. Never throws.
        Supports -WhatIf and -Confirm; with -WhatIf the session keeps running.

    .EXAMPLE
        try { ... } finally { Stop-Log }

    .LINK
        Start-Log
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param()

    try {
        if ($PSCmdlet.ShouldProcess('logging session', 'Stop')) {
            $script:LogConfig = $null
        }
    }
    catch {
        # ShouldProcess throws if the user halts at a -Confirm prompt.
        Write-LogFallback "Stop-Log failed: $($_.Exception.Message)"
    }
}

function Test-LogSession {
    <#
    .SYNOPSIS
        Tells whether a logging session is running.

    .DESCRIPTION
        Returns $true if a configuration is active, either from Start-Log or
        from the default configuration that Write-Log sets up when it is
        called without Start-Log. Returns $false before the first Start-Log
        or Write-Log and after Stop-Log.

        Sub-scripts use it to decide whether to call Start-Log themselves or
        to log into the session of the script that called them. Never throws.

    .OUTPUTS
        System.Boolean

    .EXAMPLE
        if (-not (Test-LogSession)) { Start-Log -LogDirectory 'Sync-ADUsers' }

    .LINK
        Start-Log

    .LINK
        Stop-Log
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $null -ne $script:LogConfig
}

function Get-LogSession {
    <#
    .SYNOPSIS
        Returns the configuration of the running logging session.

    .DESCRIPTION
        Returns a copy of the active configuration with the properties
        Directory, FilePath, RetentionCount, MinimumLevel, RetryCount and
        RetryDelayMs. Changing the copy does not change the session.

        Returns $null if no session is running, which is exactly when
        Test-LogSession returns $false. Unlike Write-Log, it never starts a
        session. Never throws.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .EXAMPLE
        $csvPath = Join-Path (Get-LogSession).Directory 'Report.csv'

        Writes an extra file next to the log files of the running session.

    .LINK
        Test-LogSession

    .LINK
        Start-Log
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    try {
        $config = $script:LogConfig
        if ($null -eq $config) {
            return $null
        }
        [pscustomobject]@{
            Directory      = $config.Directory
            FilePath       = $config.FilePath
            RetentionCount = $config.RetentionCount
            MinimumLevel   = $config.MinimumLevel
            RetryCount     = $config.RetryCount
            RetryDelayMs   = $config.RetryDelayMs
        }
    }
    catch {
        $null
    }
}

function Update-DonGrobioneLogging {
    <#
    .SYNOPSIS
        Installs the latest release of DonGrobione.Logging from GitHub.

    .DESCRIPTION
        Reads the latest release of https://github.com/DonGrobione/Logging and
        compares its version with the newest version installed in the module
        folder of the chosen scope. If the release is newer, it downloads the
        release zip and extracts it directly into a new version folder:

          CurrentUser: <Documents>\WindowsPowerShell\Modules\DonGrobione.Logging\<version>
          AllUsers:    <ProgramFiles>\WindowsPowerShell\Modules\DonGrobione.Logging\<version>
          (PowerShell 7 uses 'PowerShell' instead of 'WindowsPowerShell'.)

        The package's manifest version is checked before anything is written.
        The new folder is then verified: its name, the manifest's ModuleVersion
        and the imported version must match, and Import-Module must succeed in
        a separate runspace. Only after that are the older versions in that
        folder removed, including an installation in the legacy layout without
        a version folder (versions up to 1.2.1). If anything fails before, the
        new folder is removed again and the old version stays as it was.

        An older version whose files are in use is left in place with a
        warning; the next run removes it. If the version folder of the latest
        release already exists but is not valid, nothing is changed: remove
        that folder first. A module folder that is a git clone is never
        changed; update it with 'git pull'.

        If this session loaded the module from the updated scope, the new
        version is imported in its place once the old one is removed. This
        ends a running logging session, as Stop-Log does.

        Unlike the logging functions, errors are reported with Write-Error.

    .PARAMETER Scope
        CurrentUser (default) or AllUsers. AllUsers requires an elevated session.

    .OUTPUTS
        An object with InstalledVersion (the newest version before the update),
        LatestVersion, Path (the folder of the latest version) and Updated.

    .EXAMPLE
        Update-DonGrobioneLogging

        Installs the latest release if it is newer than the installed version.

    .EXAMPLE
        Update-DonGrobioneLogging -WhatIf

        Shows whether an update is available without installing it.

    .EXAMPLE
        Update-DonGrobioneLogging -Scope AllUsers

        Updates the copy for all users (run as administrator).
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateSet('CurrentUser', 'AllUsers')]
        [string]$Scope = 'CurrentUser'
    )

    $moduleRoot       = Get-ModuleInstallPath -Scope $Scope
    $installed        = @(Get-InstalledModuleVersion -ModuleRoot $moduleRoot | Sort-Object -Property Version -Descending)
    $installedVersion = if ($installed.Count -gt 0) { $installed[0].Version } else { $null }

    $headers = @{ 'User-Agent' = $script:ModuleName; 'Accept' = 'application/vnd.github+json' }
    try {
        # Windows PowerShell 5.1 does not enable TLS 1.2 by default; GitHub requires it.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod -Uri $script:ReleaseApiUrl -Headers $headers -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Error "Could not query the latest release from '$script:ReleaseApiUrl': $($_.Exception.Message)"
        return
    }

    $latestVersion = $null
    if (-not [version]::TryParse(([string]$release.tag_name).TrimStart('v', 'V'), [ref]$latestVersion)) {
        Write-Error "The latest release tag '$($release.tag_name)' is not a version number."
        return
    }

    # No Select-Object -First here: in 5.1 it leaks StopUpstreamCommandsException into -ErrorVariable.
    $assets = @($release.assets | Where-Object { $_.name -like "$script:ModuleName-*.zip" })
    if ($assets.Count -eq 0) {
        Write-Error "Release '$($release.tag_name)' has no '$script:ModuleName-*.zip' asset."
        return
    }
    $asset = $assets[0]

    $result = [pscustomobject]@{
        InstalledVersion = $installedVersion
        LatestVersion    = $latestVersion
        Path             = [System.IO.Path]::Combine($moduleRoot, $latestVersion.ToString())
        Updated          = $false
    }

    if (Test-Path -LiteralPath (Join-Path $moduleRoot '.git')) {
        if ($null -ne $installedVersion -and $installedVersion -ge $latestVersion) {
            Write-Verbose -Message "The git clone in '$moduleRoot' has version $installedVersion, which is up to date."
            return $result
        }
        Write-Error "'$moduleRoot' is a git clone. Update it with 'git pull'."
        return $result
    }

    # The legacy flat layout never counts as up to date: it is migrated by
    # installing the latest release into its version folder.
    $versioned = @($installed | Where-Object { -not $_.IsLegacy })
    if ($versioned.Count -gt 0 -and $versioned[0].Version -ge $latestVersion) {
        $keep = $versioned[0]
        $result.Path = $keep.Path
        Write-Verbose -Message "Version $($keep.Version) in '$($keep.Path)' is up to date."
    }
    else {
        if (Test-Path -LiteralPath $result.Path) {
            Write-Error ("'{0}' already exists but is not a valid installation of version {1}. Remove that folder and run Update-DonGrobioneLogging again." -f
                $result.Path, $latestVersion)
            return $result
        }

        $action = if ($null -eq $installedVersion) { "Install version $latestVersion" } else { "Update from version $installedVersion to $latestVersion" }
        if (-not $PSCmdlet.ShouldProcess($result.Path, $action)) {
            return $result
        }

        $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) ('{0}-{1}.zip' -f $script:ModuleName, [guid]::NewGuid().ToString('N'))
        try {
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers @{ 'User-Agent' = $script:ModuleName } -UseBasicParsing -ErrorAction Stop
            $null = Install-ModulePackage -ZipPath $zipPath -ModuleRoot $moduleRoot -ExpectedVersion $latestVersion
        }
        catch {
            Write-Error "Update to version $latestVersion failed, the installed version is unchanged: $($_.Exception.Message)"
            return $result
        }
        finally {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        }
        $result.Updated = $true
        $keep = [pscustomobject]@{ Version = $latestVersion; Path = $result.Path; IsLegacy = $false }
        Write-Verbose -Message "Installed version $latestVersion to '$($result.Path)'."
    }

    # Older versions go only once the kept version is verified. After an
    # install Install-ModulePackage has verified it; otherwise verify it now.
    $obsolete   = @($installed | Where-Object { $_.Path -ne $keep.Path })
    $allRemoved = $true
    if ($obsolete.Count -gt 0) {
        if (-not $result.Updated) {
            try {
                Confirm-ModuleVersionFolder -Path $keep.Path -ExpectedVersion $keep.Version
            }
            catch {
                Write-Error "Older versions were not removed because version $($keep.Version) in '$($keep.Path)' failed verification: $($_.Exception.Message)"
                return $result
            }
        }
        foreach ($old in $obsolete) {
            if (-not (Remove-InstalledModuleVersion -Installed $old)) {
                $allRemoved = $false
            }
        }
    }

    # Reload only if this session runs a copy from this scope that was just
    # replaced. Import first, then remove, so a failed import keeps the old one.
    $thisModule = $MyInvocation.MyCommand.Module
    if ($allRemoved -and $null -ne $thisModule) {
        $loadedBase = $thisModule.ModuleBase.TrimEnd('\')
        $fromScope  = $loadedBase -eq $moduleRoot -or $loadedBase.StartsWith($moduleRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)
        if ($fromScope -and $loadedBase -ne $keep.Path) {
            try {
                Import-Module -Name (Join-Path $keep.Path "$script:ModuleName.psd1") -Global -Force -ErrorAction Stop
                Remove-Module -ModuleInfo $thisModule -Force -ErrorAction Stop
                Write-Verbose -Message "Loaded version $($keep.Version) in this session."
            }
            catch {
                Write-Warning "Could not load version $($keep.Version) in this session: $($_.Exception.Message) Start a new session to use it."
            }
        }
    }

    $result
}

Export-ModuleMember -Function Start-Log, Write-Log, Stop-Log, Test-LogSession, Get-LogSession, Update-DonGrobioneLogging
