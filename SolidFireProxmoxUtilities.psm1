function Get-ProxmoxSolidFireStoragePool {
    param (
        [switch]$Silent
    )
    $script:sfStorage = @()
    Invoke-SpectreCommandWithProgress -ScriptBlock {
        $sfStorageLocal = @()
        $storageIndexes = @()
        foreach ($storageType in @('iscsi', 'lvm')) {
            if (-not $global:pveTicketLast -or -not $global:pveTicketLast.data.ticket) {
                $null = Connect-ProxmoxVE
            }
            if (-not $global:pveTicketLast -or -not $global:pveTicketLast.data.ticket) {
                Write-SpectreHost -Message "[Red]Failed to obtain a valid Proxmox VE API ticket. Please check your API URL, username, and password.[/]"
                return
            }
            $params = @{ type = $storageType }
            $storageIndex = Invoke-RestMethod -Uri "$global:pveBaseUrl/api2/json/storage" -Headers $global:pveHeaders -Body $params -Method Get
            $storageIndexes += $storageIndex.data
        }
        foreach ($stuff in $storageIndexes) {
            if ($stuff.type -eq 'iscsi' -and $stuff.target -like "*iqn.2010-01.com.solidfire:*") {
                $baseKv = $stuff.target -split '\.'
                $volumeId = $baseKv[-1]
                $volume = $baseKv[-2]
                $sfStorageItem = [PSCustomObject]@{
                    type        = $stuff.type
                    pve_pool_id = $stuff.storage
                    backing     = $stuff.target
                    content     = ($stuff.PSObject.Properties['content'] ? $stuff.content : $null)
                    portal      = $stuff.portal
                    volume      = $volume
                    volumeId    = $volumeId
                }
                $sfStorageLocal += $sfStorageItem
            }
            elseif ($stuff.type -eq "lvm" -and $stuff.base -like "*scsi-36f47acc1*") {
                $baseKv = $stuff.base -split ':'
                $volumeId = [Convert]::ToInt32(($baseKv[1]).Substring($baseKv[1].Length - 8), 16)
                $sfStorageItem = [PSCustomObject]@{
                    type        = $stuff.type
                    pve_pool_id = $stuff.storage
                    backing     = $stuff.base
                    content     = ($stuff.PSObject.Properties['content'] ? $stuff.content : $null)
                    volume      = ($stuff.PSObject.Properties['vgname'] ? $stuff.vgname : $null)
                    volumeId    = $volumeId
                }
                $sfStorageLocal += $sfStorageItem
            }
        }
        $script:sfStorage = $sfStorageLocal
    }

    $sfStorage = $script:sfStorage
    if (-not $Silent) {
        $table = $sfStorage | Sort-Object -Property type, pve_pool_id | Get-Unique -AsString | Format-SpectreTable -Title "Proxmox-SolidFire Storage Pools" -Color Orange3 -Wrap
        $table | Out-SpectreHost
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
    return $sfStorage
}

function New-ProxmoxSolidFireStoragePool {
    $body = @{
        accountID = $global:sfAccountId
    }
    $sfVolumes = (Invoke-SolidFireRestMethod -Method "ListVolumesForAccount" -Body $body).result.volumes
    if (-not $global:pveTicketLast -or -not $global:pveTicketLast.data.ticket) {
        $null = Connect-ProxmoxVE
    }
    $storageIndex = Invoke-RestMethod -Uri "$global:pveBaseUrl/api2/json/storage" -Headers $global:pveHeaders -Method Get

    $usedIqns = @()
    foreach ($storage in $storageIndex.data) {
        if ($storage.type -eq 'iscsi' -and $storage.target -like "*iqn.2010-01.com.solidfire:*") {
            $usedIqns += $storage.target
        }
    }
    Write-SpectreHost -Message "[Yellow]Used IQNs: $($usedIqns -join ', ')[/]"

    $unusedIscsiTargets = @()
    foreach ($sfVol in $sfVolumes) {
        if ($usedIqns -notcontains $sfVol.iqn) {
            $unusedIscsiTargets += [PSCustomObject]@{
                Name     = $sfVol.name
                Iqn      = $sfVol.iqn
                VolumeId = $sfVol.volumeID
                SizeGiB  = $sfVol.totalSize / 1GB
            }
        }
        else {
            Write-SpectreHost -Message "[Yellow]Skipping used iSCSI target (Name: $($sfVol.name), IQN: $($sfVol.iqn), VolumeID: $($sfVol.volumeID), Size: $($sfVol.totalSize/1GB) GiB)[/]"
        }
    }

    if ($unusedIscsiTargets.Count -eq 0) {
        Write-SpectreHost -Message "[Yellow]No unused iSCSI targets found in SolidFire cluster.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
    Write-SpectreHost -Message "[Green]Found $($unusedIscsiTargets.Count) unused iSCSI targets in SolidFire cluster.[/]"
    $choices = @()
    if ($unusedIscsiTargets -and $unusedIscsiTargets.Count -gt 0) {
        $choices = $unusedIscsiTargets | Sort-Object -Property Name | ForEach-Object { $_.name }
    }
    $selectedUnusedVolumes = Read-SpectreMultiSelection -Message "Select at least one volume for new iSCSI storage pool. You will be asked to Confirm or Cancel later." `
        -Choices $choices `
        -PageSize 8
    Write-SpectreHost "Your selected volumes are $($selectedUnusedVolumes -join ', ')"
    $answer = Read-SpectreConfirm -Message "Would you like to continue? Any existing data on these volumes [Red]may be lost[/]?" `
        -Color Blue -TimeoutSeconds 10 -DefaultAnswer 'n'
    if (-not $answer) {
        Write-SpectreHost -Message "[Yellow]Aborting iSCSI pool creation.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
    else {
        foreach ($sfVolumeName in $selectedUnusedVolumes) {
            Write-SpectreHost -Message "[Green]Creating a new iSCSI pool for volume ID: $volumeId[/]"
            $sfVolName = ($sfVolumes | Where-Object { $_.name -eq $sfVolumeName }).name
            $sfVolIqn = ($sfVolumes | Where-Object { $_.name -eq $sfVolumeName }).iqn
            $null = New-PveIscsiStoragePool -PoolName $sfVolName -Portal ($global:sfClusterInfo.svip) -Target $sfVolIqn -Content 'none'

        }
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
}


function New-PveIscsiStoragePool {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PoolName,
        [Parameter(Mandatory = $true)]
        [string]$Portal,
        [Parameter(Mandatory = $true)]
        [string]$Target,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )
    if (-not $global:pveTicketLast -or -not $global:pveTicketLast.data.ticket) {
        try {
            $connect = Connect-ProxmoxVE
        }
        catch {
            Write-SpectreHost -Message "[Red]Failed to connect to Proxmox VE API: $_[/]"
            Write-SpectreHost -Message "[Red]Connect-ProxmoxVE API response: $($response.data)[/]"
            Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
            return
        }
    }
    $body = @{
        storage = $PoolName
        type    = 'iscsi'
        content = $Content
        portal  = $Portal
        target  = $Target
    }
    $response = Invoke-RestMethod -Uri "$global:pveBaseUrl/api2/json/storage" `
        -Headers $global:pveHeaders `
        -Body ($body | ConvertTo-Json) `
        -Method Post `
        -ContentType 'application/json'
    if ($response.data) {
        Write-SpectreHost -Message "[Green]Storage pool '$($PoolName)' of type 'iscsi' created successfully.[/]"
    }
    else {
        Write-SpectreHost -Message "[Red]Failed to create storage pool '$($PoolName)'. Error: $($response.errors)[/]"
        Write-SpectreHost -Message "[Red]API response: $($response.data)[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
    }
    return
}

function New-PveLvmStoragePool {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PoolName,
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$VgName,
        [Parameter(Mandatory = $true)]
        [string]$Base,
        [Parameter(Mandatory = $true)]
        [string]$Shared,
        [Parameter(Mandatory = $true)]
        [string]$Saferemove
    )
    if (-not $global:pveTicketLast -or -not $global:pveTicketLast.data.ticket) {
        try {
            $null = Connect-ProxmoxVE
        }
        catch {
            Write-SpectreHost -Message "[Red]Failed to connect to Proxmox VE API: $_[/]"
            Write-SpectreHost -Message "[Red]Connect-ProxmoxVE API response: $($response.data)[/]"
            Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
            return
        }
    }
    $body = @{
        storage    = $PoolName
        type       = 'lvm'
        content    = $Content
        vgname     = $VgName
        base       = $Base
        shared     = $Shared
        saferemove = $Saferemove
    }
    $response = Invoke-RestMethod -Uri "$global:pveBaseUrl/api2/json/storage" `
        -Headers $global:pveHeaders `
        -Body ($body | ConvertTo-Json) `
        -Method Post `
        -ContentType 'application/json'
    if ($response.data) {
        Write-SpectreHost -Message "[Green]Storage pool '$($PoolName)' of type 'lvm' created successfully.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
    }
    else {
        Write-SpectreHost -Message "[Red]Failed to create storage pool '$($PoolName)'. Error: $($response.errors)[/]"
        Write-SpectreHost -Message "[Red]API response: $($response.data)[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
    }
    return
}

function New-ProxmoxVolumeGroup {
    $sfPveSfStoragePool = Get-ProxmoxSolidFireStoragePool -Silent
    $unusedPveLvmPools = @()
    foreach ($item in $sfPveSfStoragePool) {
        if ($item.type -eq 'iscsi') {
            $lvmPool = $sfPveSfStoragePool | Where-Object { $_.type -eq 'lvm' -and $_.volumeId -eq $item.volumeId }
            if (-not $lvmPool) {
                $unusedPveLvmPools += $item
            }
        }
    }
    if ($unusedPveLvmPools.Count -eq 0) {
        Write-SpectreHost -Message "[Yellow]No unused iSCSI pools found in Proxmox VE that can be used to create LVM Volume Groups.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
    Write-SpectreHost -Message "[Green]Found $($unusedPveLvmPools.Count) unused iSCSI pools in Proxmox VE that can be used to create LVM Volume Groups.[/]"
    $selectUnusedLvmPools = $unusedPveLvmPools | Sort-Object -Property pve_pool_id | ForEach-Object { $_.pve_pool_id }
    $selectedUnusedLvmPools = Read-SpectreMultiSelection -Message "Select at least one iSCSI pool to create LVM Volume Group on top of it. You will be asked to Confirm or Cancel later." `
        -Choices $selectUnusedLvmPools `
        -PageSize 8
    Write-SpectreHost "Your selected iSCSI pools are $($selectedUnusedLvmPools -join ', ')"
    $answer = Read-SpectreConfirm -Message "Would you like to continue? Any existing data on these volumes [red]may be lost[/]?" `
        -Color Blue -TimeoutSeconds 10 -DefaultAnswer 'n'
    if (-not $answer) {
        return
    }
    Write-SpectreHost -Message "[Green]Creating LVM Volume Groups on Proxmox VE for iSCSI pools: $($selectedUnusedLvmPools -join ', ')[/]"
    foreach ($sfPoolName in $selectedUnusedLvmPools) {
        $sfPool = $sfPveSfStoragePool | Where-Object { $_.pve_pool_id -eq $sfPoolName }
        if ($sfPool) {
            $lvmName = "lvm-$($sfPoolName)"
            $vgName = "vg-$($sfPoolName)"
            $vendorString = "36f47acc1"
            $clusterHex = (Convert-UniqueIDToHex -UniqueID $global:sfClusterInfo.uniqueID).PadLeft(16, '0')
            $volHex = [Convert]::ToInt32($sfPool.volumeId, 10).ToString("x").PadLeft(8, '0')
            $base = "$($sfPool.pve_pool_id):0.0.0.scsi-$vendorString$clusterHex$volHex"
            Write-SpectreHost -Message "[Yellow]If you continue, function to create LVM/VG will be called. Press n or N to abort, or any other key to continue.[/]"
            $userInput = Read-Host "Continue? (y/N)"
            if ($userInput -eq 'n' -or $userInput -eq 'N') {
                Write-SpectreHost -Message "[Yellow]Aborting LVM Volume Group creation.[/]"
                continue
            }
            New-PveLvmStoragePool -PoolName $lvmName `
                -Content 'images,rootdir' `
                -Shared 1 `
                -VgName $vgName `
                -Base $base `
                -Saferemove 1
        }
        else {
            Write-SpectreHost -Message "[Red]No matching iSCSI pool found for '$sfPoolName'[/]"
            continue
        }
    }
    return
}

function Get-ProxmoxSolidFireStorageMap {
    param (
        [switch]$Silent
    )
    $sfStorage = Get-ProxmoxSolidFireStoragePool -Silent
    $sfStorageMap = @()
    foreach ($item in $sfStorage) {
        if ($item.type -eq 'lvm') {
            $sfStorageMap += [PSCustomObject]@{
                VG              = $item.volume
                LVM             = $item.pve_pool_id
                Iscsi_Pool      = ""
                SF_Iscsi_Target = ""
                SF_VolumeID     = $item.volumeId
            }
        }
    }
    foreach ($item in $sfStorage) {
        if ($item.type -eq 'iscsi') {
            $matchingItem = $sfStorageMap | Where-Object { $_.SF_VolumeID -eq $item.volumeId }
            if ($matchingItem) {
                $matchingItem.Iscsi_Pool = $item.pve_pool_id
                $matchingItem.SF_Iscsi_Target = $item.backing
                $matchingItem.SF_VolumeID = $item.volumeId
            }
        }
    }

    if (-not $Silent) {
        $table = $sfStorageMap | Sort-Object -Property VG | Format-SpectreTable -Title "Proxmox-SolidFire VG-to-iSCSI Map" -Color Orange3 -Wrap
        $table | Out-SpectreHost
        $userInput = Read-Host "Press any key to continue, press y or Y to save this map to a CSV file"
        if ($userInput -eq 'y' -or $userInput -eq 'Y') {
            $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $fileName = "pve_solidfire_map_$timestamp.csv"
            $sfStorageMap | Sort-Object -Property VG | Export-Csv -Path $fileName -NoTypeInformation
            Write-SpectreHost -Message "[Green]Exported storage map to $fileName[/]"
            Start-Sleep -Seconds 2
            return
        }
        else {
            return
        }
    }
    else {
        return $sfStorageMap
    }
}

function Get-SFClusterIscsiTarget {
    param (
        [Parameter(Mandatory = $true)]
        [int]$sfAccountId
    )
    $body = @{}
    $response = Invoke-SolidFireRestMethod -Method 'GetClusterInfo' -Body $body
    if ($response.result) {
        $clusterInfo = [PSCustomObject]@{
            name             = $response.result.clusterInfo.name
            cluster_id       = $response.result.clusterInfo.uniqueID
            target_iqn       = ""
            storage_vip      = $response.result.clusterInfo.svip
            storage_vlan_tag = $response.result.clusterInfo.svipVlanTag
            wwn_path         = "/dev/wwn-0x6"
            wwn_naa_dev      = ""
            pve_base_path    = "<isci_pool_name>:0.0.0.scsi-<wwn_naa_dev>"
        }
    }
    else {
        Write-SpectreHost -Message "[Red]Failed to retrieve iSCSI targets from SolidFire cluster.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return @()
    }
    $uidHex = Convert-UniqueIDToHex -UniqueID $clusterInfo.cluster_id
    $clusterInfo.target_iqn = "iqn.2010-10.com.solidfire:$($response.result.clusterInfo.uniqueID).<vol_name>.<vol_id>"
    $clusterInfo.wwn_path = "/dev/disk/by-id/wwn-0x6f47acc100000000${uidHex}<hex-vol-id-left-padded-to-8bytes>"
    $clusterInfo.wwn_naa_dev = "36f47acc100000000${uidHex}<hex-vol-id-left-padded-to-8bytes>"

    $clusterObject = @(
        [PSCustomObject]@{
            Name  = "Cluster name"
            Value = $clusterInfo.name
        },
        [PSCustomObject]@{
            Name  = "Cluster ID"
            Value = $clusterInfo.cluster_id
        },
        [PSCustomObject]@{
            Name  = "Target IQN"
            Value = $clusterInfo.target_iqn
        },
        [PSCustomObject]@{
            Name  = "Storage VIP"
            Value = $clusterInfo.storage_vip
        },
        [PSCustomObject]@{
            Name  = "Storage VLAN Tag"
            Value = $clusterInfo.storage_vlan_tag
        },
        [PSCustomObject]@{
            Name  = "WWN Path"
            Value = $clusterInfo.wwn_path
        },
        [PSCustomObject]@{
            Name  = "WWN NAA Device"
            Value = $clusterInfo.wwn_naa_dev
        },
        [PSCustomObject]@{
            Name  = "PVE Base Path"
            Value = $clusterInfo.pve_base_path
        }
    )

    Format-SpectreTable -Data $clusterObject -Title "SolidFire Cluster iSCSI Targets" -Color Red

    $body = @{ accountID = $sfAccountId }
    $response = Invoke-SolidFireRestMethod -Method 'ListVolumesForAccount' -Body $body
    if ($response.result -and $response.result.volumes) {
        $accountTargets = $response.result.volumes | ForEach-Object {
            [PSCustomObject]@{
                name            = $_.name
                volumeID        = $_.volumeID
                totalSizeGiB    = ($_.totalSize) / 1GB
                scsiNAADeviceID = $_.scsiNAADeviceID
                iqn             = $_.iqn
                qosID           = $_.qosPolicyID
                qosName         = $null
            }
        }
    }
    elseif ($response.result) {
        $accountTargets = @()
    }
    else {
        Write-SpectreHost -Message "[Red]Failed to retrieve volumes for account ID $sfAccountId.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return @()
    }

    $body = @{}
    $qosList = (Invoke-SolidFireRestMethod -Method 'ListQoSPolicies' -Body $body).result.qosPolicies
    $qosLookup = @{ }
    foreach ($pol in $qosList) {
        $qosLookup[[int]$pol.qosPolicyID] = $pol.name
    }
    foreach ($t in $accountTargets) {
        $id = $t.qosID
        if ($null -ne $id -and '' -ne $id -and $qosLookup.ContainsKey([int]$id)) {
            $t.qosName = $qosLookup[[int]$id]
        }
        else {
            $t.qosName = 'none'
        }
    }

    Format-SpectreTable -InputObject $accountTargets `
        -Title "iSCSI Targets for Account ID $sfAccountId" `
        -Color Red -Wrap
    Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
    return
}

function Get-SolidFirePveNetworkSetting {
    $body = @{}
    $sfClusterInfo = Invoke-SolidFireRestMethod -Method 'GetClusterInfo' -Body $body
    if (-not $sfClusterInfo) {
        Write-SpectreHost -Message "[Red]Failed to retrieve SolidFire cluster info.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
    $sfPveNodes = @()
    $sfPveNodes += [PSCustomObject]@{
        nodeType  = "SolidFire"
        nodeName  = "Storage Virtual IP"
        storageIp = $sfClusterInfo.result.clusterInfo.svip
        vlanTag   = $sfClusterInfo.result.clusterInfo.svipVlanTag
        nodeId    = "-"
    }
    $body = @{}
    $sfNodes = Invoke-SolidFireRestMethod -Method 'ListActiveNodes' -Body $body
    if ($sfNodes.result -and $sfNodes.result.nodes) {
        $sfPveNodes += $sfNodes.result.nodes | ForEach-Object {
            [PSCustomObject]@{
                nodeType  = "SolidFire"
                nodeName  = $_.name
                storageIp = $_.sip
                nodeId    = $_.nodeID
                vlanTag   = "N/A"
            }
        }
    }
    $iscsiNetwork = ($sfNodes.result.nodes[0].sip -split '\.')[0..2] -join '.'
    $null = Connect-ProxmoxVE
    $pveTicket = $global:pveTicketLast.data.ticket
    $pveHeaders = @{"Cookie" = "PVEAuthCookie=$pveTicket" }
    $pveNodesInfo = (Invoke-RestMethod -Uri "$global:pveBaseUrl/api2/json/cluster/config/nodes" -Headers $global:pveHeaders -Method Get).data
    if (-not $pveNodesInfo) {
        Write-SpectreHost -Message "[Red]Failed to retrieve Proxmox VE nodes.[/]"
        Write-SpectreHost -Message "[Red]Please check your Proxmox VE API connection and try again.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
    foreach ($node in $pveNodesInfo) {
        try {
            $pveNodeNetwork = (Invoke-RestMethod -Uri "$global:pveBaseUrl/api2/json/nodes/$($node.node)/network" -Headers $global:pveHeaders -Method Get).data
            foreach ($iface in $pveNodeNetwork) {
                if ($iface.address -and $iface.address -match "^$iscsiNetwork\.\d{1,3}(/\d+)?$") {
                    $sfPveNodes += [PSCustomObject]@{
                        nodeType  = "Proxmox VE"
                        nodeName  = $node.node
                        storageIp = $iface.address -replace '/\d+$', ''
                        nodeId    = $node.nodeid
                        vlanTag   = $iface.vlan ? $iface.vlan : 'N/A'
                    }
                }
            }

        }
        catch {
            Write-SpectreHost -Message "[Red]Failed to retrieve network settings for node $($node.node): $_[/]"
            continue
        }
    }

    $sfPveNodes | Sort-Object -Property nodeType, nodeName | Format-SpectreTable -Title "SolidFire and Proxmox VE Nodes' iSCSI Network Settings" -Wrap -Color Blue -Width 78

    Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
    return
}

function Remove-ProxmoxVgLvm {
    Write-SpectreFigletText -Text "SENSITIVE OPERATION" -Alignment "Center" -Color "Red"
    Write-SpectreRule -Title "[red]:warning:[/] Read before proceeding [red]:warning:[/]" -Alignment Center -Color Yellow
    Write-SpectreHost -Message "This is a destructive operation that can go wrong in many ways (e.g. if you have VMs or CTs using this VG/LVM) :bomb:"
    Write-SpectreHost -Message "It is recommended to use the PVE Web UI to remove VG/LVM, followed by PVE iSCSI pool removal if required."
    Write-SpectreRule -Title "" -Alignment Center -Color Yellow
    if (-not $global:pveTicketLast -or -not $global:pveTicketLast.data.ticket) {
        $null = Connect-ProxmoxVE
    }
    $ticket = $global:pveTicketLast.data.ticket
    $csrf = $null
    if ($global:pveTicketLast.data.PSObject.Properties["CSRFPreventionToken"]) {
        $csrf = $global:pveTicketLast.data.CSRFPreventionToken
    }
    elseif ($global:CSRFPreventionToken) {
        $csrf = $global:CSRFPreventionToken
    }
    $headers = @{ "Cookie" = "PVEAuthCookie=$ticket" }
    if ($csrf) { $headers["CSRFPreventionToken"] = $csrf }

    $pveSolidFireStorageMap = Get-ProxmoxSolidFireStorageMap -Silent
    $pveSolidFireStorageMap | Sort-Object -Property VG | Format-SpectreTable -Title "Proxmox VE SolidFire Storage Map" -Color Blue -Wrap
    Write-SpectreHost "This is a list of [Yellow]existing[/] [orange3]PVE[/] Volume Groups (VG) and their corresponding LVMs that are backed by SolidFire cluster."
    if (-not $pveSolidFireStorageMap) {
        Write-SpectreHost -Message "[Yellow]No Proxmox VE Volume Groups (VG) found for SolidFire cluster.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
    $vgChoices = $pveSolidFireStorageMap | ForEach-Object { $_.VG } | Sort-Object
    $selectedVg = Read-SpectreSelection -Message "Select the Proxmox VE Volume Group (VG) to remove. You will be asked to Confirm or Cancel later." `
        -Choices $vgChoices `
        -PageSize 8
    if (-not $selectedVg) {
        Write-SpectreHost -Message "[Yellow]No Volume Group (VG) selected. Returning to the module menu.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
    Write-SpectreHost "You selected the following Volume Group(s) (VG): $($selectedVg -join ', ')"
    $confirmation = Read-SpectreText -Message "Would you like to proceed?" -DefaultAnswer "n" -TimeoutSeconds 10 -Choices @("y", "n")
    if ($confirmation -ne 'y') {
        Write-SpectreHost -Message "[Yellow]Volume Group (VG) removal canceled.[/]"
        return
    }

    if ($selectedVg -is [System.Array]) {
        $selectedVgName = $selectedVg[0]
    }
    else {
        $selectedVgName = $selectedVg
    }
    $selectedVgName = [string]$selectedVgName
    $mapObj = $pveSolidFireStorageMap | Where-Object { $_.VG -eq $selectedVgName }
    if (-not $mapObj) {
        Write-SpectreHost -Message "[Red]ERROR: Could not find mapping object for selected VG '$selectedVgName'. Aborting.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
    if ($mapObj -is [System.Array]) {
        $mapObj = $mapObj[0]
    }
    $vgName = $mapObj.VG
    $lvmName = $mapObj.LVM
    if (-not $vgName -or $vgName.Trim() -eq '' -or $vgName -match "[?&=]") {
        Write-SpectreHost -Message "[Red]ERROR: No valid VG name selected or VG name contains illegal characters. Aborting.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
    if (-not $global:pveTicketLast -or -not $global:pveTicketLast.data.ticket) {
        Write-SpectreHost -Message "[Cyan]No valid Proxmox VE ticket found. Connecting to Proxmox VE API...[/]"
        $null = Connect-ProxmoxVE
    }
    $nodeList = (Invoke-RestMethod -Uri "$global:pveBaseUrl/api2/json/cluster/config/nodes" -Headers $headers -Method Get).data
    if (-not $nodeList) {
        Write-SpectreHost -Message "[red]Failed to retrieve Proxmox VE nodes.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
    Write-SpectreHost -Message "It is recommended to use the PVE Web UI to remove VG/LVM, followed by iSCSI pool removal if required."
    $firstNode = $nodeList | Sort-Object -Property name | Select-Object -First 1
    if (-not $firstNode -or -not $firstNode.name) {
        Write-SpectreHost -Message "[Red]Could not determine a valid node to perform VG removal.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
    if (-not $vgName -or $vgName.Trim() -eq '' -or $vgName -match "[?&=]") {
        Write-SpectreHost -Message "[Red]ERROR: Invalid VG name for DELETE URI: '$vgName'[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
    $vgDeleteUri = "$global:pveBaseUrl/api2/json/nodes/$($firstNode.name)/disks/lvm/$vgName" + "?cleanup-disks=1&cleanup-config=1"
    $response = Invoke-RestMethod -Uri $vgDeleteUri -Headers $headers -Method Delete
    if ($response.data -and $response.data -is [string] -and $response.data -match (':lvmremove:' + [regex]::Escape($vgName) + ':')) {
        $removeLvm = Read-SpectreSelection -Message "Do you also want to remove the LVM storage pool definition '$lvmName' from the cluster?" -Choices @("yes", "no") -Color Yellow
        if ($removeLvm -eq 'yes') {
            $lvmUri = "$global:pveBaseUrl/api2/json/storage/$lvmName"
            $lvmResponse = Invoke-RestMethod -Uri $lvmUri -Headers $headers -Method Delete
            if (
                ($lvmResponse.data -and $lvmResponse.data.status -eq 'success') -or
                ($null -eq $lvmResponse.data)
            ) {
                Write-SpectreHost -Message "[Green]Proxmox VE LVM storage pool '$lvmName' removed successfully from cluster config.[/]"
            }
            else {
                Write-SpectreHost -Message "[Red]Failed to remove Proxmox VE LVM storage pool: $lvmName from cluster config.[/]"
            }
        }
        else {
            Write-SpectreHost -Message "[Yellow]Skipped removal of LVM storage pool definition.[/]"
        }
    }
    else {
        Write-SpectreHost -Message "[Red]Failed to remove Proxmox VE Volume Group (VG): $vgName from node: $($firstNode.name)[/]"
        if ($response.data) {
            Write-SpectreHost -Message "Proxmox returned: $($response.data)"
        }
        $tryLvm = Read-SpectreConfirm -Message "Do you want to attempt to remove the LVM storage pool definition '$lvmName' from the cluster anyway?" `
            -TimeoutSeconds 10 -DefaultAnswer 'n'
        if ($tryLvm -eq 'yes') {
            $lvmUri = "$global:pveBaseUrl/api2/json/storage/$lvmName"
            $lvmResponse = Invoke-RestMethod -Uri $lvmUri -Headers $headers -Method Delete
            if (
                ($lvmResponse.data -and $lvmResponse.data.status -eq 'success') -or
                ($null -eq $lvmResponse.data)
            ) {
                Write-SpectreHost -Message "[Green]Proxmox VE LVM storage pool '$lvmName' removed successfully from cluster config.[/]"
            }
            else {
                Write-SpectreHost -Message "[Red]Failed to remove Proxmox VE LVM storage pool: $lvmName from cluster config.[/]"
            }
        }
        else {
            Write-SpectreHost -Message "[Yellow]Skipped removal of LVM storage pool definition.[/]"
            Write-SpectreHost -Message "[Yellow]It is recommended to use the PVE Web UI to remove VG/LVM, followed by iSCSI pool removal if required.[/]"
        }
    }
    $headers.Remove("CSRFPreventionToken")
    Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
    return
}

function Remove-ProxmoxIscsiPool {
    Write-SpectreFigletText -Text "SENSITIVE OPERATION" -Alignment "Center" -Color "Red"
    Write-SpectreRule -Title "[red]:warning:[/] Read before proceeding [red]:warning:[/]" -Alignment Center -Color Yellow
    Write-SpectreHost -Message "This is a destructive operation that can go wrong in many ways (e.g. if you have VG/LVM on this iSCSI pool) :bomb:"
    Write-SpectreHost -Message "It is recommended to use the PVE Web UI to remove VG/LVM, followed by iSCSI pool removal if required."
    Write-SpectreHost -Message "[red]This function works under the assumption the iSCSI Pools you choose to remove are not in use[/]. You will be asked to Confirm or Cancel later."
    Write-SpectreHost -Message "If you delete a wrong iSCSI pool, you may be able to import it manually [yellow]on your own[/]."
    Write-SpectreRule -Title "" -Alignment Center -Color Yellow

    if (-not $global:pveTicketLast -or -not $global:pveTicketLast.data.ticket) {
        Write-SpectreHost -Message "[Yellow]No valid Proxmox VE ticket found. Connecting to Proxmox VE API...[/]"
        $null = Connect-ProxmoxVE
    }
    $ticket = $global:pveTicketLast.data.ticket
    $csrf = $null
    if ($global:pveTicketLast.data.PSObject.Properties["CSRFPreventionToken"]) {
        $csrf = $global:pveTicketLast.data.CSRFPreventionToken
    }
    elseif ($global:CSRFPreventionToken) {
        $csrf = $global:CSRFPreventionToken
    }
    $headers = @{ "Cookie" = "PVEAuthCookie=$ticket" }
    if ($csrf) { $headers["CSRFPreventionToken"] = $csrf }

    $pveSolidFireStoragePool = Get-ProxmoxSolidFireStoragePool -Silent
    if (-not $pveSolidFireStoragePool) {
        Write-SpectreHost -Message "[Yellow]No Proxmox VE iSCSI pools found for SolidFire cluster.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
    $pveSolidFireStoragePool | Sort-Object -Property pve_pool_id | Format-SpectreTable -Title "Proxmox VE SolidFire iSCSI Pools" -Color Blue -Wrap
    $poolChoices = $pveSolidFireStoragePool | ForEach-Object { $_.pve_pool_id } | Sort-Object

    $selectedPool = Read-SpectreSelection -Title "Select single iSCSI Pool to Remove" -Choices $poolChoices -Color Yellow -PageSize 10
    if (-not $selectedPool) {
        Write-SpectreHost -Message "[Yellow]No iSCSI pool selected. Returning to the module menu.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
    if ($selectedPool -is [System.Array]) {
        $selectedPoolName = $selectedPool[0]
    }
    else {
        $selectedPoolName = $selectedPool
    }
    $selectedPoolName = [string]$selectedPoolName
    $mapObj = $pveSolidFireStoragePool | Where-Object { $_.pve_pool_id -eq $selectedPoolName }
    if (-not $mapObj) {
        Write-SpectreHost -Message "[Red]ERROR: Could not find mapping object for selected iSCSI pool '$selectedPoolName'. Aborting.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
    if ($mapObj -is [System.Array]) {
        $mapObj = $mapObj[0]
    }
    $poolName = $mapObj.pve_pool_id
    $confirmation = Read-SpectreConfirm -Message "Are you sure you want to remove the iSCSI pool '$poolName'? This action cannot be undone." `
        -Color Red -TimeoutSeconds 10 -DefaultAnswer 'n'
    if ($confirmation -ne 'yes') {
        Write-SpectreHost -Message "[Yellow]iSCSI pool removal canceled.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }

    $nodeList = (Invoke-RestMethod -Uri "$global:pveBaseUrl/api2/json/cluster/config/nodes" -Headers $headers -Method Get).data
    if (-not $nodeList) {
        Write-SpectreHost -Message "[Red]ERROR: No Proxmox cluster nodes found. Aborting.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
    $firstNodeObj = $nodeList | Sort-Object name | Select-Object -First 1
    if (-not $firstNodeObj -or -not $firstNodeObj.name) {
        Write-SpectreHost -Message "[Red]Could not determine a valid node to perform iSCSI pool removal.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
        return
    }
    $poolDeleteUri = "$global:pveBaseUrl/api2/json/storage/$poolName"
    $null = Invoke-RestMethod -Uri $poolDeleteUri -Headers $headers -Method Delete
    $headers.Remove("CSRFPreventionToken")

    Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
    return
}

function Convert-UniqueIDToHex {
    param(
        [Parameter(Mandatory = $true)][string]$UniqueID
    )
    $hex = ''
    foreach ($char in $UniqueID.ToCharArray()) {
        $hex += ([byte][char]$char).ToString('X2')
    }
    return $hex
}

Export-ModuleMember -Function Get-ProxmoxSolidFireStoragePool, Get-VgLvmIscsiMapping, Get-SolidFirePVENetworkSetting, Convert-UniqueIDToHex, New-ProxmoxSolidFireStoragePool, New-ProxmoxVolumeGroup, Get-ProxmoxVolumeGroup, Get-ProxmoxSolidFireStorageMap, Get-SFClusterIscsiTarget, Remove-ProxmoxVgLvm, Remove-ProxmoxIscsiPool
