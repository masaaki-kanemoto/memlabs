# InstallDPMPClient.ps1



param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get reguired values from config
$DomainFullName = $deployConfig.vmOptions.domainName
$DomainName = $DomainFullName.Split(".")[0]
$NetbiosDomainName = $deployConfig.vmOptions.domainNetBiosName

$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }

# bug fix to not deploy to other sites clients (also multi-network bug if we allow multi networks)
#$ClientNames = ($deployConfig.virtualMachines | Where-Object { $_.role -eq "DomainMember" -and -not ($_.hidden -eq $true)} -and -not ($_.SqlVersion)).vmName -join ","
$ClientNames = $thisVM.thisParams.ClientPush
$cm_svc = "$NetbiosDomainName\cm_svc"
$pushClients = $deployConfig.cmOptions.pushClientToDomainMembers

# Read Actions file
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

# Read Site Code from registry
$SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'
if (-not $SiteCode) {
    Write-DscStatus "Failed to get 'Site Code' from SOFTWARE\Microsoft\SMS\Identification. Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
    return
}

# Provider
$smsProvider = Get-SMSProvider -SiteCode $SiteCode
if (-not $smsProvider.FQDN) {
    Write-DscStatus "Failed to get SMS Provider for site $SiteCode. Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
    return $false
}

# Set CMSite Provider
$worked = Set-CMSiteProvider -SiteCode $SiteCode -ProviderFQDN $($smsProvider.FQDN)
if (-not $worked) {
    return
}

# Set the current location to be the site code.
Set-Location "$($SiteCode):\"
if ((Get-Location).Drive.Name -ne $SiteCode) {
    Write-DscStatus "Failed to Set-Location to $SiteCode`:"
    return $false
}

$cm_svc_file = "$LogPath\cm_svc.txt"
if (Test-Path $cm_svc_file) {
    # Add cm_svc user as a CM Account
    $secure = Get-Content $cm_svc_file | ConvertTo-SecureString -AsPlainText -Force
    Write-DscStatus "Adding cm_svc domain account as CM account"
    Start-Sleep -Seconds 5
    New-CMAccount -Name $cm_svc -Password $secure -SiteCode $SiteCode | Out-File $global:StatusLog -Append
    Remove-Item -Path $cm_svc_file -Force -Confirm:$false

    # Set client push account
    Write-DscStatus "Setting the Client Push Account"
    Set-CMClientPushInstallation -SiteCode $SiteCode -AddAccount $cm_svc
    Start-Sleep -Seconds 5

    # Restart services to make sure push account is acknowledged by CCM
    Write-DscStatus "Restarting services"
    Restart-Service -DisplayName "SMS_Executive" -ErrorAction SilentlyContinue
    Restart-Service -DisplayName "SMS_Site_Component_Manager" -ErrorAction SilentlyContinue
}

$DPs = @()
$MPs = @()
$PullDPs = @()
$ValidSiteCodes = @($SiteCode)
$ReportingSiteCodes = Get-CMSite | Where-Object { $_.ReportingSiteCode -eq $SiteCode } | Select-Object -Expand SiteCode
$ValidSiteCodes += $ReportingSiteCodes

foreach ($dpmp in $deployConfig.virtualMachines | Where-Object { $_.role -eq "DPMP" } ) {
    if ($dpmp.siteCode -in $ValidSiteCodes) {
        if ($dpmp.installDP) {
            if ($dpmp.enablePullDP) {
                $PullDPs += [PSCustomObject]@{
                    ServerName     = $dpmp.vmName
                    ServerSiteCode = $dpmp.siteCode
                    SourceDP       = $dpmp.pullDPSourceDP
                }
            }
            else {
                $DPs += [PSCustomObject]@{
                    ServerName     = $dpmp.vmName
                    ServerSiteCode = $dpmp.siteCode
                }
            }
        }
        if ($dpmp.installMP) {
            if ($dpmp.siteCode -notin $ReportingSiteCodes) {
                $MPs += [PSCustomObject]@{
                    ServerName     = $dpmp.vmName
                    ServerSiteCode = $dpmp.siteCode
                }
            }
            else {
                Write-DscStatus "Skip MP role for $($dpmp.vmName) since it's a remote site system in Secondary site"
            }
        }
    }
}

# Trim nulls/blanks
$DPNames = $DPs.ServerName | Where-Object { $_ -and $_.Trim() }
$PullDPNames = $PullDPs.ServerName | Where-Object { $_ -and $_.Trim() }
$MPNames = $MPs.ServerName | Where-Object { $_ -and $_.Trim() }

