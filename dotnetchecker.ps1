<#
    This script:
      - Scans the computer for installed .NET versions (both .NET Framework and .NET Core/5+).
      - Logs them to a CSV file.
      - Determines which installed versions are End-Of-Support (EOL) based on predefined EOS dates.
      - Creates an Azure DevOps user story that lists only the EOL versions for upgrade.
      - Downloads and installs the latest .NET version.
#>

#region Global EOS Mapping

# Define a global mapping of .NET Core/.NET (major.minor) versions to their End-Of-Support dates.
# Adjust these dates as needed.
$global:DotNetEOLMapping = @(
    @{ MajorMinor = "7.0"; EOS = [datetime]::Parse("May 14, 2024") },
    @{ MajorMinor = "6.0"; EOS = [datetime]::Parse("November 12, 2024") },
    @{ MajorMinor = "5.0"; EOS = [datetime]::Parse("May 10, 2022") },
    @{ MajorMinor = "3.1"; EOS = [datetime]::Parse("December 13, 2022") },
    @{ MajorMinor = "3.0"; EOS = [datetime]::Parse("March 3, 2020") },
    @{ MajorMinor = "2.2"; EOS = [datetime]::Parse("December 23, 2019") },
    @{ MajorMinor = "2.1"; EOS = [datetime]::Parse("August 21, 2021") },
    @{ MajorMinor = "2.0"; EOS = [datetime]::Parse("October 1, 2018") },
    @{ MajorMinor = "1.1"; EOS = [datetime]::Parse("June 27, 2019") },
    @{ MajorMinor = "1.0"; EOS = [datetime]::Parse("June 27, 2019") }
)

#endregion

#region Version Scanning Functions

# Function to retrieve installed .NET Framework versions from the registry.
function Get-DotNetFrameworkVersions {
    $versions = @()
    $regPath = "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\"
    $keys = Get-ChildItem $regPath -Recurse -ErrorAction SilentlyContinue | 
            Where-Object { $null -ne $_.GetValue("Version") }
    foreach ($key in $keys) {
        $versions += [PSCustomObject]@{
            Name    = "Framework: $($key.PSChildName)"
            Version = $key.GetValue("Version")
        }
    }
    return $versions
}

# Function to retrieve installed .NET Core / .NET (5+) versions by checking the installation folder.
function Get-DotNetCoreVersions {
    $versions = @()
    $dotnetCorePath = "$env:ProgramFiles\dotnet\shared\Microsoft.NETCore.App"
    if (Test-Path $dotnetCorePath) {
        $dirs = Get-ChildItem -Path $dotnetCorePath -Directory -ErrorAction SilentlyContinue
        foreach ($dir in $dirs) {
            $versions += [PSCustomObject]@{
                Name    = "Core: Microsoft.NETCore.App"
                Version = $dir.Name
            }
        }
    }
    return $versions
}

# Combined function to retrieve all installed .NET versions.
function Get-DotNetVersions {
    $frameworkVersions = Get-DotNetFrameworkVersions
    $coreVersions = Get-DotNetCoreVersions
    return $frameworkVersions + $coreVersions
}

#endregion

#region EOL Determination Functions

# Function to determine if a given .NET version is considered EOL.
function IsEOLDotNetVersion {
    param(
       [Parameter(Mandatory = $true)]
       $DotNetVersionObj
    )
    $name = $DotNetVersionObj.Name
    $version = $DotNetVersionObj.Version

    if ($name -like "Framework*") {
        # For .NET Framework, assume only 4.8 is supported.
        if ($version -like "4.8*") {
            return $false
        }
        else {
            return $true
        }
    }
    elseif ($name -like "Core*") {
        # Parse major.minor from the version string.
        $parts = $version -split "\."
        if ($parts.Length -ge 2) {
            $majorMinor = "$($parts[0]).$($parts[1])"
            # Check if there is a matching entry in our EOS mapping.
            foreach ($entry in $global:DotNetEOLMapping) {
                if ($entry.MajorMinor -eq $majorMinor) {
                    if ((Get-Date) -gt $entry.EOS) {
                        return $true
                    }
                    else {
                        return $false
                    }
                }
            }
            # If version not found in mapping, assume supported.
            return $false
        }
        else {
            return $false
        }
    }
    else {
         return $false
    }
}

# Returns only the installed .NET versions that are flagged as EOL.
function Get-EOLDotNetVersions {
    $all = Get-DotNetVersions
    return $all | Where-Object { IsEOLDotNetVersion $_ }
}

#endregion

#region Logging Function

# Function to log .NET versions to a CSV file.
function Log-DotNetVersionsToCsv {
    param (
        [string]$OutputPath = ".\dotnet_versions.csv"
    )
    $versions = Get-DotNetVersions
    if ($versions.Count -gt 0) {
        $versions | Export-Csv -Path $OutputPath -NoTypeInformation
        Write-Host "Logged .NET versions to $OutputPath"
    }
    else {
        Write-Host "No .NET versions found to log."
    }
}

#endregion

#region Azure DevOps Function

