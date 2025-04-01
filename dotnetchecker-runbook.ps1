<#
.SYNOPSIS
    Azure Runbook to check for EOL .NET versions and create Azure DevOps work items.

.DESCRIPTION
    This Azure Runbook scans for installed .NET versions on an Azure VM, 
    determines which are End-of-Support (EOL), logs the versions, 
    and creates Azure DevOps work items for remediation.

.PARAMETER ResourceGroupName
    The resource group containing the VMs to scan.

.PARAMETER VMNames
    Optional. Comma-separated list of VM names to scan. If not provided, all VMs in the resource group will be scanned.

.PARAMETER AzureDevOpsOrg
    Azure DevOps organization name.

.PARAMETER AzureDevOpsProject
    Azure DevOps project name.

.PARAMETER AreaPath
    Area path for the work items.

.PARAMETER IterationPath
    Iteration path for the work items.

.PARAMETER AssignedTo
    User to assign the work items to.

.PARAMETER LogAnalyticsWorkspaceId
    Log Analytics workspace ID to send logs to.

.NOTES
    Version:        1.0
    Author:         Your Name
    Creation Date:  April 1, 2025
    Purpose/Change: Initial script development

.EXAMPLE
    DotNetChecker-Runbook -ResourceGroupName "MyResourceGroup" -AzureDevOpsOrg "MyOrg" -AzureDevOpsProject "MyProject" -AreaPath "MyProject\Team" -IterationPath "MyProject\Sprint1" -AssignedTo "user@domain.com" -LogAnalyticsWorkspaceId "workspace-id"
#>

param(
    [Parameter(Mandatory = $true)]
    [string] $ResourceGroupName,
    
    [Parameter(Mandatory = $false)]
    [string] $VMNames,
    
    [Parameter(Mandatory = $true)]
    [string] $AzureDevOpsOrg,
    
    [Parameter(Mandatory = $true)]
    [string] $AzureDevOpsProject,
    
    [Parameter(Mandatory = $true)]
    [string] $AreaPath,
    
    [Parameter(Mandatory = $true)]
    [string] $IterationPath,
    
    [Parameter(Mandatory = $true)]
    [string] $AssignedTo,
    
    [Parameter(Mandatory = $false)]
    [string] $LogAnalyticsWorkspaceId
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Helper function for logging
function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("Info", "Warning", "Error")]
        [string] $Severity = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$timestamp] [$Severity] $Message"
    
    # If Log Analytics workspace ID is provided, send logs there
    if ($LogAnalyticsWorkspaceId) {
        $logEntry = @{
            "Timestamp" = $timestamp
            "Severity" = $Severity
            "Message" = $Message
        }
        
        # Convert to JSON
        $json = ConvertTo-Json -InputObject $logEntry
        
        # Send to Log Analytics
        try {
            Send-AzOperationalInsightsLogAnalyticsDC -WorkspaceId $LogAnalyticsWorkspaceId -Body $json -Type "DotNetCheckerLogs" -ErrorAction SilentlyContinue
        }
        catch {
            Write-Output "Could not send to Log Analytics: $_"
        }
    }
}

# Region: .NET EOS Mapping
$DotNetEOLMapping = @(
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

# Script to execute on target VMs
$remoteScript = @'
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

# Get versions and convert to JSON for return
$dotNetVersions = Get-DotNetVersions
$dotNetVersions | ConvertTo-Json -Depth 3
'@

# Function to determine if a .NET version is EOL
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
            foreach ($entry in $DotNetEOLMapping) {
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

# Function to create Azure DevOps work item
function Add-AzureDevOpsWorkItem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        
        [Parameter(Mandatory = $true)]
        [string]$Project,
        
        [Parameter(Mandatory = $true)]
        [string]$Title,
        
        [Parameter(Mandatory = $true)]
        [string]$Description,
        
        [Parameter(Mandatory = $true)]
        [string]$AreaPath,
        
        [Parameter(Mandatory = $true)]
        [string]$IterationPath,
        
        [Parameter(Mandatory = $true)]
        [string]$AssignedTo,
        
        [Parameter(Mandatory = $false)]
        [string]$WorkItemType = "User Story",
        
        [Parameter(Mandatory = $false)]
        [double]$EffortHours = 1,
        
        [Parameter(Mandatory = $false)]
        [string]$Tag = "dotnet remediation"
    )
    
    try {
        # Get PAT from Automation Assets
        $patCredential = Get-AutomationPSCredential -Name "AzureDevOpsPAT"
        $pat = $patCredential.GetNetworkCredential().Password
        
        # Create the patch document for work item creation
        $patchDocument = @(
            @{ op = "add"; path = "/fields/System.Title"; value = $Title },
            @{ op = "add"; path = "/fields/System.Description"; value = $Description },
            @{ op = "add"; path = "/fields/System.WorkItemType"; value = $WorkItemType },
            @{ op = "add"; path = "/fields/System.AreaPath"; value = $AreaPath },
            @{ op = "add"; path = "/fields/System.IterationPath"; value = $IterationPath },
            @{ op = "add"; path = "/fields/System.AssignedTo"; value = $AssignedTo },
            @{ op = "add"; path = "/fields/System.Tags"; value = $Tag },
            @{ op = "add"; path = "/fields/Microsoft.VSTS.Scheduling.OriginalEstimate"; value = $EffortHours.ToString() }
        )
        
        $jsonBody = $patchDocument | ConvertTo-Json -Depth 10
        $encodedWorkItemType = $WorkItemType -replace " ", "%20"
        $uri = "https://dev.azure.com/$Organization/$Project/_apis/wit/workitems/\$$encodedWorkItemType?api-version=6.0"
        
        $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
        $headers = @{
            Authorization  = "Basic $base64AuthInfo"
            "Content-Type" = "application/json-patch+json"
        }
        
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $jsonBody
        Write-Log -Message "Work item created with ID: $($response.id)" -Severity "Info"
        return $response.id
    }
    catch {
        Write-Log -Message "Failed to create work item: $_" -Severity "Error"
        throw "Failed to create work item: $_"
    }
}

