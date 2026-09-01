@{
    RootModule = 'IntuneShared.psm1'
    ModuleVersion = '1.0.0'
    GUID = '3a1d7f4c-9b5e-402a-8c3d-1e5f7a9b2c40'
    Author = 'Matthew Bubb'
    CompanyName = 'OnYaChamp.com'
    Copyright = '(c) 2026 Matthew Bubb. All rights reserved.'
    Description = 'Shared transport, resilient Graph REST client, and token provider kernel for modern endpoint management.'
    PowerShellVersion = '5.1'
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
}
