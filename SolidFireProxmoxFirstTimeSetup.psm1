function New-SolidFireStorageAccount {
    Get-SolidFireTenant
    $proceedChoice = Read-SpectreSelection -Choices @("Return", "Set existing", "Create new") -Title "How do you want to proceed?"
    if ($proceedChoice -eq 'Return') {
        return
    }
    elseif ($proceedChoice -eq 'Set existing') {
        $global:sfAccountId = Read-Host "Enter existing SolidFire tenant account ID"
        Write-SpectreHost -Message "[Yellow]You can ignore the next question - it is for users who manage multiple PVE DCs. Do not change if you are not one of such users.[/]"
        $prefixChoice = Read-SpectreSelection -Choices @("No change", "Set custom prefix") -Title "Do you want to use the default volume prefix or set a custom one?"
        if ($prefixChoice -eq 'Set custom prefix') {
            $global:sfVolumePrefix = Read-Host "Enter custom volume prefix"
        }
        else {
            Write-SpectreHost -Message "Leaving default volume prefix in place"
            Start-Sleep -Seconds 1
        }
        return
    }
    elseif ($proceedChoice -eq 'Create new') {
        $sfAccountName = Read-Host "Enter SolidFire tenant account name (recommended: use Proxmox datacenter name)"
        $sfAccountPassPlain = Read-Host "Enter SolidFire account and iSCSI CHAP password (12-16 characters)"
        Write-SpectreHost -Message "CHAP password length: $($sfAccountPassPlain.Length)"
        $chapLength = if ([string]::IsNullOrEmpty($sfAccountPassPlain)) { 0 } else { $sfAccountPassPlain.Length }
        if ($chapLength -lt 12 -or $chapLength -gt 16) {
            Write-SpectreHost -Message "[Red]Failed to create SolidFire storage account: chapSecret must be between 12 and 16 characters in length[/]"
            return
        }
    }
    $body = @{
        "username"        = $sfAccountName
        "initiatorSecret" = $sfAccountPassPlain
        "enableChap"      = $true
        "attributes"      = @{
            "proxmox" = $true
        }
    }
    $response = Invoke-SolidFireRestMethod -Method "AddAccount" -Body $body
    if ($response.result.accountID) {
        Write-SpectreHost -Message "[green]SolidFire storage account created successfully. Edit your environment variables or script to use this account ID.[/]"
        Write-SpectreHost -Message "Account Name: $($response.result.account.username)"
        Write-SpectreHost -Message "Account ID: $($response.result.accountID)"
        Write-SpectreHost -Message "CHAP enabled: $($response.result.account.enableChap)"
        $showPass = Read-Host "Display the CHAP password? (y/N)"
        if ($showPass -eq 'y' -or $showPass -eq 'Y') {
            Write-SpectreHost -Message "[Yellow]CHAP Password: $sfAccountPassPlain[/]"
        }
        . "$PSScriptRoot/SolidFireProxmoxFirstTimeSetup.psm1"
        Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
        return
    }
    else {
        if ($response.error -and $response.error.message) {
            Write-SpectreHost -Message "[Red]Failed to create SolidFire storage account: $($response.error.message)[/]"
        }
        else {
            Write-SpectreHost -Message "[Red]Failed to create SolidFire storage account. Raw response:[/]"
            Write-SpectreHost -Message ($response | ConvertTo-Json -Depth 4)
        }
        Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
        return
    }
}

function Get-SolidFireTenant {
    param(
        [switch]$Silent
    )
    $sfAccounts = (Invoke-SolidFireRestMethod -Method "ListAccounts" -Body @{}).result.accounts
    if ($sfAccounts.Count -gt 0) {
        if (-not $Silent) {
            Write-SpectreHost -Message "SolidFire Tenants"
            $tenantList = @()
            foreach ($account in $sfAccounts) {
                $tenantList += [pscustomobject]@{
                    ID   = $account.accountID
                    Name = $account.username
                }
            }
            Format-SpectreTable -Title "SolidFire Storage Tenants" -Data $tenantList -Width 78
        }
        else {
            return $sfAccounts
        }
    }
    else {
        if (-not $Silent) {
            Write-SpectreHost -Message "[Yellow]No SolidFire tenants found.[/]"
            Write-SpectreHost -Message "[Yellow]Response:[/]"
            Write-SpectreHost -Message ($sfAccounts | ConvertTo-Json -Depth 4)
            $null = Read-Host "Press any key to continue"
        }
        else {
            return $null
        }
    }
}

