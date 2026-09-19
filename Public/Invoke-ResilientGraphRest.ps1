<#
.SYNOPSIS
    Execute resilient HTTP requests against Microsoft Graph with exponential backoff, Retry-After parsing, and mock redirection.
.DESCRIPTION
    Handles 429 (Too Many Requests), 503 (Service Unavailable), and 504 (Gateway Timeout) using
    exponential jittered backoff. Dual-engine compatible with Windows PowerShell 5.1 and PowerShell 7.2+.
    Supports mock base URI interception via $env:GRAPH_BASE_URI or $script:GraphBaseUri.
#>
function Invoke-ResilientGraphRest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter()]
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method = 'GET',

        [Parameter()]
        [hashtable]$Headers = @{},

        [Parameter()]
        [object]$Body,

        [Parameter()]
        [string]$ContentType = 'application/json',

        [Parameter()]
        [string]$Token,

        [Parameter()]
        [int]$MaxRetries = 5,

        [Parameter()]
        [int]$BaseDelaySeconds = 2
    )

    # 1. Token Injection (on a copy - never mutate the caller's hashtable)
    $Headers = if ($Headers) { $Headers.Clone() } else { @{} }
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $Headers['Authorization'] = "Bearer $Token"
    } elseif (-not $Headers.ContainsKey('Authorization') -and $script:GraphAuthContext -and $script:GraphAuthContext.AccessToken) {
        $Headers['Authorization'] = "Bearer $($script:GraphAuthContext.AccessToken)"
    }

    # 2. Base URI Mock Interception
    $effectiveUri = $Uri
    $baseUriOverride = if ($env:GRAPH_BASE_URI) { $env:GRAPH_BASE_URI } elseif ($script:GraphBaseUri) { $script:GraphBaseUri } else { $null }
    if ($baseUriOverride) {
        if ($effectiveUri -match '^https?://graph\.microsoft\.com/(v1\.0|beta)(.*)$') {
            $effectiveUri = "$($baseUriOverride.TrimEnd('/'))/$($Matches[1])$($Matches[2])"
            Write-Verbose "Redirected Graph URI to mock endpoint: $effectiveUri"
        } elseif ($effectiveUri -match '^/(v1\.0|beta)(.*)$') {
            $effectiveUri = "$($baseUriOverride.TrimEnd('/'))/$($Matches[1])$($Matches[2])"
            Write-Verbose "Redirected relative Graph URI to mock endpoint: $effectiveUri"
        }
    }

    $retryCount = 0
    $success = $false
    $result = $null

    while (-not $success -and $retryCount -le $MaxRetries) {
        try {
            $requestParams = @{
                Uri         = $effectiveUri
                Method      = $Method
                Headers     = $Headers
                ContentType = $ContentType
                ErrorAction = 'Stop'
            }

            if ($Body) {
                if ($Body -is [string] -or $Body -is [byte[]]) {
                    $requestParams['Body'] = $Body
                } else {
                    $requestParams['Body'] = ($Body | ConvertTo-Json -Depth 20 -Compress)
                }
            }

            $response = Invoke-RestMethod @requestParams
            $success = $true
            $result = $response
        }
        catch {
            $ex = $_.Exception
            $statusCode = 0
            $retryAfterSeconds = 0

            # 3. Status Code & Header Extraction (Cross-Engine)
            if ($ex.Response) {
                if ($ex.Response.StatusCode) {
                    $statusCode = [int]$ex.Response.StatusCode
                }

                # Safe Retry-After Extraction across PS 5.1 (WebHeaderCollection) and PS 7+ (HttpResponseHeaders)
                try {
                    $headersObj = $ex.Response.Headers
                    if ($headersObj) {
                        if ($headersObj -is [System.Net.Http.Headers.HttpResponseHeaders] -or ($headersObj.GetType().FullName -eq 'System.Net.Http.Headers.HttpResponseHeaders')) {
                            # PS7 / .NET Core
                            if ($headersObj.RetryAfter) {
                                if ($headersObj.RetryAfter.Delta) {
                                    $retryAfterSeconds = [int][Math]::Ceiling($headersObj.RetryAfter.Delta.Value.TotalSeconds)
                                } elseif ($headersObj.RetryAfter.Date) {
                                    $diff = ($headersObj.RetryAfter.Date.Value.UtcDateTime - [DateTime]::UtcNow).TotalSeconds
                                    if ($diff -gt 0) {
                                        $retryAfterSeconds = [int][Math]::Ceiling($diff)
                                    }
                                }
                            }
                            if ($retryAfterSeconds -le 0 -and $headersObj.Contains('Retry-After')) {
                                $vals = @($headersObj.GetValues('Retry-After'))
                                if ($vals.Count -gt 0) {
                                    $parsedSec = 0
                                    if ([int]::TryParse($vals[0], [ref]$parsedSec)) {
                                        $retryAfterSeconds = $parsedSec
                                    }
                                }
                            }
                        } elseif ($headersObj -is [System.Net.WebHeaderCollection] -or ($headersObj.GetType().Name -eq 'WebHeaderCollection')) {
                            # PS 5.1 / .NET Framework
                            $retryHeaderVal = $headersObj['Retry-After']
                            if ($retryHeaderVal) {
                                $parsedSec = 0
                                if ([int]::TryParse($retryHeaderVal, [ref]$parsedSec)) {
                                    $retryAfterSeconds = $parsedSec
                                }
                            }
                        }
                    }
                } catch { }
            }

            # 4. Transient Error Evaluation (429, 500, 502, 503, 504, Connection Timeouts)
            #    Message sniffing is only a fallback for when no HTTP status could be extracted (pure transport failures);
            #    a definitive non-transient status such as 400/404 must never be retried because of text in the message.
            $isTransient = if ($statusCode -gt 0) {
                ($statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -le 504))
            } else {
                (($null -ne $ex.InnerException -and $ex.InnerException.Message -match 'timed out|connection closed|forcibly closed') -or
                 ($ex.Message -match 'timed out|connection closed|The operation has timed out|Too Many Requests|Service Unavailable|Gateway Timeout'))
            }

            if ($isTransient) {
                $retryCount++
                if ($retryCount -gt $MaxRetries) {
                    Write-Error "Graph API request failed after $MaxRetries retries. Status: $statusCode. Error: $($_.Exception.Message)"
                    throw $_
                }

                if ($retryAfterSeconds -le 0) {
                    $jitter = (Get-Random -Minimum 0 -Maximum 1000) / 1000.0
                    $calculatedDelay = [Math]::Pow(2, $retryCount) * $BaseDelaySeconds + $jitter
                    $retryAfterSeconds = [Math]::Min(30, [int][Math]::Ceiling($calculatedDelay))
                }

                Write-Warning "Microsoft Graph returned HTTP $statusCode (Throttled/Unavailable). Retrying in $retryAfterSeconds seconds (Attempt $retryCount of $MaxRetries)..."
                Start-Sleep -Seconds $retryAfterSeconds
            }
            else {
                # 5. Structured Error Payload Extraction
                $rawBodyText = $null

                if ($_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
                    $rawBodyText = $_.ErrorDetails.Message
                }

                if ([string]::IsNullOrWhiteSpace($rawBodyText) -and $ex.Response) {
                    try {
                        if ($ex.Response -is [System.Net.Http.HttpResponseMessage] -or ($ex.Response.GetType().FullName -eq 'System.Net.Http.HttpResponseMessage')) {
                            if ($ex.Response.Content) {
                                $rawBodyText = $ex.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                            }
                        } elseif ($ex.Response.PsObject.Methods['GetResponseStream']) {
                            $stream = $ex.Response.GetResponseStream()
                            if ($stream) {
                                $reader = [System.IO.StreamReader]::new($stream)
                                $rawBodyText = $reader.ReadToEnd()
                                $reader.Dispose()
                            }
                        }
                    } catch { }
                }

                $errorDetails = $_.Exception.Message
                if (-not [string]::IsNullOrWhiteSpace($rawBodyText)) {
                    try {
                        $errorJson = $rawBodyText | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($errorJson -and $errorJson.error) {
                            $code = $errorJson.error.code
                            $msg = $errorJson.error.message
                            if ($code -and $msg) {
                                $errorDetails = "$($code): $msg"
                            } elseif ($msg) {
                                $errorDetails = $msg
                            } elseif ($code) {
                                $errorDetails = $code
                            }
                        } else {
                            $errorDetails = $rawBodyText
                        }
                    } catch {
                        $errorDetails = $rawBodyText
                    }
                }

                Write-Error "Graph API request failed (HTTP $statusCode): $errorDetails"
                throw [System.InvalidOperationException]::new("Graph API Error ($statusCode): $errorDetails", $ex)
            }
        }
    }

    return $result
}
