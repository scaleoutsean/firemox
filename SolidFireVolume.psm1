function Get-SolidFireVolume {
    param (
        [Parameter(Mandatory = $true)]
        [int]$sfAccountId,
        [Parameter(Mandatory = $false)][switch]$Silent = $false
    )
    try {
        $body = @{ accountID = $sfAccountId }
        $response = Invoke-SolidFireRestMethod -Method 'ListVolumesForAccount' -Body $body
    }
    catch {
        Write-SpectreHost -Message "[Red]Error calling Invoke-SolidFireRestMethod: $_[/]"
        exit 1
    }
    if (-not $response.result.volumes.Count -gt 0) {
        Write-SpectreHost -Message "[Yellow]No volumes returned. Have you set storage account ID (global:sfAccountId)? Create SolidFire storage tenant account.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to continue." -AnyKey
        return @()
    }
    else {
        $sfVolumes = $response.result.volumes | ForEach-Object {
            [PSCustomObject]@{
                Name         = $_.name
                VolumeId     = $_.volumeID
                Size         = [math]::Round($_.totalSize / 1GB, 2)
                QosPolicyId  = $_.qosPolicyID
                ScsiNaaDevId = $_.scsiNAADeviceID
                iqn          = $_.iqn
                Status       = $_.status
                AccountId    = $_.accountID
            }
        }
    }
    if (-not $Silent) {
        if ($sfVolumes) {
            $sfVolumes | Sort-Object -Property name | Format-SpectreTable -Title "SolidFire Volumes" -Expand -Color Red
            Read-SpectrePause -Message "Press [Green]ANY[/] key to continue." -AnyKey
            return @()
        }
        else {
            Write-SpectreHost -Message "[Yellow]No SolidFire volumes found for Proxmox VE account ID ${sfAccountId}.[/]"
            Read-SpectrePause -Message "Press [Green]ANY[/] key to continue." -AnyKey
            return @()
        }
    }
    else {
        return $sfVolumes
    }

}

