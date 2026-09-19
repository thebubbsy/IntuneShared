<#
.SYNOPSIS
    Comprehensive End-to-End Integration Test Suite for IntuneShared, WingetIntune, and AutopilotFast.
.DESCRIPTION
    Validates tenant safety guardrails, offline Mock Graph Server operations, Autopilot device ingestion
    and profile assignment two-stage lifecycles, Win32 app packaging with session 0 registry redirection,
    Azure Block Blob transactional uploads with resume and SHA256 integrity detection, and OAuth2 token engine
    multi-tenant partitioned cache isolation and refresh.
#>

# This suite spans all three sibling repos (IntuneShared, WingetIntune, AutopilotFast) checked out side by side.
# Pester evaluates top-level code at discovery only, so the sibling check is done twice: here (feeds -Skip so the
# file is skipped, not failed, in per-repo CI) and again inside BeforeAll for the Run phase.
function Test-IntegrationSiblingsPresent {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    (Test-Path (Join-Path $root 'WingetIntune\WingetIntune.psd1')) -and (Test-Path (Join-Path $root 'AutopilotFast\AutopilotFast.psd1'))
}
$script:skipIntegration = -not (Test-IntegrationSiblingsPresent)

BeforeAll {
    $script:repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:skipIntegration = -not ((Test-Path (Join-Path $script:repoRoot 'WingetIntune\WingetIntune.psd1')) -and
                                    (Test-Path (Join-Path $script:repoRoot 'AutopilotFast\AutopilotFast.psd1')))
    if ($script:skipIntegration) { return }

    $sharedPath = Join-Path $script:repoRoot 'IntuneShared\IntuneShared.psd1'
    $wingetPath = Join-Path $script:repoRoot 'WingetIntune\WingetIntune.psd1'
    $autoPath = Join-Path $script:repoRoot 'AutopilotFast\AutopilotFast.psd1'
    $autoMockPath = Join-Path $script:repoRoot 'AutopilotFast\tests\AutopilotFast.Mock.psm1'
    $mockServerPath = Join-Path $PSScriptRoot 'MockGraphServer.psm1'

    Import-Module $sharedPath -Force -ErrorAction Stop
    Import-Module $wingetPath -Force -ErrorAction Stop
    Import-Module $autoPath -Force -ErrorAction Stop
    Import-Module $autoMockPath -Force -ErrorAction Stop
    Import-Module $mockServerPath -Force -ErrorAction Stop

    # Private helpers under test are not exported; expose thin proxies that invoke them inside the module scope.
    foreach ($privateFn in @('Send-AzureBlockBlob', 'New-StandaloneInstallShim')) {
        $body = [scriptblock]::Create("& (Get-Module WingetIntune) { $privateFn @args } @args")
        Set-Item -Path "function:script:$privateFn" -Value $body
    }

    # Start Offline Mock Graph & Azure Blob Server
    $global:MockServer = Start-MockGraphServer -Port 0 -TenantId '11111111-2222-3333-4444-555555555555' -TenantName 'Contoso Dev Sandbox' -SetGlobalEnv
}

AfterAll {
    if ($script:skipIntegration) { return }
    if ($global:MockServer) {
        Stop-MockGraphServer -Server $global:MockServer
    }
    Remove-Item -Path 'env:GRAPH_BASE_URI' -ErrorAction SilentlyContinue
    Remove-Item -Path 'env:M365_TEST_TENANT_ID' -ErrorAction SilentlyContinue
    Remove-Item -Path 'env:AUTOPILOT_MOCK_HARDWARE_HASH' -ErrorAction SilentlyContinue
    if (Get-Command Clear-AutopilotMockHardwareHash -ErrorAction SilentlyContinue) { Clear-AutopilotMockHardwareHash }
}

