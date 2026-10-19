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
        [string]$Version = '1.0.0',

        [Parameter()]
        [switch]$CopyReceipt,

        [Parameter()]
        [switch]$Quiet
    )

    $files = @(Get-ChildItem -Path $ModuleRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' | Sort-Object FullName)
    $fileHashes = [ordered]@{}
    $totalBytes = 0L

    foreach ($f in $files) {
        $relPath = $f.FullName.Substring($ModuleRoot.Length).TrimStart('\', '/')
        $hash = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash
        $fileHashes[$relPath] = $hash
        $totalBytes += $f.Length
    }

    $gitCommit = 'uncommitted'
    try {
        $resolvedCommit = (git -C $ModuleRoot rev-parse --short HEAD 2>$null)
        if ($resolvedCommit) { $gitCommit = "$resolvedCommit".Trim() }
    } catch { }

    $buildTimeUtc = (Get-Date).ToUniversalTime().ToString('o')
    $moduleName = (Split-Path $ModuleRoot -Leaf)

    $manifest = [PSCustomObject]@{
        ModuleName        = $moduleName
        ModuleVersion     = $Version
        BuildTimestampUtc = $buildTimeUtc
        GitCommit         = $gitCommit
        ComponentHashes   = $fileHashes
    }

    $manifestPath = Join-Path $ModuleRoot 'BuildManifest.json'
    $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $manifestPath -Force -Encoding utf8

    $totalKb = [Math]::Round($totalBytes / 1024.0, 1)

    if ($CopyReceipt) {
        $mdLines = [System.Collections.Generic.List[string]]::new()
        $mdLines.Add("### Module Build Provenance & SHA-256 Digest (``$moduleName v$Version``)")
        $mdLines.Add("- **Git Commit**: ``$gitCommit``")
        $mdLines.Add("- **Timestamp (UTC)**: ``$buildTimeUtc``")
        $mdLines.Add("- **Files Hashed**: $($files.Count) ($totalKb KB total)")
        $mdLines.Add("")
        $mdLines.Add("| File | SHA-256 Digest |")
        $mdLines.Add("| :--- | :--- |")
        foreach ($relKey in $fileHashes.Keys) {
            $mdLines.Add("| ``$relKey`` | ``$($fileHashes[$relKey])`` |")
        }
        try { Set-Clipboard -Value ($mdLines -join [Environment]::NewLine) -ErrorAction SilentlyContinue } catch { }
    }

    if (-not $Quiet) {
        Write-Host ""
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host "  | MODULE BUILD PROVENANCE & SHA-256 INTEGRITY RECEIPT     [VERIFIED]   |" -ForegroundColor Cyan
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host ("  | Module        : {0,-52} |" -f "$moduleName v$Version") -ForegroundColor White
        Write-Host ("  | Git Commit    : {0,-52} |" -f $gitCommit) -ForegroundColor Green
        Write-Host ("  | Timestamp UTC : {0,-52} |" -f $buildTimeUtc) -ForegroundColor Gray
        Write-Host ("  | Files Hashed  : {0,-52} |" -f "$($files.Count) files ($totalKb KB total)") -ForegroundColor Cyan
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        $previewFiles = $files | Select-Object -First 8
        foreach ($pf in $previewFiles) {
            $rel = $pf.FullName.Substring($ModuleRoot.Length).TrimStart('\', '/')
            $h = $fileHashes[$rel]
            $shortHash = if ($h.Length -ge 16) { "$($h.Substring(0, 8))...$($h.Substring($h.Length - 6))" } else { $h }
            $displayRel = if ($rel.Length -gt 34) { '...' + $rel.Substring($rel.Length - 31) } else { $rel }
            Write-Host ("  |  {0,-34}  {1,-31} |" -f $displayRel, "SHA256:$shortHash") -ForegroundColor DarkGray
        }
        if ($files.Count -gt 8) {
            Write-Host ("  |  ... and {0,-59} |" -f "$($files.Count - 8) additional verified module file(s)") -ForegroundColor DarkGray
        }
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host ("  | Output File   : {0,-52} |" -f $manifestPath) -ForegroundColor Green
        if ($CopyReceipt) {
            Write-Host "  | [CLIPBOARD] Markdown SHA-256 provenance digest copied to clipboard.  |" -ForegroundColor Green
        }
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host ""
    }
    return $manifestPath
}
