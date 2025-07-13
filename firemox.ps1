#!/usr/bin/env pwsh
# -*- coding: utf-8 -*-


# Firemox is used to configure SolidFire for use with Proxmox VE.
# It sets up the SolidFire account, volumes, initiators, VAG and QoS policies.
# It then uses the Proxmox VE API to create iSCSI pools and optionally VGs/LVMs on those pools.
#
# License: MIT
# Copyright (c) 2025 scaleoutSean@Github https://github.com/scaleoutsean/firemox
#

# SolidFire and Proxmox VE configuration parameters
[Uri]$Global:sfApiUri = [Uri]'https://192.168.1.34/json-rpc/12.5/' # SolidFire API address as Uri type
[string]$Global:sfAdmin = 'admin'       # SolidFire account name used for Proxmox VE datacenter configuration
[string]$Global:sfPass = 'admin'
[int]$Global:sfAccountId = $null        # SolidFire account ID used for Proxmox VE datacenter configuration
[hashtable]$Global:sfClusterInfo = @{}  # We keep cluster info, uniqueID, etc. here
[string]$Global:sfClusterName = ''      # Updated from sfClusterInfo after connecting to SolidFire
[hashtable]$Global:sfHeaders = @{}
[hashtable]$Global:sfConnection = @{}
# Proxmox VE datacenter API parameters
[Uri]$Global:pveApiUri = [Uri]'https://192.168.1.194:8006'
[string]$Global:pveBaseUrl = $Global:pveApiUri.AbsoluteUri.TrimEnd('/') # Base URL for Proxmox VE API
$Global:pveHeaders = @{}
[string]$Global:pveAdmin = 'root@pam'   # Proxmox VE user with sufficient privileges to create storage pools and volumes and view certain datacenter objects
[string]$Global:pvePass = 'NetApp123$'           # Proxmox VE user's password
$Global:pveTicketLast = @{}
[string]$Global:sfVolumePrefix = 'dc1-' # Prefix for SolidFire volumes created for Proxmox VE datacenter, also for the optional VAG name. We add $sfClustername and "-<vol_id>" to create volume names.

$essentials = @('sfApiUri', 'sfAdmin', 'sfPass', 'pveApiUri', 'pveAdmin', 'pvePass')
foreach ($essential in $essentials) {
    $varValue = Get-Variable -Name $essential -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    $envValue = [Environment]::GetEnvironmentVariable($essential)
    if (-not $varValue -and -not $envValue) {
        Write-Host "Essential variable `$Global:$essential is not set. It should be loaded from environment variables or set in the script." -ForegroundColor Yellow
    }
}
$mustHave = @('sfPass', 'pvePass')
foreach ($thing in $mustHave) {
    $varValue = Get-Variable -Name $thing -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    $envValue = [Environment]::GetEnvironmentVariable($thing)
    if (-not $varValue -and -not $envValue) {
        Write-Host "Must-have variable `$Global:$thing is not set." -ForegroundColor Red
        $value = Read-Host -AsSecureString "Please enter value for `$Global:$thing (input hidden)"
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($value)
        $plainValue = [Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $value = $plainValue
        if (-not $value) {
            Write-Host "Exiting script due to missing value without which the script cannot work." -ForegroundColor Red
            exit 1
        }
        Set-Variable -Name $thing -Value $value -Scope Global
    }
}

$modules = @('PwshSpectreConsole')
foreach ($module in $modules) {
    if (-not (Get-Module -Name ${module})) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-Host "Module $module is not installed."
            $install = Read-Host "Do you want to install module $module from PSGallery? (Y/n)"
            if ($install -eq '' -or $install -match '^[Yy]$') {
                try {
                    Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber
                    Write-Host "Module $module installed."
                }
                catch {
                    Write-Host "Failed to install module ${module}: $_" -ForegroundColor Red
                    continue
                }
            }
            else {
                Write-Host "Skipping installation of ${module}. Firemox is likely to crash in 3..2..." -ForegroundColor
                continue
            }
        }
        Import-Module -Name $module -ErrorAction Stop
    }
    else {
        continue
    }
}