# Main workflow
try {
    # Log the start of the script
    Write-Log -Message "Starting .NET checker runbook for resource group: $ResourceGroupName" -Severity "Info"
    
    # Connect to Azure
    Write-Log -Message "Connecting to Azure..." -Severity "Info"
    
    # Get Azure Run As Connection
    $connectionName = "AzureRunAsConnection"
    try {
        $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName
        Connect-AzAccount -ServicePrincipal `
            -TenantId $servicePrincipalConnection.TenantId `
            -ApplicationId $servicePrincipalConnection.ApplicationId `
            -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint | Out-Null
        Write-Log "Successfully connected to Azure" -Severity "Info"
    }
    catch {
        Write-Log "Failed to connect to Azure: $_" -Severity "Error"
        throw "Failed to connect to Azure: $_"
    }
    
    # Get VMs to scan
    $targetVMs = @()
    if ([string]::IsNullOrEmpty($VMNames)) {
        # Get all VMs in the resource group
        Write-Log "Getting all VMs in resource group: $ResourceGroupName" -Severity "Info"
        $targetVMs = Get-AzVM -ResourceGroupName $ResourceGroupName
    }
    else {
        # Get specific VMs
        Write-Log "Getting specific VMs: $VMNames" -Severity "Info"
        $vmList = $VMNames -split ","
        foreach ($vmName in $vmList) {
            $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName.Trim()
            if ($vm) {
                $targetVMs += $vm
            }
            else {
                Write-Log "VM not found: $vmName" -Severity "Warning"
            }
        }
    }
    
    if ($targetVMs.Count -eq 0) {
        Write-Log "No VMs found to scan." -Severity "Warning"
        return
    }
    
    Write-Log "Found $($targetVMs.Count) VMs to scan" -Severity "Info"
    
    # Process each VM
    foreach ($vm in $targetVMs) {
        Write-Log "Processing VM: $($vm.Name)" -Severity "Info"
        
        # Check if VM is running
        $vmStatus = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status
        $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -match 'PowerState' }).DisplayStatus
        
        if ($powerState -ne "VM running") {
            Write-Log "VM $($vm.Name) is not running (status: $powerState). Skipping." -Severity "Warning"
            continue
        }
        
        try {
            # Run script on VM to get .NET versions
            Write-Log "Running script on VM $($vm.Name) to get .NET versions" -Severity "Info"
            $result = Invoke-AzVMRunCommand -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -CommandId 'RunPowerShellScript' -ScriptString $remoteScript
            
            # Process the output
            $scriptOutput = $result.Value[0].Message
            $dotNetVersions = $scriptOutput | ConvertFrom-Json
            
            # Find EOL versions
            $eolVersions = @()
            foreach ($version in $dotNetVersions) {
                if (IsEOLDotNetVersion -DotNetVersionObj $version) {
                    $eolVersions += $version
                    Write-Log "Found EOL .NET version on $($vm.Name): $($version.Name) $($version.Version)" -Severity "Warning"
                }
            }
            
            # Create work item if EOL versions found
            if ($eolVersions.Count -gt 0) {
                $versionList = ($eolVersions | ForEach-Object { "$($_.Name) $($_.Version)" }) -join ', '
                
                $title = ".NET EOL Remediation Required: $($vm.Name)"
                $description = @"
VM Name: $($vm.Name)
Resource Group: $($vm.ResourceGroupName)
EOL .NET versions detected: 
$($eolVersions | ForEach-Object { "- $($_.Name) $($_.Version)" } | Out-String)

Please remediate these end-of-life .NET versions to maintain security compliance.
"@
                
                Write-Log "Creating Azure DevOps work item for $($vm.Name)" -Severity "Info"
                $workItemId = Add-AzureDevOpsWorkItem -Organization $AzureDevOpsOrg -Project $AzureDevOpsProject `
                    -Title $title -Description $description -AreaPath $AreaPath -IterationPath $IterationPath `
                    -AssignedTo $AssignedTo -WorkItemType "User Story" -EffortHours 2 -Tag "dotnet remediation,security"
                
                Write-Log "Work item created with ID: $workItemId" -Severity "Info"
                
                # Log to custom table in Log Analytics if workspace ID is provided
                if ($LogAnalyticsWorkspaceId) {
                    $logObject = @{
                        "TimeGenerated" = (Get-Date).ToUniversalTime().ToString("o")
                        "VMName" = $vm.Name
                        "ResourceGroup" = $vm.ResourceGroupName
                        "EOLVersions" = $versionList
                        "WorkItemID" = $workItemId
                        "Action" = "Created Work Item"
                    }
                    
                    $jsonLog = $logObject | ConvertTo-Json
                    Send-AzOperationalInsightsLogAnalyticsDC -WorkspaceId $LogAnalyticsWorkspaceId -Body $jsonLog -Type "DotNetEOLDetections" -ErrorAction SilentlyContinue
                }
            }
            else {
                Write-Log "No EOL .NET versions found on $($vm.Name)" -Severity "Info"
            }
        }
        catch {
            Write-Log "Error processing VM $($vm.Name): $_" -Severity "Error"
        }
    }
    
    Write-Log "Completed .NET checker runbook for resource group: $ResourceGroupName" -Severity "Info"
}
catch {
    Write-Log "Runbook failed: $_" -Severity "Error"
    throw $_
}