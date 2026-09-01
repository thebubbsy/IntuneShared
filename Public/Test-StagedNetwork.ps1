<#
.SYNOPSIS
    Executes a 7-stage network, cloud connectivity, and HTTPS time synchronization diagnostic probe.
.DESCRIPTION
    Performs staged verification across physical link, gateway, DNS, TCP socket, TLS handshake,
    HTTPS time synchronization over port 443, captive portal interception, and Autopilot endpoints.
#>
function Test-StagedNetwork {
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$TimeoutSeconds = 5,

        [Parameter()]
        [switch]$AutoSyncClock = $true
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

    # Stage 5: HTTPS Clock Sync & TLS Handshake (Replaces UDP 123 NTP with TCP 443 Date Header)
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

                if ($timeSkewSec -gt 30 -and $AutoSyncClock) {
                    Write-Warning "Detected $timeSkewSec sec clock skew in OOBE. Synchronizing system clock..."
                    # Correct system time
                    try {
                        [Microsoft.VisualBasic.DateAndTime]::TimeString = $cloudTimeUtc.ToLocalTime().ToString('HH:mm:ss')
                    } catch { }
                }
                $tlsAndTimeOk = $true
            }
            $resp.Close()
        }
        catch {
            $tlsAndTimeOk = $false
        }
    }

    $stages.Add([PSCustomObject]@{
        Stage       = 5
        Name        = 'HTTPS Time & TLS Sync'
        Success     = $tlsAndTimeOk
        Description = if ($tlsAndTimeOk) { "TLS verified (Clock Skew: $timeSkewSec sec against Entra ID)" } else { "TLS handshake or HTTPS Date header probe failed" }
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
        $resp = $req.GetResponse()
        $resp.Close()
        $autopilotEpOk = $true
    } catch {
        if ($_.Exception.Response) { $autopilotEpOk = $true }
    }

    $stages.Add([PSCustomObject]@{
        Stage       = 7
        Name        = 'Autopilot Endpoint'
        Success     = $autopilotEpOk
        Description = if ($autopilotEpOk) { "ztd.dds.microsoft.com reachable" } else { "Autopilot enrollment endpoint unreachable" }
    })
    if (-not $autopilotEpOk) { $allPassed = $false }

    $passedCount = @($stages | Where-Object { $_.Success }).Count

    return [PSCustomObject]@{
        IsFullyReady = ($allPassed -and $passedCount -eq 7)
        StagesPassed = $passedCount
        TotalStages  = 7
        Details      = $stages
    }
}
