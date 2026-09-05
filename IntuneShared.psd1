@{
    RootModule = 'IntuneShared.psm1'
    ModuleVersion = '1.0.0'
    GUID = '3a1d7f4c-9b5e-402a-8c3d-1e5f7a9b2c40'
    Author = 'Matthew Bubb'
    CompanyName = 'OnYaChamp.com'
    Copyright = '(c) 2026 Matthew Bubb. All rights reserved.'
    Description = 'High-performance shared transport, resilient Graph REST client, and token provider kernel for modern PowerShell 7+ endpoint management.'
    PowerShellVersion = '7.2'
    RequiredModules = @()
    FunctionsToExport = @(
        'Invoke-ResilientGraphRest',
        'Connect-GraphToken',
        'Test-StagedNetwork',
        'Out-AsciiQrCode',
        'New-BuildManifest'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('intune', 'graph-api', 'transport', 'rest-client', 'msal', 'network-diagnostics', 'endpoint-management', 'powershell7')
            LicenseUri = 'https://github.com/thebubbsy/IntuneShared/blob/main/LICENSE'
            ProjectUri = 'https://github.com/thebubbsy/IntuneShared'
            ReleaseNotes = @'
v1.0.0 - Initial Release
- Resilient Graph REST client with jittered exponential backoff and HTTP 429 Retry-After handling.
- Multi-provider MSAL token engine supporting Device Code Flow, Client Secret, and Certificate auth.
- 7-Stage network diagnostic ladder (Interface, Gateway, DNS, Port, TLS, Portal, Cloud).
- Decoupled terminal ASCII QR visualizer.
- Component integrity digest and SHA256 build manifest generator.
'@
        }
    }
}
