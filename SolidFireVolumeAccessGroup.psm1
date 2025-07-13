function Get-SolidFireVag {
    param(
        [switch]$Silent
    )
    $expectedVagName = ($global:sfVolumePrefix) + ($global:sfClusterInfo.name).ToLower()
    $vagResult = (Invoke-SolidFireRestMethod -Method "ListVolumeAccessGroups" -Body @{}).result
    if (-not $vagResult.volumeAccessGroups) {
        Write-Host "No VAGs found" -ForegroundColor Yellow
        [void][System.Console]::ReadKey($true)
        Show-VolumeAccessGroupMenu
        return
    }
    elseif ($vagResult.volumeAccessGroups.Count -eq 0) {
        Write-SpectreHost "[Yellow]No VAGs found[/]"
        Write-SpectreHost "Press [Green]ANY[/] key to return to the menu." -AnyKey
        return
    }
    $vagFound = $vagResult.volumeAccessGroups | Where-Object { $_.Name -eq $expectedVagName }
    if ($null -eq $vagFound) {
        Write-SpectreHost -Message "[Yellow]No VAG named $expectedVagName found[/]"
        Write-SpectreHost -Message "If you already have a VAG for this PVE cluster, rename it in in SolidFire UI to: `n[Blue]$($expectedVagName)[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to the menu." -AnyKey
        return
    }
    $vagDisplay = $vagFound | ForEach-Object {
        [PSCustomObject]@{
            name                = $_.name
            volumeAccessGroupID = $_.volumeAccessGroupID
            initiatorIDsArray   = $_.initiatorIDs
            "volumesArray"      = $_.volumes
            initiatorIDs        = ($_.initiatorIDs -join ',')
            volumes             = ($_.volumes -join ',')
        }
    }
    if (-not $Silent) {
        $vagDisplay | Format-SpectreTable -Title "SolidFire VAG for PVE" -Property name, volumeAccessGroupID, initiatorIDsArray, volumesArray -Color Red -Width 78
    }
    if ($vagDisplay.initiatorIDsArray.Count -gt 0) {
        $initiators = Invoke-SolidFireRestMethod -Method "ListInitiators" -Body @{ initiators = $vagDisplay.initiatorIDsArray }
        $vagInitiators = $initiators.result.initiators | ForEach-Object {
            [PSCustomObject]@{
                Alias  = $_.alias
                ID     = $_.initiatorID
                Name   = $_.initiatorName     
                VagIDs = if ($_.volumeAccessGroups.Count -gt 0) { $_.volumeAccessGroups -join ',' } else { "" }
            }
        }
        $volumes = Invoke-SolidFireRestMethod -Method "ListVolumes" -Body @{ volumes = $vagDisplay.volumesArray }
        $vagVolumes = $volumes.result.volumes | Where-Object { $vagDisplay.volumesArray -contains $_.volumeID } | ForEach-Object {
            [PSCustomObject]@{
                Name   = $_.name
                ID     = $_.volumeID
                Size   = $_.totalSize / 1GB
                Status = $_.status
            }
        }      
    }
    if (-not $Silent) {
        if ($vagInitiators.Count -gt 0) {
            $vagInitiators | Format-SpectreTable -Title "SolidFire VAG Initiator Member Details" -Color Red -Property ID, Alias, Name, VagIDs -Width 78
        }
        if ($vagVolumes.Count -gt 0) {
            $vagVolumes | Format-SpectreTable -Title "SolidFire VAG Volume Member Details" -Color Red -Property ID, Name, Size, Status -Width 78
        }
        $initiatorCount = $vagDisplay.initiatorIDsArray.Count
        $volumeCount = $vagDisplay.volumesArray.Count
        Write-SpectreHost -Message "Firemox [Blue]VAG $($vagDisplay.name) has [Green]$initiatorCount[/] initiator(s) and [Green]$volumeCount[/] volume(s).[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to QoS Policies menu." -AnyKey
        return
    }
    else {
        return $vagFound
    }
    
}

