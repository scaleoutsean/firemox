function Get-SolidFireQosPolicies {
    param (
        [Parameter(Mandatory = $false)][int]$sfAccountId,
        [Parameter(Mandatory = $false)][bool]$returnResponse = $false
    )
    $qosPolicies = Invoke-SolidFireRestMethod -Method 'ListQoSPolicies' -Body @{}
    if ($returnResponse) {
        return $qosPolicies.result.qosPolicies
    }
    if (-not $returnResponse) {
        if ($qosPolicies.result.qosPolicies) {
            $qosPolicies.result.qosPolicies | ForEach-Object {
                [PSCustomObject]@{
                    Name      = $_.name
                    ID        = $_.qosPolicyID
                    minIOPS   = $_.qos.minIOPS
                    maxIOPS   = $_.qos.maxIOPS
                    burstIOPS = $_.qos.burstIOPS
                    VolumeIDs = ($_.volumeIDs -join ', ')
                }
            } | Format-SpectreTable -Title "SolidFire QoS Policies" -Expand
        }
        else {
            Write-Host "No QoS policies found in SolidFire cluster." -ForegroundColor Yellow
        }
        Write-Host ""
        Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
    } 

}

function Set-SolidFireQosPolicy {
    param (
        [Parameter(Mandatory = $false)]
        [int]$qosPolicyId
    )
    $policies = Get-SolidFireQosPolicies -returnResponse:$true
    $policies | ForEach-Object {
        [PSCustomObject]@{
            ID        = $_.qosPolicyID
            Name      = $_.name
            MinIOPS   = $_.qos.minIOPS
            MaxIOPS   = $_.qos.maxIOPS
            BurstIOPS = $_.qos.burstIOPS
        }
    } | Format-SpectreTable -Title "Existing QoS Policies on Cluster" -Expand
    do {
        if (-not $qosPolicyId) {
            $qosPolicyId = Read-Host -Prompt "Enter QoS Policy ID to set"
        }
        $selected = $policies | Where-Object { $_.qosPolicyID -eq [int]$qosPolicyId }
        if (-not $selected -and $qosPolicyId -ne 0) {
            Write-Host "Invalid QoS policy ID. Please try again or press 0 to return to QoS Menu." -ForegroundColor Yellow            
            $qosPolicyId = $null
        }
        if ($qosPolicyId -eq 0) {
            Write-Host ""
            Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
        }
    } while (-not $selected)
    $qosPolicyIdCurrent = [PSCustomObject]@{
        minIOPS   = $selected.qos.minIOPS
        maxIOPS   = $selected.qos.maxIOPS
        burstIOPS = $selected.qos.burstIOPS    
    }
    $minIops = Read-Host -Prompt "Enter new Min IOPS [current: $($selected.qos.minIOPS)]"
    $maxIops = Read-Host -Prompt "Enter new Max IOPS [current: $($selected.qos.maxIOPS)]"
    $burstIops = Read-Host -Prompt "Enter new Burst IOPS [current: $($selected.qos.burstIOPS)]"    
    foreach ($prop in @('minIops', 'maxIops', 'burstIops')) {
        if (-not [int](Get-Variable -Name $prop -ValueOnly) -or ($null -eq (Get-Variable -Name $prop -ValueOnly))) {
            Write-Host "Setting current value for ${prop}: $($qosPolicyIdCurrent.$prop)" 
            Set-Variable -Name $prop -Value $($qosPolicyIdCurrent.$prop)
        }
    }
    $confirm = Read-Host -Prompt "Confirm QoS policy modification (Y/n)" 
    if ($confirm -eq "n" -or $confirm -eq "N") {
        Write-Host ""
        Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
        return 
    }
    $body = @{
        qosPolicyID = [int]$qosPolicyId
        qos         = @{
            minIOPS   = [int]$minIops
            maxIOPS   = [int]$maxIops
            burstIOPS = [int]$burstIops
        }
    }
    if ($body.qos -eq $qosPolicyIdCurrent) {
        Write-Host ""
        Write-SpectreHost -Message "[yellow]No changes detected. Skipping QoS policy modification.[/]"
        Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
        return
    }
    else {
        Write-SpectreHost -Message "Setting QoS policy ID [green]$qosPolicyId[/] with new values: [green]MinIOPS=$minIops[/], [green]MaxIOPS=$maxIops[/], [green]BurstIOPS=$burstIops[/]"
        Invoke-SolidFireRestMethod -Method 'ModifyQoSPolicy' -Body $body
        Write-SpectreHost -Message "Set QoS policy ID [green]$qosPolicyId[/]."
        return
    }
    Write-SpectreHost -Message ""
    Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
    return
}

