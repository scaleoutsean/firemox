function Invoke-SolidFireRestMethod {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [hashtable]$Body
    )
    if (-not $global:sfHeaders) {
        Write-Host "SolidFire headers must be present." -ForegroundColor Red
        exit 1
    }
    $payload = @{
        method = $Method
        params = $Body
    } | ConvertTo-Json -Depth 5
    try {
        $response = Invoke-RestMethod -Uri $global:sfApiUri -Method Post -Headers $global:sfHeaders -Body $payload -ContentType 'application/json' -ErrorAction Stop -FollowRelLink -PreserveAuthorizationOnRedirect -SkipCertificateCheck -SslProtocol Tls12
        return $response
    }
    catch {
        Write-Host "Failed to invoke SolidFire API method '$Method': $_" -ForegroundColor Red
        exit 1
    }
}

Export-ModuleMember -Function Invoke-SolidFireRestMethod

