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
        [switch]$PassThru
    )

    $utcIso = (Get-Date).ToUniversalTime().ToString('o')
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
