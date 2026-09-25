# Pester 3.4 (bundled with Windows PowerShell 5.1).
# Run all:          Invoke-Pester -Script .\Tests
# Run one Describe: Invoke-Pester -Script .\Tests -TestName 'Retention'

$moduleManifest = Join-Path (Split-Path -Parent $PSScriptRoot) 'DonGrobione.Logging.psd1'
Get-Module -Name DonGrobione.Logging | Remove-Module -Force
Import-Module $moduleManifest -Force -ErrorAction Stop

# Each Describe mocks Get-LogBasePath into its TestDrive. Pester 3.4 requires a
# literal scriptblock for mock bodies ($TestDrive is a global variable there).

function New-TestDirectoryName {
    'T' + [guid]::NewGuid().ToString('N').Substring(0, 8)
}

function Get-LogLines {
    param([string]$Path)
    # Leading comma: keep a one-line file as an array instead of unrolling it to a string.
    , @(Get-Content -LiteralPath $Path -Encoding UTF8)
}

$timestampPattern = '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} '

Describe 'Formatting' {
    $logRoot = Join-Path $TestDrive 'Logs'
    Mock -ModuleName DonGrobione.Logging Get-LogBasePath { [System.IO.Path]::Combine($TestDrive, 'Logs') }

    BeforeEach {
        Stop-Log
        $dir = New-TestDirectoryName
        Start-Log -LogDirectory $dir -LogFileName 'test.log'
        $logFile = Join-Path (Join-Path $logRoot $dir) 'test.log'
    }

    It 'writes a single-line message as exactly one line' {
        Write-Log 'Hello'
        $lines = Get-LogLines $logFile
        $lines.Count | Should Be 1
        $lines[0] | Should Match ($timestampPattern + '\[INFO\] Hello$')
    }

    It 'writes a message with N line breaks as N+1 lines with continuation prefix' {
        Write-Log -Level ERROR -Message "first`r`nsecond`nthird`rfourth"
        $lines = Get-LogLines $logFile
        $lines.Count | Should Be 4
        $lines[0] | Should Match ($timestampPattern + '\[ERROR\] first$')
        $lines[1] | Should BeExactly '    -> second'
        $lines[2] | Should BeExactly '    -> third'
        $lines[3] | Should BeExactly '    -> fourth'
    }

    It 'writes Exception.Message and ScriptStackTrace from an ErrorRecord' {
        function Invoke-Failure { throw 'Connection to domain controller unavailable' }
        try { Invoke-Failure } catch { $errorRecord = $_ }

        Write-Log -Level ERROR -Message 'Sync-ADUsers failed' -ErrorRecord $errorRecord
        $lines = Get-LogLines $logFile

        $lines[0] | Should Match ($timestampPattern + '\[ERROR\] Sync-ADUsers failed$')
        $lines[1] | Should BeExactly '    -> Exception: Connection to domain controller unavailable'
        $lines[2] | Should Match '^    -> StackTrace: \S+ Invoke-Failure'   # 'at' is localized ('bei' on de-DE)
        foreach ($line in $lines[1..($lines.Count - 1)]) {
            $line.StartsWith('    -> ') | Should Be $true
        }
    }

    It 'does not write entries below MinimumLevel' {
        Start-Log -LogDirectory (Split-Path -Leaf (Split-Path -Parent $logFile)) -LogFileName 'test.log' -MinimumLevel WARN
        Write-Log -Level DEBUG -Message 'debug'
        Write-Log -Level INFO -Message 'info'
        Write-Log -Level WARN -Message 'warn'
        $lines = Get-LogLines $logFile
        $lines.Count | Should Be 1
        $lines[0] | Should Match '\[WARN\] warn$'
    }

    It 'accepts an empty message' {
        { Write-Log '' } | Should Not Throw
        (Get-LogLines $logFile)[0] | Should Match ($timestampPattern + '\[INFO\] $')
    }
}

Describe 'Timestamp' {
    $logRoot = Join-Path $TestDrive 'Logs'
    Mock -ModuleName DonGrobione.Logging Get-LogBasePath { [System.IO.Path]::Combine($TestDrive, 'Logs') }
    Mock -ModuleName DonGrobione.Logging Get-Date { New-Object DateTime 2026, 9, 17, 14, 50, 58, 123 }

    It 'uses yyyy-MM-dd HH:mm:ss in 24-hour format without milliseconds' {
        Stop-Log
        Start-Log -LogDirectory 'Timestamp' -LogFileName 'test.log'
        Write-Log 'afternoon'
        $lines = Get-LogLines (Join-Path $logRoot 'Timestamp\test.log')
        $lines[0] | Should BeExactly '2026-09-17 14:50:58 [INFO] afternoon'
    }
}