function New-SolidFireVolume {
    param (
        [Parameter(Mandatory = $true)]
        [int]$sfAccountId,
        [Parameter(Mandatory = $false)]
        [string]$volumeName = ""
    )
    $numberOfVolumes = Read-SpectreText -Prompt "Enter the number of volumes to create (1-4). Press ENTER or 1 to use 1 volume, 'n' to return" `
        -DefaultAnswer 1 -TimeoutSeconds 30 -Choices @("1", "2", "3", "4", "n")
    if ($numberOfVolumes -eq '') {
        Write-SpectreHost -Message "[Yellow]No input provided. Defaulting to 1 volume.[/]"
        $numberOfVolumes = 1
    }
    elseif ($numberOfVolumes -eq 'n' -or $numberOfVolumes -eq 'N') {
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to Volumes menu." -AnyKey
        return
    }
    elseif (-not [int]::TryParse($numberOfVolumes, [ref]$null)) {
        Write-SpectreHost -Message "[Red]Invalid input.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to Volumes menu." -AnyKey
        return
    }

    $highestVolumeId = Get-SolidFireVolumeIdSuffix -Body @{ accountID = $sfAccountId }
    $nextVolumeId = $highestVolumeId + 1
    $Global:sfClusterName = ($Global:sfClusterName).ToLower()
    if (-not $Global:sfVolumePrefixOriginal) {
        $Global:sfVolumePrefixOriginal = $Global:sfVolumePrefix
    }
    $Global:sfVolumePrefix = $Global:sfVolumePrefixOriginal.TrimEnd('-')
    $namePattern = $Global:sfVolumePrefix + '-' + $Global:sfClusterName
    $namePattern = $namePattern.TrimEnd('-') # No trailing hyphen
    $namePatternOK = Read-SpectreText -Message "Enter [Green]Y[/] or [Green]ENTER[/] to use suggested volume name pattern (suffixed by an incrementing 3-digit integer) (Y/n): [Green]$namePattern-[/]" `
        -DefaultAnswer 'Y' -TimeoutSeconds 30 -Choices @('Y', 'N')
    if ($namePatternOK -eq 'Y' -or $namePatternOK -eq 'y' -or $namePatternOK -eq '') {
        $Global:sfVolumePrefix = $namePattern
    }
    else {
        $customName = Read-SpectreText -Message "Enter [Yellow]custom[/] volume name prefix. Start with a letter. Letters, numbers and -'s are allowed." `
            -DefaultAnswer $namePattern -TimeoutSeconds 30
        $customName = $customName.Trim().TrimEnd('-')
        if ($customName -notmatch '^[a-zA-Z][a-zA-Z0-9-]*$') {
            Write-SpectreHost -Message "[Red]Invalid custom name. It must start with a letter and can contain letters, numbers, and hyphens.[/]"
            $Global:sfVolumePrefix = $namePattern
        }
        else {
            $namePatternOK = Read-Host "You entered: ${customName}. Is this correct? (Y/n)"
            if ($namePatternOK -eq 'Y' -or $namePatternOK -eq 'y' -or $namePatternOK -eq '') {
                Write-SpectreHost -Message "[Green]Using custom volume name prefix: ${customName}[/]"
            }
            else {
                Write-SpectreHost -Message "[Yellow]Leave function without creating volumes.[/] "
                Read-SpectrePause -Message "Press [Green]ANY[/] key to return." -AnyKey
                return
            }
            $Global:sfVolumePrefix = $customName.TrimEnd('-')
        }
    }

    $volumesCreated = @()
    for ($i = $nextVolumeId; $i -lt $nextVolumeId + $numberOfVolumes; $i++) {
        $name = $($Global:sfVolumePrefix) + '-' + $($i.ToString().PadLeft(3, '0'))
        $volumeSizeGiB = Read-SpectreText -Message "Enter [Green]size[/] for volume $($name) in GiB (default is 1 GiB)" -DefaultAnswer 1 -TimeoutSeconds 10
        if (-not [int]::TryParse($volumeSizeGiB, [ref]$null) -or [int]$volumeSizeGiB -lt 1) {
            Write-SpectreHost -Message "[Red]Invalid volume size input. Initial volume size must be at least 1 (GiB).[/]"
            $volumeSizeGiB = Read-SpectreText -Message "Enter volume size in GiB (default is 1 GiB)"
            if (-not [int]::TryParse($volumeSizeGiB, [ref]$null) -or [int]$volumeSizeGiB -lt 1) {
                $volumeSizeGiB = 1
            }
        }
        $existingQosPolicyIds = (Invoke-SolidFireRestMethod -Method 'ListQoSPolicies' -Body @{}).result.qosPolicies | ForEach-Object { $_.qosPolicyID }
        $qosPolicyId = 0
        $qosPolicyId = Read-SpectreText -Message "Enter [Green]QoS policy ID[/] (integer) for volume $name (default is 0, which means no QoS policy)." `
            -DefaultAnswer 0 -TimeoutSeconds 10 -Choices $existingQosPolicyIds
        if (-not [int]::TryParse($qosPolicyId, [ref]$null
            ) -or [int]$qosPolicyId -lt 0) {
            Write-SpectreHost -Message "[Red]Invalid QoS policy ID input. ID must be a non-negative integer.[/]"
            $qosPolicyId = Read-Host "Enter QoS policy ID (positive integer of a valid QoS policy ID or 0. Default: 0):"
            if (-not [int]::TryParse($qosPolicyId, [ref]$null
                ) -or [int]$qosPolicyId -lt 0) {
                $qosPolicyId = 0
            }
        }
        $volumeSizeGiB = [int]$volumeSizeGiB
        $totalSize = [int64]($volumeSizeGiB * 1024 * 1024 * 1024)
        Write-SpectreHost -Message "Creating SolidFire volume: [green]name: ${name}[/], [green]size: ${volumeSizeGiB} GiB[/], [green]QoS policy ID: ${qosPolicyId}[/]"

        if (($qosPolicyId -eq 0) -or ($null -eq $qosPolicyId)) {
            $body = @{
                name                   = $name
                accountID              = $sfAccountId
                totalSize              = $totalSize
                associateWithQoSPolicy = $false
                enable512e             = $false
            }
        }
        else {
            $body = @{
                name                   = $name
                accountID              = $sfAccountId
                totalSize              = $totalSize
                qosPolicyID            = $qosPolicyId
                associateWithQoSPolicy = $true
                enable512e             = $false
            }
        }
        try {
            $response = Invoke-SolidFireRestMethod -Method 'CreateVolume' -Body $body
            if ($response -and $response.result -and $response.result.volumeID) {
                $volumesCreated += $response.result.volumeID
                Write-SpectreHost -Message "[Green]Successfully created volume $name (ID: $($response.result.volumeID))[/]"
                Write-SpectreHost -Message "[Cyan]$($volumesCreated.count) volume(s) created so far: $($volumesCreated -join ', ')[/]"
            }
            else {
                Write-SpectreHost -Message "[Red]Failed to create volume $name[/]"
                Write-SpectreHost -Message "[Red]Response: $($response | ConvertTo-Json -Depth 4)[/]"
            }
        }
        catch {
            Write-SpectreHost -Message "[Red]Error calling Invoke-SolidFireRestMethod: $_[/]"
        }
    }

    if ($volumesCreated.Count -gt 0) {
        Write-SpectreHost -Message "[Green]Successfully created SolidFire volumes: $($volumesCreated -join ', ')[/]"
        Write-SpectreHost -Message "[Yellow]Volumes have been created, but not added to VAG.[/]"
    }
    else {
        Write-SpectreHost -Message "[Red]No volumes have been created.[/]"
    }
    Read-SpectrePause -Message "Press [Green]ANY[/] key to return to Volumes menu." -AnyKey
    return
}

