#!/usr/bin/env pwsh

# This script loops over CSV file with IQN aliases and initiator names, uses rows to populate a list of hash tables,
#  and then uploads IQN settings to SolidFire using the SolidFire API CreateInitiators.
# Example: "params": { "initiators": [ { "attributes": { "proxmox": true, "alias": "s196", "requireChap": false, "volumeAccessGroupID": 1, "name": "iqn.1993-08.org.debian:01:3e428bdc87a6" } }] }
#

# (c) ScaleoutSean 2025
# License: MIT License

# Require PS version 7.4 or later
$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -lt 7.4) {
    Write-Host "This script requires PowerShell 7.4 or later." -ForegroundColor Red
    exit 1
}

$volumeAccessGroupID = 1 # Set your VAG ID here. You MUST be careful to not add initiators to a VAG that is not intended for them.
$solidFireUrl = "https://192.168.1.34/json-rpc/12.5"    # Replace with your SolidFire API URL

Write-Host "Your PowerShell version is $($PSVersionTable.PSVersion)."
Write-Host "SolidFire API URL: $solidFireUrl"
Write-Host "You're about to create initiators in SolidFire using the latest CSV file in the current directory and add them to VAG ID $volumeAccessGroupID."
Write-Host "All initiators must be new and not already present in the SolidFire system. If you have existing, re-run the Bash script with hosts limited to the new ones only and come back here after that."

# Confirm the action
$confirmation = Read-Host "Do you want to proceed? (yes/no)"
if ($confirmation -ne "yes" -and $confirmation -ne "y") {
    Write-Host "Operation cancelled by user." -ForegroundColor Yellow
    exit 0
}


# Get all *.csv files in the current directory and propose to use the one that has the most recent timestamp.
$csvFiles = Get-ChildItem -Path . -Filter "*.csv" | Sort-Object LastWriteTime -Descending
if ($csvFiles.Count -eq 0) {
    Write-Host "No CSV files found in the current directory."
    exit 1
}

# Use the most recent CSV file
$csvFile = $csvFiles[0]
$csvIqnCount = (Import-Csv -Path $csvFile).Count
Write-Host "Using CSV file: $csvFile with $csvIqnCount initiators."
# Confirm the CSV file or ask the user to select another one
$confirmation = Read-Host "Do you want to use this CSV file? (yes/no)"
if ($confirmation -ne "yes" -and $confirmation -ne "y") {
    # Ask the user to specify a different CSV file
    $csvFile = Read-Host "Please enter the path to the CSV file you want to use"
    if (-not (Test-Path -Path $csvFile)) {
        Write-Host "The specified CSV file does not exist: $csvFile" -ForegroundColor Red
        exit 1
    }
    $csvIqnCount = (Import-Csv -Path $csvFile).Count
    Write-Host "Using CSV file: $csvFile with $csvIqnCount initiators."
}

# Read the CSV file and populate the initiators array
$initiators = @()
Import-Csv -Path $csvFile | ForEach-Object {
    $initiator = @{
        attributes = @{
            proxmox = $true
            alias = $_.Alias
            requireChap = $false
            volumeAccessGroupID = $volumeAccessGroupID
            name = $_.Name
        }
    }
    $initiators += $initiator
}

# Prepare the API request body
$body = @{
    params = @{
        initiators = $initiators
    }
} | ConvertTo-Json

# Output the request body for debugging
Write-Host "API Request Body:"
Write-Host $body

# Send the API request to SolidFire
$solidfireHeaders = @{
    "Content-Type" = "application/json"
}
# Prompt for SolidFire credentials (username and password for basic auth)
$solidfireCredentials = (Get-Credential -Message "Enter SolidFire API credentials")
# Add credentials to the headers
$solidfireHeaders["Authorization"] = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($solidfireCredentials.UserName):$($solidfireCredentials.GetNetworkCredential().Password)"))

# Loop over lines in CSV file and run one Invoke-RestMethod call to SolidFire API CreateInitiators for each line
foreach ($initiator in $initiators) {
    Write-Host "Creating initiator: $($initiator.attributes.name) with alias: $($initiator.attributes.alias)"
    try {
        $response = Invoke-RestMethod -Uri $solidFireUrl -Method Post -Headers $solidfireHeaders -Body $body -Credential $solidfireCredentials
        Write-Host "Initiators created successfully."
        Write-Host "Response: $($response | ConvertTo-Json)"
    } catch {
        Write-Host "Error creating initiators: $_"
        exit 1
    }
}

Write-Host "Use Firemox or SolidFire Web UI to verify that the initiators have been created successfully and added to the correct VAG."
$body =  @{
    method = "ListInitiators"
    params = @{
        volumeAccessGroupID = $volumeAccessGroupID
    }
    id = 1
} | ConvertTo-Json
# Output the list of initiators in the specified VAG
(Invoke-RestMethod -Uri $solidFireUrl -Method Post -Body $body -Headers $solidfireHeaders).result.initiators | Format-Table -AutoSize
