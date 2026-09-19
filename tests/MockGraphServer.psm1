<#
.SYNOPSIS
    Offline Mock Microsoft Graph & Azure Blob REST Server for deterministic integration testing.
.DESCRIPTION
    Provides an in-memory HTTP mock server utilizing [System.Net.HttpListener] to simulate
    Microsoft Graph v1.0 / beta endpoints and Azure Storage Block Blob upload APIs.
    Dual-engine compatible with Windows PowerShell 5.1 and PowerShell 7+.
#>

# Module-scoped reference to the active mock server instance
$script:CurrentMockServer = $null

function Start-MockGraphServer {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [int]$Port = 0,

        [Parameter()]
        [string]$TenantId = '11111111-2222-3333-4444-555555555555',

        [Parameter()]
        [string]$TenantName = 'Contoso Dev Sandbox',

        [Parameter()]
        [switch]$SetGlobalEnv
    )

    # 1. Allocate Port Dynamically if Port is 0
    $actualPort = $Port
    if ($actualPort -le 0) {
        $tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $tcpListener.Start()
        $actualPort = ($tcpListener.LocalEndpoint).Port
        $tcpListener.Stop()
    }

    # 2. Initialize HttpListener
    $listener = [System.Net.HttpListener]::new()
    $prefix = "http://127.0.0.1:$actualPort/"
    $listener.Prefixes.Add($prefix)
    $listener.Start()

    # 3. Thread-Safe Synchronized State Store
    $state = [hashtable]::Synchronized(@{
        IsRunning                             = $true
        Port                                  = $actualPort
        TenantId                              = $TenantId
        TenantName                            = $TenantName
        DefaultImportStatus                   = 'complete'
        DefaultImportErrorCode                = 0
        DefaultImportErrorName                = 'none'
        DefaultProfileAssignmentStatus        = 'assigned'
        DefaultProfileAssignmentDetailedStatus = 'none'
        DefaultProfileDisplayName             = 'Standard Autopilot Profile'
        DefaultFileUploadState                = 'succeeded'
        ForceForbidden                        = $false
        SyncCallCount                         = 0
        CommitCallCount                       = 0
        ReceivedBlockBytes                    = 0L
        ReceivedBlocks                        = [System.Collections.Generic.List[string]]::new()
        CommittedBlocks                       = [System.Collections.Generic.List[string]]::new()
        ExistingBlocks                        = [System.Collections.Generic.List[string]]::new()
        ImportedDevices                       = [hashtable]::Synchronized(@{})
        AutopilotDevices                      = [hashtable]::Synchronized(@{})
        MobileApps                            = [hashtable]::Synchronized(@{})
        ContentFiles                          = [hashtable]::Synchronized(@{})
        RequestLog                            = [System.Collections.Generic.List[PSCustomObject]]::new()
    })

    # 4. Background Request Dispatcher (runs in a dedicated runspace; a raw .NET thread has no
    #    runspace and PowerShell script blocks cannot execute there)
    $dispatcher = {
        while ($state.IsRunning -and $listener.IsListening) {
            try {
                $context = $listener.GetContext()
                $req = $context.Request
                $resp = $context.Response
                $httpMethod = $req.HttpMethod
                $rawUrl = $req.RawUrl
                $path = $req.Url.AbsolutePath
                $queryString = $req.Url.Query
                $decodedQuery = [System.Uri]::UnescapeDataString($queryString)

                # Record request for audit inspection
                try {
                    $state.RequestLog.Add([PSCustomObject]@{
                        Method    = $httpMethod
                        Path      = $path
                        Query     = $queryString
                        Timestamp = [DateTime]::UtcNow.ToString('o')
                    })
                } catch { }

                # Global Simulation Error Toggle
                if ($state.ForceForbidden) {
                    $resp.StatusCode = 403
                    $resp.OutputStream.Close()
                    continue
                }

                # -------------------------------------------------------------
                # Route 1: Azure Storage Blob Upload (PUT comp=block)
                # -------------------------------------------------------------
                if ($httpMethod -eq 'PUT' -and $queryString -match 'comp=block(&|$)') {
                    $blockId = ''
                    if ($queryString -match 'blockid=([^&]+)') {
                        $blockId = [System.Uri]::UnescapeDataString($matches[1])
                        $state.ReceivedBlocks.Add($blockId)
                    }

                    $buffer = New-Object byte[] 65536
                    $read = 0
                    while (($read = $req.InputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $state.ReceivedBlockBytes += $read
                    }

                    $resp.StatusCode = 201
                    $resp.OutputStream.Close()
                    continue
                }

                # -------------------------------------------------------------
                # Route 2: Azure Storage Blocklist Query (GET comp=blocklist)
                # -------------------------------------------------------------
                if ($httpMethod -eq 'GET' -and $queryString -match 'comp=blocklist') {
                    $xmlBuilder = [System.Text.StringBuilder]::new()
                    [void]$xmlBuilder.Append('<?xml version="1.0" encoding="utf-8"?><BlockList><CommittedBlocks>')

                    # Output existing & committed blocks
                    $seen = [System.Collections.Generic.HashSet[string]]::new()
                    foreach ($b in $state.ExistingBlocks) {
                        if ($seen.Add($b)) {
                            [void]$xmlBuilder.Append("<Block><Name>$b</Name><Size>4194304</Size></Block>")
                        }
                    }
                    foreach ($b in $state.CommittedBlocks) {
                        if ($seen.Add($b)) {
                            [void]$xmlBuilder.Append("<Block><Name>$b</Name><Size>4194304</Size></Block>")
                        }
                    }
                    [void]$xmlBuilder.Append('</CommittedBlocks><UncommittedBlocks>')

                    # Output uncommitted blocks (received but not in committed)
                    foreach ($b in $state.ReceivedBlocks) {
                        if (-not $seen.Contains($b)) {
                            [void]$xmlBuilder.Append("<Block><Name>$b</Name><Size>4194304</Size></Block>")
                        }
                    }
                    [void]$xmlBuilder.Append('</UncommittedBlocks></BlockList>')

                    $xmlBytes = [System.Text.Encoding]::UTF8.GetBytes($xmlBuilder.ToString())
                    $resp.ContentType = 'application/xml'
                    $resp.ContentLength64 = $xmlBytes.Length
                    $resp.StatusCode = 200
                    $resp.OutputStream.Write($xmlBytes, 0, $xmlBytes.Length)
                    $resp.OutputStream.Close()
                    continue
                }

                # -------------------------------------------------------------
                # Route 3: Azure Storage Blocklist Commit (PUT comp=blocklist)
                # -------------------------------------------------------------
                if ($httpMethod -eq 'PUT' -and $queryString -match 'comp=blocklist') {
                    $reader = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                    $bodyXml = $reader.ReadToEnd()
                    $reader.Close()

                    $matchesLatest = [System.Text.RegularExpressions.Regex]::Matches($bodyXml, '<Latest>([^<]+)</Latest>')
                    foreach ($m in $matchesLatest) {
                        $state.CommittedBlocks.Add($m.Groups[1].Value)
                    }

                    $resp.StatusCode = 201
                    $resp.OutputStream.Close()
                    continue
                }

                # -------------------------------------------------------------
                # Route 4: Organization / Tenant Discovery (GET /v1.0/organization)
                # -------------------------------------------------------------
                if ($httpMethod -eq 'GET' -and ($path -eq '/v1.0/organization' -or $path -eq '/beta/organization')) {
                    $orgJson = '{"value":[{"id":"' + $state.TenantId + '","displayName":"' + $state.TenantName + '","verifiedDomains":[{"name":"contoso.onmicrosoft.com","isDefault":true}]}]}'
                    $orgBytes = [System.Text.Encoding]::UTF8.GetBytes($orgJson)
                    $resp.ContentType = 'application/json'
                    $resp.ContentLength64 = $orgBytes.Length
                    $resp.StatusCode = 200
                    $resp.OutputStream.Write($orgBytes, 0, $orgBytes.Length)
                    $resp.OutputStream.Close()
                    continue
                }

                # -------------------------------------------------------------
                # Route 5: Autopilot Settings Tenant Sync (POST /beta/deviceManagement/windowsAutopilotSettings/sync)
                # -------------------------------------------------------------
                if ($httpMethod -eq 'POST' -and $path -match '/windowsAutopilotSettings/sync$') {
                    $state.SyncCallCount++
                    $emptyJson = [System.Text.Encoding]::UTF8.GetBytes('{}')
                    $resp.ContentType = 'application/json'
                    $resp.ContentLength64 = $emptyJson.Length
                    $resp.StatusCode = 200
                    $resp.OutputStream.Write($emptyJson, 0, $emptyJson.Length)
                    $resp.OutputStream.Close()
                    continue
                }

                # -------------------------------------------------------------
                # Route 6: Autopilot Device Registration Ingestion (POST importedWindowsAutopilotDeviceIdentities)
                # -------------------------------------------------------------
                if ($httpMethod -eq 'POST' -and $path -match '/importedWindowsAutopilotDeviceIdentities$') {
                    $reader = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                    $bodyText = $reader.ReadToEnd()
                    $reader.Close()

                    $sn = 'MOCK-DEVICE-' + [Guid]::NewGuid().ToString().Substring(0, 8).ToUpper()
                    $gt = ''
                    $pk = ''
                    if ($bodyText -match '"serialNumber"\s*:\s*"([^"]+)"') { $sn = $matches[1] }
                    if ($bodyText -match '"groupTag"\s*:\s*"([^"]+)"') { $gt = $matches[1] }
                    if ($bodyText -match '"productKey"\s*:\s*"([^"]+)"') { $pk = $matches[1] }

                    $importId = [Guid]::NewGuid().ToString()
                    $devGuid = [Guid]::NewGuid().ToString()

                    $importObj = @{
                        id           = $importId
                        serialNumber = $sn
                        groupTag     = $gt
                        productKey   = $pk
                        state        = @{
                            deviceImportStatus = $state.DefaultImportStatus
                            deviceErrorCode    = $state.DefaultImportErrorCode
                            deviceErrorName    = $state.DefaultImportErrorName
                        }
                    }
                    $state.ImportedDevices[$importId] = $importObj

                    # Register device in Autopilot identities table
                    $state.AutopilotDevices[$sn] = @{
                        id                                         = $devGuid
                        serialNumber                               = $sn
                        groupTag                                   = $gt
                        deploymentProfileAssignmentStatus          = $state.DefaultProfileAssignmentStatus
                        deploymentProfileAssignmentDetailedStatus  = $state.DefaultProfileAssignmentDetailedStatus
                        deploymentProfileAssignedDateTime          = [DateTime]::UtcNow.ToString('o')
                        assignedDeploymentProfile                  = @{
                            displayName = $state.DefaultProfileDisplayName
                        }
                    }

                    $resJson = '{"id":"' + $importId + '","serialNumber":"' + $sn + '","groupTag":"' + $gt + '","state":{"deviceImportStatus":"' + $state.DefaultImportStatus + '","deviceErrorCode":' + $state.DefaultImportErrorCode + ',"deviceErrorName":"' + $state.DefaultImportErrorName + '"}}'
                    $resBytes = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                    $resp.ContentType = 'application/json'
                    $resp.ContentLength64 = $resBytes.Length
                    $resp.StatusCode = 201
                    $resp.OutputStream.Write($resBytes, 0, $resBytes.Length)
                    $resp.OutputStream.Close()
                    continue
                }

                # -------------------------------------------------------------
                # Route 7: Autopilot Ingestion Status Poll (GET importedWindowsAutopilotDeviceIdentities/{id})
                # -------------------------------------------------------------
                if ($httpMethod -eq 'GET' -and $path -match '/importedWindowsAutopilotDeviceIdentities/([a-zA-Z0-9\-_]+)$') {
                    $importId = $matches[1]
                    $statusVal = $state.DefaultImportStatus
                    $errCode = $state.DefaultImportErrorCode
                    $errName = $state.DefaultImportErrorName

                    if ($state.ImportedDevices.ContainsKey($importId)) {
                        $dev = $state.ImportedDevices[$importId]
                        if ($dev.state) {
                            $statusVal = $dev.state.deviceImportStatus
                            $errCode = $dev.state.deviceErrorCode
                            $errName = $dev.state.deviceErrorName
                        }
                    }

                    $resJson = '{"id":"' + $importId + '","state":{"deviceImportStatus":"' + $statusVal + '","deviceErrorCode":' + $errCode + ',"deviceErrorName":"' + $errName + '"}}'
                    $resBytes = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                    $resp.ContentType = 'application/json'
                    $resp.ContentLength64 = $resBytes.Length
                    $resp.StatusCode = 200
                    $resp.OutputStream.Write($resBytes, 0, $resBytes.Length)
                    $resp.OutputStream.Close()
                    continue
                }

                # -------------------------------------------------------------
                # Route 8: Autopilot Device Identities Query (GET windowsAutopilotDeviceIdentities)
                # -------------------------------------------------------------
                if ($httpMethod -eq 'GET' -and $path -match '/windowsAutopilotDeviceIdentities$') {
                    $targetSn = 'MOCK-DEVICE-SERIAL'
                    if ($decodedQuery -match "serialNumber\s+eq\s+'?([^'&]+)'?") {
                        $targetSn = $matches[1]
                    }

                    $devGuid = [Guid]::NewGuid().ToString()
                    $gt = 'DEFAULT'
                    $status = $state.DefaultProfileAssignmentStatus
                    $detailedStatus = $state.DefaultProfileAssignmentDetailedStatus
                    $profName = $state.DefaultProfileDisplayName
                    $assignedDate = [DateTime]::UtcNow.ToString('o')

                    if ($state.AutopilotDevices.ContainsKey($targetSn)) {
                        $existingDev = $state.AutopilotDevices[$targetSn]
                        $devGuid = $existingDev.id
                        $gt = $existingDev.groupTag
                        $status = $existingDev.deploymentProfileAssignmentStatus
                        $detailedStatus = $existingDev.deploymentProfileAssignmentDetailedStatus
                        $assignedDate = $existingDev.deploymentProfileAssignedDateTime
                        if ($existingDev.assignedDeploymentProfile) {
                            $profName = $existingDev.assignedDeploymentProfile.displayName
                        }
                    }

                    $devJson = '{"id":"' + $devGuid + '","serialNumber":"' + $targetSn + '","groupTag":"' + $gt + '","deploymentProfileAssignmentStatus":"' + $status + '","deploymentProfileAssignmentDetailedStatus":"' + $detailedStatus + '","deploymentProfileAssignedDateTime":"' + $assignedDate + '","assignedDeploymentProfile":{"displayName":"' + $profName + '"}}'
                    $listJson = '{"value":[' + $devJson + ']}'
                    $resBytes = [System.Text.Encoding]::UTF8.GetBytes($listJson)
                    $resp.ContentType = 'application/json'
                    $resp.ContentLength64 = $resBytes.Length
                    $resp.StatusCode = 200
                    $resp.OutputStream.Write($resBytes, 0, $resBytes.Length)
                    $resp.OutputStream.Close()
                    continue
                }

                # -------------------------------------------------------------
                # Route 9: Mobile App Entity Creation (POST /beta/deviceAppManagement/mobileApps)
                # -------------------------------------------------------------
                if ($httpMethod -eq 'POST' -and $path -match '/mobileApps$') {
                    $reader = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                    $bodyText = $reader.ReadToEnd()
                    $reader.Close()

                    $appId = [Guid]::NewGuid().ToString()
                    $dispName = 'Mock Win32 App'
                    if ($bodyText -match '"displayName"\s*:\s*"([^"]+)"') { $dispName = $matches[1] }

                    $appObj = @{
                        id          = $appId
                        displayName = $dispName
                    }
                    $state.MobileApps[$appId] = $appObj

                    $resJson = '{"@odata.type":"#microsoft.graph.win32LobApp","id":"' + $appId + '","displayName":"' + $dispName + '"}'
                    $resBytes = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                    $resp.ContentType = 'application/json'
                    $resp.ContentLength64 = $resBytes.Length
                    $resp.StatusCode = 201
                    $resp.OutputStream.Write($resBytes, 0, $resBytes.Length)
                    $resp.OutputStream.Close()
                    continue
                }

                # -------------------------------------------------------------
                # Route 10: Mobile App Patch / Get (PATCH/GET /beta/deviceAppManagement/mobileApps/{id})
                # -------------------------------------------------------------
                if ($path -match '/mobileApps/([a-zA-Z0-9\-_]+)$') {
                    $appId = $matches[1]
                    $dispName = 'Mock Win32 App'
                    if ($state.MobileApps.ContainsKey($appId)) {
                        $dispName = $state.MobileApps[$appId].displayName
                    }

                    $resJson = '{"@odata.type":"#microsoft.graph.win32LobApp","id":"' + $appId + '","displayName":"' + $dispName + '"}'
                    $resBytes = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                    $resp.ContentType = 'application/json'
                    $resp.ContentLength64 = $resBytes.Length
                    $resp.StatusCode = 200
                    $resp.OutputStream.Write($resBytes, 0, $resBytes.Length)
                    $resp.OutputStream.Close()
                    continue
                }

                # -------------------------------------------------------------
                # Route 11: Content Version Creation (POST /beta/deviceAppManagement/mobileApps/{id}/contentVersions)
                # -------------------------------------------------------------
                if ($httpMethod -eq 'POST' -and $path -match '/mobileApps/([a-zA-Z0-9\-_]+)/contentVersions$') {
                    $appId = $matches[1]
                    $verId = '1'
                    $resJson = '{"id":"' + $verId + '"}'
                    $resBytes = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                    $resp.ContentType = 'application/json'
                    $resp.ContentLength64 = $resBytes.Length
                    $resp.StatusCode = 201
                    $resp.OutputStream.Write($resBytes, 0, $resBytes.Length)
                    $resp.OutputStream.Close()
                    continue
                }

                # -------------------------------------------------------------
                # Route 12: Content File Registration (POST .../contentVersions/{verId}/files)
                # -------------------------------------------------------------
                if ($httpMethod -eq 'POST' -and $path -match '/contentVersions/([a-zA-Z0-9\-_]+)/files$') {
                    $reader = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                    $bodyText = $reader.ReadToEnd()
                    $reader.Close()

                    $fileId = [Guid]::NewGuid().ToString()
                    $fileName = 'package.intunewin'
                    if ($bodyText -match '"name"\s*:\s*"([^"]+)"') { $fileName = $matches[1] }

                    $sasUri = "http://127.0.0.1:$($state.Port)/blob/$fileId?sv=2020-08-04&sig=mockSasToken"
                    $fileObj = @{
                        id              = $fileId
                        name            = $fileName
                        azureStorageUri = $sasUri
                        uploadState     = $state.DefaultFileUploadState
                        isCommitted     = $true
                    }
                    $state.ContentFiles[$fileId] = $fileObj

                    $resJson = '{"@odata.type":"#microsoft.graph.mobileAppContentFile","id":"' + $fileId + '","name":"' + $fileName + '","size":1048576,"sizeEncrypted":1048576,"azureStorageUri":"' + $sasUri + '","uploadState":"' + $state.DefaultFileUploadState + '","isCommitted":true}'
                    $resBytes = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                    $resp.ContentType = 'application/json'
                    $resp.ContentLength64 = $resBytes.Length
                    $resp.StatusCode = 201
                    $resp.OutputStream.Write($resBytes, 0, $resBytes.Length)
                    $resp.OutputStream.Close()
                    continue
                }

                # -------------------------------------------------------------
                # Route 13: Content File Status Poll (GET .../contentVersions/{verId}/files/{fileId})
                # -------------------------------------------------------------
                if ($httpMethod -eq 'GET' -and $path -match '/contentVersions/([a-zA-Z0-9\-_]+)/files/([a-zA-Z0-9\-_]+)$') {
                    $verId = $matches[1]
                    $fileId = $matches[2]
                    $sasUri = "http://127.0.0.1:$($state.Port)/blob/$fileId?sv=2020-08-04&sig=mockSasToken"
                    $status = $state.DefaultFileUploadState

                    $resJson = '{"@odata.type":"#microsoft.graph.mobileAppContentFile","id":"' + $fileId + '","azureStorageUri":"' + $sasUri + '","uploadState":"' + $status + '","isCommitted":true,"sizeEncrypted":1048576}'
                    $resBytes = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                    $resp.ContentType = 'application/json'
                    $resp.ContentLength64 = $resBytes.Length
                    $resp.StatusCode = 200
                    $resp.OutputStream.Write($resBytes, 0, $resBytes.Length)
                    $resp.OutputStream.Close()
                    continue
                }

                # -------------------------------------------------------------
                # Route 14: Content File Commit (POST .../files/{fileId}/commit)
                # -------------------------------------------------------------
                if ($httpMethod -eq 'POST' -and $path -match '/files/([a-zA-Z0-9\-_]+)/commit$') {
                    $state.CommitCallCount++
                    $resJson = '{}'
                    $resBytes = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                    $resp.ContentType = 'application/json'
                    $resp.ContentLength64 = $resBytes.Length
                    $resp.StatusCode = 200
                    $resp.OutputStream.Write($resBytes, 0, $resBytes.Length)
                    $resp.OutputStream.Close()
                    continue
                }

                # -------------------------------------------------------------
                # Route 15: OAuth2 Token Endpoint
                # -------------------------------------------------------------
                if ($httpMethod -eq 'POST' -and $path -match '/oauth2/v2.0/token$') {
                    $tokenJson = '{"access_token":"mock_graph_jwt_token_ci_sandbox","token_type":"Bearer","expires_in":3600,"refresh_token":"mock_graph_refresh_token_ci_sandbox"}'
                    $tokenBytes = [System.Text.Encoding]::UTF8.GetBytes($tokenJson)
                    $resp.ContentType = 'application/json'
                    $resp.ContentLength64 = $tokenBytes.Length
                    $resp.StatusCode = 200
                    $resp.OutputStream.Write($tokenBytes, 0, $tokenBytes.Length)
                    $resp.OutputStream.Close()
                    continue
                }

                # -------------------------------------------------------------
                # Fallback Route: Generic 200 OK
                # -------------------------------------------------------------
                $defBytes = [System.Text.Encoding]::UTF8.GetBytes('{}')
                $resp.ContentType = 'application/json'
                $resp.ContentLength64 = $defBytes.Length
                $resp.StatusCode = 200
                $resp.OutputStream.Write($defBytes, 0, $defBytes.Length)
                $resp.OutputStream.Close()
            }
            catch { }
        }
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('state', $state)
    $runspace.SessionStateProxy.SetVariable('listener', $listener)
    $worker = [powershell]::Create()
    $worker.Runspace = $runspace
    [void]$worker.AddScript($dispatcher.ToString())
    $workerHandle = $worker.BeginInvoke()

    $baseUri = "http://127.0.0.1:$actualPort"
    $baseSasUri = "http://127.0.0.1:$actualPort/blob/mockpackage.intunewin?sv=2020-08-04&sig=mock"

    if ($SetGlobalEnv) {
        $env:GRAPH_BASE_URI = $baseUri
        $env:M365_TEST_TENANT_ID = $TenantId
    }

    $serverObj = [PSCustomObject]@{
        Port        = $actualPort
        BaseUri     = $baseUri
        BaseSasUri  = $baseSasUri
        Listener    = $listener
        Worker      = $worker
        WorkerHandle = $workerHandle
        Runspace    = $runspace
        State       = $state
    }
    # ScriptMethod (not a scriptblock property) so $this is bound when callers invoke $server.Stop()
    $serverObj | Add-Member -MemberType ScriptMethod -Name Stop -Value { Stop-MockGraphServer -Server $this } -Force

    $script:CurrentMockServer = $serverObj
    return $serverObj
}

function Stop-MockGraphServer {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [object]$Server = $null
    )

    $target = if ($Server) { $Server } else { $script:CurrentMockServer }
    if (-not $target) { return }

    try {
        if ($target.State) {
            $target.State.IsRunning = $false
        }
        if ($target.Listener) {
            try { $target.Listener.Stop() } catch { }
            try { $target.Listener.Close() } catch { }
        }
        if ($target.Worker) {
            try {
                if ($target.WorkerHandle -and -not $target.WorkerHandle.AsyncWaitHandle.WaitOne(2000)) {
                    $target.Worker.Stop()
                }
            } catch { }
            try { $target.Worker.Dispose() } catch { }
        }
        if ($target.Runspace) {
            try { $target.Runspace.Dispose() } catch { }
        }
    }
    catch { }

    if ($env:GRAPH_BASE_URI -eq $target.BaseUri) {
        Remove-Item -Path 'env:GRAPH_BASE_URI' -ErrorAction SilentlyContinue
    }

    if ($script:CurrentMockServer -eq $target) {
        $script:CurrentMockServer = $null
    }
}

