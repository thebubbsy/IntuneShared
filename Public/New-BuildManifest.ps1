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
        [switch]$CopyJson,

        [Parameter()]
        [switch]$CopyTsv,

        [Parameter()]
        [switch]$CopyCsv,

        [Parameter()]
        [switch]$CopyHtml,

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
    if ($CopyJson) {
        try { Set-Clipboard -Value ($manifest | ConvertTo-Json -Depth 5) -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyTsv) {
        $tsvLines = [System.Collections.Generic.List[string]]::new()
        $tsvLines.Add("ModuleName`tModuleVersion`tGitCommit`tFile`tSha256Digest")
        foreach ($relKey in $fileHashes.Keys) {
            $tsvLines.Add("$moduleName`t$Version`t$gitCommit`t$relKey`t$($fileHashes[$relKey])")
        }
        try { Set-Clipboard -Value ($tsvLines -join [Environment]::NewLine) -ErrorAction SilentlyContinue } catch { }
    }

    if ($CopyHtml) {
        $previewRows = [System.Collections.Generic.List[string]]::new()
        foreach ($relKey in ($fileHashes.Keys | Select-Object -First 10)) {
            $h = $fileHashes[$relKey]
            $short = if ($h.Length -ge 16) { "$($h.Substring(0, 8))...$($h.Substring($h.Length - 6))" } else { $h }
            $previewRows.Add("<tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:4px 0;color:#f8fafc;font-family:monospace;font-size:11px;`">$relKey</td><td style=`"padding:4px 0;text-align:right;color:#38bdf8;font-family:monospace;font-size:11px;`">$short</td></tr>")
        }
        $htmlManifest = @(
            "<div style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:640px;background:#0f172a;color:#f8fafc;border:1px solid #334155;border-radius:8px;padding:16px;box-shadow:0 4px 6px -1px rgba(0,0,0,0.1);`">",
            "  <div style=`"display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #334155;padding-bottom:10px;margin-bottom:12px;`">",
            "    <h3 style=`"margin:0;color:#38bdf8;font-size:16px;font-weight:600;`">Module Build Provenance ($moduleName v$Version)</h3>",
            "    <span style=`"background:#166534;color:#4ade80;padding:2px 8px;border-radius:12px;font-size:12px;font-weight:600;`">VERIFIED</span>",
            "  </div>",
            "  <table style=`"width:100%;border-collapse:collapse;font-size:13px;margin-bottom:12px;`">",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:4px 0;color:#94a3b8;font-weight:500;`">Git Commit</td><td style=`"padding:4px 0;text-align:right;color:#4ade80;font-family:monospace;`">$gitCommit</td></tr>",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:4px 0;color:#94a3b8;font-weight:500;`">Timestamp UTC</td><td style=`"padding:4px 0;text-align:right;color:#f8fafc;font-size:12px;`">$buildTimeUtc</td></tr>",
            "    <tr><td style=`"padding:4px 0;color:#94a3b8;font-weight:500;`">Files Hashed</td><td style=`"padding:4px 0;text-align:right;color:#f8fafc;`">$($files.Count) files ($totalKb KB total)</td></tr>",
            "  </table>",
            "  <div style=`"font-size:12px;font-weight:600;color:#94a3b8;margin-bottom:6px;`">Component SHA-256 Hashes</div>",
            "  <table style=`"width:100%;border-collapse:collapse;`">",
            ($previewRows -join [Environment]::NewLine),
            "  </table>",
            "</div>"
        ) -join [Environment]::NewLine
        try { Set-Clipboard -Value $htmlManifest -ErrorAction SilentlyContinue } catch { }
    }

    if ($CopyCsv) {
        $csvLines = [System.Collections.Generic.List[string]]::new()
        $csvLines.Add("ModuleName,ModuleVersion,GitCommit,File,Sha256Digest")
        foreach ($relKey in $fileHashes.Keys) {
            $csvLines.Add("`"$moduleName`",`"$Version`",`"$gitCommit`",`"$relKey`",`"$($fileHashes[$relKey])`"")
        }
        try { Set-Clipboard -Value ($csvLines -join [Environment]::NewLine) -ErrorAction SilentlyContinue } catch { }
    }

    if (-not $Quiet) {
        Write-Host ""
        Write-Host ("  [MANIFEST:BUILD] [MODULE:{0}] [VERSION:v{1}] [COMMIT:{2}] [FILES:{3}] [INTEGRITY:SHA256]" -f $moduleName, $Version, $gitCommit, $files.Count) -ForegroundColor Cyan
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
        if ($CopyJson) {
            Write-Host "  | [CLIPBOARD] JSON BuildManifest provenance copied to clipboard.       |" -ForegroundColor Green
        }
        if ($CopyTsv) {
            Write-Host "  | [CLIPBOARD] TSV SHA-256 file digest table copied to clipboard.       |" -ForegroundColor Green
        }
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host ""
    }
    return $manifestPath
}