$scriptDir = if ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { Get-Location }
$modules = @('SolidFireProxmoxFirstTimeSetup', 'SolidFireConnect', 'SolidFireAccount', 'SolidFireInvoke', 'SolidFireQosPolicy', 'SolidFireVolumeAccessGroup', 'SolidFireVolume', 'ProxmoxConnect', 'SolidFireProxmoxUtilities')
foreach ($module in $modules) {
    $modulePath = Join-Path -Path $scriptDir -ChildPath "${module}.psm1"
    if (Test-Path -Path $modulePath) {
        Import-Module -Name $modulePath -ErrorAction Stop
    }
    else {
        Write-Host "Module not found: ${module}" -ForegroundColor Red
    }
}

try {
    Connect-SolidFire -SFApiUri $Global:sfApiUri -SFAdmin $Global:sfAdmin -SFPass $Global:sfPass
}
catch {
    Write-SpectreHost -Message "Failed to connect to SolidFire cluster"
    Write-SpectreHost -Message "Exception details: $($_ | Out-String)"
    Write-SpectreHost -Message "Please check your SolidFire API URI, account name and password"
    exit 1
}

# If $Global:sfAccountId is not set, prompt user to create SolidFire storage account or quit
if (-not $Global:sfAccountId) {
    Write-SpectreHost -Message "[Yellow]SolidFire storage tenant account ID is not set. You have to have a SolidFire account ID set or create a new one now.[/]"
    $createAccount = Read-SpectreSelection -Title "Do you want to create a SolidFire storage account now?" -Choices @("Y. Yes, create account", "N. No, exit") -Color Yellow -PageSize 3
    if ($createAccount.Substring(0, 1).ToUpper() -eq 'Y') {
        New-SolidFireStorageAccount
    }
    else {
        Write-SpectreHost -Message "[Red]Exiting script due to missing SolidFire storage account ID.[/]"
        exit 1
    }
}

Write-SpectreRule -Title "Firemox: Console for Proxmox PVE with NetApp SolidFire | $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")" -Alignment Center -Color Red
Write-SpectreHost -Message "Welcome to [blue underline]Firemox[/]. See more at https://github.com/scaleoutsean/firemox.`n"

