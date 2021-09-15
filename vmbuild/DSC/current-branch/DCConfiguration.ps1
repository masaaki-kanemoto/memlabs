﻿configuration DCConfiguration
{
    param
    (
        [Parameter(Mandatory)]
        [string]$ConfigFilePath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'xDhcpServer', 'DnsServerDsc', 'ComputerManagementDsc', 'ActiveDirectoryDsc'

    # Read config
    $deployConfig = Get-Content -Path $ConfigFilePath | ConvertFrom-Json
    $ThisMachineName = $deployConfig.parameters.ThisMachineName
    $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }
    $DomainName = $deployConfig.parameters.domainName
    $PSName = $deployConfig.parameters.PSName
    $CSName = $deployConfig.parameters.CSName
    $DPMPName = $deployConfig.parameters.DPMPName
    $DHCP_DNSAddress = $deployConfig.parameters.DHCPDNSAddress
    $DHCP_DefaultGateway = $deployConfig.parameters.DHCPDefaultGateway
    $DHCP_ScopeId = $deployConfig.parameters.DHCPScopeId
    $DHCP_ScopeStart = $deployConfig.parameters.DHCPScopeStart
    $DHCP_ScopeEnd = $deployConfig.parameters.DHCPScopeEnd
    $Configuration = $deployConfig.parameters.Scenario

    # Define log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # CM Files folder/share
    $CM = if ($deployConfig.cmOptions.version -eq "tech-preview") { "CMTP" } else { "CMCB" }

    # Domain creds
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)

    Node LOCALHOST
    {
        LocalConfigurationManager {
            ConfigurationMode  = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        WriteStatus NewName {
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
            Name      = 'DC'
            Role      = 'DC'
            DependsOn = "[SetCustomPagingFile]PagingSettings"
        }

        WriteStatus FirstDS {
            DependsOn = "[InstallFeatureForSCCM]InstallFeature"
            Status    = "Configuring ADDS and setting up the domain. The computer will reboot a couple of times."
        }

        SetupDomain FirstDS {
            DependsOn                     = "[InstallFeatureForSCCM]InstallFeature"
            DomainFullName                = $DomainName
            SafemodeAdministratorPassword = $DomainCreds
        }

        ADUser Admin {
            Ensure              = 'Present'
            UserName            = 'admin'
            Password            = $DomainCreds
            PasswordNeverResets = $true
            DomainName          = $DomainName
            DependsOn           = "[SetupDomain]FirstDS"
        }

        ADUser cm-svc {
            Ensure              = 'Present'
            UserName            = 'cm_svc'
            Password            = $DomainCreds
            PasswordNeverResets = $true
            DomainName          = $DomainName
            DependsOn           = "[SetupDomain]FirstDS"
        }

        ADGroup AddToAdmin {
            GroupName        = "Administrators"
            MembersToInclude = @("admin")
            DependsOn        = "[ADUser]Admin"
        }

        ADGroup AddToDomainAdmin {
            GroupName        = "Domain Admins"
            MembersToInclude = @("admin")
            DependsOn        = @("[ADUser]Admin", "[ADUser]cm-svc")
        }

        ADGroup AddToSchemaAdmin {
            GroupName        = "Schema Admins"
            MembersToInclude = @("admin")
            DependsOn        = "[ADUser]Admin"
        }

        WriteStatus NetworkDNS {
            DependsOn = "[SetupDomain]FirstDS"
            Status    = "Setting Primary DNS, Default Gateway and configuring DNS Forwarders"
        }

        IPAddress NewIPAddressDC {
            DependsOn      = "[SetupDomain]FirstDS"
            IPAddress      = $DHCP_DNSAddress
            InterfaceAlias = 'Ethernet'
            AddressFamily  = 'IPV4'
        }

        DefaultGatewayAddress SetDefaultGateway {
            DependsOn      = "[IPAddress]NewIPAddressDC"
            Address        = $DHCP_DefaultGateway
            InterfaceAlias = 'Ethernet'
            AddressFamily  = 'IPv4'
        }

        DnsServerForwarder DnsServerForwarder {
            DependsOn        = "[DefaultGatewayAddress]SetDefaultGateway"
            IsSingleInstance = 'Yes'
            IPAddresses      = @('1.1.1.1', '8.8.8.8', '9.9.9.9')
            UseRootHint      = $true
            EnableReordering = $true
        }

        WriteStatus NetworkDHCP {
            DependsOn = "[DnsServerForwarder]DnsServerForwarder"
            Status    = "Installing DHCP and configuring DHCP scopes & options"
        }

        WindowsFeature DHCP {
            DependsOn            = "[DnsServerForwarder]DnsServerForwarder"
            Name                 = 'DHCP'
            Ensure               = 'Present'
            IncludeAllSubFeature = $true
        }

        WindowsFeature RSAT-DHCP {
            DependsOn            = "[WindowsFeature]DHCP"
            Name                 = 'RSAT-DHCP'
            Ensure               = 'Present'
            IncludeAllSubFeature = $true
        }

        xDhcpServerAuthorization LocalServerActivation {
            DependsOn        = "[WindowsFeature]RSAT-DHCP"
            IsSingleInstance = 'Yes'
            Ensure           = 'Present'
        }

        xDhcpServerScope Scope {
            DependsOn     = "[xDhcpServerAuthorization]LocalServerActivation"
            Ensure        = 'Present'
            ScopeId       = $DHCP_ScopeId
            IPStartRange  = $DHCP_ScopeStart
            IPEndRange    = $DHCP_ScopeEnd
            Name          = $DHCP_ScopeId
            SubnetMask    = '255.255.255.0'
            LeaseDuration = ((New-TimeSpan -Hours 72).ToString())
            State         = 'Active'
            AddressFamily = 'IPv4'
        }

        DhcpScopeOptionValue ScopeOptionGateway {
            DependsOn     = "[xDhcpServerScope]Scope"
            OptionId      = 3
            Value         = $DHCP_DefaultGateway
            ScopeId       = $DHCP_ScopeId
            VendorClass   = ''
            UserClass     = ''
            AddressFamily = 'IPv4'
        }

        DhcpScopeOptionValue ScopeOptionDNS {
            DependsOn     = "[DhcpScopeOptionValue]ScopeOptionGateway"
            OptionId      = 6
            Value         = @($DHCP_DNSAddress)
            ScopeId       = $DHCP_ScopeId
            VendorClass   = ''
            UserClass     = ''
            AddressFamily = 'IPv4'
        }

        WriteStatus ADCS {
            DependsOn = "[DhcpScopeOptionValue]ScopeOptionDNS"
            Status    = "Installing Certificate Authority"
        }

        InstallCA InstallCA {
            DependsOn     = "[DhcpScopeOptionValue]ScopeOptionDNS"
            HashAlgorithm = "SHA256"
        }

        if (-not $PSName) {

            WriteStatus Complete {
                DependsOn = "[InstallCA]InstallCA"
                Status    = "Complete!"
            }

            return
        }

        WriteStatus WaitDomainJoin {
            DependsOn = "[InstallCA]InstallCA"
            Status    = "Waiting for computers to join the domain"
        }

        File ShareFolder {
            DestinationPath = $LogPath
            Type            = 'Directory'
            Ensure          = 'Present'
            DependsOn       = "[InstallCA]InstallCA"
        }

        FileReadAccessShare DomainSMBShare {
            Name      = $LogFolder
            Path      = $LogPath
            DependsOn = "[File]ShareFolder"
        }

        VerifyComputerJoinDomain WaitForPS {
            ComputerName = $PSName
            Ensure       = "Present"
            DependsOn    = "[FileReadAccessShare]DomainSMBShare"
        }

        WriteConfigurationFile WritePSJoinDomain {
            Role      = "DC"
            LogPath   = $LogPath
            WriteNode = "PSJoinDomain"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[VerifyComputerJoinDomain]WaitForPS"
        }

        DelegateControl AddPS {
            Machine        = $PSName
            DomainFullName = $DomainName
            Ensure         = "Present"
            DependsOn      = "[WriteConfigurationFile]WritePSJoinDomain"
        }

        if ($Configuration -eq 'Standalone') {

            WriteConfigurationFile WriteDelegateControlfinished {
                Role      = "DC"
                LogPath   = $LogPath
                WriteNode = "DelegateControl"
                Status    = "Passed"
                Ensure    = "Present"
                DependsOn = "[DelegateControl]AddPS"
            }

        }
        else { # Hierarchy

            VerifyComputerJoinDomain WaitForCS {
                ComputerName = $CSName
                Ensure       = "Present"
                DependsOn    = "[FileReadAccessShare]DomainSMBShare"
            }

            WriteConfigurationFile WriteCSJoinDomain {
                Role      = "DC"
                LogPath   = $LogPath
                WriteNode = "CSJoinDomain"
                Status    = "Passed"
                Ensure    = "Present"
                DependsOn = "[VerifyComputerJoinDomain]WaitForCS"
            }

            DelegateControl AddCS {
                Machine        = $CSName
                DomainFullName = $DomainName
                Ensure         = "Present"
                DependsOn      = "[WriteConfigurationFile]WriteCSJoinDomain"
            }

            WriteConfigurationFile WriteDelegateControlfinished {
                Role      = "DC"
                LogPath   = $LogPath
                WriteNode = "DelegateControl"
                Status    = "Passed"
                Ensure    = "Present"
                DependsOn = @("[DelegateControl]AddCS", "[DelegateControl]AddPS")
            }
        }

        WriteStatus WaitExtSchema {
            DependsOn = "[WriteConfigurationFile]WriteDelegateControlfinished"
            Status    = "Waiting for site to download ConfigMgr source files, before extending schema for Configuration Manager"
        }

        WaitForExtendSchemaFile WaitForExtendSchemaFile {
            MachineName = if ($Configuration -eq 'Standalone') { $PSName } else { $CSName }
            ExtFolder   = $CM
            Ensure      = "Present"
            DependsOn   = "[WriteConfigurationFile]WriteDelegateControlfinished"
        }

        WriteStatus Complete {
            DependsOn = "[WaitForExtendSchemaFile]WaitForExtendSchemaFile"
            Status    = "Complete!"
        }
    }
}