Write-DscStatus "MP role to be installed on '$($MPNames -join ',')'"
Write-DscStatus "DP role to be installed on '$($DPNames -join ',')'"
Write-DscStatus "Pull DP role to be installed on '$($PullDPNames -join ',')'"
Write-DscStatus "Client push candidates are '$ClientNames'"

foreach ($DP in $DPs) {

    if ([string]::IsNullOrWhiteSpace($DP.ServerName)) {
        Write-DscStatus "Found an empty DP ServerName. Skipping"
        continue
    }

    $DPFQDN = $DP.ServerName.Trim() + "." + $DomainFullName
    Install-DP -ServerFQDN $DPFQDN -ServerSiteCode $DP.ServerSiteCode
}

foreach ($MP in $MPs) {

    if ([string]::IsNullOrWhiteSpace($MP.ServerName)) {
        Write-DscStatus "Found an empty MP ServerName. Skipping"
        continue
    }

    $MPFQDN = $MP.ServerName.Trim() + "." + $DomainFullName
    Install-MP -ServerFQDN $MPFQDN -ServerSiteCode $MP.ServerSiteCode
}


foreach ($PDP in $PullDPs) {

    if ([string]::IsNullOrWhiteSpace($PDP.ServerName)) {
        Write-DscStatus "Found an empty Pull DP ServerName. Skipping"
        continue
    }

    if ([string]::IsNullOrWhiteSpace($PDP.SourceDP)) {
        Write-DscStatus "Found Pull DP $($PDP.ServerName) with empty SourceDP. Skipping"
        continue
    }

    $DPFQDN = $PDP.ServerName.Trim() + "." + $DomainFullName
    $SourceDPFQDN = $PDP.SourceDP.Trim() + "." + $DomainFullName
    Install-PullDP -ServerFQDN $DPFQDN -ServerSiteCode $PDP.ServerSiteCode -SourceDPFQDN $SourceDPFQDN
}

# Force install DP/MP on PS Site Server if none present
$dpCount = (Get-CMDistributionPoint -SiteCode $SiteCode | Measure-Object).Count
$mpCount = (Get-CMManagementPoint -SiteCode $SiteCode | Measure-Object).Count

if ($dpCount -eq 0) {
    Write-DscStatus "No DP's were found in this site. Forcing DP install on Site Server $ThisMachineName"
    Install-DP -ServerFQDN ($ThisMachineName + "." + $DomainFullName) -ServerSiteCode $SiteCode
}

if ($mpCount -eq 0) {
    Write-DscStatus "No MP's were found in this site. Forcing MP install on Site Server $ThisMachineName"
    Install-MP -ServerFQDN ($ThisMachineName + "." + $DomainFullName) -ServerSiteCode $SiteCode
}

# Create Boundary groups
$bgs = $ThisVM.thisParams.sitesAndNetworks | Where-Object { $_.SiteCode -in $ValidSiteCodes }
$bgsCount = $bgs.count
Write-DscStatus "Create $bgsCount Boundary Groups"
foreach ($bgsitecode in ($bgs.SiteCode | Select-Object -Unique)) {
    $siteStatus = Get-CMSite -SiteCode $bgsitecode
    if ($siteStatus.Status -eq 1) {
        $dpmplist = @()
        $dpmplist += (Get-CMDistributionPoint -SiteCode $bgsitecode).NetworkOSPath -replace "\\", ""
        $dpmplist += (Get-CMManagementPoint -SiteCode $bgsitecode).NetworkOSPath -replace "\\", ""
        $dpmplist = $dpmplist | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique
        try {
            $exists = Get-CMBoundaryGroup -Name $bgsitecode
            if ($exists) {
                Write-DscStatus "Updating Boundary Group '$bgsitecode' with Site Systems $($dpmplist -join ',')"
                Set-CMBoundaryGroup -Name $bgsiteCode -AddSiteSystemServerName $dpmplist
            }
            else {
                Write-DscStatus "Creating Boundary Group '$bgsitecode' with Site Systems $($dpmplist -join ',')"
                New-CMBoundaryGroup -Name $bgsitecode -DefaultSiteCode $SiteCode -AddSiteSystemServerName $dpmplist
            }
        }
        catch {
            Write-DscStatus "Failed to create Boundary Group '$bgsitecode'. Error: $_"
        }
    }
    else {
        Write-DscStatus "Skip creating Boundary groups for site $bgsitecode because Site Status is not 'Active'."
    }
    Start-Sleep -Seconds 5
}

