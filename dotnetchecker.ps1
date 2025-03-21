# Auto-elevation snippet with progress indication.
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Host "This script requires administrative privileges. Elevating..."
    Write-Progress -Activity "Elevating privileges" -Status "Initializing..." -PercentComplete 0
    Start-Sleep -Seconds 1
    Write-Progress -Activity "Elevating privileges" -Status "Please wait..." -PercentComplete 50
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Write-Progress -Activity "Elevating privileges" -Completed
    exit
}

<# 
   dotnetchecker.ps1
   This script scans for installed .NET versions, determines which are End-of-Support,
   logs the versions to a CSV file, creates an Azure DevOps work item for .NET remediation,
   and installs the latest .NET version.
#>

#region Global EOS Mapping
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
function Get-DotNetFrameworkVersions {
    $versions = @()
    $regPath = "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\"
    $keys = Get-ChildItem $regPath -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.GetValue("Version") -ne $null }
    foreach ($key in $keys) {
        $versions += [PSCustomObject]@{
            Name    = "Framework: $($key.PSChildName)"
            Version = $key.GetValue("Version")
        }
    }
    return $versions
}

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

function Get-DotNetVersions {
    $frameworkVersions = Get-DotNetFrameworkVersions
    $coreVersions = Get-DotNetCoreVersions
    return $frameworkVersions + $coreVersions
}
#endregion

#region EOL Determination Functions
function IsEOLDotNetVersion {
    param(
       [Parameter(Mandatory = $true)]
       $DotNetVersionObj
    )
    $name = $DotNetVersionObj.Name
    $version = $DotNetVersionObj.Version
    if ($name -like "Framework*") {
        if ($version -like "4.8*") { return $false } else { return $true }
    }
    elseif ($name -like "Core*") {
        $parts = $version -split "\."
        if ($parts.Length -ge 2) {
            $majorMinor = "$($parts[0]).$($parts[1])"
            foreach ($entry in $global:DotNetEOLMapping) {
                if ($entry.MajorMinor -eq $majorMinor) {
                    if ((Get-Date) -gt $entry.EOS) { return $true } else { return $false }
                }
            }
            return $false
        }
        else { return $false }
    }
    else { return $false }
}

function Get-EOLDotNetVersions {
    $all = Get-DotNetVersions
    return $all | Where-Object { IsEOLDotNetVersion $_ }
}
#endregion

#region Logging Function
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

#region Add Work Item Function
function Add-WorkItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [string]$WorkItemType,
        [Parameter(Mandatory = $false)]
        [string]$Title,
        [Parameter(Mandatory = $false)]
        [string]$Description,
        [Parameter(Mandatory = $true)]
        [string]$PersonalAccessToken,
        [double]$EffortHours = 1,
        [string]$Tag = "dotnet remediation"
    )
    $machineName = $env:COMPUTERNAME
    $eolVersions = Get-EOLDotNetVersions
    if ($eolVersions.Count -gt 0) {
        $versionList = ($eolVersions | ForEach-Object { $_.Version }) -join ', '
    }
    else {
        $versionList = "None"
    }
    if (-not $Title) {
        $Title = "Upgrade .NET on $machineName (EOL installed: $versionList)"
    }
    if (-not $Description) {
        $Description = "Machine: $machineName`nEOL .NET versions: $versionList`nPlease remediate."
    }
    $patchDocument = @()
    $patchDocument += @{ op = "add"; path = "/fields/System.Title"; value = $Title }
    $patchDocument += @{ op = "add"; path = "/fields/System.Description"; value = $Description }
    $patchDocument += @{ op = "add"; path = "/fields/System.Tags"; value = $Tag }
    $patchDocument += @{ op = "add"; path = "/fields/Microsoft.VSTS.Scheduling.OriginalEstimate"; value = $EffortHours.ToString() }
    $jsonBody = $patchDocument | ConvertTo-Json -Depth 10
    $encodedWorkItemType = $WorkItemType -replace " ", "%20"
    $uri = "https://dev.azure.com/$Organization/$Project/_apis/wit/workitems/\$$encodedWorkItemType?api-version=6.0"
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PersonalAccessToken"))
    $headers = @{
        Authorization  = "Basic $base64AuthInfo"
        "Content-Type" = "application/json-patch+json"
    }
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $jsonBody
        Write-Host "Work item created with ID: $($response.id)"
        return $response.id
    }
    catch {
        throw "Failed to create work item: $_"
    }
}
#endregion

#region Install Latest .NET Function
function Install-LatestDotNet {
    param(
        [string]$InstallDir = "$env:ProgramFiles\dotnet",
        [string]$Channel = "STS"  # "STS" for latest, or "LTS" for long-term support.
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
function Show-Menu {
    Write-Host ""
    Write-Host "Select an option:"
    Write-Host "1. Scan installed .NET versions"
    Write-Host "2. Log .NET versions to CSV"
    Write-Host "3. Create Azure DevOps work item for .NET remediation"
    Write-Host "4. Install latest .NET version"
    Write-Host "5. Exit"
}

do {
    Show-Menu
    $choice = Read-Host "Enter your choice (1-5)"
    switch ($choice) {
        "1" {
            $versions = Get-DotNetVersions
            if ($versions) {
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
                Write-Host "No .NET installations found."
            }
        }
        "2" {
            Log-DotNetVersionsToCsv
        }
        "3" {
            $org = Read-Host "Enter Azure DevOps Organization"
            $project = Read-Host "Enter Azure DevOps Project"
            $pat = Read-Host "Enter your Personal Access Token (PAT)"
            $workItemType = Read-Host "Enter work item type (e.g., User Story, Bug)"
            $titleInput = Read-Host "Enter work item title (or leave blank for default)"
            $descInput = Read-Host "Enter work item description (or leave blank for default)"
            if (-not ([string]::IsNullOrWhiteSpace($org) -or [string]::IsNullOrWhiteSpace($project) -or [string]::IsNullOrWhiteSpace($pat) -or [string]::IsNullOrWhiteSpace($workItemType))) {
                Add-WorkItem -Organization $org -Project $project -WorkItemType $workItemType -Title $titleInput -Description $descInput -PersonalAccessToken $pat
            }
            else {
                Write-Host "Organization, Project, PAT, and Work Item Type are required."
            }
        }
        "4" {
            $channel = Read-Host "Enter channel (STS for latest, LTS for long-term support) [STS]"
            if ([string]::IsNullOrEmpty($channel)) { $channel = "STS" }
            Install-LatestDotNet -Channel $channel
        }
        "5" {
            Write-Host "Exiting..."
            exit
        }
        default {
            Write-Host "Invalid selection. Please choose 1-5."
        }
    }
} while ($true)
#endregion