function Set-ProxmoxIscsiClient {
    Write-SpectreHost -Message "[Yellow]The way this function works is: (1) you must know your SolidFire tenant account name or ID and you must have just one active volume not yet used by Proxmox VE, and (2) your PVE nodes' iSCSI service must not be in use.[/]"
    Write-SpectreHost -Message "[Red]This command provides copy-paste commands to run on all PVE nodes, but they will break your existing iSCSI configuration if it's not exactly the same as the new one.[/]"
    $accounts = Get-SolidFireTenant -Silent
    $account = $accounts | Where-Object { $_.accountID -eq $global:sfAccountId } | Select-Object -First 1

    if ($account -and $account.enableChap) {
        $sfAccountPassword = $account.initiatorSecret
        $sfAccountName = $account.username
    }
    elseif (-not $account.enableChap) {
        Write-SpectreHost -Message "[Red]SolidFire account does not have CHAP enabled. Please enable CHAP for the account first.[/]"
        Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
        return
    }
    $body = @{
        "accountID" = $global:sfAccountId
    }
    $volumes = Invoke-SolidFireRestMethod -Method "ListVolumesForAccount" -Body $body
    $volumes.result.volumes = $volumes.result.volumes | Where-Object { $_.status -eq 'active' }
    if ($volumes.result.volumes.Count -eq 0) {
        Write-SpectreHost -Message "[Red]No active volumes found for account ID $sfAccountId. Please create at least one volume first and come back after that.[/]"
        Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
        return
    }
    elseif ($volumes.result.volumes.Count -eq 1) {
        $name = $volumes.result.volumes[0].name
        $iqn = $volumes.result.volumes[0].iqn
        $volumeID = $volumes.result.volumes[0].volumeID
    }
    elseif ($volumes.result.volumes.Count -gt 1) {
        Write-SpectreHost -Message "[Yellow]Multiple active volumes found for account ID $sfAccountId. Please specify which volume to use.[/]"
        $volumeList = $volumes.result.volumes | ForEach-Object {
            [pscustomobject]@{
                Name = $_.name
                ID   = $_.volumeID
            }
        }
        Format-SpectreTable -Title "SolidFire Volumes assigned to PVE nodes" -Data $volumeList -Width 78
        $selectedVolumeName = Read-SpectreSelection -Title "Select any volume for initial [orange3]PVE node[/] configuration" -Choices $volumes.result.volumes.name
        if ($selectedVolumeName) {
            $selectedVolumeObj = $volumes.result.volumes | Where-Object { $_.name -eq $selectedVolumeName }
            if ($selectedVolumeObj) {
                $name = $selectedVolumeObj.name
                $iqn = $selectedVolumeObj.iqn
                $volumeID = $selectedVolumeObj.volumeID
            }
            else {
                Write-SpectreHost -Message "[Yellow]Selected volume not found. Exiting...[/]"
                Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
                return
            }
        }
        else {
            Write-SpectreHost -Message "[Yellow]No volume selected. Exiting...[/]"
            Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
            return
        }
    }

    if (-not $volumes.result.volumes[0].qosPolicyID -or $volumes.result.volumes[0].qosPolicyID -eq 0) {
        Write-SpectreHost -Message "[Yellow]Warning: QoS Policy ID is not set for this volume. We'll pick a random one. You may re-type the volume later.[/]"
    }
    else {
        $qosPolicyId = $volumes.result.volumes[0].qosPolicyID
    }

    $svip = ($global:sfClusterInfo).svip
    if (-not $svip) {
        Write-Host "Failed to get storage VIP (svip) from SolidFire cluster info." -ForegroundColor Red
        return
    }

    if (-not $sfAccountName -or -not $sfAccountPassword) {
        Write-SpectreHost -Message "[Red]SolidFire account name or password is not set. Please ensure both are available before generating commands.[/]"
        Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
        return
    }

    $commands = @()
    $commands += "cp /etc/iscsi/iscsid.conf /etc/iscsi/iscsid.conf.original-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $commands += "sed -i 's/^node.startup = .*/node.startup = automatic/' /etc/iscsi/iscsid.conf"
    $commands += "sed -i 's/^#*node.session.auth.authmethod *=.*/node.session.auth.authmethod = CHAP/' /etc/iscsi/iscsid.conf"
    $commands += "sed -i 's/^#*node.session.auth.username *=.*/node.session.auth.username = $sfAccountName/' /etc/iscsi/iscsid.conf"
    $commands += "sed -i 's/^#*node.session.auth.password *=.*/node.session.auth.password = $sfAccountPassword/' /etc/iscsi/iscsid.conf"
    $commands += "sed -i 's/^#*discovery.sendtargets.auth.authmethod *=.*/discovery.sendtargets.auth.authmethod = CHAP/' /etc/iscsi/iscsid.conf"
    $commands += "sed -i 's/^#*discovery.sendtargets.auth.username *=.*/discovery.sendtargets.auth.username = $sfAccountName/' /etc/iscsi/iscsid.conf"
    $commands += "sed -i 's/^#*discovery.sendtargets.auth.password *=.*/discovery.sendtargets.auth.password = $sfAccountPassword/' /etc/iscsi/iscsid.conf"
    $commands += "iscsiadm --mode node --target $iqn --portal $svip -o new"
    $commands += "iscsiadm --mode node --target $iqn --portal $svip -n discovery.sendtargets.use_discoveryd -v Yes"
    $commands += "systemctl restart iscsid"
    $commands += "systemctl status iscsid"
    $commands += "systemctl is-enabled iscsid"
    Write-SpectreHost -Message "[Cyan]Run the following commands on your Proxmox node(s):[/]"
    Write-SpectreHost -Message ($commands -join "`n")
    Write-SpectreHost -Message "[Cyan]Connect to a Proxmox node using SSH in another terminal (or tab) and run the commands above.[/]"
    Write-SpectreHost -Message "[Cyan]If you see no errors, you should be able to enable iscsid and if everything works fine, repeat that on other PVE nodes:[/]"
    Write-SpectreHost -Message "systemctl enable iscsid && fdisk -l"
    Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
    return
}

Export-ModuleMember -Function Invoke-FirstTimeSetupMenu, New-SolidFireStorageAccount, New-ProxmoxIscsiInitiator, New-SolidFireVolumeAccessGroup, Set-ProxmoxIscsiClient