Describe 'Default configuration' {
    $logRoot = Join-Path $TestDrive 'Logs'
    Mock -ModuleName DonGrobione.Logging Get-LogBasePath { [System.IO.Path]::Combine($TestDrive, 'Logs') }

    It 'falls back to <base>\Default\<HOSTNAME>_yyyy-MM-dd_HH-mm-ss.log without Start-Log' {
        Stop-Log
        Write-Log 'uninitialized'

        $files = @(Get-ChildItem -LiteralPath (Join-Path $logRoot 'Default') -Filter '*.log')
        $files.Count | Should Be 1
        $files[0].Name | Should Match ('^{0}_\d{{4}}-\d{{2}}-\d{{2}}_\d{{2}}-\d{{2}}-\d{{2}}\.log$' -f [regex]::Escape($env:COMPUTERNAME))
        (Get-LogLines $files[0].FullName)[0] | Should Match '\[INFO\] uninitialized$'
    }
}

Describe 'Retention' {
    $logRoot = Join-Path $TestDrive 'Logs'
    Mock -ModuleName DonGrobione.Logging Get-LogBasePath { [System.IO.Path]::Combine($TestDrive, 'Logs') }

    It 'keeps only RetentionCount files of the current host and never touches foreign files' {
        Stop-Log
        $dir = Join-Path $logRoot 'Retention'
        $null = New-Item -ItemType Directory -Path $dir

        $now = Get-Date
        for ($i = 1; $i -le 7; $i++) {
            $path = Join-Path $dir ('{0}_2026-01-0{1}_12-00-00.log' -f $env:COMPUTERNAME, $i)
            Set-Content -LiteralPath $path -Value 'old'
            (Get-Item -LiteralPath $path).LastWriteTime = $now.AddDays(-10 + $i)   # file 7 is the newest
        }
        $foreign = @(
            (Join-Path $dir 'OTHERHOST_2026-01-01_12-00-00.log'),
            (Join-Path $dir ('{0}X_2026-01-01_12-00-00.log' -f $env:COMPUTERNAME))
        )
        foreach ($path in $foreign) {
            Set-Content -LiteralPath $path -Value 'foreign'
            (Get-Item -LiteralPath $path).LastWriteTime = $now.AddDays(-30)
        }

        Start-Log -LogDirectory 'Retention' -RetentionCount 3
        Write-Log 'new session'

        $own = @(Get-ChildItem -LiteralPath $dir -Filter ('{0}_*.log' -f $env:COMPUTERNAME))
        $own.Count | Should Be 3
        Test-Path -LiteralPath (Join-Path $dir ('{0}_2026-01-07_12-00-00.log' -f $env:COMPUTERNAME)) | Should Be $true
        Test-Path -LiteralPath (Join-Path $dir ('{0}_2026-01-06_12-00-00.log' -f $env:COMPUTERNAME)) | Should Be $true
        Test-Path -LiteralPath (Join-Path $dir ('{0}_2026-01-05_12-00-00.log' -f $env:COMPUTERNAME)) | Should Be $false
        foreach ($path in $foreign) {
            Test-Path -LiteralPath $path | Should Be $true
        }
    }
}

Describe 'Safety' {
    $logRoot = Join-Path $TestDrive 'Logs'
    Mock -ModuleName DonGrobione.Logging Get-LogBasePath { [System.IO.Path]::Combine($TestDrive, 'Logs') }

    It 'does not throw when the log directory is read-only' {
        Stop-Log
        $dir = Join-Path $logRoot 'ReadOnly'
        $null = New-Item -ItemType Directory -Path $dir

        # The ReadOnly attribute does not stop file creation in a directory; an ACL deny does.
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity, 'Write', 'ContainerInherit,ObjectInherit', 'None', 'Deny')
        $acl = Get-Acl -LiteralPath $dir
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $dir -AclObject $acl

        try {
            $threw = $false
            try {
                Start-Log -LogDirectory 'ReadOnly' -RetryCount 2 -RetryDelayMs 1
                $warnings = @(Write-Log -Level FATAL -Message 'cannot be written' -ErrorAction Stop 3>&1)
            }
            catch {
                $threw = $true
            }
            $threw | Should Be $false
            $warnings.Count | Should Be 1
            $warnings[0].Message | Should Match 'cannot be written'
        }
        finally {
            $acl = Get-Acl -LiteralPath $dir
            $null = $acl.RemoveAccessRule($rule)
            Set-Acl -LiteralPath $dir -AclObject $acl
        }
    }
}