# Create Boundaries for each subnet and add to BG
Write-DscStatus "Create Boundaries for each subnet and add to BG"
foreach ($bg in $bgs) {
    $exists = Get-CMBoundary -BoundaryName $bg.Subnet
    if ($exists) {
        try {
            Write-DscStatus "Adding Boundary $($bg.SiteCode) with subnet $($bg.Subnet) to Boundary Group $($bg.SiteCode)"
            Add-CMBoundaryToGroup -BoundaryName $bg.Subnet -BoundaryGroupName $bg.SiteCode
        }
        catch {
            Write-DscStatus "Failed to add boundary '$($bg.Subnet)' to Boundary Group '$($bg.SiteCode)'. Error: $_"
        }
    }
    else {
        try {
            Write-DscStatus "Creating Boundary $($bg.SiteCode) with subnet $($bg.Subnet)"
            New-CMBoundary -Type IPSubnet -Name $bg.Subnet -Value "$($bg.Subnet)/24"
            try {
                Write-DscStatus "Adding Boundary $($bg.SiteCode) with subnet $($bg.Subnet) to Boundary Group $($bg.SiteCode)"
                Add-CMBoundaryToGroup -BoundaryName $bg.Subnet -BoundaryGroupName $bg.SiteCode
            }
            catch {
                Write-DscStatus "Failed to add boundary '$($bg.Subnet)' to Boundary Group '$($bg.SiteCode)'. Error: $_"
            }
        }
        catch {
            Write-DscStatus "Failed to create boundary '$($bg.Subnet)'. Error: $_"
        }
    }

    Start-Sleep -Seconds 5
}

# Setup System Discovery
Write-DscStatus "Enabling AD system discovery"
$lastdomainname = $DomainFullName.Split(".")[-1]
do {
    $adiscovery = (Get-CMDiscoveryMethod | Where-Object { $_.ItemName -eq "SMS_AD_SYSTEM_DISCOVERY_AGENT|SMS Site Server" }).Props | Where-Object { $_.PropertyName -eq "Settings" }

    if ($adiscovery.Value1.ToLower() -ne "active") {
        Write-DscStatus "AD System Discovery state is: $($adiscovery.Value1)" -RetrySeconds 30
        Start-Sleep -Seconds 30
        Set-CMDiscoveryMethod -ActiveDirectorySystemDiscovery -SiteCode $SiteCode -Enabled $true -AddActiveDirectoryContainer "LDAP://DC=$DomainName,DC=$lastdomainname" -Recursive
    }
    else {
        Write-DscStatus "AD System Discovery state is: $($adiscovery.Value1)"
    }
} until ($adiscovery.Value1.ToLower() -eq "active")

# Run discovery
Write-DscStatus "Invoking AD system discovery"
Start-Sleep -Seconds 5
Invoke-CMSystemDiscovery
Start-Sleep -Seconds 5

if ($ThisVm.thisParams.PassiveNode) {
    Write-DscStatus "Skip Client Push since we're adding Passive site server"
    $pushClients = $false
    #return
}

# Push Clients
#==============
if (-not $pushClients) {
    Write-DscStatus "Skipping Client Push. pushClientToDomainMembers options is set to false."
    $Configuration.InstallClient.Status = 'NotRequested'
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}

# Wait for collection to populate
$CollectionName = "All Systems"
Write-DscStatus "Waiting for clients to appear in '$CollectionName'"
$ClientNameList = $ClientNames.split(",")
$machinelist = (get-cmdevice -CollectionName $CollectionName).Name
Start-Sleep -Seconds 5

foreach ($client in $ClientNameList) {

    if ([string]::IsNullOrWhiteSpace($client)) {
        continue
    }

    $testClient = Test-NetConnection -ComputerName $client -CommonTCPPort SMB -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    if (-not $testClient.TcpTestSucceeded) {
        # Don't wait for client to appear in collection if it's not online
        Write-DscStatus "Could not test SMB connection to $client. Skipping."
        continue
    }

    $failCount = 0
    $success = $true
    while ($machinelist -notcontains $client) {
        if ($failCount -gt 30) {
            $success = $false
            break
        }
        Invoke-CMSystemDiscovery
        Invoke-CMDeviceCollectionUpdate -Name $CollectionName

        Write-DscStatus "Waiting for $client to appear in '$CollectionName'" -RetrySeconds 30
        Start-Sleep -Seconds 30
        $machinelist = (get-cmdevice -CollectionName $CollectionName).Name
        $failCount++
    }
    if ($success) {
        Write-DscStatus "Pushing client to $client."
        Install-CMClient -DeviceName $client -SiteCode $SiteCode -AlwaysInstallClient $true | Out-File $global:StatusLog -Append
        Start-Sleep -Seconds 5
    }
}

# Update actions file
$Configuration.InstallClient.Status = 'Completed'
$Configuration.InstallClient.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
