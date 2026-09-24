<#
.SYNOPSIS
    Downloads and installs the latest release of DonGrobione.Logging.

.DESCRIPTION
    Reads the latest release from https://github.com/DonGrobione/Logging,
    downloads its zip and installs the module into the default module folder:

      CurrentUser: <Documents>\WindowsPowerShell\Modules\DonGrobione.Logging
      AllUsers:    <ProgramFiles>\WindowsPowerShell\Modules\DonGrobione.Logging
      (PowerShell 7 uses 'PowerShell' instead of 'WindowsPowerShell'.)

    Existing files are overwritten; the folder itself is not deleted. If the
    same or a newer version is already installed, nothing is changed unless
    -Force is given. A folder that is a git clone is not touched unless -Force
    is given.

    Run it straight from GitHub:

      irm https://raw.githubusercontent.com/DonGrobione/Logging/main/Install.ps1 | iex

    With parameters:

      & ([scriptblock]::Create((irm https://raw.githubusercontent.com/DonGrobione/Logging/main/Install.ps1))) -Scope AllUsers

.PARAMETER Scope
    CurrentUser (default) or AllUsers. AllUsers requires an elevated session.

.PARAMETER Force
    Reinstall even if the installed version is up to date, and overwrite the
    files of a git clone.
#>
param(
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope = 'CurrentUser',

    [switch]$Force
)

# Child scope: when run through 'irm | iex', variables set here would otherwise
# leak into the caller's session, including $ErrorActionPreference.
& {
    param([string]$Scope, [bool]$Force)

    $ErrorActionPreference = 'Stop'
    $moduleName = 'DonGrobione.Logging'
    $apiUrl     = 'https://api.github.com/repos/DonGrobione/Logging/releases/latest'
    $headers    = @{ 'User-Agent' = $moduleName; 'Accept' = 'application/vnd.github+json' }
    $tempRoot   = Join-Path ([System.IO.Path]::GetTempPath()) ('{0}-{1}' -f $moduleName, [guid]::NewGuid().ToString('N'))

    try {
        $editionFolder = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
        $root          = if ($Scope -eq 'AllUsers') { $env:ProgramFiles } else { [Environment]::GetFolderPath('MyDocuments') }
        $installPath   = [System.IO.Path]::Combine($root, $editionFolder, 'Modules', $moduleName)

        # Windows PowerShell 5.1 does not enable TLS 1.2 by default; GitHub requires it.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        Write-Host "Checking latest release of $moduleName ..."
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

        $installedVersion  = $null
        $installedManifest = Join-Path $installPath "$moduleName.psd1"
        if (Test-Path -LiteralPath $installedManifest) {
            $installedVersion = [version](Import-PowerShellDataFile -LiteralPath $installedManifest).ModuleVersion
        }

        if ($null -ne $installedVersion -and $installedVersion -ge $latestVersion -and -not $Force) {
            Write-Host "$moduleName $installedVersion is already installed in '$installPath'. Use -Force to reinstall."
            return
        }
        if ((Test-Path -LiteralPath (Join-Path $installPath '.git')) -and -not $Force) {
            throw "'$installPath' is a git clone. Update it with 'git pull', or use -Force to overwrite its files."
        }

        Write-Host "Downloading $($asset.name) ..."
        $null = New-Item -ItemType Directory -Path $tempRoot
        $zipPath = Join-Path $tempRoot $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers @{ 'User-Agent' = $moduleName } -UseBasicParsing

        $extractPath = Join-Path $tempRoot 'extracted'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath

        # Validate the package before touching the installed module.
        $sourcePath     = Join-Path $extractPath $moduleName
        $sourceManifest = Join-Path $sourcePath "$moduleName.psd1"
        if (-not (Test-Path -LiteralPath $sourceManifest)) {
            throw "The package does not contain '$moduleName\$moduleName.psd1'."
        }
        $packageVersion = [version](Import-PowerShellDataFile -LiteralPath $sourceManifest).ModuleVersion
        if ($packageVersion -ne $latestVersion) {
            throw "The package contains version $packageVersion, expected $latestVersion."
        }

        $null = New-Item -ItemType Directory -Path $installPath -Force
        Copy-Item -Path (Join-Path $sourcePath '*') -Destination $installPath -Recurse -Force
        Get-ChildItem -LiteralPath $installPath -Recurse -File | Unblock-File

        if ($null -eq $installedVersion) {
            Write-Host "Installed $moduleName $latestVersion to '$installPath'."
        }
        elseif ($installedVersion -eq $latestVersion) {
            Write-Host "Reinstalled $moduleName $latestVersion in '$installPath'."
        }
        else {
            Write-Host "Updated $moduleName from $installedVersion to $latestVersion in '$installPath'."
        }
        if (Get-Module -Name $moduleName) {
            Write-Host "The module is loaded in this session. Run 'Import-Module $moduleName -Force' to load the new version."
        }
        else {
            Write-Host "Use it with: Import-Module $moduleName"
        }
    }
    catch {
        Write-Error "Installing $moduleName failed: $($_.Exception.Message)" -ErrorAction Continue
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} -Scope $Scope -Force $Force.IsPresent
