
function New-SolidFireTenant {
    $sfAccountName = Read-SpectreText -Message "Enter SolidFire account name for Proxmox VE" -DefaultValue "dc1"
    $sfAccountPassword = Read-SpectreText -Message "Enter SolidFire account password for Proxmox VE" -DefaultValue "up-to-16-alphanumeric-chars"
    $body = @{
        username        = $sfAccountName
        enableChap      = $true
        initiatorSecret = $sfAccountPassword
        attributes      = @{
            proxmox = $true
        }
    }
    $global:sfAccount = Invoke-SolidFireRestMethod -Method "AddAccount" -Body $body
    if (-not $global:sfAccount) {
        Write-SpectreHost "Creating new SolidFire account for Proxmox VE: ${sfAccountName}"
        $global:sfAccount = New-SFAccount -Connection $sfConnection -Name ${sfAccountName} -Alias ${sfAccountAlias}
    }
    else {
        $errMsg = "SolidFire account already exists: ${sfAccountName}"
        Write-SpectreHost "[Red]$errMsg[/]"
        Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
    }
}

function Get-SolidFireTenant {
    param (
        [switch]$Silent
    )
    $sfAccounts = (Invoke-SolidFireRestMethod -Method "ListAccounts" -Body @{}).result.accounts
    if ($Silent) {
        return $sfAccounts
    }
    if ($sfAccounts.Count -gt 0) {
        Write-Host "SolidFire Tenants:" -ForegroundColor Cyan
        foreach ($account in $sfAccounts) {
            Write-Host " - Name: $($account.username), ID: $($account.accountID), CHAP enabled: $($account.enableChap)" -ForegroundColor White
        }
        Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey

    }
    else {
        Write-Host "No SolidFire tenants found." -ForegroundColor Yellow
        Read-SpectrePause -Message "Press [green]ANY[/] key to return to QoS Policies menu." -AnyKey
    }
}