function Get-MockGraphServerState {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [object]$Server = $null
    )

    $target = if ($Server) { $Server } else { $script:CurrentMockServer }
    if ($target -and $target.State) {
        return $target.State
    }
    return $null
}

function Reset-MockGraphServer {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [object]$Server = $null
    )

    $target = if ($Server) { $Server } else { $script:CurrentMockServer }
    if (-not $target -or -not $target.State) { return }

    $target.State.ReceivedBlockBytes = 0L
    $target.State.SyncCallCount = 0
    $target.State.CommitCallCount = 0
    $target.State.ForceForbidden = $false
    $target.State.DefaultImportStatus = 'complete'
    $target.State.DefaultImportErrorCode = 0
    $target.State.DefaultImportErrorName = 'none'
    $target.State.DefaultProfileAssignmentStatus = 'assigned'
    $target.State.DefaultProfileAssignmentDetailedStatus = 'none'
    $target.State.DefaultProfileDisplayName = 'Standard Autopilot Profile'
    $target.State.DefaultFileUploadState = 'succeeded'

    $target.State.ReceivedBlocks.Clear()
    $target.State.CommittedBlocks.Clear()
    $target.State.ExistingBlocks.Clear()
    $target.State.ImportedDevices.Clear()
    $target.State.AutopilotDevices.Clear()
    $target.State.MobileApps.Clear()
    $target.State.ContentFiles.Clear()
    $target.State.RequestLog.Clear()
}

