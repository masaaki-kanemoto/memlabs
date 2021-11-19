configuration SecondaryConfiguration
{
    param
    (
        [Parameter(Mandatory)]
        [string]$ConfigFilePath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'ComputerManagementDsc'

    # Read config
    $deployConfig = Get-Content -Path $ConfigFilePath | ConvertFrom-Json
    $ThisMachineName = $deployConfig.parameters.ThisMachineName
    $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }
    $DomainName = $deployConfig.parameters.domainName
    $DCName = $deployConfig.parameters.DCName

    # Passive Site Config Props
    $PSName = $deployConfig.parameters.PSName
    if (-not $PSName) {
        $PSName = $deployConfig.parameters.ExistingPSName
    }

    # Log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # Domain creds
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)

    Node LOCALHOST
    {
        LocalConfigurationManager {
            ConfigurationMode  = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        WriteStatus Rename {
            Status = "Renaming the computer to $ThisMachineName"
        }

        Computer NewName {
            Name = $ThisMachineName
        }

        WriteStatus InitDisks {
            DependsOn = "[Computer]NewName"
            Status    = "Initializing disks"
        }

        InitializeDisks InitDisks {
            DependsOn = "[Computer]NewName"
            DummyKey  = "Dummy"
            VM        = $ThisVM | ConvertTo-Json
        }

        SetCustomPagingFile PagingSettings {
            DependsOn   = "[InitializeDisks]InitDisks"
            Drive       = 'C:'
            InitialSize = '8192'
            MaximumSize = '8192'
        }

        WriteStatus InstallFeature {
            DependsOn = "[SetCustomPagingFile]PagingSettings"
            Status    = "Installing required windows features"
        }

        InstallFeatureForSCCM InstallFeature {
            NAME      = "Primary"
            Role      = "Site Server"
            DependsOn = "[SetCustomPagingFile]PagingSettings"
        }

        WriteStatus WaitDomain {
            DependsOn = "[InstallFeatureForSCCM]InstallFeature"
            Status    = "Waiting for domain to be ready"
        }

        WaitForDomainReady WaitForDomain {
            Ensure     = "Present"
            DomainName = $DomainName
            DCName     = $DCName
            DependsOn  = "[InstallFeatureForSCCM]InstallFeature"
        }

        WriteStatus DomainJoin {
            DependsOn = "[WaitForDomainReady]WaitForDomain"
            Status    = "Joining computer to the domain"
        }

        JoinDomain JoinDomain {
            DomainName = $DomainName
            Credential = $DomainCreds
            DependsOn  = "[WaitForDomainReady]WaitForDomain"
        }

        WriteStatus OpenPorts {
            DependsOn = "[JoinDomain]JoinDomain"
            Status    = "Open required firewall ports"
        }

        OpenFirewallPortForSCCM OpenFirewall {
            DependsOn = "[JoinDomain]JoinDomain"
            Name      = "Primary"
            Role      = "Site Server"
        }

        WriteStatus InstallDotNet {
            DependsOn = '[OpenFirewallPortForSCCM]OpenFirewall'
            Status    = "Installing .NET 4.7.2"
        }

        InstallDotNet472 DotNet {
            DownloadUrl = "https://download.visualstudio.microsoft.com/download/pr/1f5af042-d0e4-4002-9c59-9ba66bcf15f6/089f837de42708daacaae7c04b7494db/ndp472-kb4054530-x86-x64-allos-enu.exe"
            Ensure      = "Present"
            DependsOn   = "[WriteStatus]InstallDotNet"
        }

        File ShareFolder {
            DestinationPath = $LogPath
            Type            = 'Directory'
            Ensure          = 'Present'
            DependsOn       = '[InstallDotNet472]DotNet'
        }

        FileReadAccessShare DomainSMBShare {
            Name      = $LogFolder
            Path      = $LogPath
            DependsOn = "[File]ShareFolder"
        }

        WriteEvent WriteJoinDomain {
            LogPath   = $LogPath
            WriteNode = "MachineJoinDomain"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[FileReadAccessShare]DomainSMBShare"
        }

        AddNtfsPermissions AddNtfsPerms {
            Ensure    = "Present"
            DependsOn = "[WriteEvent]WriteJoinDomain"
        }

        WriteStatus SSMS {
            DependsOn = "[AddNtfsPermissions]AddNtfsPerms"
            Status    = "Downloading and installing SQL Management Studio"
        }

        InstallSSMS SSMS {
            DownloadUrl = "https://aka.ms/ssmsfullsetup"
            Ensure      = "Present"
            DependsOn   = "[WriteStatus]SSMS"
        }

        WriteStatus WaitDelegate {
            DependsOn = "[InstallSSMS]SSMS"
            Status    = "Wait for DC to assign permissions to Systems Management container"
        }

        WaitForEvent DelegateControl {
            MachineName   = $DCName
            LogFolder     = $LogFolder
            ReadNode      = "DelegateControl"
            ReadNodeValue = "Passed"
            Ensure        = "Present"
            DependsOn     = "[InstallSSMS]SSMS"
        }

        AddUserToLocalAdminGroup AddActiveLocalAdmin {
            Name       = "$PSName$"
            DomainName = $DomainName
            DependsOn  = "[WaitForEvent]DelegateControl"
        }

        WriteEvent ReadyForPrimary {
            LogPath   = $LogPath
            WriteNode = "ReadyForPrimary"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[AddUserToLocalAdminGroup]AddActiveLocalAdmin"
        }

        WriteStatus WaitPrimary {
            DependsOn = "[WriteEvent]ReadyForPrimary"
            Status    = "Waiting for Site Server $PSName to finish configuration."
        }

        WaitForEvent WaitPrimary {
            MachineName   = $PSName
            LogFolder     = $LogFolder
            FileName      = "ScriptWorkflow"
            ReadNode      = "ScriptWorkflow"
            ReadNodeValue = "Completed"
            Ensure        = "Present"
            DependsOn     = "[WriteStatus]WaitPrimary"
        }

        WriteStatus Complete {
            DependsOn = "[WaitForEvent]WaitPrimary"
            Status    = "Complete!"
        }

        WriteEvent WriteConfigFinished {
            LogPath   = $LogPath
            WriteNode = "ConfigurationFinished"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[WriteStatus]Complete"
        }

    }

}