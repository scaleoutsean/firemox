function Connect-ProxmoxVE {
    $body = @{username = $global:pveAdmin; password = $global:pvePass }
    if (-not $global:pveConnectFailures) {
        $global:pveConnectFailures = 0
    }
    while ($global:pveConnectFailures -lt 3) {
        try {
            $global:pveTicketLast = Invoke-RestMethod -Uri "$global:pveBaseUrl/api2/json/access/ticket" -Method Post -Body $body
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

Export-ModuleMember -Function Connect-ProxmoxVE

