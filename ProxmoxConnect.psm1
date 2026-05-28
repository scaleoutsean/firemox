function Connect-ProxmoxVE {
    $hasToken = -not [string]::IsNullOrWhiteSpace($global:pveTokenId) -and -not [string]::IsNullOrWhiteSpace($global:pveTokenSecret)
    if ($hasToken) {
        $global:pveHeaders = @{
            'Content-Type'  = 'application/json'
            'Accept'        = 'application/json'
            'Authorization' = "PVEAPIToken $($global:pveTokenId)=$($global:pveTokenSecret)"
        }
        $global:pveTicketLast = @{
            data = @{
                ticket               = 'token-auth'
                CSRFPreventionToken  = $null
                authenticationMethod = 'token'
            }
        }
        return
    }

    $body = @{username = $global:pveAdmin; password = $global:pvePass }
    if (-not $global:pveConnectFailures) {
        $global:pveConnectFailures = 0
    }
    while ($global:pveConnectFailures -lt 3) {
        try {
            $global:pveTicketLast = Invoke-ProxmoxRestMethod -Uri "$global:pveBaseUrl/api2/json/access/ticket" -Method Post -Body $body
            $pveTicket = $global:pveTicketLast.data.ticket
            $csrfToken = $global:pveTicketLast.data.CSRFPreventionToken
            $global:pveHeaders = @{
                'Content-Type'        = 'application/json'
                'Accept'              = 'application/json'
                "Cookie"              = "PVEAuthCookie=$pveTicket"
                "CSRFPreventionToken" = $csrfToken
            }
            $global:pveConnectFailures = 0
            break
        }
        catch {
            $global:pveConnectFailures++
            Write-Host "Failed to connect to Proxmox VE datacenter API: $_" -ForegroundColor Red
            Write-Host ($body | ConvertTo-Json -Depth 4)
            Write-Host "Please check your API URL, username, and password." -ForegroundColor Yellow
            if ($global:pveConnectFailures -ge 3) {
                break
            }
            else {
                Start-Sleep -Seconds 5
            }
        }
    }
}

function Invoke-ProxmoxRestMethod {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Get', 'Post', 'Put', 'Delete')]
        [string]$Method,
        [hashtable]$Headers,
        [object]$Body,
        [string]$ContentType
    )

    $invokeParams = @{
        Uri                  = $Uri
        Method               = $Method
        ErrorAction          = 'Stop'
        SkipHeaderValidation = $true
    }

    if ($PSBoundParameters.ContainsKey('Headers') -and $Headers) {
        $invokeParams.Headers = $Headers
    }
    elseif ($global:pveHeaders -and $global:pveHeaders.Count -gt 0) {
        $invokeParams.Headers = Get-ProxmoxRequestHeaders
    }

    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $invokeParams.Body = $Body
    }
    if ($PSBoundParameters.ContainsKey('ContentType') -and -not [string]::IsNullOrWhiteSpace($ContentType)) {
        $invokeParams.ContentType = $ContentType
    }
    if ($global:skipCertificateCheck) {
        $invokeParams.SkipCertificateCheck = $true
    }

    return Invoke-RestMethod @invokeParams
}

function Get-ProxmoxRequestHeaders {
    if (-not $global:pveHeaders -or $global:pveHeaders.Count -eq 0) {
        return @{}
    }

    $headers = @{}
    foreach ($key in $global:pveHeaders.Keys) {
        $headers[$key] = $global:pveHeaders[$key]
    }
    return $headers
}

Export-ModuleMember -Function Connect-ProxmoxVE, Get-ProxmoxRequestHeaders, Invoke-ProxmoxRestMethod

