PROJECT: Build a complete PowerShell logging module named
"DonGrobione.Logging" for central, unified logging across all my scripts.

PURPOSE:
Scripts import the module and initialize logging via an init function.
If not initialized, a default configuration is used.

BASE PATH:
All logs are stored under [Environment]::GetFolderPath('MyDocuments') + "\Logs"
The project/application folder is defined during initialization.

MODULE FUNCTIONS AND BEHAVIOR:

1. Start-Log (initialization, called once at script start):
   - Parameters: -LogDirectory (project name), -LogFileName, -RetentionCount,
     -MinimumLevel, -RetryCount, -RetryDelayMs
   - Stores configuration in module session state (Script scope)
   - -LogDirectory: relative subfolder under base path; defaults to "Default"
   - -LogFileName: defaults to "<HOSTNAME>_yyyy-MM-dd_HHmmss.log"
   - -RetentionCount: default 5 (files per hostname in the project folder)
   - -MinimumLevel: default 'INFO'; entries below threshold are not written
   - -RetryCount: default 3 (write attempts on failure)
   - -RetryDelayMs: default 500 (milliseconds between retries)

2. Write-Log (core function):
   - Parameters:
     $Message (Position 0, Mandatory)
     $Level = ValidateSet('DEBUG','INFO','WARN','ERROR','FATAL'), default 'INFO'
     $ErrorRecord (System.Management.Automation.ErrorRecord, optional)
   - If Start-Log was never called, fall back to the default
     configuration automatically (create directories on demand)
   - Line format: "yyyy-MM-dd HH:mm:ss [LEVEL] Message"
   - Timestamp uses 24-hour format (local time)

3. MULTILINE HANDLING (one-line-per-entry must not break):
   - All continuation lines get the prefix "    -> " (4 spaces + arrow).
   - Example:
     2026-09-17 14:50:58 [ERROR] Sync-ADUsers failed
         -> Exception: Connection to domain controller unavailable
         -> Target: DC01.mydomain.local
         -> StackTrace: at Connect-DC...
   - Auto-detect multiline: split $Message on "`r`n", "`r", "`n"
   - If $ErrorRecord provided: extract Exception.Message and
     ScriptStackTrace as separate continuation lines

4. WRITE RETRY LOGIC (important — log files live in a folder synced
   by a cloud sync client, which occasionally locks files briefly):
   - Wrap each write operation in a retry loop
   - On failure (file locked, IOException): wait $RetryDelayMs and retry
   - Repeat until $RetryCount attempts are exhausted
   - Increase the delay slightly between retries (e.g. linear or fixed)
   - If ALL attempts fail: fall back to Write-Warning to the console
     with the intended message, then continue silently
   - The log entry is never silently lost without at least one fallback
     attempt on the console
   - The same retry logic applies to creating the log directory

5. LOG RETENTION:
   - On Start-Log: delete oldest files matching "<HOSTNAME>*.log" in the
     target directory so that at most $RetentionCount remain
   - Only touch files of the CURRENT hostname, never foreign files
   - If deletion of a retention candidate fails (locked by sync client),
     skip that file and continue with the next candidate

6. SAFETY (critical):
   - The module must NEVER throw. FATAL is a severity tag only —
     aborting the calling script is the orchestrator's job, not the
     module's
   - If writing fails permanently after all retries: Write-Warning to
     the console, continue silently

7. ORCHESTRATOR USAGE EXAMPLE:
   - Deliver a usage example showing the recommended caller pattern:
     $ErrorActionPreference = 'Stop', full try/catch/finally around the
     script body, Write-Log -Level FATAL in the catch block with the
     caught $ErrorRecord, "Stop-Log" cleanup in finally, exit 1 on failure

TECHNICAL CONSTRAINTS:
- Windows PowerShell 5.1 compatible, no external modules
- Open/append/close the log file per entry (no persistent handle) —
  short lock windows reduce conflicts with the sync client
- Comment-based help for every public function
- Follow PowerShell best practices: approved verbs, PascalCase
- Use [Environment]::GetFolderPath('MyDocuments') as base path for logs

DELIVERABLES:
1. DonGrobione.Logging.psm1 (complete module)
2. DonGrobione.Logging.psd1 (manifest)
3. Usage example (orchestrator pattern with try/catch/finally)
4. Pester tests covering:
   - Single-line message produces exactly 1 line in the log file
   - Multi-line message produces N+1 lines, each continuation line
     starting with "    -> "
   - ErrorRecord extraction writes Exception.Message and StackTrace
   - Uninitialized Write-Log call falls back to the default config
   - Retention keeps only $RetentionCount files per hostname
   - Module does not throw when the log directory is read-only
   - Retry logic: a temporarily locked log file (simulate with a held
     FileStream) eventually gets written after the lock is released
   - Retry exhaustion: permanent lock leads to Write-Warning, no throw
   - Timestamp format is yyyy-MM-dd HH:mm:ss (24-hour, no milliseconds)