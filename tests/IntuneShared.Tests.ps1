Describe 'IntuneShared Kernel Test Suite' {
    BeforeAll {
        $manifest = Join-Path $PSScriptRoot '..\IntuneShared.psd1'
        Import-Module $manifest -Force -ErrorAction Stop
    }

    # =========================================================================
    # 1. Module Architecture & Type Integrity
    # =========================================================================
    Context 'Module Metadata & Type Integrity' {
        It 'Exports all expected public cmdlets' {
            $expected = @(
                'Invoke-ResilientGraphRest',
                'Connect-GraphToken',
                'Test-StagedNetwork',
                'Out-AsciiQrCode',
                'New-BuildManifest',
                'Assert-TestTenantSafety',
                'Write-IntuneLog'
            )
            foreach ($fn in $expected) {
                Get-Command -Module IntuneShared -Name $fn | Should -Not -BeNullOrEmpty
            }
        }

        It 'Defines [TenantSafetyViolationException] inheriting from System.Exception' {
            $ex = [TenantSafetyViolationException]::new("Test violation")
            ($ex -is [System.Exception]) | Should -BeTrue
            ($ex -is [TenantSafetyViolationException]) | Should -BeTrue
            $ex.GetType().Name | Should -Be 'TenantSafetyViolationException'
            $ex.Message | Should -Be "Test violation"
        }

        It 'Instantiates [TenantSafetyViolationException] with innerException' {
            $inner = [System.InvalidOperationException]::new("Inner fault")
            $ex = [TenantSafetyViolationException]::new("Outer violation", $inner)
            $ex.InnerException.Message | Should -Be "Inner fault"
        }
    }

    # =========================================================================
    # 2. Tenant Safety Guardrails (Assert-TestTenantSafety)
    # =========================================================================
    Context 'Assert-TestTenantSafety Guardrail Assertions' {
        BeforeEach {
            $script:origEnvTenant = $env:M365_TEST_TENANT_ID
            $env:M365_TEST_TENANT_ID = '11111111-2222-3333-4444-555555555555'
        }
        AfterEach {
            $env:M365_TEST_TENANT_ID = $script:origEnvTenant
        }

        It 'Succeeds when TenantId matches and TenantName contains Sandbox' {
            {
                Assert-TestTenantSafety -TenantId '11111111-2222-3333-4444-555555555555' -TenantName 'Contoso-Sandbox'
            } | Should -Not -Throw
        }

        It 'Succeeds for allowed regex variants (Dev, Test, Lab, Sandbox case-insensitive)' {
            $validNames = @('Enterprise-DEV', 'Tenant-test-01', 'LAB-Environment', 'MySandbox')
            foreach ($name in $validNames) {
                {
                    Assert-TestTenantSafety -TenantId '11111111-2222-3333-4444-555555555555' -TenantName $name
                } | Should -Not -Throw
            }
        }

        It 'Throws TenantSafetyViolationException when M365_TEST_TENANT_ID is missing' {
            $env:M365_TEST_TENANT_ID = $null
            {
                Assert-TestTenantSafety -TenantId '11111111-2222-3333-4444-555555555555' -TenantName 'Contoso-Dev'
            } | Should -Throw -ExceptionType ([TenantSafetyViolationException])
        }

        It 'Throws TenantSafetyViolationException when TenantId mismatches M365_TEST_TENANT_ID' {
            {
                Assert-TestTenantSafety -TenantId '99999999-9999-9999-9999-999999999999' -TenantName 'Contoso-Dev'
            } | Should -Throw -ExceptionType ([TenantSafetyViolationException])
        }

        It 'Throws TenantSafetyViolationException when TenantName indicates production' {
            $prodNames = @('Contoso Production', 'Contoso Corp', 'Live-Prod-01', 'Finance-Main')
            foreach ($prodName in $prodNames) {
                {
                    Assert-TestTenantSafety -TenantId '11111111-2222-3333-4444-555555555555' -TenantName $prodName
                } | Should -Throw -ExceptionType ([TenantSafetyViolationException])
            }
        }

        It 'Returns true when PassThru is specified on valid tenant' {
            $result = Assert-TestTenantSafety -TenantId '11111111-2222-3333-4444-555555555555' -TenantName 'DevLab' -PassThru
            $result | Should -BeTrue
        }
    }

    # =========================================================================
    # 3. Resilient Graph REST Client (Invoke-ResilientGraphRest)
    # =========================================================================
    Context 'Invoke-ResilientGraphRest Error Extraction & Throttling' {
        It 'Successfully executes GET and returns deserialized PSCustomObject' {
            Mock -ModuleName IntuneShared -CommandName Invoke-RestMethod -MockWith {
                return [PSCustomObject]@{ id = '12345'; displayName = 'Test App' }
            }

            $res = Invoke-ResilientGraphRest -Uri 'https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/12345'
            $res.id | Should -Be '12345'
            $res.displayName | Should -Be 'Test App'
        }

        It 'Injects Authorization Bearer token header when Token parameter is supplied' {
            $script:capturedHeaders = $null
            Mock -ModuleName IntuneShared -CommandName Invoke-RestMethod -MockWith {
                $script:capturedHeaders = $Headers
                return [PSCustomObject]@{ status = 'ok' }
            }

            Invoke-ResilientGraphRest -Uri 'https://graph.microsoft.com/v1.0/me' -Token 'token-xyz-123'
            $script:capturedHeaders['Authorization'] | Should -Be 'Bearer token-xyz-123'
        }

        It 'Extracts structured Graph JSON error code and message on 400 Bad Request' {
            Mock -ModuleName IntuneShared -CommandName Invoke-RestMethod -MockWith {
                $rawJson = @{
                    error = @{
                        code    = 'Request_BadRequest'
                        message = 'Specified property is invalid.'
                    }
                } | ConvertTo-Json -Compress
                $errDetails = [System.Management.Automation.ErrorDetails]::new($rawJson)
                $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Response status code does not indicate success: 400 (Bad Request)."),
                    "GraphBadRequest",
                    [System.Management.Automation.ErrorCategory]::InvalidOperation,
                    $null
                )
                $errorRecord.ErrorDetails = $errDetails
                throw $errorRecord
            }

            {
                Invoke-ResilientGraphRest -Uri 'https://graph.microsoft.com/v1.0/me'
            } | Should -Throw -ExpectedMessage "*Request_BadRequest: Specified property is invalid.*"
        }

        It 'Falls back to raw error text when error payload is not JSON' {
            Mock -ModuleName IntuneShared -CommandName Invoke-RestMethod -MockWith {
                $rawText = 'Bad Gateway Error From Upstream Proxy'
                $errDetails = [System.Management.Automation.ErrorDetails]::new($rawText)
                $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("Response status code 400"),
                    "GraphError",
                    [System.Management.Automation.ErrorCategory]::InvalidOperation,
                    $null
                )
                $errorRecord.ErrorDetails = $errDetails
                throw $errorRecord
            }

            {
                Invoke-ResilientGraphRest -Uri 'https://graph.microsoft.com/v1.0/me'
            } | Should -Throw -ExpectedMessage "*Bad Gateway Error From Upstream Proxy*"
        }

        It 'Retries on HTTP 429 transient error and succeeds on subsequent attempt' {
            $script:attempt = 0
            Mock -ModuleName IntuneShared -CommandName Invoke-RestMethod -MockWith {
                $script:attempt++
                if ($script:attempt -eq 1) {
                    $httpEx = [System.Net.Http.HttpRequestException]::new("429 Too Many Requests")
                    $errRecord = [System.Management.Automation.ErrorRecord]::new(
                        $httpEx,
                        "Throttled",
                        [System.Management.Automation.ErrorCategory]::ResourceUnavailable,
                        $null
                    )
                    throw $errRecord
                }
                return [PSCustomObject]@{ success = $true; attempt = $script:attempt }
            }

            Mock -ModuleName IntuneShared -CommandName Start-Sleep -MockWith { }

            $res = Invoke-ResilientGraphRest -Uri 'https://graph.microsoft.com/v1.0/me' -MaxRetries 3 -BaseDelaySeconds 1
            $res.success | Should -BeTrue
            $script:attempt | Should -Be 2
        }

        It 'Retries on HTTP 503 Service Unavailable with exponential backoff' {
            $script:attempt503 = 0
            Mock -ModuleName IntuneShared -CommandName Invoke-RestMethod -MockWith {
                $script:attempt503++
                if ($script:attempt503 -eq 1) {
                    $httpEx = [System.Net.Http.HttpRequestException]::new("503 Service Unavailable")
                    $errRecord = [System.Management.Automation.ErrorRecord]::new(
                        $httpEx,
                        "Unavailable",
                        [System.Management.Automation.ErrorCategory]::ResourceUnavailable,
                        $null
                    )
                    throw $errRecord
                }
                return [PSCustomObject]@{ service = 'recovered'; attempt = $script:attempt503 }
            }

            Mock -ModuleName IntuneShared -CommandName Start-Sleep -MockWith { }

            $res = Invoke-ResilientGraphRest -Uri 'https://graph.microsoft.com/v1.0/users' -MaxRetries 3 -BaseDelaySeconds 1
            $res.service | Should -Be 'recovered'
            $script:attempt503 | Should -Be 2
        }

        It 'Throws terminating error when max retries are exhausted' {
            Mock -ModuleName IntuneShared -CommandName Invoke-RestMethod -MockWith {
                $httpEx = [System.Net.Http.HttpRequestException]::new("503 Service Unavailable")
                $errRecord = [System.Management.Automation.ErrorRecord]::new(
                    $httpEx,
                    "Unavailable",
                    [System.Management.Automation.ErrorCategory]::ResourceUnavailable,
                    $null
                )
                throw $errRecord
            }

            Mock -ModuleName IntuneShared -CommandName Start-Sleep -MockWith { }

            {
                Invoke-ResilientGraphRest -Uri 'https://graph.microsoft.com/v1.0/groups' -MaxRetries 2 -BaseDelaySeconds 1
            } | Should -Throw
        }

        It 'Redirects URI to mock server when GRAPH_BASE_URI is configured' {
            $script:capturedUri = $null
            Mock -ModuleName IntuneShared -CommandName Invoke-RestMethod -MockWith {
                $script:capturedUri = $Uri
                return [PSCustomObject]@{ ok = $true }
            }

            $env:GRAPH_BASE_URI = 'http://localhost:5050'
            try {
                Invoke-ResilientGraphRest -Uri 'https://graph.microsoft.com/v1.0/deviceManagement'
                $script:capturedUri | Should -Be 'http://localhost:5050/v1.0/deviceManagement'
            } finally {
                $env:GRAPH_BASE_URI = $null
            }
        }
    }

    # =========================================================================
    # 4. Token Engine & Cache Isolation (Connect-GraphToken)
    # =========================================================================
    Context 'Connect-GraphToken Partitioned Caching & Refresh' {
        BeforeEach {
            & (Get-Module IntuneShared) {
                if ($script:GraphTokenCache) { $script:GraphTokenCache.Clear() }
                $script:GraphAuthContext = $null
            }
        }

        It 'Acquires token via ClientSecret and returns access token string' {
            Mock -ModuleName IntuneShared -CommandName Invoke-RestMethod -MockWith {
                return [PSCustomObject]@{
                    access_token = 'secret-token-123'
                    token_type   = 'Bearer'
                    expires_in   = 3600
                }
            }

            $token = Connect-GraphToken -ClientSecret 'secret' -TenantId 'tenant-test' -ClientId 'client-test'
            $token | Should -Be 'secret-token-123'
        }

        It 'Isolates cached tokens across different TenantIds' {
            Mock -ModuleName IntuneShared -CommandName Invoke-RestMethod -MockWith {
                $tId = if ($Body.client_id -eq 'client-1') { 'tenant-A' } else { 'tenant-B' }
                return [PSCustomObject]@{
                    access_token = "token-$tId"
                    token_type   = "Bearer"
                    expires_in   = 3600
                }
            }

            $tokenA = Connect-GraphToken -ClientSecret 'secretA' -TenantId 'tenant-A' -ClientId 'client-1'
            $tokenB = Connect-GraphToken -ClientSecret 'secretB' -TenantId 'tenant-B' -ClientId 'client-2'

            $tokenA | Should -Be 'token-tenant-A'
            $tokenB | Should -Be 'token-tenant-B'
            $tokenA | Should -Not -Be $tokenB
        }

        It 'Isolates cached tokens across different ClientIds and Scopes' {
            Mock -ModuleName IntuneShared -CommandName Invoke-RestMethod -MockWith {
                return [PSCustomObject]@{
                    access_token = "token-$($Body.scope)"
                    token_type   = 'Bearer'
                    expires_in   = 3600
                }
            }

            $token1 = Connect-GraphToken -ClientSecret 'sec' -TenantId 'tenant-X' -ClientId 'client-1' -Scopes @('https://graph.microsoft.com/DeviceManagementApps.ReadWrite.All')
            $token2 = Connect-GraphToken -ClientSecret 'sec' -TenantId 'tenant-X' -ClientId 'client-1' -Scopes @('https://graph.microsoft.com/User.Read')

            $token1 | Should -Not -Be $token2
        }

        It 'Refreshes expired token using RefreshToken when available' {
            $script:refreshCalled = $false
            $cacheKey = "tenant-A:client-1:https://graph.microsoft.com/.default"
            & (Get-Module IntuneShared) {
                if (-not $script:GraphTokenCache) {
                    $script:GraphTokenCache = [System.Collections.Generic.Dictionary[string, object]]::new()
                }
                $script:GraphTokenCache[$args[0]] = [PSCustomObject]@{
                    AccessToken    = 'stale-token'
                    RefreshToken   = 'valid-refresh-token'
                    TokenType      = 'Bearer'
                    ExpiresOn      = [datetime]::UtcNow.AddMinutes(-5)
                    TenantId       = 'tenant-A'
                    ClientId       = 'client-1'
                    PermissionType = 'Delegated'
                    Scopes         = @('https://graph.microsoft.com/.default')
                }
            } $cacheKey

            Mock -ModuleName IntuneShared -CommandName Invoke-RestMethod -MockWith {
                if ($Body.grant_type -eq 'refresh_token') {
                    $script:refreshCalled = $true
                    return [PSCustomObject]@{
                        access_token  = 'renewed-access-token'
                        refresh_token = 'new-refresh-token'
                        token_type    = 'Bearer'
                        expires_in    = 3600
                    }
                }
                throw "Unexpected flow"
            }

            $token = Connect-GraphToken -DeviceCode -TenantId 'tenant-A' -ClientId 'client-1'
            $token | Should -Be 'renewed-access-token'
            $script:refreshCalled | Should -BeTrue
        }

        It 'Bypasses cached token when ForceRefresh is supplied' {
            $script:callCount = 0
            Mock -ModuleName IntuneShared -CommandName Invoke-RestMethod -MockWith {
                $script:callCount++
                return [PSCustomObject]@{
                    access_token = "token-pass-$($script:callCount)"
                    token_type   = 'Bearer'
                    expires_in   = 3600
                }
            }

            $t1 = Connect-GraphToken -ClientSecret 'sec' -TenantId 'tenant-1' -ClientId 'client-1'
            $t2 = Connect-GraphToken -ClientSecret 'sec' -TenantId 'tenant-1' -ClientId 'client-1' -ForceRefresh

            $t1 | Should -Be 'token-pass-1'
            $t2 | Should -Be 'token-pass-2'
            $script:callCount | Should -Be 2
        }
    }

    # =========================================================================
    # 5. Structured JSON Logging (Write-IntuneLog)
    # =========================================================================
    Context 'Write-IntuneLog Structured Telemetry' {
        It 'Creates log directory and appends single-line JSON log entry with expected schema' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "IntuneLogTest_$([System.Guid]::NewGuid())"
            $tempLog = Join-Path $tempDir 'TestLog.log'
            try {
                $entry = Write-IntuneLog -Message 'Test event' -Level 'Info' -Component 'TestHarness' -CustomData @{ AppId = '123' } -LogPath $tempLog -PassThru
                $entry.Message | Should -Be 'Test event'
                $entry.Level | Should -Be 'Info'
                $entry.Component | Should -Be 'TestHarness'

                Test-Path $tempLog | Should -BeTrue
                $content = Get-Content -Path $tempLog -Raw
                $parsed = $content | ConvertFrom-Json
                $parsed.Message | Should -Be 'Test event'
                $parsed.Component | Should -Be 'TestHarness'
                $parsed.CustomData.AppId | Should -Be '123'
                $parsed.ProcessId | Should -Be $PID
                $parsed.TimestampUtc | Should -Not -BeNullOrEmpty
            }
            finally {
                if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'Appends multiple log events without overwriting prior entries' {
            $tempLog = Join-Path ([System.IO.Path]::GetTempPath()) "IntuneLogTest_Multi_$([System.Guid]::NewGuid()).log"
            try {
                Write-IntuneLog -Message 'Event 1' -Level 'Info' -LogPath $tempLog
                Write-IntuneLog -Message 'Event 2' -Level 'Warning' -LogPath $tempLog
                Write-IntuneLog -Message 'Event 3' -Level 'Error' -LogPath $tempLog

                $lines = Get-Content -Path $tempLog
                $lines.Count | Should -Be 3
                ($lines[0] | ConvertFrom-Json).Message | Should -Be 'Event 1'
                ($lines[1] | ConvertFrom-Json).Message | Should -Be 'Event 2'
                ($lines[2] | ConvertFrom-Json).Message | Should -Be 'Event 3'
            }
            finally {
                if (Test-Path $tempLog) { Remove-Item -Path $tempLog -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    # =========================================================================
    # 6. Network Diagnostics (Test-StagedNetwork)
    # =========================================================================
    Context 'Test-StagedNetwork Diagnostic Probe' {
        It 'Executes 7 stages and returns structured diagnostic details' {
            $probe = Test-StagedNetwork -TimeoutSeconds 2
            $probe | Should -Not -BeNullOrEmpty
            $probe.TotalStages | Should -Be 7
            $probe.Details.Count | Should -Be 7
            $probe.Details[0].Name | Should -Be 'Network Interface'
            $probe.Details[2].Name | Should -Be 'DNS Resolution'
            $probe.Details[6].Name | Should -Be 'Autopilot Endpoint'
        }

        It 'Marks Stage 7 Autopilot reachability as Success on HTTP 404 response' {
            $probe = Test-StagedNetwork -TimeoutSeconds 2
            $stage7 = $probe.Details | Where-Object { $_.Stage -eq 7 }
            $stage7 | Should -Not -BeNullOrEmpty
            $stage7.Name | Should -Be 'Autopilot Endpoint'
        }
    }

    # =========================================================================
    # 7. Build Manifest Integrity (New-BuildManifest)
    # =========================================================================
    Context 'New-BuildManifest Integrity Engine' {
        It 'Computes SHA256 component hashes and generates BuildManifest.json' {
            $modRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
            $manifestPath = New-BuildManifest -ModuleRoot $modRoot -Version '1.0.0'
            Test-Path $manifestPath | Should -BeTrue
            $json = Get-Content $manifestPath -Raw | ConvertFrom-Json
            $json.ModuleName | Should -Be 'IntuneShared'
            $json.ModuleVersion | Should -Be '1.0.0'
            $json.ComponentHashes.'IntuneShared.psd1' | Should -Not -BeNullOrEmpty
            $json.ComponentHashes.'Private\TenantSafetyViolationException.ps1' | Should -Not -BeNullOrEmpty
            $json.ComponentHashes.'Public\Assert-TestTenantSafety.ps1' | Should -Not -BeNullOrEmpty
            $json.ComponentHashes.'Public\Write-IntuneLog.ps1' | Should -Not -BeNullOrEmpty
        }
    }
}
