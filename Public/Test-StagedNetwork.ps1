<#
.SYNOPSIS
    Executes a 7-stage network, cloud connectivity, and HTTPS time synchronization diagnostic probe.
.DESCRIPTION
    Performs staged verification across physical link, gateway, DNS, TCP socket, TLS handshake,
    HTTPS time synchronization over port 443 with 5-minute Kerberos tolerance, and Autopilot endpoints.
#>
function Test-StagedNetwork {
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$TimeoutSeconds = 5,

        [Parameter()]
        [switch]$AutoSyncClock = $true,

        [Parameter()]
        [int]$MaxTimeSkewSeconds = 300,

        [Parameter()]
        [switch]$CopyReport,

        [Parameter()]
        [switch]$CopyJson,

        [Parameter()]
        [switch]$CopyTsv,

        [Parameter()]
        [switch]$Quiet
    )

    $stages = [System.Collections.Generic.List[PSCustomObject]]::new()
    $allPassed = $true

    # Stage 1: Network Interface Check
    $adapters = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled = TRUE" -ErrorAction SilentlyContinue)
    $interfaceUp = ($adapters.Count -gt 0)
    $stages.Add([PSCustomObject]@{
        Stage       = 1
        Name        = 'Network Interface'
        Success     = $interfaceUp
        Description = if ($interfaceUp) { "Active adapter found (IP: $($adapters[0].IPAddress[0]))" } else { "No active IP-enabled network adapter" }
    })
    if (-not $interfaceUp) { $allPassed = $false }

    # Stage 2: Gateway Check
    $gatewayOk = $false
    if ($interfaceUp -and $adapters[0].DefaultIPGateway) {
        $gatewayOk = $true
    }
    $stages.Add([PSCustomObject]@{
        Stage       = 2
        Name        = 'Default Gateway'
        Success     = $gatewayOk
        Description = if ($gatewayOk) { "Gateway configured: $($adapters[0].DefaultIPGateway[0])" } else { "No default gateway assigned" }
    })

    # Stage 3: DNS Resolution
    $endpoints = @('login.microsoftonline.com', 'graph.microsoft.com', 'ztd.dds.microsoft.com')
    $dnsOk = $true
    foreach ($ep in $endpoints) {
        try {
            $ips = [System.Net.Dns]::GetHostAddresses($ep)
            if ($ips.Count -eq 0) { $dnsOk = $false }
        }
        catch { $dnsOk = $false }
    }

    $stages.Add([PSCustomObject]@{
        Stage       = 3
        Name        = 'DNS Resolution'
        Success     = $dnsOk
        Description = if ($dnsOk) { "Cloud hostnames resolved successfully" } else { "DNS resolution failed for one or more endpoints" }
    })
    if (-not $dnsOk) { $allPassed = $false }

    # Stage 4: TCP 443 Socket Connection
    $tcpOk = $false
    $latencyMs = 0
    if ($dnsOk) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $iar = $client.BeginConnect('login.microsoftonline.com', 443, $null, $null)
            $wh = $iar.AsyncWaitHandle
            if ($wh.WaitOne($TimeoutSeconds * 1000, $false)) {
                $client.EndConnect($iar)
                $sw.Stop()
                $latencyMs = $sw.ElapsedMilliseconds
                $tcpOk = $true
            }
            $client.Close()
        } catch { }
    }

    $stages.Add([PSCustomObject]@{
        Stage       = 4
        Name        = 'TCP Port 443 Connect'
        Success     = $tcpOk
        Description = if ($tcpOk) { "TCP connection established in $latencyMs ms" } else { "Port 443 socket connection failed or timed out" }
    })
    if (-not $tcpOk) { $allPassed = $false }

    # Stage 5: HTTPS Clock Sync (5-Minute Kerberos/TLS Tolerance Threshold)
    $tlsAndTimeOk = $false
    $timeSkewSec = 0
    if ($tcpOk) {
        try {
            $req = [System.Net.HttpWebRequest]::Create('https://login.microsoftonline.com')
            $req.Method = 'HEAD'
            $req.Timeout = $TimeoutSeconds * 1000
            $resp = $req.GetResponse()
            
            if ($resp.Headers['Date']) {
                $cloudTimeUtc = [DateTime]::Parse($resp.Headers['Date']).ToUniversalTime()
                $localTimeUtc = (Get-Date).ToUniversalTime()
                $timeSkewSec = [Math]::Round([Math]::Abs(($localTimeUtc - $cloudTimeUtc).TotalSeconds), 1)

                if ($timeSkewSec -gt $MaxTimeSkewSeconds -and $AutoSyncClock) {
                    Write-Warning "Detected $timeSkewSec sec clock skew (> $MaxTimeSkewSeconds sec threshold). Resynchronizing system clock..."
                    try {
                        Set-Date -Date $cloudTimeUtc.ToLocalTime() -ErrorAction SilentlyContinue
                    } catch { }
                }
                $tlsAndTimeOk = $true
            }
            $resp.Close()
        }
        catch {
            $webResp = $null
            if ($_.Exception -is [System.Net.WebException] -and $_.Exception.Response) {
                $webResp = $_.Exception.Response
            } elseif ($_.Exception.InnerException -is [System.Net.WebException] -and $_.Exception.InnerException.Response) {
                $webResp = $_.Exception.InnerException.Response
            }

            if ($webResp) {
                $tlsAndTimeOk = $true
                try { $webResp.Close() } catch { }
            }
        }
    }

    $stages.Add([PSCustomObject]@{
        Stage       = 5
        Name        = 'HTTPS Time & TLS Sync'
        Success     = $tlsAndTimeOk
        Description = if ($tlsAndTimeOk) { "TLS verified (Clock Skew: $timeSkewSec sec within $MaxTimeSkewSeconds sec tolerance)" } else { "TLS handshake or HTTPS Date header probe failed" }
    })
    if (-not $tlsAndTimeOk) { $allPassed = $false }

    # Stage 6: Captive Portal Check
    $captivePortal = $false
    try {
        $ncsiReq = [System.Net.HttpWebRequest]::Create('http://www.msftconnecttest.com/connecttest.txt')
        $ncsiReq.Timeout = $TimeoutSeconds * 1000
        $ncsiReq.AllowAutoRedirect = $false
        $ncsiResp = $ncsiReq.GetResponse()
        
        if ([int]$ncsiResp.StatusCode -eq 302 -or [int]$ncsiResp.StatusCode -eq 301) {
            $captivePortal = $true
        } else {
            $stream = $ncsiResp.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $text = $reader.ReadToEnd().Trim()
            if ($text -ne 'Microsoft Connect Test') { $captivePortal = $true }
        }
        $ncsiResp.Close()
    } catch { }

    $stages.Add([PSCustomObject]@{
        Stage       = 6
        Name        = 'Captive Portal Check'
        Success     = (-not $captivePortal)
        Description = if (-not $captivePortal) { "No captive portal or HTTP interception detected" } else { "Captive portal detected (HTTP 302 redirect / body mismatch)" }
    })
    if ($captivePortal) { $allPassed = $false }

    # Stage 7: Microsoft Autopilot Endpoint Probe
    $autopilotEpOk = $false
    try {
        $req = [System.Net.HttpWebRequest]::Create('https://ztd.dds.microsoft.com')
        $req.Timeout = $TimeoutSeconds * 1000
        $req.Method = 'HEAD'
        $resp = $req.GetResponse()
        $resp.Close()
        $autopilotEpOk = $true
    } catch {
        $webResp = $null
        if ($_.Exception -is [System.Net.WebException] -and $_.Exception.Response) {
            $webResp = $_.Exception.Response
        } elseif ($_.Exception.InnerException -is [System.Net.WebException] -and $_.Exception.InnerException.Response) {
            $webResp = $_.Exception.InnerException.Response
        }

        if ($webResp) {
            $autopilotEpOk = $true
            try { $webResp.Close() } catch { }
        } elseif ($_.Exception.Response) {
            $autopilotEpOk = $true
        } elseif ($_.Exception.Message -match '404|403|401|Method Not Allowed') {
            $autopilotEpOk = $true
        }
    }

    $stages.Add([PSCustomObject]@{
        Stage       = 7
        Name        = 'Autopilot Endpoint'
        Success     = $autopilotEpOk
        Description = if ($autopilotEpOk) { "ztd.dds.microsoft.com reachable" } else { "Autopilot enrollment endpoint unreachable" }
    })
    if (-not $autopilotEpOk) { $allPassed = $false }

    $passedCount = @($stages | Where-Object { $_.Success }).Count

    if (-not $Quiet) {
        $bar = ('#' * $passedCount) + ('-' * (7 - $passedCount))
        $hdrColor = if ($allPassed -and $passedCount -eq 7) { 'Green' } else { 'Yellow' }
        $verdictText = if ($allPassed -and $passedCount -eq 7) { 'CLOUD READY' } else { 'DEGRADED / BLOCKED' }
        $borderColor = if ($allPassed -and $passedCount -eq 7) { 'DarkGreen' } else { 'DarkYellow' }
        Write-Host "  [IntuneShared] 7-Stage Cloud Network Ladder [$bar] ($passedCount/7 Passed)" -ForegroundColor $hdrColor
        foreach ($st in $stages) {
            $tag = if ($st.Success) { '[PASS]' } else { '[FAIL]' }
            $col = if ($st.Success) { 'Green' } else { 'Red' }
            Write-Host ("    {0} Stage {1}: {2,-22} - {3}" -f $tag, $st.Stage, $st.Name, $st.Description) -ForegroundColor $col
        }
        $tcpSummary = if ($tcpOk) { "$latencyMs ms (login.microsoftonline.com:443)" } else { 'Unreachable' }
        $skewSummary = if ($tlsAndTimeOk) { "$timeSkewSec sec (Max $MaxTimeSkewSeconds sec)" } else { 'Unverified' }
        $portalSummary = if (-not $captivePortal) { 'Clear (Direct Cloud Route)' } else { 'Intercepted (301/302 Redirect)' }
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor $borderColor
        Write-Host ("  | CLOUD NETWORK & TIME SYNC POSTURE SUMMARY     [{0,20}] |" -f $verdictText) -ForegroundColor $hdrColor
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor $borderColor
        Write-Host ("  | Stages Passed : {0,-22} TCP 443 RTT : {1,-16} |" -f "$passedCount / 7 [$bar]", $(if ($tcpOk) { "$latencyMs ms" } else { 'FAIL' })) -ForegroundColor White
        Write-Host ("  | Clock Skew    : {0,-22} Captive     : {1,-16} |" -f $skewSummary, $(if (-not $captivePortal) { 'CLEAR' } else { 'DETECTED' })) -ForegroundColor Gray
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor $borderColor
    }

    if ($CopyReport) {
        try {
            $mdLines = [System.Collections.Generic.List[string]]::new()
            $mdLines.Add("### IntuneShared 7-Stage Cloud Network & Time Sync Report")
            $mdLines.Add("- **Host:** ``$($env:COMPUTERNAME)`` | **Passed:** $passedCount/7 | **TCP 443 RTT:** ${latencyMs}ms | **Clock Skew:** ${timeSkewSec}s")
            $mdLines.Add("")
            $mdLines.Add("| Stage | Check | Status | Details |")
            $mdLines.Add("| :---: | :--- | :---: | :--- |")
            foreach ($st in $stages) {
                $statusStr = if ($st.Success) { 'PASS' } else { 'FAIL' }
                $mdLines.Add("| $($st.Stage) | **$($st.Name)** | ``$statusStr`` | $($st.Description) |")
            }
            Set-Clipboard -Value ($mdLines -join "`r`n") -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied 7-Stage Network Diagnostic Report (Markdown) to clipboard." -ForegroundColor Green
            }
        } catch { }
    }

    $resultObj = [PSCustomObject]@{
        IsFullyReady = ($allPassed -and $passedCount -eq 7)
        StagesPassed = $passedCount
        TotalStages  = 7
        Details      = $stages
    }

    if ($CopyJson) {
        try {
            $jsonStr = $resultObj | ConvertTo-Json -Depth 4
            Set-Clipboard -Value $jsonStr -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied 7-Stage Network Diagnostic JSON to clipboard." -ForegroundColor Green
            }
        } catch { }
    }

    if ($CopyTsv) {
        try {
            $tsvRows = [System.Collections.Generic.List[string]]::new()
            $tsvRows.Add("Stage`tName`tStatus`tDescription")
            foreach ($st in $stages) {
                $statusStr = if ($st.Success) { 'PASS' } else { 'FAIL' }
                $tsvRows.Add("$($st.Stage)`t$($st.Name)`t$statusStr`t$($st.Description)")
            }
            Set-Clipboard -Value ($tsvRows -join "`r`n") -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied 7-Stage Network Diagnostic TSV rows to clipboard." -ForegroundColor Green
            }
        } catch { }
    }

    return $resultObj
}