do {

    $mainChoices = @(
        "1. Proxmox-SolidFire toolbox :toolbox:",
        "2. SolidFire volumes :floppy_disk:",
        "3. SolidFire storage QoS policies :up_down_arrow:",
        "4. SolidFire Volume Access Groups :shield:",
        "5. First-time setup (SolidFire tenant and Proxmox iSCSI clients) :gear:",
        "Q. Quit :stop_sign:"
    )
    $MainMenu = Read-SpectreSelection -Title "Select a [Blue]task[/] using :up_down_arrow: or search" -Choices $mainChoices -Color Turquoise2 -PageSize 10 -EnableSearch
    if ($MainMenu -match '^[1-5qQ]\.?') {
        $MainMenu = $MainMenu.Substring(0, 1).ToUpper()
    }
    else {
        Write-SpectreHost -Message "Invalid selection. Please try again."
        continue
    }

    switch ($MainMenu) {
        '1' {
            $sub = ''
            do {
                Write-SpectreRule -Title "SolidFire-Proxmox Toolbox :toolbox: | $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")" -Alignment Center -Color Yellow
                $volumeChoices = @(
                    "1. [Blue]View[/] all [orange3]PVE[/] VG/LVM and iSCSI storage pool(s) backed by SolidFire :eyes:",
                    "2. [Blue]View[/] end-to-end VG-to-IQN mapping (does not show iSCSI pools w/o VG/LVM) :world_map:",
                    "3. [Green]Create[/] VG/LVM on existing [orange3]PVE[/] iSCSI storage pool :new_button:",
                    "4. [Green]Create[/] [orange3]PVE[/] iSCSI storage pool on SolidFire-based iSCSI volume :new_button:",
                    "5. [Purple_2]Remove[/] empty (void of VM/CT) [orange3]PVE[/] VG and LVM from SolidFire-backed iSCSI pool(s) :red_exclamation_mark:",
                    "6. [Purple_2]Remove[/] empty (void of VG/LVM configuration) [orange3]PVE[/] iSCSI pool to release volume to SolidFire :red_exclamation_mark:",
                    "7. [Blue]View[/] PVE and SolidFire storage network details :double_curly_loop:",
                    "8. [Blue]View[/] [Red]SolidFire[/] iSCSI targets exposed to PVE :eyes:",
                    "B. Back to [Blue]main menu[/] :house:"
                )
                $sub = Read-SpectreSelection -Title "Pick a [Blue]tool[/]" -Choices $volumeChoices -Color Turquoise2 -PageSize 10 -EnableSearch

                switch ($sub.Substring(0, 1).ToUpper()) {
                    '1' { Get-ProxmoxSolidFireStoragePool; break }
                    '2' { Get-ProxmoxSolidFireStorageMap; break }
                    '3' { New-ProxmoxVolumeGroup; break }
                    '4' { New-ProxmoxSolidFireStoragePool; break }
                    '5' { Remove-ProxmoxVgLvm; break }
                    '6' { Remove-ProxmoxIscsiPool; break }
                    '7' { Get-SolidFirePveNetworkSetting; break }
                    '8' { Get-SFClusterIscsiTarget -sfAccountId $sfAccountId; break }
                    'B' { break }
                    default { Write-Host 'Invalid option'; break }
                }
                if ($sub -match '^[bB]\.?') {
                    $sub = 'B'
                }
            } until ($sub.Substring(0, 1).ToUpper() -eq 'B')
        }
        '2' {
            $sub = ''
            do {
                Write-SpectreRule -Title "SolidFire Volumes :floppy_disk: | $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")" -Alignment Center -Color Yellow
                $volumeChoices = @(
                    "1. [Blue]View[/] SolidFire volumes created for Proxmox VE :eyes:",
                    "2. [Green]Create[/] SolidFire volume :new_button:",
                    "3. [Purple_2]Remove[/] unused SolidFire volume released by [orange3]PVE[/] :litter_in_bin_sign:",
                    "4. [Green]Edit[/] SolidFire volume properties (enlarge :red_triangle_pointed_up: and/or retype volume QoS :up_down_arrow:)",
                    "5. [Purple_2]Remove[/] (purge) [red]ALL[/] already deleted SolidFire volumes :red_exclamation_mark:",
                    "6. [Green]Add[/] volume to existing SolidFire snapshot schedule :three_o_clock:",
                    "7. [Purple_2]Remove[/] volume from existing SolidFire snapshot schedule",
                    "8. [Blue]View[/] [Orange3]PVE[/] storage account's efficiency :eyes:",
                    "B. Back to [Blue]main menu[/] :house:"
                )
                $sub = Read-SpectreSelection -Title "Pick a [blue]volume task[/]" -Choices $volumeChoices -Color Turquoise2 -PageSize 10 -EnableSearch

                switch ($sub.Substring(0, 1).ToUpper()) {
                    '1' { Get-SolidFireVolume -sfAccountId $sfAccountId; break }
                    '2' { New-SolidFireVolume -sfAccountId $sfAccountId; break }
                    '3' { Remove-SolidFireVolume -sfAccountId $sfAccountId; break }
                    '4' { Set-SolidFireVolume -sfAccountId $sfAccountId; break }
                    '5' { Remove-SolidFireDeletedVolume -sfAccountId $sfAccountId; break }
                    '6' { Add-SolidFireVolumeToSnapshotSchedule -sfAccountId $sfAccountId; break }
                    '7' { Remove-SolidFireVolumeFromSnapshotSchedule -sfAccountId $sfAccountId; break }
                    '8' { Get-SolidFireAccountStorageEfficiency; break }
                    'B' { break }
                    default { Write-Host 'Invalid option'; break }
                }
                if ($sub -match '^[bB]\.?') {
                    $sub = 'B'
                }
            } until ($sub.Substring(0, 1).ToUpper() -eq 'B')
        }
        '3' {
            $sub = ''
            do {
                Write-SpectreRule -Title "SolidFire QoS Policies :up_down_arrow: | $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")" -Alignment Center -Color Yellow
                $volumeChoices = @(
                    "1. [Blue]List[/] SolidFire volume QoS policies :open_book:",
                    "2. [Green]Edit[/] SolidFire QoS policy :pencil:",
                    "3. [Green]Create[/] new SolidFire QoS policy :new_button:",
                    "4. [Purple_2]Remove[/] SolidFire QoS policy :litter_in_bin_sign:",
                    "B. Back to [Blue]main menu[/] :house:"
                )
                $sub = Read-SpectreSelection -Title "Pick a [blue]QoS policy task[/]" -Choices $volumeChoices -Color Turquoise2 -PageSize 10 -EnableSearch

                switch ($sub.Substring(0, 1).ToUpper()) {
                    '1' { Get-SolidFireQosPolicies; break }
                    '2' { Set-SolidFireQosPolicy; break }
                    '3' { New-SolidFireQosPolicy; break }
                    '4' { Remove-SolidFireQosPolicy; break }
                    'B' { break }
                    default { Write-Host 'Invalid option'; break }
                }
                if ($sub -match '^[bB]\.?') {
                    $sub = 'B'
                }
            } until ($sub.Substring(0, 1).ToUpper() -eq 'B')
        }
        '4' {
            $sub = ''
            do {
                Write-SpectreRule -Title "SolidFire Volume Access Groups :shield: | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Alignment Center -Color Yellow
                $volumeChoices = @(
                    "1. [Blue]List[/] VAGs :open_book:",
                    "2. [Green]Add[/] all Firemox volumes for active account ID to VAG :plus:",
                    "3. [Green]Add[/] selected (already registered) SolidFire initiators to VAG :plus:",
                    "4. [Green]Create[/] new VAG :new_button:",
                    "B. Back to [Blue]main menu[/] :house:"
                )
                $sub = Read-SpectreSelection -Title "Pick a [blue]VAG task[/]" -Choices $volumeChoices -Color Turquoise2 -PageSize 10 -EnableSearch

                switch ($sub.Substring(0, 1).ToUpper()) {
                    '1' { Get-SolidFireVag; break }
                    '2' { Add-SolidFireFiremoxVolumesToVag; break }
                    '3' { Add-SolidFireVagInitiatorsToVag; break }
                    '4' { New-SolidFireVag; break }
                    'B' { break }
                    default { Write-Host 'Invalid option'; break }
                }
                if ($sub -match '^[bB]\\.?') {
                    $sub = 'B'
                }
            } until ($sub.Substring(0, 1).ToUpper() -eq 'B')
        }
        '5' {
            $sub = ''
            do {
                Write-SpectreRule -Title "First-time setup :gear: | $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")" -Alignment Center -Color Yellow
                $volumeChoices = @(
                    "1. [Green]Create[/] [red]SolidFire[/] storage tenant account for [orange3]PVE[/] :bust_in_silhouette:",
                    "2. [Green]Configure[/] iSCSI client on new [orange3]PVE[/] node :wrench:",
                    "B. Back to [Blue]main menu[/] :house:"
                )
                $sub = Read-SpectreSelection -Title "Pick a [blue]tool[/]" -Choices $volumeChoices -Color Turquoise2 -PageSize 10 -EnableSearch
                switch ($sub.Substring(0, 1).ToUpper()) {
                    '1' { New-SolidFireStorageAccount; break }
                    '2' { Set-ProxmoxIscsiClient; break }
                    'B' { break }
                    default { Write-Host 'Invalid option'; break }
                }
                if ($sub -match '^[bB]\.?') {
                    $sub = 'B'
                }
            } until ($sub.Substring(0, 1).ToUpper() -eq 'B')
        }
    }
} until ($MainMenu -eq 'Q')

Write-SpectreRule -Title "Exiting... :electric_plug: | $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")" -Alignment Center -Color Blue
foreach ($module in $modules) {
    Remove-Module -Name $module -ErrorAction SilentlyContinue
}