function Add-SolidFireFiremoxVolumesToVag {
    $expectedVagName = ($global:sfVolumePrefix) + ($global:sfClusterInfo.name).ToLower()
    $vagResult = (Invoke-SolidFireRestMethod -Method "ListVolumeAccessGroups" -Body @{}).result
    if (-not $vagResult.volumeAccessGroups -or $vagResult.volumeAccessGroups.Count -eq 0) {
        Write-SpectreHost "[Yellow]No VAGs found[/]"
        Read-SpectrePause "Press [Green]ANY[/] key to return to the menu." -AnyKey
        return
    }
    else {
        Write-SpectreHost -Message "[Blue]Found [Geen]$($vagResult.volumeAccessGroups.Count)[/] VAGs[/]"
        $vagFound = $vagResult.volumeAccessGroups | Where-Object { $_.Name -eq $expectedVagName }
    }   
        
    if ($null -eq $vagFound) {
        Write-SpectreHost -Message "[Yellow]No VAG named $expectedVagName have been found[/]"
        Write-SpectreHost -Message "If you have a VAG for this PVE cluster, rename it to`n $expectedVagName"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to the menu." -AnyKey
        return
    }
    else {
        $answer = Read-SpectreConfirm -Message "Do you want to add all Firemox user's volumes to the VAG $expectedVagName?" -DefaultAnswer 'n'
        if ($answer -eq $false) {
            Write-SpectreHost -Message "[Yellow]No volumes added to VAG $expectedVagName[/]"
            Read-SpectrePause -Message "Press [Green]ANY[/] key to return to the menu." -AnyKey
            return
        }
        else {
            $msg = "Adding all Firemox user's volumes to VAG $expectedVagName"
            Write-SpectreHost -Message "[Green]$msg[/]"
            try {
                $firemoxVolumes = (Invoke-SolidFireRestMethod -Method "ListVolumesForAccount" -Body @{ accountID = $global:sfAccountId }).result.volumes
            }
            catch {
                Write-SpectreHost -Message "[Red]Failed to fetch Firemox user's volumes[/]"
                Read-SpectrePause -Message "Press [Green]ANY[/] key to return to the menu." -AnyKey
                return
            }
            if ($firemoxVolumes.Count -eq 0) {
                Write-SpectreHost -Message "[Yellow]No volumes found for Firemox user[/]"
                Read-SpectrePause -Message "Press [Green]ANY[/] key to return to the menu." -AnyKey
                return
            }
            Write-SpectreHost -Message "[Green]Found [Green]$($firemoxVolumes.Count)[/] volumes for Firemox user[/]"
            try {
                $volumesToAdd = @()
                $volumesToAdd = $firemoxVolumes | ForEach-Object { $_.volumeID }
                Invoke-SolidFireRestMethod -Method "AddVolumesToVolumeAccessGroup" -Body @{
                    volumeAccessGroupID = $vagFound.volumeAccessGroupID
                    volumes             = $volumesToAdd
                } | Out-Null
                Write-SpectreHost -Message "[Green]Successfully added all Firemox user's volumes to VAG $expectedVagName[/]"
            }
            catch {
                Write-SpectreHost -Message "[Red]Failed to add volumes to VAG $expectedVagName[/]"
                Read-SpectrePause -Message "Press [Green]ANY[/] key to return to the menu." -AnyKey
            }
        }
    }
}