function Get-SolidFireQosPolicyId {
    param (
        [Parameter(Mandatory = $true)]
        [int]$qosPolicyId,
        [Parameter(Mandatory = $false)]
        [bool]$returnResponse = $false
    )
    $body = @{
        qosPolicyID = $qosPolicyId
    }
    $qosPolicy = Invoke-SolidFireRestMethod -Method 'GetQoSPolicy' -Body $body
    if ($returnResponse) {
        return $qosPolicy
    }
    else {
        if ($qosPolicy) {
            $qosPolicy | Format-SpectreTable -Title "SolidFire QoS Policy" -Expand
        }
        else {
            Write-SpectreHost -Message "[red]QoS policy with ID '$qosPolicyId' not found.[/]"
        }
        Write-SpectreHost -Message ""
        Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
        return
    }
}

function Remove-SolidFireQosPolicy {
    param (
        [Parameter(Mandatory = $false)]
        [int]$qosPolicyId
    )
    if (-not $qosPolicyId) {
        Write-SpectreHost -Message "QoS policy ID is required." 
        $qosPolicyId = Read-SpectreText -Prompt "Enter valid QoS policy ID to remove."
        $qosPolicyIdList = (Invoke-SolidFireRestMethod -Method 'ListQoSPolicies' -Body @{}).result.qosPolicies | ForEach-Object { $_.qosPolicyID }
        if (-not [int]$qosPolicyId -or -not $qosPolicyIdList.Contains([int]$qosPolicyId)) {
            Write-Host "Invalid QoS policy ID '$qosPolicyId'." -ForegroundColor Red
            Read-SpectrePause -Message "Press [green]ANY[/] key to return to menu. You may choose to list QoS policies and try agan." -AnyKey
            return
        }
        Write-SpectreHost -Message "[red]QoS policy with ID '$qosPolicyId' not found.[/]"
        Read-SpectrePause -Message "Press [green]ANY[/] key to return to menu. You may choose to list QoS policies and try agan." -AnyKey
        return
    }
    if ($qosPolicy.volumeIDs -and $qosPolicy.volumeIDs.Count -gt 0) {
        Write-SpectreHost -Message "[red]Cannot remove QoS policy '$qosPolicyId' as it is still assigned to volumes: $($qosPolicy.volumeIDs -join ', '). Retype these volumes first.[/]"
        Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
        return
    }
    $body = @{
        name = $qosPolicyId
    }
    Invoke-SolidFireRestMethod -Method 'DeleteQoSPolicy' -Body $body
    Write-SpectreHost -Message "[green]QoS policy '$($qosPolicyId)' removed successfully.[/]"
    Write-SpectreHost -Message ""
    Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
    return
}

function New-SolidFireQosPolicy {    
    $policyName = Read-SpectreText -Prompt "Enter [Green]new QoS policy name[/]"
    $minIops = Read-SpectreText -Prompt "Enter Min IOPS for new policy '$policyName'"
    $maxIops = Read-SpectreText -Prompt "Enter Max IOPS for new policy '$policyName'"
    $burstIops = Read-SpectreText -Prompt "Enter burst IOPS for new policy '$policyName'"
    $body = @{
        name = $policyName
        qos  = @{
            minIops   = [int]$minIops
            maxIops   = [int]$maxIops
            burstIops = [int]$burstIops
        }
    }
    Invoke-SolidFireRestMethod -Method 'AddQoSPolicy' -Body $body
    Write-SpectreHost -Message "[green]QoS policy '$policyName' added successfully.[/]"
    Read-SpectrePause -Message "Press [green]ANY[/] key to return." -AnyKey
    return
}

# TODO: could be done to show the sum of storate QoS and disk capacity on PVE side vs. SolidFire volumes on which VMs/CTs live
function Get-ProxmoxQosPolicy {
    param (
        [Parameter(Mandatory = $false)]
        [int]$vmId,
        [Parameter(Mandatory = $false)]
        [int]$ctId,
        [Parameter(Mandatory = $true)]
        [int]$sfVolumeId
    )
    if ((-not $vmId) -and (-not $ctId)) {
        $vmId = Read-SpectreInput -Prompt "Enter valid Proxmox VM or CT ID to get their PVE QoS policy. Without either we just look for all VMs/CTs using SolidFire volume ID ${sfVolumeId}"
    }
    Write-SpectreHost -Message ""
    Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
    return
} 

Export-ModuleMember -Function Get-SolidFireQosPolicies, Set-SolidFireQosPolicy, Remove-SolidFireQosPolicy, Add-SolidFireQosPolicy, Get-SolidFireQosPolicyId
