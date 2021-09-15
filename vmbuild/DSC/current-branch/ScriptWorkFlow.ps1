param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

$global:StatusFile = "C:\staging\DSC\DSC_Status.txt"
$global:StatusLog = "C:\staging\DSC\InstallCM.log"

function Write-DscStatusSetup {
    $StatusPrefix = "Setting up ConfigMgr. See ConfigMgrSetup.log"
    $StatusPrefix | Out-File $global:StatusFile -Force
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] $StatusPrefix" | Out-File -Append $global:StatusLog
}

function Write-DscStatus {
    param($status, [switch]$NoLog, [switch]$NoStatus, [int]$RetrySeconds)

    if ($RetrySeconds) {
        $status = "$status; checking again in $RetrySeconds seconds"
    }

    if (-not $NoStatus.IsPresent) {
        $StatusPrefix = "Setting up ConfigMgr."
        "$StatusPrefix Current Status: $status" | Out-File $global:StatusFile -Force
    }

    if (-not $NoLog.IsPresent) {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] $status" | Out-File -Append $global:StatusLog
    }
}

# Read required items from config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json
$Config = $deployConfig.parameters.Scenario
$CurrentRole = $deployConfig.parameters.ThisMachineRole

# Provision Tool path, RegisterTaskScheduler copies files here
$ProvisionToolPath = "$env:windir\temp\ProvisionScript"
if (!(Test-Path $ProvisionToolPath)) {
    New-Item $ProvisionToolPath -ItemType directory | Out-Null
}

# Script Workflow json file
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"

if (Test-Path -Path $ConfigurationFile) {
    $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
}
else {
    if ($Config -eq "Standalone") {
        [hashtable]$Actions = @{
            InstallSCCM    = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
            UpgradeSCCM    = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
            InstallDP      = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
            InstallMP      = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
            InstallClient  = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
            ScriptWorkflow = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
        }
    }
    else {
        if ($CurrentRole -eq "CS") {
            [hashtable]$Actions = @{
                InstallSCCM    = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                UpgradeSCCM    = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                PSReadytoUse   = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                ScriptWorkflow = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
            }
        }
        elseif ($CurrentRole -eq "PS") {
            [hashtable]$Actions = @{
                WaitingForCASFinsihedInstall = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                InstallSCCM                  = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                InstallDP                    = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                InstallMP                    = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                InstallClient                = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                ScriptWorkflow               = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
            }
        }
    }
    $Configuration = New-Object -TypeName psobject -Property $Actions
    $Configuration.ScriptWorkflow.Status = "Running"
    $Configuration.ScriptWorkflow.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
}

if ($Config -eq "Standalone") {

    #Install CM and Config
    $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallAndUpdateSCCM.ps1"
    . $ScriptFile $ConfigFilePath $LogPath

    #Install DP/MP/Client
    $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallDPMPClient.ps1"
    . $ScriptFile $ConfigFilePath $LogPath

}
else {
    if ($CurrentRole -eq "CS") {

        #Install CM and Config
        $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallAndUpdateSCCM.ps1"
        . $ScriptFile $ConfigFilePath $LogPath

    }
    elseif ($CurrentRole -eq "PS") {

        #Install CM and Config
        $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallPSForHierarchy.ps1"
        . $ScriptFile $ConfigFilePath $LogPath

        #Install DP/MP/Client
        $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallDPMPClient.ps1"
        . $ScriptFile $ConfigFilePath $LogPath
    }
}

Write-DscStatus "Finished setting up ConfigMgr."

# Mark ScriptWorkflow completed for DSC to move on.
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
$Configuration.ScriptWorkflow.Status = "Completed"
$Configuration.ScriptWorkflow.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