function Remove-SolidFireVolume {
    param (
        [Parameter(Mandatory = $true)]
        [int]$sfAccountId
    )
    Write-SpectreFigletText -Text "SENSITIVE OPERATION" -Alignment "Center" -Color "Red"
    Write-SpectreRule -Title "[Red]:warning:[/] Read before proceeding [red]:warning:[/]" -Alignment Center -Color Yellow
    Write-SpectreHost -Message "This is a destructive operation that can go wrong in many ways (e.g. if [orange3]PVE[/] is still using the volume) :bomb:"
    Write-SpectreHost -Message "Make sure volumes you are removing have been cleaned from VG/LVM data and removed from PVE iSCSI storage pool."
    Write-SpectreRule -Title "" -Alignment Center -Color Yellow

    $volumes = Get-SolidFireVolume -sfAccountId $sfAccountId -Silent | Where-Object { $_.Status -ne 'deleted' }
    if (-not $volumes -or $volumes.Count -eq 0) {
        Write-SpectreHost -Message "[Yellow]No SolidFire volumes found for account ID $sfAccountId.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to Volumes menu." -AnyKey
        return
    }
    else {
        Write-SpectreHost -Message "[Green]SolidFire volumes for account ID ${sfAccountId}:[/]"
        $volumes | Format-SpectreTable -Title "SolidFire Volumes" -Expand -Color Red
    }
    $volumeId = Read-Host "Enter the volume ID to remove. First ensure PVE LVM/VG _and_ iSCSI pool have been removed on PVE. You may enter multiple values (up to 4, either space- or comma-delimited)"
    $volumeIds = $volumeId -split '[,\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if ($volumeIds.Count -eq 0) {
        Write-SpectreHost -Message "[Yellow]No valid volume IDs provided. Returning to Volumes menu.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to Volumes menu." -AnyKey
        return
    }
    $volumesToRemove = @()
    foreach ($id in $volumeIds) {
        $volume = $volumes | Where-Object { $_.VolumeId -eq $id }
        if ($volume) {
            $volumesToRemove += $volume
        }
        else {
            Write-SpectreHost -Message "[Red]Volume ID $id not found for account ID $sfAccountId.[/]"
            Read-SpectrePause -Message "Press [green]ANY[/] key to return to Volumes menu." -AnyKey
        }
    }

    if ($volumesToRemove.Count -eq 0) {
        Write-SpectreHost -Message "[Red]No valid volumes selected for removal.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to Volumes menu." -AnyKey
        return
    }

    foreach ($volume in $volumesToRemove) {
        try {
            $body = @{
                volumeID = $volume.VolumeId
            }
            $response = Invoke-SolidFireRestMethod -Method 'DeleteVolume' -Body $body
            if ($response -and $null -ne $response.result) {
                Write-SpectreHost -Message "[Green]Successfully removed volume:[/] $($volume.Name) (ID: $($volume.VolumeId))"
            }
            else {
                Write-SpectreHost -Message "[Red]Failed to remove volume:[/] $($volume.Name) (ID: $($volume.VolumeId))"
                Write-SpectreHost -Message "[Yellow]Response:[/] $($response | ConvertTo-Json -Depth 4)"
            }
        }
        catch {
            Write-SpectreHost -Message "[Red]Error removing volume:[/] $($volume.Name) (ID: $($volume.VolumeId)): $_"
            Write-SpectreHost -Message "[Yellow]Response:[/] $($response | ConvertTo-Json -Depth 4)"
        }
    }
    Read-SpectrePause -Message "Press [green]ANY[/] key to return to Volumes menu." -AnyKey
    return
}