Describe 'Integration Test Suite: Microsoft Intune Management Suite' -Skip:$script:skipIntegration {

    # =========================================================================
    # Context 1: Tenant Safety Guardrails
    # =========================================================================
    Context 'Context 1: Tenant Safety Guardrails' {
        BeforeEach {
            $script:savedTenantEnv = $env:M365_TEST_TENANT_ID
            $env:M365_TEST_TENANT_ID = '11111111-2222-3333-4444-555555555555'
        }
        AfterEach {
            $env:M365_TEST_TENANT_ID = $script:savedTenantEnv
        }

        It 'Passes cleanly for authorized non-production test tenants (Contoso Dev Sandbox, Alpha Lab Tenant, Engineering Test Tenant)' {
            $validTenants = @(
                'Contoso Dev Sandbox',
                'Alpha Lab Tenant',
                'Engineering Test Tenant',
                'Dev-Tenant-01',
                'PreProd-Test-Lab',
                'QA-Sandbox-Environment'
            )

            foreach ($tName in $validTenants) {
                {
                    Assert-TestTenantSafety -TenantId '11111111-2222-3333-4444-555555555555' -TenantName $tName
                } | Should -Not -Throw
            }
        }

        It 'Returns true when PassThru is supplied on authorized test tenant' {
            $res = Assert-TestTenantSafety -TenantId '11111111-2222-3333-4444-555555555555' -TenantName 'Contoso Dev Sandbox' -PassThru
            $res | Should -BeTrue
        }

        It 'Throws [TenantSafetyViolationException] for production tenant names (Contoso Production Global, Main Corporate Production)' {
            $productionTenants = @(
                'Contoso Production Global',
                'Main Corporate Production',
                'Live Enterprise Root',
                'Finance-Production-Tenant',
                'MSFT Commercial Prod'
            )

            foreach ($pName in $productionTenants) {
                {
                    Assert-TestTenantSafety -TenantId '11111111-2222-3333-4444-555555555555' -TenantName $pName
                } | Should -Throw -ExceptionType ([TenantSafetyViolationException])
            }
        }

        It 'Throws [TenantSafetyViolationException] when M365_TEST_TENANT_ID environment variable is missing' {
            $env:M365_TEST_TENANT_ID = $null
            {
                Assert-TestTenantSafety -TenantId '11111111-2222-3333-4444-555555555555' -TenantName 'Contoso Dev Sandbox'
            } | Should -Throw -ExceptionType ([TenantSafetyViolationException])
        }

        It 'Throws [TenantSafetyViolationException] when TenantId does not match M365_TEST_TENANT_ID' {
            {
                Assert-TestTenantSafety -TenantId '99999999-9999-9999-9999-999999999999' -TenantName 'Contoso Dev Sandbox'
            } | Should -Throw -ExceptionType ([TenantSafetyViolationException])
        }

        It 'Allows bypass only when AllowBypass switch and INTUNE_ALLOW_PRODUCTION_OVERRIDE=true are both present' {
            $origBypass = $env:INTUNE_ALLOW_PRODUCTION_OVERRIDE
            try {
                $env:INTUNE_ALLOW_PRODUCTION_OVERRIDE = 'true'
                {
                    Assert-TestTenantSafety -TenantId '99999999-9999-9999-9999-999999999999' -TenantName 'Contoso Production Global' -AllowBypass
                } | Should -Not -Throw
            }
            finally {
                $env:INTUNE_ALLOW_PRODUCTION_OVERRIDE = $origBypass
            }
        }
    }

    # =========================================================================
    # Context 2: Autopilot Ingestion and Profile Sync
    # =========================================================================
    Context 'Context 2: Autopilot Ingestion and Profile Sync' {
        BeforeEach {
            Reset-MockGraphServer -Server $global:MockServer
            Clear-AutopilotMockHardwareHash
            $env:GRAPH_BASE_URI = $global:MockServer.BaseUri
            $env:M365_TEST_TENANT_ID = '11111111-2222-3333-4444-555555555555'
        }

        It 'Verifies MockGraphServer returns organization tenant metadata matching configured sandbox' {
            $orgRes = Invoke-ResilientGraphRest -Uri 'https://graph.microsoft.com/v1.0/organization'
            $orgRes | Should -Not -BeNullOrEmpty
            $orgRes.value.Count | Should -BeGreaterThan 0
            $orgRes.value[0].id | Should -Be '11111111-2222-3333-4444-555555555555'
            $orgRes.value[0].displayName | Should -Be 'Contoso Dev Sandbox'
        }

        It 'Executes two-stage device registration and profile assignment against MockGraphServer' {
            # Generate genuine synthetic 4K ASN.1 DER hardware hash
            $syntheticHash = New-AutopilotSyntheticHardwareHash -LengthBytes 4096
            Set-AutopilotMockHardwareHash -Hash $syntheticHash

            # Mock network diagnostic to succeed without calling external WAN endpoints
            Mock Test-StagedNetwork {
                return [PSCustomObject]@{
                    IsFullyReady = $true
                    StagesPassed = 7
                    TotalStages  = 7
                    Details      = @()
                }
            } -ModuleName AutopilotFast

            # Mock Start-Sleep in AutopilotFast so test completes immediately
            Mock Start-Sleep { } -ModuleName AutopilotFast

            # Injected mock access token
            & (Get-Module AutopilotFast) { $script:AutopilotAccessToken = 'mock_jwt_autopilot_token' }

            # Execute Register-AutopilotDevice against MockGraphServer
            $result = Register-AutopilotDevice -GroupTag 'ENG-AUTOPILOT' -AssignedUser 'engineer@contoso.com' -WaitForSync -TimeoutMinutes 5

            $result | Should -Not -BeNullOrEmpty
            $result.IsAssigned | Should -BeTrue
            $result.AssignedProfileName | Should -Be 'Standard Autopilot Profile'
            $result.DeploymentProfileAssignmentStatus | Should -Be 'assigned'

            # Verify server state recorded the device and sync trigger
            $serverState = Get-MockGraphServerState -Server $global:MockServer
            $serverState.ImportedDevices.Count | Should -BeGreaterThan 0
            $serverState.SyncCallCount | Should -BeGreaterThan 0
        }

        It 'Executes Sync-AutopilotProfile directly against MockGraphServer and verifies profile assignment' {
            & (Get-Module AutopilotFast) { $script:AutopilotAccessToken = 'mock_jwt_autopilot_token' }
            Mock Start-Sleep { } -ModuleName AutopilotFast

            $syncResult = Sync-AutopilotProfile -SerialNumber 'PF-INTEGRATION-001' -WaitForAssignment -InitialIntervalSeconds 0 -TimeoutMinutes 1

            $syncResult | Should -Not -BeNullOrEmpty
            $syncResult.IsAssigned | Should -BeTrue
            $syncResult.AssignedProfileName | Should -Be 'Standard Autopilot Profile'
            $syncResult.DeploymentProfileAssignmentStatus | Should -Be 'assigned'
            $syncResult.SerialNumber | Should -Be 'PF-INTEGRATION-001'

            $serverState = Get-MockGraphServerState -Server $global:MockServer
            $serverState.SyncCallCount | Should -BeGreaterThan 0
        }

        It 'Handles hardware ingestion error gracefully when MockGraphServer simulates enrollment conflict' {
            Set-MockGraphServerAutopilotState -ImportStatus 'error' -ImportErrorCode 800 -ImportErrorName 'DeviceAlreadyAssignedToOtherTenant' -Server $global:MockServer

            $syntheticHash = New-AutopilotSyntheticHardwareHash -LengthBytes 4096
            Set-AutopilotMockHardwareHash -Hash $syntheticHash

            Mock Test-StagedNetwork {
                return [PSCustomObject]@{
                    IsFullyReady = $true
                    StagesPassed = 7
                    TotalStages  = 7
                    Details      = @()
                }
            } -ModuleName AutopilotFast

            Mock Start-Sleep { } -ModuleName AutopilotFast
            & (Get-Module AutopilotFast) { $script:AutopilotAccessToken = 'mock_jwt_autopilot_token' }

            $errResult = Register-AutopilotDevice -GroupTag 'CONFLICT-TAG' -WaitForSync -TimeoutMinutes 1

            $errResult | Should -Not -BeNullOrEmpty
            $errResult.state.deviceImportStatus | Should -Be 'error'
            $errResult.state.deviceErrorCode | Should -Be 800
            $errResult.state.deviceErrorName | Should -Be 'DeviceAlreadyAssignedToOtherTenant'
        }
    }

    # =========================================================================
    # Context 3: Win32 App Packaging, Block Blob Upload, and Resume
    # =========================================================================
    Context 'Context 3: Win32 App Packaging, Block Blob Upload, and Resume' {
        BeforeEach {
            Reset-MockGraphServer -Server $global:MockServer
        }

        It 'Generates standalone install shim with Session 0 Win32 RegOverridePredefKey and Task Runner fallback' {
            $shimContent = New-StandaloneInstallShim -PackageId 'Enterprise.DeveloperTools' -Scope 'machine' -CustomArgs '--silent --allusers'

            $shimContent | Should -Not -BeNullOrEmpty
            $shimContent | Should -Match 'RegOverridePredefKey'
            $shimContent | Should -Match 'AdvApi32'
            $shimContent | Should -Match 'HKU\\DefaultUser'
            $shimContent | Should -Match 'Get-RegSnapshot'
            $shimContent | Should -Match 'WingetIntune_TaskRunner_Enterprise\.DeveloperTools'
            $shimContent | Should -Match 'reg\.exe unload "HKU\\DefaultUser"'
            $shimContent | Should -Match 'Global\\_MSIExecute'
        }

        It 'Uploads multi-block binary to MockGraphServer Azure Block Blob endpoint' {
            $tempFile = Join-Path $TestDrive "MultiBlockUploadTest_$([Guid]::NewGuid().ToString('N')).bin"
            
            try {
                # Create an 8MB file (2 x 4MB blocks)
                $fs = [System.IO.File]::Create($tempFile)
                $fs.SetLength(8 * 1024 * 1024)
                $fs.Close()

                $uploadSasUri = "$($global:MockServer.BaseUri)/blob/testapp.intunewin?sv=2020-08-04&sig=mock"

                $res = Send-AzureBlockBlob -FilePath $tempFile `
                                           -SasUri $uploadSasUri `
                                           -PackageId 'MockIntegrationApp' `
                                           -BlockSizeMb 4

                $res | Should -BeTrue

                # Verify server state
                $serverState = Get-MockGraphServerState -Server $global:MockServer
                $serverState.ReceivedBlocks.Count | Should -Be 2
                $serverState.CommittedBlocks.Count | Should -Be 2

                # Verify session persistence
                $sessionFile = "C:\ProgramData\WingetIntune\UploadSessions\MockIntegrationApp.json"
                Test-Path $sessionFile | Should -BeTrue
                $sessionObj = Get-Content $sessionFile -Raw | ConvertFrom-Json
                $sessionObj.PackageId | Should -Be 'MockIntegrationApp'
                $sessionObj.State | Should -Be 'Succeeded'
                $sessionObj.TotalBlocks | Should -Be 2
            }
            finally {
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\ProgramData\WingetIntune\UploadSessions\MockIntegrationApp.json" -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Reconciles server-side blocklist and resumes interrupted upload transmitting only remaining blocks' {
            $tempFile = Join-Path $TestDrive "ResumeInterruptedTest_$([Guid]::NewGuid().ToString('N')).bin"

            try {
                # Create a 5MB file (5 x 1MB blocks)
                $fs = [System.IO.File]::Create($tempFile)
                $fs.SetLength(5 * 1024 * 1024)
                $fs.Close()

                # Pre-populate MockGraphServer with first 2 blocks already committed
                $serverState = Get-MockGraphServerState -Server $global:MockServer
                for ($b = 0; $b -lt 2; $b++) {
                    $rawId = "block_{0:D6}" -f $b
                    $base64Id = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($rawId))
                    $serverState.ExistingBlocks.Add($base64Id)
                }

                $uploadSasUri = "$($global:MockServer.BaseUri)/blob/resumable.intunewin?sv=2020-08-04&sig=mock"

                # Resume upload with BlockSizeMb = 1
                $res = Send-AzureBlockBlob -FilePath $tempFile `
                                           -SasUri $uploadSasUri `
                                           -PackageId 'MockResumeApp' `
                                           -BlockSizeMb 1 `
                                           -Resume

                $res | Should -BeTrue

                # Assert that only 3 remaining blocks (blocks 2, 3, 4) were transmitted over HTTP
                $serverState.ReceivedBlocks.Count | Should -Be 3

                # Assert all 5 blocks were committed in the final block list
                $serverState.CommittedBlocks.Count | Should -Be 5
            }
            finally {
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\ProgramData\WingetIntune\UploadSessions\MockResumeApp.json" -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Detects SHA256 mutation before resume, aborts stale session, and executes fresh upload transaction' {
            $tempFile = Join-Path $TestDrive "MutationDigestTest_$([Guid]::NewGuid().ToString('N')).bin"

            try {
                # Create initial file with known content
                $initialBytes = [byte[]]((1..4096) | ForEach-Object { $_ -band 0xFF })
                [System.IO.File]::WriteAllBytes($tempFile, $initialBytes)
                $origHash = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash

                # Seed pre-existing stale session
                $sessionDir = "C:\ProgramData\WingetIntune\UploadSessions"
                if (-not (Test-Path $sessionDir)) { New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null }
                $sessionFile = Join-Path $sessionDir "MockMutationApp.json"
                $staleSession = @{
                    UploadId       = "StaleSession999"
                    PackageId      = "MockMutationApp"
                    FileDigest     = $origHash
                    SourceFilePath = $tempFile
                    State          = "UploadingBlocks"
                    LastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                }
                $staleSession | ConvertTo-Json | Out-File -FilePath $sessionFile -Force -Encoding utf8

                # Mutate local file
                $initialBytes[0] = [byte]($initialBytes[0] -bxor 0xAA)
                [System.IO.File]::WriteAllBytes($tempFile, $initialBytes)
                $mutatedHash = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash
                $mutatedHash | Should -Not -Be $origHash

                $uploadSasUri = "$($global:MockServer.BaseUri)/blob/mutated.intunewin?sv=2020-08-04&sig=mock"

                $uploadRes = Send-AzureBlockBlob -FilePath $tempFile `
                                                 -SasUri $uploadSasUri `
                                                 -PackageId 'MockMutationApp' `
                                                 -BlockSizeMb 1 `
                                                 -Resume

                $uploadRes | Should -BeTrue

                # Verify session updated with mutated hash and Succeeded state
                $updatedSession = Get-Content $sessionFile -Raw | ConvertFrom-Json
                $updatedSession.FileDigest | Should -Be $mutatedHash
                $updatedSession.State | Should -Be 'Succeeded'
            }
            finally {
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\ProgramData\WingetIntune\UploadSessions\MockMutationApp.json" -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # =========================================================================
    # Context 4: Token Engine Multi-Tenant Isolation & Cache Refresh
    # =========================================================================
    Context 'Context 4: Token Engine Multi-Tenant Isolation & Cache Refresh' {
        BeforeEach {
            # Reset In-Memory Token Cache in IntuneShared module
            & (Get-Module IntuneShared) {
                if ($script:GraphTokenCache) { $script:GraphTokenCache.Clear() }
                $script:GraphAuthContext = $null
            }
        }

        It 'Isolates cached tokens by partitioned TenantId, ClientId, and Scope keys' {
            Mock -ModuleName IntuneShared -CommandName Invoke-RestMethod -MockWith {
                $tenant = if ($Body.client_id -eq 'client-alpha') { 'tenant-alpha' } else { 'tenant-beta' }
                return [PSCustomObject]@{
                    access_token = "token-for-$tenant"
                    token_type   = 'Bearer'
                    expires_in   = 3600
                }
            }

            $tokenAlpha = Connect-GraphToken -ClientSecret 'secretA' -TenantId 'tenant-alpha' -ClientId 'client-alpha'
            $tokenBeta = Connect-GraphToken -ClientSecret 'secretB' -TenantId 'tenant-beta' -ClientId 'client-beta'

            $tokenAlpha | Should -Be 'token-for-tenant-alpha'
            $tokenBeta | Should -Be 'token-for-tenant-beta'
            $tokenAlpha | Should -Not -Be $tokenBeta

            # Verify partitioned cache entries
            & (Get-Module IntuneShared) {
                $script:GraphTokenCache.ContainsKey('tenant-alpha:client-alpha:https://graph.microsoft.com/.default') | Should -BeTrue
                $script:GraphTokenCache.ContainsKey('tenant-beta:client-beta:https://graph.microsoft.com/.default') | Should -BeTrue
            }
        }

        It 'Refreshes expired access tokens via refresh_token grant and updates cache context' {
            $script:refreshExecuted = $false
            $cacheKey = 'tenant-refresh:client-refresh:https://graph.microsoft.com/.default'

            # Seed an expired cache entry with a RefreshToken
            & (Get-Module IntuneShared) {
                if (-not $script:GraphTokenCache) {
                    $script:GraphTokenCache = [System.Collections.Generic.Dictionary[string, object]]::new()
                }
                $script:GraphTokenCache[$args[0]] = [PSCustomObject]@{
                    AccessToken    = 'expired-token-val'
                    RefreshToken   = 'valid-refresh-token-xyz'
                    TokenType      = 'Bearer'
                    ExpiresOn      = [DateTime]::UtcNow.AddMinutes(-10)
                    TenantId       = 'tenant-refresh'
                    ClientId       = 'client-refresh'
                    PermissionType = 'Delegated'
                    Scopes         = @('https://graph.microsoft.com/.default')
                }
            } $cacheKey

            Mock -ModuleName IntuneShared -CommandName Invoke-RestMethod -MockWith {
                if ($Body.grant_type -eq 'refresh_token') {
                    $script:refreshExecuted = $true
                    return [PSCustomObject]@{
                        access_token  = 'new-refreshed-jwt-token'
                        refresh_token = 'updated-refresh-token-123'
                        token_type    = 'Bearer'
                        expires_in    = 3600
                    }
                }
                throw "Unexpected authentication route."
            }

            $refreshedToken = Connect-GraphToken -DeviceCode -TenantId 'tenant-refresh' -ClientId 'client-refresh'

            $refreshedToken | Should -Be 'new-refreshed-jwt-token'
            $script:refreshExecuted | Should -BeTrue

            # Verify cache context updated
            & (Get-Module IntuneShared) {
                $script:GraphAuthContext.AccessToken | Should -Be 'new-refreshed-jwt-token'
                $script:GraphAuthContext.RefreshToken | Should -Be 'updated-refresh-token-123'
            }
        }

        It 'Bypasses cached token when ForceRefresh switch is specified' {
            $script:counter = 0
            Mock -ModuleName IntuneShared -CommandName Invoke-RestMethod -MockWith {
                $script:counter++
                return [PSCustomObject]@{
                    access_token = "token-pass-$($script:counter)"
                    token_type   = 'Bearer'
                    expires_in   = 3600
                }
            }

            $t1 = Connect-GraphToken -ClientSecret 'sec' -TenantId 'tenant-cache' -ClientId 'client-cache'
            $t2 = Connect-GraphToken -ClientSecret 'sec' -TenantId 'tenant-cache' -ClientId 'client-cache' -ForceRefresh

            $t1 | Should -Be 'token-pass-1'
            $t2 | Should -Be 'token-pass-2'
            $script:counter | Should -Be 2
        }
    }
}
