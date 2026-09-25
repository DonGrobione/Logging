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

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

function Get-LogBasePath {
    # Separate function so tests can mock the base path.
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($documents)) {
        # Some service accounts have no Documents folder.
        $documents = [System.IO.Path]::GetTempPath()
    }
    [System.IO.Path]::Combine($documents, 'Logs')
}

function Get-LogTimestamp {
    param([string]$Format = $script:TimestampFormat)
    # InvariantCulture: ':' in a .NET format string is the culture's time separator.
    (Get-Date).ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-DefaultLogFileName {
    '{0}_{1}.log' -f $env:COMPUTERNAME, (Get-LogTimestamp -Format 'yyyy-MM-dd_HHmmss')
}

function Write-LogFallback {
    # Last-resort console output. Must never throw, even if the caller set
    # $WarningPreference = 'Stop'.
    param([string]$Text)
    try {
        Write-Warning -Message "DonGrobione.Logging: $Text"
    }
    catch {
        # Nothing left to fall back to.
    }
}

function Invoke-WithRetry {
    # Runs $Action up to $RetryCount times with a linearly increasing delay
    # (RetryDelayMs, 2x, 3x, ...). Returns an object with Success and Error.
    param(
        [scriptblock]$Action,
        [int]$RetryCount,
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
    param([pscustomobject]$Config)

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
    # cannot be deleted (e.g. locked by the sync client) are skipped.
    param([pscustomobject]$Config)

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
        [string]$LogDirectory = 'Default',
        [string]$LogFileName,
        [int]$RetentionCount = 5,
        [string]$MinimumLevel = 'INFO',
        [int]$RetryCount = 3,
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
    param(
        [string]$Message,
        [string]$Level,
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
    # Default module folder of the running edition. Separate function so tests
    # can mock the install location.
    param([string]$Scope)

    $editionFolder = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
    $root = if ($Scope -eq 'AllUsers') { $env:ProgramFiles } else { [Environment]::GetFolderPath('MyDocuments') }
    [System.IO.Path]::Combine($root, $editionFolder, 'Modules', $script:ModuleName)
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

    .PARAMETER LogDirectory
        Project/application subfolder under <MyDocuments>\Logs. Default: 'Default'.

    .PARAMETER LogFileName
        Log file name. Default: '<HOSTNAME>_yyyy-MM-dd_HHmmss.log'.

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

    .LINK
        Write-Log

    .LINK
        Stop-Log
    #>
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$LogDirectory = 'Default',

        [string]$LogFileName,

        [ValidateRange(1, 10000)]
        [int]$RetentionCount = 5,

        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL')]
        [string]$MinimumLevel = 'INFO',

        [ValidateRange(1, 100)]
        [int]$RetryCount = 3,

        [ValidateRange(0, 60000)]
        [int]$RetryDelayMs = 500
    )

    try {
        Initialize-LogSession @PSBoundParameters
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

        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL')]
        [string]$Level = 'INFO',

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

    .EXAMPLE
        try { ... } finally { Stop-Log }

    .LINK
        Start-Log
    #>
    [CmdletBinding()]
    param()

    $script:LogConfig = $null
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

function Update-DonGrobioneLogging {
    <#
    .SYNOPSIS
        Installs the latest release of DonGrobione.Logging from GitHub.

    .DESCRIPTION
        Reads the latest release of https://github.com/DonGrobione/Logging,
        compares its version with the version installed in the default module
        folder and, if the release is newer, downloads the release zip and
        copies the module files over the installed ones.

        Default module folders:
          CurrentUser: <Documents>\WindowsPowerShell\Modules\DonGrobione.Logging
          AllUsers:    <ProgramFiles>\WindowsPowerShell\Modules\DonGrobione.Logging
        (PowerShell 7 uses 'PowerShell' instead of 'WindowsPowerShell'.)

        The downloaded package is checked first: it must contain the module
        manifest with the release's version. Files are overwritten, the folder
        itself is not deleted. A folder that is a git clone is not touched
        unless -Force is given; update it with 'git pull' instead.

        The running session keeps the old version. Start a new session or run
        'Import-Module DonGrobione.Logging -Force' to load the update.

        Unlike the logging functions, errors are reported with Write-Error.

    .PARAMETER Scope
        CurrentUser (default) or AllUsers. AllUsers requires an elevated session.

    .PARAMETER Force
        Reinstall even if the installed version is up to date, and overwrite
        the files of a git clone.

    .OUTPUTS
        An object with InstalledVersion (before the update), LatestVersion,
        Path and Updated.

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
    param(
        [ValidateSet('CurrentUser', 'AllUsers')]
        [string]$Scope = 'CurrentUser',

        [switch]$Force
    )

    $installPath      = Get-ModuleInstallPath -Scope $Scope
    $installedVersion = $null
    $installedManifest = Join-Path $installPath "$script:ModuleName.psd1"
    if (Test-Path -LiteralPath $installedManifest) {
        try {
            $installedVersion = [version](Import-PowerShellDataFile -LiteralPath $installedManifest).ModuleVersion
        }
        catch {
            Write-Warning "Could not read the installed version from '$installedManifest': $($_.Exception.Message)"
        }
    }

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
        Path             = $installPath
        Updated          = $false
    }

    if ($null -ne $installedVersion -and $installedVersion -ge $latestVersion -and -not $Force) {
        Write-Verbose -Message "Version $installedVersion in '$installPath' is up to date."
        return $result
    }

    if ((Test-Path -LiteralPath (Join-Path $installPath '.git')) -and -not $Force) {
        Write-Error "'$installPath' is a git clone. Update it with 'git pull', or use -Force to overwrite its files."
        return $result
    }

    $action = if ($null -eq $installedVersion) { "Install version $latestVersion" } else { "Update from version $installedVersion to $latestVersion" }
    if (-not $PSCmdlet.ShouldProcess($installPath, $action)) {
        return $result
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('{0}-{1}' -f $script:ModuleName, [guid]::NewGuid().ToString('N'))
    try {
        $null = New-Item -ItemType Directory -Path $tempRoot -ErrorAction Stop
        $zipPath = Join-Path $tempRoot $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers @{ 'User-Agent' = $script:ModuleName } -UseBasicParsing -ErrorAction Stop

        $extractPath = Join-Path $tempRoot 'extracted'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -ErrorAction Stop

        # Validate the package before touching the installed module.
        $sourcePath     = Join-Path $extractPath $script:ModuleName
        $sourceManifest = Join-Path $sourcePath "$script:ModuleName.psd1"
        if (-not (Test-Path -LiteralPath $sourceManifest)) {
            throw "The package does not contain '$script:ModuleName\$script:ModuleName.psd1'."
        }
        $packageVersion = [version](Import-PowerShellDataFile -LiteralPath $sourceManifest).ModuleVersion
        if ($packageVersion -ne $latestVersion) {
            throw "The package contains version $packageVersion, expected $latestVersion."
        }

        $null = New-Item -ItemType Directory -Path $installPath -Force -ErrorAction Stop
        Copy-Item -Path (Join-Path $sourcePath '*') -Destination $installPath -Recurse -Force -ErrorAction Stop
        $result.Updated = $true
        Write-Verbose -Message "Installed version $latestVersion to '$installPath'. Start a new session to load it."
    }
    catch {
        Write-Error "Update to version $latestVersion failed: $($_.Exception.Message)"
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $result
}

Export-ModuleMember -Function Start-Log, Write-Log, Stop-Log, Test-LogSession, Update-DonGrobioneLogging