function Set-MockGraphServerTenant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$TenantId = '11111111-2222-3333-4444-555555555555',

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$TenantName = 'Contoso Dev Sandbox',

        [Parameter()]
        [object]$Server = $null
    )

    $target = if ($Server) { $Server } else { $script:CurrentMockServer }
    if ($target -and $target.State) {
        $target.State.TenantId = $TenantId
        $target.State.TenantName = $TenantName
    }
}

function Set-MockGraphServerAutopilotState {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ImportStatus = 'complete',

        [Parameter()]
        [int]$ImportErrorCode = 0,

        [Parameter()]
        [string]$ImportErrorName = 'none',

        [Parameter()]
        [string]$ProfileAssignmentStatus = 'assigned',

        [Parameter()]
        [string]$ProfileAssignmentDetailedStatus = 'none',

        [Parameter()]
        [string]$ProfileDisplayName = 'Standard Autopilot Profile',

        [Parameter()]
        [object]$Server = $null
    )

    $target = if ($Server) { $Server } else { $script:CurrentMockServer }
    if ($target -and $target.State) {
        $target.State.DefaultImportStatus = $ImportStatus
        $target.State.DefaultImportErrorCode = $ImportErrorCode
        $target.State.DefaultImportErrorName = $ImportErrorName
        $target.State.DefaultProfileAssignmentStatus = $ProfileAssignmentStatus
        $target.State.DefaultProfileAssignmentDetailedStatus = $ProfileAssignmentDetailedStatus
        $target.State.DefaultProfileDisplayName = $ProfileDisplayName
    }
}

Export-ModuleMember -Function @(
    'Start-MockGraphServer',
    'Stop-MockGraphServer',
    'Get-MockGraphServerState',
    'Reset-MockGraphServer',
    'Set-MockGraphServerTenant',
    'Set-MockGraphServerAutopilotState'
)