Describe 'Retry' {
    $logRoot = Join-Path $TestDrive 'Logs'
    Mock -ModuleName DonGrobione.Logging Get-LogBasePath { [System.IO.Path]::Combine($TestDrive, 'Logs') }

    It 'writes the entry once a temporary lock is released' {
        Stop-Log
        Start-Log -LogDirectory 'TempLock' -LogFileName 'test.log' -RetryCount 10 -RetryDelayMs 100
        Write-Log 'before lock'
        $logFile = Join-Path $logRoot 'TempLock\test.log'

        # Hold an exclusive lock from another runspace, release it after 600 ms.
        $ready = New-Object System.Threading.ManualResetEvent($false)
        $ps = [powershell]::Create()
        $null = $ps.AddScript({
            param($Path, $Ready)
            $stream = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
            try {
                $null = $Ready.Set()
                Start-Sleep -Milliseconds 600
            }
            finally {
                $stream.Dispose()
            }
        }).AddArgument($logFile).AddArgument($ready)
        $handle = $ps.BeginInvoke()

        try {
            $ready.WaitOne(10000) | Should Be $true
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $warnings = @(Write-Log 'after lock' 3>&1)
            $stopwatch.Stop()
        }
        finally {
            $null = $ps.EndInvoke($handle)
            $ps.Dispose()
            $ready.Dispose()
        }

        $warnings.Count | Should Be 0
        $stopwatch.ElapsedMilliseconds | Should BeGreaterThan 300
        $lines = Get-LogLines $logFile
        $lines.Count | Should Be 2
        $lines[1] | Should Match '\[INFO\] after lock$'
    }

    It 'falls back to Write-Warning and does not throw when the lock is permanent' {
        Stop-Log
        Start-Log -LogDirectory 'PermLock' -LogFileName 'test.log' -RetryCount 3 -RetryDelayMs 10
        $logFile = Join-Path $logRoot 'PermLock\test.log'

        $stream = [System.IO.File]::Open($logFile, 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            $threw = $false
            try {
                $warnings = @(Write-Log -Level FATAL -Message "lost line 1`nlost line 2" -ErrorAction Stop 3>&1)
            }
            catch {
                $threw = $true
            }
        }
        finally {
            $stream.Dispose()
        }

        $threw | Should Be $false
        $warnings.Count | Should Be 1
        $warnings[0].Message | Should Match 'after 3 attempt'
        $warnings[0].Message | Should Match '\[FATAL\] lost line 1'
        $warnings[0].Message | Should Match '    -> lost line 2'
        (Get-Item -LiteralPath $logFile).Length | Should Be 0
    }
}

Describe 'Session' {
    Mock -ModuleName DonGrobione.Logging Get-LogBasePath { [System.IO.Path]::Combine($TestDrive, 'Logs') }

    BeforeEach {
        Stop-Log
    }

    It 'returns false before any session is started' {
        Test-LogSession | Should Be $false
    }

    It 'returns true after Start-Log and false after Stop-Log' {
        Start-Log -LogDirectory (New-TestDirectoryName)
        Test-LogSession | Should Be $true

        Stop-Log
        Test-LogSession | Should Be $false
    }

    It 'returns true after Write-Log falls back to the default configuration' {
        Write-Log 'default session'
        Test-LogSession | Should Be $true
    }

    It 'returns a boolean' {
        (Test-LogSession).GetType() | Should Be ([bool])
    }

    It 'Get-LogSession returns null before Start-Log and after Stop-Log' {
        $null -eq (Get-LogSession) | Should Be $true

        Start-Log -LogDirectory (New-TestDirectoryName)
        Stop-Log
        $null -eq (Get-LogSession) | Should Be $true
    }

    It 'Get-LogSession returns the directory and file of the running session' {
        $dir = New-TestDirectoryName
        Start-Log -LogDirectory $dir -LogFileName 'Session.log' -RetentionCount 7 -MinimumLevel DEBUG -RetryCount 4 -RetryDelayMs 10
        $session = Get-LogSession

        $expectedDir = [System.IO.Path]::Combine($TestDrive, 'Logs', $dir)
        $session.Directory      | Should Be $expectedDir
        $session.FilePath       | Should Be ([System.IO.Path]::Combine($expectedDir, 'Session.log'))
        $session.RetentionCount | Should Be 7
        $session.MinimumLevel   | Should Be 'DEBUG'
        $session.RetryCount     | Should Be 4
        $session.RetryDelayMs   | Should Be 10
    }

    It 'Get-LogSession returns the default session after Write-Log without Start-Log' {
        Write-Log 'default session'
        $session = Get-LogSession

        $session.Directory | Should Be ([System.IO.Path]::Combine($TestDrive, 'Logs', 'Default'))
        Test-Path -LiteralPath $session.FilePath | Should Be $true
    }

    It 'Get-LogSession does not start a session' {
        $null = Get-LogSession
        Test-LogSession | Should Be $false
    }

    It 'changing the object from Get-LogSession does not change the session' {
        Start-Log -LogDirectory (New-TestDirectoryName)
        $original = (Get-LogSession).Directory

        $session = Get-LogSession
        $session.Directory = 'C:\Elsewhere'
        $session.MinimumLevel = 'FATAL'

        (Get-LogSession).Directory    | Should Be $original
        (Get-LogSession).MinimumLevel | Should Be 'INFO'
    }
}

