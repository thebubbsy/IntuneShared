# IntuneShared Module Loader
$publicDir = Join-Path $PSScriptRoot 'Public'
$privateDir = Join-Path $PSScriptRoot 'Private'

$Public = @(Get-ChildItem -Path $publicDir -Filter '*.ps1' -ErrorAction SilentlyContinue)
$Private = @(Get-ChildItem -Path $privateDir -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in $Private) {
    . $file.FullName
}

foreach ($file in $Public) {
    . $file.FullName
}

Export-ModuleMember -Function @(
    'Invoke-ResilientGraphRest',
    'Connect-GraphToken',
    'Test-StagedNetwork',
    'Out-AsciiQrCode',
    'New-BuildManifest'
)