function Remove-SolidFireDeletedVolume {
    param (
        [Parameter(Mandatory = $true)]
        [int]$sfAccountId
    )

    Write-SpectreFigletText -Text "SENSITIVE OPERATION" -Alignment "Center" -Color "Red"
    Write-SpectreRule -Title "[Red]:warning:[/] Read before proceeding [red]:warning:[/]" -Alignment Center -Color Yellow
    Write-SpectreHost -Message "This is a destructive operation that purges [Red]ALL[/] deleted SolidFire volumes :bomb:"
    Write-SpectreHost -Message "Make sure these volumes are no longer referenced by [Orange3]PVE[/] iSCSI storage pool."
    Write-SpectreRule -Title "" -Alignment Center -Color Yellow

    $confirm = Read-SpectreConfirm -Message "Are you sure you want to purge all deleted SolidFire volumes for account ID $sfAccountId?" `
        -DefaultAnswer 'n' -TimeoutSeconds 10
    if (-not $confirm) {
        Write-SpectreHost -Message "[Yellow]Operation cancelled. Returning to Volumes menu.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to Volumes menu." -AnyKey
        return
    }
    $result = Get-SolidFireVolume -sfAccountId $sfAccountId -Silent | Where-Object { $_.Status -eq 'deleted' }
    if ($result.Count -eq 0) {
        Write-SpectreHost -Message "[Yellow]No deleted volumes found for account ID $sfAccountId.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to Volumes menu." -AnyKey
        return
    }
    else {
        Write-SpectreHost -Message "[Green]Preparing to purge all deleted SolidFire volumes for account ID ${sfAccountId}:[/]"
        $result | Format-SpectreTable -Title "Deleted SolidFire Volumes" -Expand -Color Red
        $deletedVolumeIds = @()
        $result | ForEach-Object {
            $deletedVolumeIds += $_.VolumeId
        }
        $body = @{
            volumeIDs = $deletedVolumeIds
        }
        $result = Invoke-SolidFireRestMethod -Method 'PurgeDeletedVolumes' -Body $body
        if ($result -and $null -ne $result.result) {
            Write-SpectreHost -Message "[Green]Successfully purged deleted volumes for account ID $sfAccountId.[/]"
        }
        else {
            Write-SpectreHost -Message "[Red]Failed to purge deleted volumes for account ID $sfAccountId.[/]"
        }
        Write-SpectreHost -Message ""
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to Volumes menu." -AnyKey
        return
    }
    return
}

function Get-SolidFireVolumeIdSuffix {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Body
    )
    $volumes = (Invoke-SolidFireRestMethod -Method 'ListVolumesForAccount' -Body $Body).result.volumes
    $idSuffixes = @()
    foreach ($volume in $volumes) {
        if ($volume.name -match '-(\d+)$') {
            $suffixStr = $matches[1]
            $suffixStr = $suffixStr.TrimStart('0')
            $suffixInt = [int]$suffixStr
            $idSuffixes += $suffixInt
        }
    }
    if ($idSuffixes.Count -gt 0) {
        $maxSuffix = ($idSuffixes | Sort-Object -Descending | Select-Object -First 1)
        return [int]$maxSuffix
    }
    else {
        Write-SpectreHost -Message "[Yellow]No volumes found for account ID $sfAccountId. Returning 0.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to Volumes menu." -AnyKey
        return 0
    }
}

function Set-SolidFireVolume {
    param (
        [Parameter(Mandatory = $true)]
        [int]$sfAccountId
    )
    $volumes = Get-SolidFireVolume -sfAccountId $sfAccountId -Silent |
        Where-Object Status -NE 'deleted'
    if (-not $volumes) {
        Write-SpectreHost -Message "[Yellow]No volumes available to modify.[/]"
        return
    }
    $volumes | Format-SpectreTable -Title "Available Volumes" -Expand -Color Red

    $inputVolumeIDs = Read-SpectreText -Message "Enter one or more Volume IDs (comma- or space-delimited)" -DefaultAnswer "" -TimeoutSeconds 30 -AllowEmpty
    $ids = $inputVolumeIDs -split '[,\s]+' | Where-Object { $_ }

    foreach ($id in $ids) {
        Write-SpectreHost -Message "`n[Cyan]Processing Volume ID: $($id)[/]`n"
        $vol = $volumes | Where-Object { $_.volumeID -eq [int]$id }
        if (-not $vol) {
            Write-SpectreHost -Message "[Red]Volume ID $($id) not found.[/]"
            continue
        }
        else {
            Write-SpectreHost -Message "[Green]Volume ID $($id) found.[/]"
        }

        $newSize = Read-Host "New size GiB for $id (blank to skip)"
        if ($newSize -and [int]::TryParse($newSize, [ref]0)) {
            $bytes = [int64]([int]$newSize * 1GB)
            $null = Invoke-SolidFireRestMethod -Method 'ModifyVolume' -Body @{
                volumeID  = $id
                totalSize = $bytes
            }
            Write-SpectreHost -Message "[green]Volume $($id) resized to $($newSize) GiB.[/]"
        }

        $newQos = Read-Host "New QoS Policy ID for $id (blank to skip)"
        if ($newQos -and [int]::TryParse($newQos, [ref]0)) {
            $null = Invoke-SolidFireRestMethod -Method 'ModifyVolume' -Body @{
                volumeID    = $id
                qosPolicyID = [int]$newQos
            }
            Write-SpectreHost -Message "[green]Volume QoS for $($id) set to $($newQos).[/]"
        }
    }

    Read-SpectrePause -Message "Press [green]ANY[/] key to return to Volumes menu." -AnyKey
    return
}

function Add-SolidFireVolumeToSnapshotSchedule {
    $body = @{}
    $schedules = (Invoke-SolidFireRestMethod -Method 'ListSchedules' -Body $body).result.schedules

    $schedules = $schedules | Where-Object { $_.scheduleType -eq 'snapshot' }
    if (-not $schedules -or $schedules.Count -eq 0) {
        Write-SpectreHost -Message "[Yellow]No snapshot schedules found.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to Volumes menu." -AnyKey
        return
    }
    $table = $schedules | ForEach-Object {
        [PSCustomObject]@{
            scheduleID    = $_.scheduleID
            scheduleName  = $_.scheduleName
            groupSnapshot = ($_.scheduleInfo.volumes.Count -gt 1)
            volumes       = if ($_.scheduleInfo.volumeID) { @([int]$_.scheduleInfo.volumeID) }
            elseif ($_.scheduleInfo.volumes) { [int[]]$_.scheduleInfo.volumes }
            else { @() }
        }
    }

    $table | Format-SpectreTable -Title "Snapshot Schedules" -Expand -Color turquoise2
    $selectedId = Read-SpectreSelection -Title "Select a snapshot schedule to add volumes to" -Choices ($table | ForEach-Object { "$($_.scheduleID): $($_.scheduleName)" }) -Color Turquoise2
    $selectedSchedule = $schedules | Where-Object { $_.scheduleID -eq ($selectedId -split ':')[0].Trim() }
    if (-not $selectedSchedule) {
        Write-SpectreHost -Message "[Red]Invalid selection. Please select a valid snapshot schedule.[/]"
        [void][System.Console]::ReadKey($true)
        return
    }
    Write-SpectreHost -Message "[Green]Selected snapshot schedule: $($selectedSchedule.scheduleName) (ID: $($selectedSchedule.scheduleID))[/]"
    Read-SpectrePause -Message "Press [Green]ANY[/] key to continue." -AnyKey

    $volumes = Get-SolidFireVolume -sfAccountId $sfAccountId -Silent |
        Where-Object Status -NE 'deleted'
    if (-not $volumes) {
        Write-SpectreHost -Message "[Red]No volumes available to add to snapshot schedule.[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to Snapshot Schedules menu." -AnyKey
        return
    }
    $volumes | Format-SpectreTable -Title "Available Volumes" -Expand -Color turquoise2

    $inputVolumeIDs = Read-SpectreText -Message "Enter one or more Volume IDs (comma- or space-delimited)" -DefaultAnswer "" -TimeoutSeconds 30 -AllowEmpty
    $ids = $inputVolumeIDs -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ }

    foreach ($id in $ids) {
        $isInAnySchedule = $schedules | Where-Object {
            ($_.scheduleInfo.volumeID -and [int]$_.scheduleInfo.volumeID -eq $id) -or
            ($_.scheduleInfo.volumes -and ($_.scheduleInfo.volumes -contains $id))
        }
        if ($isInAnySchedule) {
            Write-SpectreHost -Message "[Red]Volume ID $id is already in another snapshot schedule. A volume can only be in one schedule at a time.[/]"
            Write-SpectreHost -Message "[Yellow]Select a volume or volumes that are not already in any snapshot schedule. Entire snapshot schedules can be deleted from the SolidFire UI.[/]"
            Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
            return
        }
    }

    foreach ($id in $ids) {
        $vol = $volumes | Where-Object { $_.volumeID -eq [int]$id }
        if (-not $vol.volumeID) {
            Write-SpectreHost -Message "[Red]Volume ID $id not found among SolidFire volumes owned by account ID $($global:sfAccountId).[/]"
            Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
            return
        }

        Write-SpectreHost -Message "[green]Adding volume $id to snapshot schedule $($selectedSchedule.name) (ID: $($selectedSchedule.scheduleID))...[/]"

        $existingVolumes = @()
        if ($selectedSchedule.scheduleInfo.volumeID) {
            $existingVolumes = @([int]$selectedSchedule.scheduleInfo.volumeID)
        }
        elseif ($selectedSchedule.scheduleInfo.volumes) {
            $existingVolumes = [int[]]$selectedSchedule.scheduleInfo.volumes
        }
        $newVolumes = $existingVolumes + [int]$id | Select-Object -Unique
        $body = @{
            scheduleID   = $selectedSchedule.scheduleID
            scheduleInfo = @{
                volumes = $newVolumes
            }
        }
        $null = Invoke-SolidFireRestMethod -Method 'ModifySchedule' -Body $body
        Write-SpectreHost -Message "[Green]Added volume $id to snapshot schedule $($selectedSchedule.scheduleName).[/]"
    }
    Read-SpectrePause -Message "Press [Green]ANY[/] key to return to Volumes menu." -AnyKey
    return
}

function Remove-SolidFireVolumeFromSnapshotSchedule {
    $body = @{}
    $schedules = (Invoke-SolidFireRestMethod -Method 'ListSchedules' -Body $body).result.schedules
    $schedules = $schedules | Where-Object { $_.scheduleType -eq 'snapshot' }
    if (-not $schedules -or $schedules.Count -eq 0) {
        Write-SpectreHost -Message "[Yellow]No snapshot schedules found.[/] "
        Read-SpectrePause -Message "Press [green]ANY[/] key to return to Volumes menu." -AnyKey
        return
    }
    $table = $schedules | ForEach-Object {
        [PSCustomObject]@{
            scheduleID    = $_.scheduleID
            scheduleName  = $_.scheduleName
            groupSnapshot = ($_.scheduleInfo.volumes.Count -gt 1)
            volumes       = if ($_.scheduleInfo.volumeID) { @([int]$_.scheduleInfo.volumeID) }
            elseif ($_.scheduleInfo.volumes) { [int[]]$_.scheduleInfo.volumes }
            else { @() }
        }
    }

    $table | Format-SpectreTable -Title "Snapshot Schedules" -Expand -Color turquoise2
    $selectedId = Read-SpectreSelection -Title "Select a snapshot schedule to add volumes to" -Choices ($table | ForEach-Object { "$($_.scheduleID): $($_.scheduleName)" }) -Color Turquoise2
    $selectedSchedule = $schedules | Where-Object { $_.scheduleID -eq ($selectedId -split ':')[0].Trim() }
    if (-not $selectedSchedule) {
        Write-SpectreHost -Message "[Yellow]No schedule selected. Returning to Volumes menu.[/] "
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to QoS Policies menu." -AnyKey
        return
    }
    Write-SpectreHost -Message "[Green]Selected snapshot schedule: $($selectedSchedule.scheduleName) (ID: $($selectedSchedule.scheduleID))[/]"
    Read-SpectrePause -Message "Press [Green]ANY[/] key to continue." -AnyKey
    $volumes = Get-SolidFireVolume -sfAccountId $sfAccountId -Silent |
        Where-Object Status -NE 'deleted'
    if (-not $volumes) {
        Write-SpectreHost -Message "[Yellow]No volumes available to add to snapshot schedule.[/] "
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to Volumes menu." -AnyKey
        return
    }
    $volumes | Format-SpectreTable -Title "Available Volumes" -Expand -Color turquoise2

    $input = Read-SpectreText -Message "Enter one or more Volume IDs (comma- or space-delimited)" -DefaultAnswer "" -TimeoutSeconds 30 -AllowEmpty
    $ids = $input -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ }

    foreach ($id in $ids) {
        $isInAnySchedule = $schedules | Where-Object {
            ($_.scheduleInfo.volumeID -and [int]$_.scheduleInfo.volumeID -eq $id) -or
            ($_.scheduleInfo.volumes -and ($_.scheduleInfo.volumes -contains $id))
        }
        if (-not $isInAnySchedule) {
            Write-SpectreHost -Message "[Yellow]Volume ID $id is not part of any snapshot schedule. Nothing to remove.[/] "
            Write-SpectreHost -Message "[Yellow]Select a volume or volumes that are already in a snapshot schedule. The last volume in a schedule cannot be removed. You would have to delete the schedule from the SolidFire UI.[/] "
            Read-SpectrePause -Message "Press [Green]ANY[/] key to return to QoS Policies menu." -AnyKey
            return
        }
    }

    foreach ($id in $ids) {
        $vol = $volumes | Where-Object { $_.volumeID -eq [int]$id }
        if (-not $vol.volumeID) {
            Write-SpectreHost -Message "[Red]Volume ID $id not found among SolidFire volumes owned by account ID $($global:sfAccountId).[/] "
            Read-SpectrePause -Message "Press [Green]ANY[/] key to return to QoS Policies menu." -AnyKey
            return
        }

        $existingVolumes = @()
        if ($selectedSchedule.scheduleInfo.volumeID) {
            $existingVolumes = @([int]$selectedSchedule.scheduleInfo.volumeID)
        }
        elseif ($selectedSchedule.scheduleInfo.volumes) {
            $existingVolumes = [int[]]$selectedSchedule.scheduleInfo.volumes
        }

        if (-not ($existingVolumes -contains [int]$id)) {
            Write-SpectreHost -Message "[Yellow]Volume ID $id is not part of the current schedule. Nothing to remove.[/] "
            Read-SpectrePause -Message "Press [Green]ANY[/] key to return to QoS Policies menu." -AnyKey
            return
        }

        if ($existingVolumes.Count -gt 2) {
            $newVolumes = $existingVolumes | Where-Object { $_ -ne [int]$id }
            $body = @{
                scheduleID   = $selectedSchedule.scheduleID
                scheduleInfo = @{
                    volumes = $newVolumes
                }
            }
            Invoke-SolidFireRestMethod -Method 'ModifySchedule' -Body $body
            Write-SpectreHost -Message "[Green]Removed volume $id from snapshot schedule $($selectedSchedule.scheduleName).[/] "
            Read-SpectrePause -Message "Press [Green]ANY[/] key to return to QoS Policies menu." -AnyKey
            return
        }
        elseif ($existingVolumes.Count -eq 2) {
            $remaining = ($existingVolumes | Where-Object { $_ -ne [int]$id })[0]
            $body = @{
                scheduleID   = $selectedSchedule.scheduleID
                scheduleInfo = @{
                    volumeID = [string]$remaining
                }
            }
            $null = Invoke-SolidFireRestMethod -Method 'ModifySchedule' -Body $body
            Write-SpectreHost -Message "[Green]Removed volume $id. Only one volume remains in the schedule.[/] "
            Read-SpectrePause -Message "Press [Green]ANY[/] key to return to QoS Policies menu." -AnyKey
            return
        }
        elseif ($existingVolumes.Count -eq 1) {
            Write-SpectreHost -Message "[Yellow]Cannot remove the last volume from a schedule. Delete the schedule or the volume from the SolidFire UI.[/] "
            Read-SpectrePause -Message "Press [Green]ANY[/] key to return to QoS Policies menu." -AnyKey
            return
        }
    }
    Read-SpectrePause -Message "Press [Green]ANY[/] key to return to QoS Policies menu." -AnyKey
    return

}

function Get-SolidFireAccountStorageEfficiency {
    $result = (Invoke-SolidFireRestMethod -Method 'GetAccountEfficiency' -Body @{ "accountID" = $global:sfAccountId }).result
    $compression = [math]::Round($result.compression, 2)
    $deduplication = [math]::Round($result.deduplication, 2)
    $efficiency = [math]::Round($compression * $deduplication, 2)
    $thinProvisioning = [math]::Round($result.thinProvisioning, 2)
    $tableData = @(
        [PSCustomObject]@{
            Compression         = $compression
            Deduplication       = $deduplication
            "Efficiency (CxD)"  = $efficiency
            "Thin Provisioning" = $thinProvisioning
        }
    )
    $compressionColor = if ($compression -lt 1.3) { "Red" } elseif ($compression -lt 1.6) { "Yellow" } else { "Green" }
    $deduplicationColor = if ($deduplication -lt 1.3) { "Red" } elseif ($deduplication -lt 1.6) { "Yellow" } else { "Green" }
    $overallEfficiencyColor = if ($efficiency -lt 2) { "Red" } elseif ($efficiency -lt 2.5) { "Yellow" } else { "Green" }

    $data = @()
    $data += New-SpectreChartItem -Label "Compression" -Value $compression -Color $compressionColor
    $data += New-SpectreChartItem -Label "Deduplication" -Value $deduplication -Color $deduplicationColor
    $data += New-SpectreChartItem -Label "Efficiency (CxD)" -Value $efficiency -Color $overallEfficiencyColor
    $chartLabel = "SolidFire Storage Efficiency (Account ID: $($global:sfAccountId))"

    $tableData | Format-SpectreTable -Title $chartLabel -Color "Orange1" -Expand -Width 78
    Format-SpectreBarChart -Data $data -Width 78
    Write-Host ""
    Write-SpectreHost -Message "[Yellow]Tip: SolidFire storage efficiency is updated hourly, after Garbage Collection runs at the top of the hour :recycling_symbol:[/]"
    Read-SpectrePause -Message "Press [Green]ANY[/] key to return to Volumes menu." -AnyKey
    return
}

Export-ModuleMember -Function Get-SolidFireVolume, New-SolidFireVolume, Set-SolidFireVolume, Remove-SolidFireVolume, Remove-SolidFireDeletedVolume, Remove-SolidFireVolumeFromSnapshotSchedule, Add-SolidFireVolumeToSnapshotSchedule, Get-SolidFireAccountStorageEfficiency