Describe 'Update' {
    # Fake release v9.9.9: the API call returns a release object, the download
    # copies a locally built zip, and the install folder lives in TestDrive.
    $installPath = [System.IO.Path]::Combine($TestDrive, 'Modules', 'DonGrobione.Logging')
    Mock -ModuleName DonGrobione.Logging Get-ModuleInstallPath { [System.IO.Path]::Combine($TestDrive, 'Modules', 'DonGrobione.Logging') }
    Mock -ModuleName DonGrobione.Logging Invoke-RestMethod {
        [pscustomobject]@{
            tag_name = 'v9.9.9'
            assets   = @([pscustomobject]@{
                name                 = 'DonGrobione.Logging-9.9.9.zip'
                browser_download_url = 'https://example.invalid/DonGrobione.Logging-9.9.9.zip'
            })
        }
    }
    Mock -ModuleName DonGrobione.Logging Invoke-WebRequest {
        Copy-Item -LiteralPath ([System.IO.Path]::Combine($TestDrive, 'package.zip')) -Destination $OutFile
    }

    $packageDir = [System.IO.Path]::Combine($TestDrive, 'package', 'DonGrobione.Logging')
    $null = New-Item -ItemType Directory -Path $packageDir
    Set-Content -LiteralPath (Join-Path $packageDir 'DonGrobione.Logging.psd1') -Value "@{ ModuleVersion = '9.9.9' }"
    Set-Content -LiteralPath (Join-Path $packageDir 'DonGrobione.Logging.psm1') -Value '# new version'
    Compress-Archive -Path $packageDir -DestinationPath ([System.IO.Path]::Combine($TestDrive, 'package.zip'))

    function Set-InstalledVersion {
        param([string]$Version)
        $null = New-Item -ItemType Directory -Path $installPath -Force
        Set-Content -LiteralPath (Join-Path $installPath 'DonGrobione.Logging.psd1') -Value "@{ ModuleVersion = '$Version' }"
        Set-Content -LiteralPath (Join-Path $installPath 'DonGrobione.Logging.psm1') -Value '# old version'
    }

    function Get-InstalledVersion {
        [version](Import-PowerShellDataFile -LiteralPath (Join-Path $installPath 'DonGrobione.Logging.psd1')).ModuleVersion
    }

    BeforeEach {
        if (Test-Path -LiteralPath $installPath) {
            Remove-Item -LiteralPath $installPath -Recurse -Force
        }
    }

    It 'installs the latest release when the module is not installed' {
        $result = Update-DonGrobioneLogging
        $result.Updated | Should Be $true
        $result.InstalledVersion | Should BeNullOrEmpty
        Get-InstalledVersion | Should Be ([version]'9.9.9')
    }

    It 'overwrites an older installed version' {
        Set-InstalledVersion '1.0.0'
        $result = Update-DonGrobioneLogging
        $result.Updated | Should Be $true
        $result.InstalledVersion | Should Be ([version]'1.0.0')
        Get-InstalledVersion | Should Be ([version]'9.9.9')
        Get-Content -LiteralPath (Join-Path $installPath 'DonGrobione.Logging.psm1') | Should Be '# new version'
    }

    It 'does not download when the installed version is up to date' {
        Set-InstalledVersion '9.9.9'
        $result = Update-DonGrobioneLogging
        $result.Updated | Should Be $false
        Assert-MockCalled -ModuleName DonGrobione.Logging Invoke-WebRequest -Times 0 -Exactly -Scope It
        Get-Content -LiteralPath (Join-Path $installPath 'DonGrobione.Logging.psm1') | Should Be '# old version'
    }

    It 'does not change anything with -WhatIf' {
        Set-InstalledVersion '1.0.0'
        $result = Update-DonGrobioneLogging -WhatIf
        $result.Updated | Should Be $false
        Get-InstalledVersion | Should Be ([version]'1.0.0')
    }

    It 'refuses to overwrite a git clone without -Force' {
        Set-InstalledVersion '1.0.0'
        $null = New-Item -ItemType Directory -Path (Join-Path $installPath '.git')
        $result = Update-DonGrobioneLogging -ErrorAction SilentlyContinue -ErrorVariable updateErrors
        $result.Updated | Should Be $false
        $updateErrors.Count | Should Be 1
        "$($updateErrors[0])" | Should Match 'git pull'
        Get-InstalledVersion | Should Be ([version]'1.0.0')
    }
}
