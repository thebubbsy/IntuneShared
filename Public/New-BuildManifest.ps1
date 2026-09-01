<#
.SYNOPSIS
    Generates a build manifest containing file integrity digests and provenance metadata.
.DESCRIPTION
    Computes SHA256 checksums for all module files and creates BuildManifest.json.
#>
function New-BuildManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModuleRoot,

        [Parameter()]
        [string]$Version = '1.0.0'
    )

    $files = Get-ChildItem -Path $ModuleRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1'
    $fileHashes = @{}

    foreach ($f in $files) {
        $relPath = $f.FullName.Substring($ModuleRoot.Length).TrimStart('\', '/')
        $hash = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash
        $fileHashes[$relPath] = $hash
    }

    $gitCommit = 'uncommitted'
    try {
        $gitCommit = (git rev-parse --short HEAD 2>$null)
    } catch { }

    $manifest = [PSCustomObject]@{
        ModuleName        = (Split-Path $ModuleRoot -Leaf)
        ModuleVersion     = $Version
        BuildTimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        GitCommit         = $gitCommit
        ComponentHashes   = $fileHashes
    }

    $manifestPath = Join-Path $ModuleRoot 'BuildManifest.json'
    $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $manifestPath -Force -Encoding utf8
    Write-Host "  [OK] Build manifest generated: $manifestPath" -ForegroundColor Green
    return $manifestPath
}
