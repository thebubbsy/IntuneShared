<#
.SYNOPSIS
    Writes structured JSON log entries to the Intune Management Extension log directory.
.DESCRIPTION
    Provides uniform structured telemetry and diagnostics for IntuneShared, WingetIntune, and AutopilotFast.
    Appends single-line JSON log events to C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\WingetIntune.log.
.PARAMETER Message
    The log message text.
.PARAMETER Level
    The severity level: Info, Warning, Error, Verbose, Debug.
.PARAMETER Component
    The source subsystem or cmdlet generating the entry.
.PARAMETER CustomData
    Optional hashtable containing structured payload properties.
.PARAMETER LogPath
    Custom override for log destination file.
.PARAMETER PassThru
    Emit the structured log entry to the pipeline. Off by default so callers' return values stay clean.
#>
function Write-IntuneLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateSet('Info', 'Warning', 'Error', 'Verbose', 'Debug')]
        [string]$Level = 'Info',

        [Parameter(Position = 2)]
        [string]$Component = 'IntuneShared',

        [Parameter()]
        [hashtable]$CustomData = @{},

        [Parameter()]
        [string]$LogPath = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\WingetIntune.log',

        [Parameter()]
        [switch]$ShowConsole,

        [Parameter()]
        [switch]$ShowCard,

        [Parameter()]
        [switch]$CopyJson,

        [Parameter()]
        [switch]$CopyMarkdown,

        [Parameter()]
        [switch]$PassThru
    )

    $utcNow = (Get-Date).ToUniversalTime()
    $utcIso = $utcNow.ToString('o')
    $logEntry = [PSCustomObject]@{
        TimestampUtc = $utcIso
        Level        = $Level
        Component    = $Component
        ProcessId    = $PID
        Message      = $Message
        CustomData   = $CustomData
    }

    $jsonLine = $logEntry | ConvertTo-Json -Compress -Depth 10

    try {
        $logDir = [System.IO.Path]::GetDirectoryName($LogPath)
        if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path $logDir)) {
            [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
        }

        [System.IO.File]::AppendAllText($LogPath, $jsonLine + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
    }
    catch {
        Write-Verbose "Failed writing to log file '$LogPath': $($_.Exception.Message)"
    }

    $lvlColor = switch ($Level) {
        'Error'   { 'Red' }
        'Warning' { 'Yellow' }
        'Info'    { 'Cyan' }
        Default   { 'DarkGray' }
    }
    $kvSuffix = ''
    if ($CustomData -and $CustomData.Count -gt 0) {
        $pairs = foreach ($k in $CustomData.Keys) { "$k=$($CustomData[$k])" }
        $kvSuffix = " {$($pairs -join ', ')}"
    }

    if ($ShowConsole) {
        $timeTag = $utcNow.ToString('HH:mm:ss.fff')
        $lvlTag = $Level.ToUpperInvariant().PadRight(7)
        Write-Host "  [$timeTag UTC] [$lvlTag] [$Component] $Message$kvSuffix" -ForegroundColor $lvlColor
    }

    if ($ShowCard) {
        $msgShort = if ($Message.Length -gt 46) { $Message.Substring(0, 43) + '...' } else { $Message }
        Write-Host "  +------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host "  |  [IntuneShared] Structured Telemetry Event                       |" -ForegroundColor Cyan
        Write-Host "  +------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host ("  |  Timestamp (UTC) : {0,-46}|" -f $utcNow.ToString('yyyy-MM-dd HH:mm:ss.fff')) -ForegroundColor Gray
        Write-Host ("  |  Severity / Comp : {0,-46}|" -f ("$($Level.ToUpperInvariant()) / $Component (PID $PID)")) -ForegroundColor $lvlColor
        Write-Host ("  |  Message         : {0,-46}|" -f $msgShort) -ForegroundColor White
        Write-Host "  +------------------------------------------------------------------+" -ForegroundColor DarkCyan
    }

    if ($CopyJson) {
        try {
            Set-Clipboard -Value $jsonLine -ErrorAction Stop
        } catch {
            Write-Verbose "Failed copying JSON log line to clipboard: $($_.Exception.Message)"
        }
    }

    if ($CopyMarkdown) {
        try {
            $mdEvent = @(
                "### IntuneShared Telemetry Event ($Component)",
                "| Field | Value |",
                "| :--- | :--- |",
                "| **Timestamp (UTC)** | ``$utcIso`` |",
                "| **Level** | **$Level** |",
                "| **Component** | ``$Component`` (PID $PID) |",
                "| **Message** | $Message |"
            ) -join [Environment]::NewLine
            Set-Clipboard -Value $mdEvent -ErrorAction Stop
        } catch {
            Write-Verbose "Failed copying Markdown log event to clipboard: $($_.Exception.Message)"
        }
    }

    switch ($Level) {
        # A log call must never become a terminating error under $ErrorActionPreference = 'Stop'
        'Error'   { Write-Error "[$Component] $Message" -ErrorAction Continue }
        'Warning' { Write-Warning "[$Component] $Message" }
        'Verbose' { Write-Verbose "[$Component] $Message" }
        'Debug'   { Write-Debug "[$Component] $Message" }
        Default   { Write-Verbose "[$Component] $Message" }
    }

    if ($PassThru) {
        return $logEntry
    }
}
