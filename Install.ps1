<#
.SYNOPSIS
    Downloads and installs the latest release of DonGrobione.Logging.

.DESCRIPTION
    Reads the latest release from https://github.com/DonGrobione/Logging,
    downloads its zip and extracts it directly into a version folder of the
    default module folder:

      CurrentUser: <Documents>\WindowsPowerShell\Modules\DonGrobione.Logging\<version>
      AllUsers:    <ProgramFiles>\WindowsPowerShell\Modules\DonGrobione.Logging\<version>
      (PowerShell 7 uses 'PowerShell' instead of 'WindowsPowerShell'.)

    Other installed versions are not touched; PowerShell loads the newest one.
    The package's manifest version is checked before anything is written, and
    the new folder is verified afterwards (folder name, manifest version and
    Import-Module must match). If that fails, the new folder is removed again.

    If the version folder already exists, nothing is changed. To reinstall,
    remove that folder first. A module folder that is a git clone is never
    changed; update it with 'git pull'.

    To also remove older versions, including an installation without a
    version folder (versions up to 1.2.1), use Update-DonGrobioneLogging.

    Run it straight from GitHub:

      irm https://raw.githubusercontent.com/DonGrobione/Logging/main/Install.ps1 | iex

    With parameters:

      & ([scriptblock]::Create((irm https://raw.githubusercontent.com/DonGrobione/Logging/main/Install.ps1))) -Scope AllUsers

.PARAMETER Scope
    CurrentUser (default) or AllUsers. AllUsers requires an elevated session.

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/DonGrobione/Logging/main/Install.ps1))) -WhatIf

    Shows where the latest release would be installed, without installing it.
    -WhatIf and -Confirm only work this way, not with 'irm | iex'.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope = 'CurrentUser'
)

# Child scope: when run through 'irm | iex', variables and functions defined
# here would otherwise leak into the caller's session, including
# $ErrorActionPreference. The helpers below mirror the private functions of
# the same name in DonGrobione.Logging.psm1; keep them in sync.
# $Cmdlet is $null under 'irm | iex', which ignores [CmdletBinding()].
& {
    param([string]$Scope, [System.Management.Automation.PSCmdlet]$Cmdlet)

    $ErrorActionPreference = 'Stop'
    $moduleName  = 'DonGrobione.Logging'
    $apiUrl      = 'https://api.github.com/repos/DonGrobione/Logging/releases/latest'
    $headers     = @{ 'User-Agent' = $moduleName; 'Accept' = 'application/vnd.github+json' }
    $legacyFiles = @("$moduleName.psd1", "$moduleName.psm1", 'LICENSE', 'README.md', 'Install.ps1')
    $zipPath     = Join-Path ([System.IO.Path]::GetTempPath()) ('{0}-{1}.zip' -f $moduleName, [guid]::NewGuid().ToString('N'))

    function ConvertFrom-ManifestText {
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
        $manifestPath = Join-Path $Path "$moduleName.psd1"
        $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
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
        $prefix     = "$moduleName/"
        $targetPath = $null
        $created    = $false
        try {
            $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
            try {
                $entries = @($archive.Entries | Where-Object {
                    ($_.FullName -replace '\\', '/').StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
                })
                $manifestEntries = @($entries | Where-Object { ($_.FullName -replace '\\', '/') -eq "$prefix$moduleName.psd1" })
                if ($manifestEntries.Count -eq 0) {
                    throw "The package does not contain '$moduleName\$moduleName.psd1'."
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
                $null = New-Item -ItemType Directory -Path $targetPath
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

    try {
        $editionFolder = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
        $root          = if ($Scope -eq 'AllUsers') { $env:ProgramFiles } else { [Environment]::GetFolderPath('MyDocuments') }
        $moduleRoot    = [System.IO.Path]::Combine($root, $editionFolder, 'Modules', $moduleName)

        if (Test-Path -LiteralPath (Join-Path $moduleRoot '.git')) {
            throw "'$moduleRoot' is a git clone. Update it with 'git pull'."
        }

        # Windows PowerShell 5.1 does not enable TLS 1.2 by default; GitHub requires it.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        Write-Information -MessageData "Checking latest release of $moduleName ..." -InformationAction Continue
        $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -UseBasicParsing

        $latestVersion = $null
        if (-not [version]::TryParse(([string]$release.tag_name).TrimStart('v', 'V'), [ref]$latestVersion)) {
            throw "The latest release tag '$($release.tag_name)' is not a version number."
        }
        $assets = @($release.assets | Where-Object { $_.name -like "$moduleName-*.zip" })
        if ($assets.Count -eq 0) {
            throw "Release '$($release.tag_name)' has no '$moduleName-*.zip' asset."
        }
        $asset = $assets[0]

        $targetPath = [System.IO.Path]::Combine($moduleRoot, $latestVersion.ToString())
        if (Test-Path -LiteralPath $targetPath) {
            throw ("Version $latestVersion is already installed in '$targetPath'. To reinstall it, remove that folder first " +
                "(Remove-Item -LiteralPath '$targetPath' -Recurse) and run the installer again.")
        }

        if ($null -ne $Cmdlet -and -not $Cmdlet.ShouldProcess($targetPath, "Install version $latestVersion")) {
            return
        }

        Write-Information -MessageData "Downloading $($asset.name) ..." -InformationAction Continue
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers @{ 'User-Agent' = $moduleName } -UseBasicParsing
        $null = Install-ModulePackage -ZipPath $zipPath -ModuleRoot $moduleRoot -ExpectedVersion $latestVersion
        Write-Information -MessageData "Installed $moduleName $latestVersion to '$targetPath'." -InformationAction Continue

        # PowerShell prefers version folders, so an installation without one
        # (versions up to 1.2.1) is no longer loaded but still listed.
        $legacyManifest = Join-Path $moduleRoot "$moduleName.psd1"
        if (Test-Path -LiteralPath $legacyManifest) {
            $present = @($legacyFiles | Where-Object { Test-Path -LiteralPath (Join-Path $moduleRoot $_) })
            Write-Warning ("An older installation without a version folder is still in '$moduleRoot' ($($present -join ', ')). " +
                "PowerShell now loads $latestVersion instead. Run Update-DonGrobioneLogging to remove it.")
        }

        if (Get-Module -Name $moduleName) {
            Write-Information -MessageData "The module is loaded in this session. Run 'Import-Module $moduleName -Force' to load the new version." -InformationAction Continue
        }
        else {
            Write-Information -MessageData "Use it with: Import-Module $moduleName" -InformationAction Continue
        }
    }
    catch {
        Write-Error "Installing $moduleName failed: $($_.Exception.Message)" -ErrorAction Continue
    }
    finally {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }
} -Scope $Scope -Cmdlet $PSCmdlet
