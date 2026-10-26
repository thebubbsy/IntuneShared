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
        [switch]$CopyTsv,

        [Parameter()]
        [switch]$CopyCsv,

        [Parameter()]
        [switch]$CopyHtml,

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
        Write-Host ""
        Write-Host ("  [LOG:{0}] [COMP:{1}] [PID:{2}] [TIME:{3}] [PAYLOAD:{4}-KVS]" -f $Level.ToUpperInvariant(), $Component, $PID, $utcNow.ToString('HH:mm:ss'), $(if ($CustomData) { $CustomData.Count } else { 0 })) -ForegroundColor $lvlColor
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

    if ($CopyTsv) {
        try {
            $cleanMsg = ($Message -replace "[\t\r\n]+", " ").Trim()
            $tsvHeader = "TimestampUtc`tLevel`tComponent`tProcessId`tMessage"
            $tsvRow = "$utcIso`t$Level`t$Component`t$PID`t$cleanMsg"
            Set-Clipboard -Value ("$tsvHeader`r`n$tsvRow") -ErrorAction Stop
        } catch {
            Write-Verbose "Failed copying TSV log event to clipboard: $($_.Exception.Message)"
        }
    }

    if ($CopyCsv) {
        try {
            $escCsv = { param($v) '"' + (([string]$v -replace "[\r\n]+", " ").Trim() -replace '"', '""') + '"' }
            $csvHeader = '"TimestampUtc","Level","Component","ProcessId","Message"'
            $csvRow = (@((& $escCsv $utcIso), (& $escCsv $Level), (& $escCsv $Component), (& $escCsv $PID), (& $escCsv $Message)) -join ',')
            Set-Clipboard -Value ("$csvHeader`r`n$csvRow") -ErrorAction Stop
        } catch {
            Write-Verbose "Failed copying CSV log event to clipboard: $($_.Exception.Message)"
        }
    }

    if ($CopyHtml) {
        try {
            $kvHtmlRows = [System.Collections.Generic.List[string]]::new()
            if ($CustomData -and $CustomData.Count -gt 0) {
                foreach ($k in $CustomData.Keys) {
                    $kvHtmlRows.Add("<tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:4px 0;color:#94a3b8;font-size:12px;`">$k</td><td style=`"padding:4px 0;text-align:right;color:#f8fafc;font-family:monospace;font-size:11px;`">$($CustomData[$k])</td></tr>")
                }
            }
            $htmlLog = @(
                "<div style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:640px;background:#0f172a;color:#f8fafc;border:1px solid #334155;border-radius:8px;padding:16px;box-shadow:0 4px 6px -1px rgba(0,0,0,0.1);`">",
                "  <div style=`"display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #334155;padding-bottom:10px;margin-bottom:12px;`">",
                "    <h3 style=`"margin:0;color:#38bdf8;font-size:16px;font-weight:600;`">IntuneShared Telemetry Event ($Component)</h3>",
                "    <span style=`"background:#1e293b;color:#38bdf8;padding:2px 8px;border-radius:12px;font-size:12px;font-weight:600;`">$($Level.ToUpperInvariant())</span>",
                "  </div>",
                "  <table style=`"width:100%;border-collapse:collapse;font-size:13px;`">",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:4px 0;color:#94a3b8;font-weight:500;`">Timestamp (UTC)</td><td style=`"padding:4px 0;text-align:right;color:#f8fafc;font-size:12px;`">$utcIso</td></tr>",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:4px 0;color:#94a3b8;font-weight:500;`">Severity</td><td style=`"padding:4px 0;text-align:right;color:#38bdf8;font-weight:600;`">$Level</td></tr>",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:4px 0;color:#94a3b8;font-weight:500;`">Component / PID</td><td style=`"padding:4px 0;text-align:right;color:#f8fafc;`">$Component (PID $PID)</td></tr>",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:4px 0;color:#94a3b8;font-weight:500;`">Message</td><td style=`"padding:4px 0;text-align:right;color:#4ade80;`">$Message</td></tr>",
                $(if ($kvHtmlRows.Count -gt 0) { $kvHtmlRows -join [Environment]::NewLine } else { "" }),
                "  </table>",
                "</div>"
            ) -join [Environment]::NewLine
            Set-Clipboard -Value $htmlLog -ErrorAction Stop
        } catch {
            Write-Verbose "Failed copying HTML log event to clipboard: $($_.Exception.Message)"
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