# Function to create an Azure DevOps user story via the REST API, including only EOL versions.
function Add-AzureDevOpsUserStory {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [string]$PAT,
        [Parameter(Mandatory = $false)]
        [string]$Title,
        [Parameter(Mandatory = $false)]
        [string]$Description
    )

    # Get the machine name.
    $machineName = $env:COMPUTERNAME

    # Retrieve only EOL .NET versions and join them as a comma-separated list.
    $eolVersions = Get-EOLDotNetVersions
    if ($eolVersions.Count -gt 0) {
        $versionList = ($eolVersions | ForEach-Object { $_.Version }) -join ', '
    }
    else {
        $versionList = "None"
    }

    # Build default title and description if not provided.
    if (-not $Title) {
        $Title = "Upgrade .NET on $machineName (EOL installed: $versionList)"
    }
    if (-not $Description) {
        $Description = "Machine: $machineName`nEOL .NET versions: $versionList`nPlease upgrade these to a supported release."
    }

    # Create the basic authentication header (PAT is used as the password).
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PAT"))
    # URL-encode "User Story" as "User%20Story".
    $url = "https://dev.azure.com/$Organization/$Project/_apis/wit/workitems/\$User%20Story?api-version=6.0"
    
    # Build the JSON patch document.
    $body = @(
        @{
            "op"    = "add"
            "path"  = "/fields/System.Title"
            "value" = $Title
        },
        @{
            "op"    = "add"
            "path"  = "/fields/System.Description"
            "value" = $Description
        }
    ) | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -Headers @{
            Authorization  = "Basic $base64AuthInfo"
            "Content-Type" = "application/json-patch+json"
        } -Body $body

        Write-Host "Azure DevOps user story created with ID: $($response.id)"
    }
    catch {
        Write-Error "Error creating Azure DevOps user story: $_"
    }
}

#endregion

#region .NET Installation Function

# Function to download and install the latest .NET version using the official install script.
function Install-LatestDotNet {
    param(
        [string]$InstallDir = "$env:ProgramFiles\dotnet",
        [string]$Channel = "STS"  # "STS" for latest (instead of deprecated "Current"), or "LTS" for long-term support.
    )

    $installScriptUrl = "https://dot.net/v1/dotnet-install.ps1"
    $tempPath = Join-Path $env:TEMP "dotnet-install.ps1"

    Write-Host "Downloading dotnet-install.ps1 from $installScriptUrl..."
    try {
        Invoke-WebRequest -Uri $installScriptUrl -OutFile $tempPath -ErrorAction Stop
        Write-Host "Download complete."
    }
    catch {
        Write-Error "Error downloading dotnet-install.ps1: $_"
        return
    }

    Write-Host "Installing latest .NET version (Channel: $Channel) to $InstallDir..."
    try {
        & $tempPath -Channel $Channel -InstallDir $InstallDir -NoPath -ErrorAction Stop
        Write-Host ".NET installation completed. You may need to restart your session for changes to take effect."
    }
    catch {
        $errorMessage = $_.Exception.Message.ToLower()
        if ($errorMessage.Contains("write access")) {
            Write-Host "Error: You don't have write access to '$InstallDir'."
            $newDir = Read-Host "Enter an alternate installation directory or press Enter to abort"
            if ($newDir) {
                if (-not (Test-Path $newDir)) {
                    try {
                        New-Item -ItemType Directory -Path $newDir -Force | Out-Null
                        Write-Host "Directory '$newDir' created."
                    }
                    catch {
                        Write-Host "Failed to create directory '$newDir'. Installation aborted."
                        return
                    }
                }
                Install-LatestDotNet -InstallDir $newDir -Channel $Channel
                return
            }
            else {
                Write-Host "Installation aborted."
                return
            }
        }
        else {
            Write-Error "Error during .NET installation: $_"
            return
        }
    }
}

#endregion

#region Menu and Main Loop

# Function to display the menu options.
function Show-Menu {
    Write-Host ""
    Write-Host "Select an option:"
    Write-Host "1. Scan installed .NET versions"
    Write-Host "2. Log .NET versions to CSV"
    Write-Host "3. Create Azure DevOps user story for EOL versions"
    Write-Host "4. Install latest .NET version"
    Write-Host "5. Exit"
}

# Main loop for user interaction.
do {
    Show-Menu
    $choice = Read-Host "Enter your choice (1-5)"
    switch ($choice) {
        "1" {
            Write-Host "Scanning for installed .NET versions..."
            $versions = Get-DotNetVersions
            if ($versions) {
                # Mark EOL versions in red.
                $versions | ForEach-Object {
                    if (IsEOLDotNetVersion $_) {
                        Write-Host "$($_.Name) $($_.Version) - EOL" -ForegroundColor Red
                    }
                    else {
                        Write-Host "$($_.Name) $($_.Version)"
                    }
                }
            }
            else {
                Write-Host "No .NET installations were found."
            }
        }
        "2" {
            Log-DotNetVersionsToCsv
        }
        "3" {
            # Prompt for Azure DevOps parameters and ensure none are empty.
            $org = Read-Host "Enter Azure DevOps Organization"
            $project = Read-Host "Enter Azure DevOps Project"
            $pat = Read-Host "Enter your Azure DevOps Personal Access Token (PAT)"
            if ([string]::IsNullOrWhiteSpace($org) -or [string]::IsNullOrWhiteSpace($project) -or [string]::IsNullOrWhiteSpace($pat)) {
                Write-Host "Error: Azure DevOps Organization, Project, and PAT must all be provided. Aborting user story creation."
            }
            else {
                Add-AzureDevOpsUserStory -Organization $org -Project $project -PAT $pat
            }
        }
        "4" {
            $channel = Read-Host "Enter channel (STS for latest, LTS for long-term support) [STS]" 
            if ([string]::IsNullOrEmpty($channel)) {
                $channel = "STS"
            }
            Install-LatestDotNet -Channel $channel
        }
        "5" {
            Write-Host "Exiting..."
            break
        }
        default {
            Write-Host "Invalid selection. Please choose an option between 1 and 5."
        }
    }
} while ($true)

#endregion
