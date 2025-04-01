# .NET Checker

A comprehensive solution for detecting and managing End-of-Life (EOL) .NET versions across your infrastructure.

## Overview

This project provides tools to:

- Scan for installed .NET versions (both .NET Framework and .NET Core/5+)
- Identify End-of-Support (EOL) versions based on Microsoft's support timeline
- Log findings to CSV files for compliance tracking
- Create Azure DevOps work items for remediation tracking
- Install the latest .NET versions when needed

The solution includes both an interactive PowerShell script for on-demand use and an Azure Runbook for automated scanning across multiple VMs.

## PowerShell Script (`dotnetchecker.ps1`)

### Features

- **Administrative Privilege Handling**: Auto-elevates to admin if needed
- **Comprehensive Scanning**: Detects both .NET Framework and .NET Core versions
- **EOL Detection**: Built-in database of EOL dates for different .NET versions
- **CSV Logging**: Records findings for compliance and tracking
- **Azure DevOps Integration**: Creates work items for remediation tracking
- **Installation Support**: Can download and install the latest .NET versions
- **User-Friendly Interface**: Interactive menu system with clear color-coded outputs

### Requirements

- Windows PowerShell 5.1 or later
- Administrator rights (the script will auto-elevate if needed)
- Internet connectivity for Azure DevOps integration and .NET installation
- Azure DevOps Personal Access Token (PAT) with work item creation permissions

### Usage

Run the script using PowerShell:

```powershell
.\dotnetchecker.ps1
```

The interactive menu provides the following options:

1. **Scan installed .NET versions**: Displays all installed .NET versions, highlighting EOL versions in red
2. **Log .NET versions to CSV**: Exports all found versions to a CSV file
3. **Log EOL .NET versions to CSV**: Exports only EOL versions to a dedicated CSV file
4. **Create Azure DevOps work item**: Creates a work item for EOL version remediation
5. **Install latest .NET version**: Downloads and installs the latest .NET version
6. **Exit**: Closes the application

## Azure Runbook (`DotNetChecker-Runbook.ps1`)

### Features

- **Automated Scanning**: Runs on a schedule without user interaction
- **Multi-VM Support**: Scans all VMs in a resource group or a specified subset
- **Centralized Logging**: Integrates with Azure Log Analytics
- **Azure DevOps Integration**: Automatically creates work items for remediation
- **Detailed Reporting**: Provides comprehensive information about detected EOL versions
- **Non-Interactive Operation**: Designed for scheduled execution

### Requirements

- Azure Automation Account
- Run As Account with VM Reader permissions
- Credential asset for Azure DevOps PAT
- Optional: Log Analytics workspace for centralized logging

### Parameters

| Parameter | Description | Required |
|-----------|-------------|----------|
| ResourceGroupName | The resource group containing the VMs to scan | Yes |
| VMNames | Comma-separated list of VM names to scan (if omitted, all VMs in the resource group are scanned) | No |
| AzureDevOpsOrg | Azure DevOps organization name | Yes |
| AzureDevOpsProject | Azure DevOps project name | Yes |
| AreaPath | Area path for the work items | Yes |
| IterationPath | Iteration path for the work items | Yes |
| AssignedTo | User to assign the work items to | Yes |
| LogAnalyticsWorkspaceId | Log Analytics workspace ID for sending logs | No |

### Usage

Import the runbook into your Azure Automation account:

1. In the Azure portal, navigate to your Automation Account
2. Go to "Runbooks" and click "Import a runbook"
3. Upload the `DotNetChecker-Runbook.ps1` file
4. Publish the runbook after importing

Create the required assets:

1. Create a credential asset named "AzureDevOpsPAT" with your Azure DevOps PAT
2. Ensure the Run As Account is configured

Schedule the runbook:

1. Go to your imported runbook and click "Schedules"
2. Add a new schedule (e.g., monthly)
3. Provide the required parameters

### Example

```powershell
DotNetChecker-Runbook -ResourceGroupName "MyResourceGroup" -AzureDevOpsOrg "MyOrg" -AzureDevOpsProject "MyProject" -AreaPath "MyProject\Team" -IterationPath "MyProject\Sprint1" -AssignedTo "user@domain.com" -LogAnalyticsWorkspaceId "workspace-id"
```

## .NET EOL Timeline

The solution includes the following EOL dates for .NET versions:

| Version | End of Support Date |
|---------|---------------------|
| 7.0     | May 14, 2024        |
| 6.0     | November 12, 2024   |
| 5.0     | May 10, 2022        |
| 3.1     | December 13, 2022   |
| 3.0     | March 3, 2020       |
| 2.2     | December 23, 2019   |
| 2.1     | August 21, 2021     |
| 2.0     | October 1, 2018     |
| 1.1     | June 27, 2019       |
| 1.0     | June 27, 2019       |

For .NET Framework, all versions except 4.8.x are considered EOL.


## Author

Tom Blanchard

## Acknowledgments

- Microsoft for providing .NET version information and installation scripts
- Azure Automation and Azure DevOps teams for their APIs and documentation