function Add-SolidFireVagInitiatorsToVag {
    $expectedVagName = ($global:sfVolumePrefix) + ($global:sfClusterInfo.name).ToLower()
    $vagFound = Get-SolidFireVag -Silent
    if ($null -eq $vagFound) {
        Write-SpectreHost -Message "[Red]No VAG found for PVE cluster[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to the menu." -AnyKey
        return
    }
    $initiatorsObjList = (Invoke-SolidFireRestMethod -Method "ListInitiators" -Body @{}).result.initiators
    if ($initiatorsObjList.Count -eq 0) {
        Write-SpectreHost -Message "[Yellow]No initiators found for SolidFire VAG $expectedVagName[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to the menu." -AnyKey
        return
    }
    $initiatorsList = $initiatorsObjList | ForEach-Object {
        [PSCustomObject]@{
            initiatorID   = $_.initiatorID
            initiatorName = $_.initiatorName
            alias         = $_.alias
        }
    }
    $initiatorsList | Format-SpectreTable -Title "All SolidFire Initiators (not necessarily in Firemox VAG)" -Property initiatorID, initiatorName, alias -Color Red -Width 78
    $initiatorsList = $initiatorsList | ForEach-Object { "$($_.initiatorID) - $($_.initiatorName) ($($_.alias))" }
    $existingInitiators = $vagFound.initiatorIDs
    $initiatorsList = $initiatorsList | Where-Object { 
        $initiatorID = ($_ -split ' ')[0] -as [int]
        -not ($existingInitiators -contains $initiatorID)
    }
    $selectedInitiators = Read-SpectreMultiSelection -Message "Select initiators to add to VAG $expectedVagName" -Choices $initiatorsList
    if ($selectedInitiators.Count -eq 0) {
        Write-SpectreHost -Message "[Yellow]No initiators selected for VAG $expectedVagName[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to the menu." -AnyKey
        return
    }
    try {
        $initiatorIDsToAdd = $selectedInitiators | ForEach-Object { ($_ -split ' ')[0] -as [int] }
        Read-SpectrePause -Message "Press [Green]ANY[/] key to continue adding initiators to VAG $expectedVagName" -AnyKey
        $body = @{
            volumeAccessGroupID = $vagFound.volumeAccessGroupID
            initiators          = $initiatorIDsToAdd
        }
        $response = Invoke-SolidFireRestMethod -Method "AddInitiatorsToVolumeAccessGroup" -Body $body | Out-Null
        if ($response.error) {
            $errMsg = "Failed to add initiators to VAG $($expectedVagName): $($response.error.message)"
            Write-SpectreHost -Message "[Red]$errMsg[/]"
            Read-SpectrePause -Message "Press [Green]ANY[/] key to return to the menu." -AnyKey
            return
        }
        else {
            $msg = "Successfully added initiators $($initiatorIDsToAdd -join ', ') to VAG $expectedVagName"
            Write-SpectreHost -Message "[Green]$msg[/]"
        }         
    }
    catch {
        $msg = "Failed to add initiators to VAG $expectedVagName"
        Write-SpectreHost -Message "[Red]$msg[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to the menu." -AnyKey
    }
}

function New-SolidFireVag {
    $expectedVagName = ($global:sfVolumePrefix) + ($global:sfClusterInfo.name).ToLower()
    $existingVag = Get-SolidFireVag -Silent    
    if ($existingVag) {
        Write-SpectreHost -Message "[Blue]Existing SolidFire VAG Names[/]"
        $existingVag | ForEach-Object { Write-Host " - $($_.name)" }
        if ($existingVag.name -eq $expectedVagName) {
            Write-SpectreHost -Message "[Red]A VAG named $expectedVagName already exists[/]"
            Read-SpectrePause -Message "Press [Green]ANY[/] key to return to the menu." -AnyKey
            return
        }
        else {
            Write-SpectreHost -Message "[Yellow]Existing VAGs found, but not named $expectedVagName[/]"
        }
    }
    else {
        Write-SpectreHost -Message "[Yellow]No existing VAGs found[/]. Continue to create a new one using $expectedVagName."
    }
    $answer = Read-SpectreConfirm -Message "Do you want to create a new VAG named ($expectedVagName)?" -DefaultAnswer 'n'
    Write-SpectreHost -Message "[Yellow]Tip: For custom VAG name you may use the SolidFire UI.[/]"
    if ($answer -eq $false) {
        Write-SpectreHost -Message "[Yellow]No new VAG will be created[/]"
        Read-SpectrePause -Message "Press [Green]ANY[/] key to return to the menu." -AnyKey
        return
    }
    else {
        Write-SpectreHost -Message "[Green]Creating new VAG named ($expectedVagName)[/]"
        $body = @{
            name    = $expectedVagName
            volumes = $accountVolumes
        }
        $response = Invoke-SolidFireRestMethod -Method "CreateVolumeAccessGroup" -Body $body
        if ($response.error) {
            Write-SpectreHost -Message "[Red]Failed to create VAG: $($response.error.message)[/]"
        }
        else {
            Write-SpectreHost -Message "[Green]Successfully created VAG: $($response.result.volumeAccessGroupID)[/]"
            Write-SpectreHost -Message "[Yellow]Tip: to use this VAG in Proxmox, you need to add initiators and volumes to it. If they're also in another VAG, you may want to remove them.[/]"
        }
    }

}

Export-ModuleMember -Function Get-SolidFireVag, Add-SolidFireFiremoxVolumesToVag, Add-SolidFireVagInitiatorsToVag, New-SolidFireVag
