
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
        $invokeParams = @{
            Uri         = $global:sfApiUri
            Method      = 'Post'
            Headers     = $sfConnection.Headers
            Body        = '{"method":"GetClusterInfo"}'
            ErrorAction = 'Stop'
        }
        if ($global:skipCertificateCheck) {
            $invokeParams.SkipCertificateCheck = $true
        }
        $response = Invoke-RestMethod @invokeParams
        $Global:sfClusterInfo = @{}
        $response.result.clusterInfo.PSObject.Properties | ForEach-Object {
            $Global:sfClusterInfo[$_.Name] = $_.Value
        }
        $global:sfClusterName = $global:sfClusterInfo.name
    }
    catch {
        throw "Failed to connect to SolidFire cluster at ${global:sfApiUri}. Details: $($_.Exception.Message)"
    }
}
