# 🔗 IntuneShared

> **Shared Transport, Resilient Graph REST Client, Token Provider, and Diagnostic Kernel for Endpoint Management.**

[![PowerShell Version](https://img.shields.io/badge/PowerShell-7.2%2B%20LTS-blue)](https://github.com/PowerShell/PowerShell)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## 🎯 Purpose
`IntuneShared` serves as the underlying transport and security kernel for `AutopilotFast` and `WingetIntune`. It encapsulates shared platform infrastructure:

1. **`Invoke-ResilientGraphRest`**: Resilient HTTP client with jittered exponential backoff, HTTP 429 `Retry-After` header parsing, and detailed Microsoft Graph error payload extraction.
2. **`Connect-GraphToken`**: Multi-provider MSAL token engine supporting Device Code Flow (interactive/OOBE), Client Secret, and Certificate authentication with explicit scope validation.
3. **`Test-StagedNetwork`**: 7-Stage diagnostic ladder verifying Network Interface $\to$ Gateway $\to$ DNS $\to$ TCP 443 $\to$ TLS Handshake $\to$ Captive Portal $\to$ Microsoft Cloud Endpoint reachability.
4. **`Out-AsciiQrCode`**: Decoupled terminal ASCII QR visualizer.
5. **`New-BuildManifest`**: SHA256 component integrity digest generator.

---

## 📄 License
MIT © 2026 [Matthew Bubb](https://github.com/thebubbsy) | [OnYaChamp.com](https://onyachamp.com)
