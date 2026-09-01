<#
.SYNOPSIS
    Executes a 7-stage network and cloud connectivity diagnostic probe.
.DESCRIPTION
    Performs staged verification across physical link, gateway, DNS, TCP socket, TLS handshake,
    captive portal interception, and Microsoft Cloud endpoints. Compatible with PowerShell 5.1+.
#>
function Test-StagedNetwork {
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$TimeoutSeconds = 5
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
    $resolvedIps = @()

    foreach ($ep in $endpoints) {
        try {
            $ips = [System.Net.Dns]::GetHostAddresses($ep)
            if ($ips.Count -gt 0) {
                $resolvedIps += "$ep -> $($ips[0].IPAddressToString)"
            } else {
                $dnsOk = $false
            }
        }
        catch {
            $dnsOk = $false
        }
    }

    $stages.Add([PSCustomObject]@{
        Stage       = 3
        Name        = 'DNS Resolution'
        Success     = $dnsOk
        Description = if ($dnsOk) { "All cloud hostnames resolved successfully" } else { "DNS resolution failed for one or more endpoints" }
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

    # Stage 5: TLS Handshake
    $tlsOk = $false
    if ($tcpOk) {
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient('login.microsoftonline.com', 443)
            $sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false)
            $sslStream.AuthenticateAsClient('login.microsoftonline.com')
            if ($sslStream.IsAuthenticated -and $sslStream.IsEncrypted) {
                $tlsOk = $true
            }
            $sslStream.Close()
            $tcpClient.Close()
        } catch { }
    }

    $stages.Add([PSCustomObject]@{
        Stage       = 5
        Name        = 'TLS Handshake'
        Success     = $tlsOk
        Description = if ($tlsOk) { "TLS handshake verified with valid certificate chain" } else { "TLS negotiation failed (possible MITM/SSL inspection)" }
    })
    if (-not $tlsOk) { $allPassed = $false }

    # Stage 6: Captive Portal Probe
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
        # Autopilot endpoint may return 401/403 or 200, both prove reachable
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
