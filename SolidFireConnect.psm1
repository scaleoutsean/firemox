
function Connect-SolidFire {
    param(
        [string]$SFApiUri = $global:sfApiUri,
        [string]$SFAdmin = $global:sfAccountName,
        [string]$SFPass = $global:sfAccountPass
    )
    $global:sfHeaders = @{
        'Authorization' = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${SFAdmin}:${SFPass}"))
        'Content-Type'  = 'application/json'
    }
    $sfConnection = @{
        'ApiEndpoint'  = ${global:sfApiUri}
        'Headers'      = ${global:sfHeaders}
        'Content-Type' = 'application/json'
    }
    try {
        $response = Invoke-RestMethod -Uri $global:sfApiUri -Method Post -Headers $sfConnection.Headers -Body '{"method":"GetClusterInfo"}'
        $Global:sfClusterInfo = @{}
        $response.result.clusterInfo.PSObject.Properties | ForEach-Object {
            $Global:sfClusterInfo[$_.Name] = $_.Value
        }
        $global:sfClusterName = $global:sfClusterInfo.name
    }
    catch {
        Write-Host "Failed to connect to SolidFire cluster at ${global:sfApiUri}."
        Write-Host ("DEBUG: Exception details: " + ($_ | Out-String))
        return
    }
}
