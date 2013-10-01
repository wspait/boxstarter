function Install-BoxstarterPackage {
    [CmdletBinding()]
	param(
        [parameter(Mandatory=$true, Position=0, ParameterSetName="ComputerName")]
        [string]$ComputerName,
        [parameter(Mandatory=$true, Position=0, ParameterSetName="Uri")]
        [Uri]$ConnectionUri,
        [parameter(Mandatory=$true, Position=0, ParameterSetName="Session")]
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [parameter(Mandatory=$true, Position=0, ParameterSetName="Package")]
        [parameter(Mandatory=$true, Position=1, ParameterSetName="ComputerName")]
        [parameter(Mandatory=$true, Position=1, ParameterSetName="Uri")]
        [parameter(Mandatory=$true, Position=1, ParameterSetName="Session")]
        [string]$PackageName,
        [PSCredential]$Credential,
        [switch]$Force,
        [switch]$DisableReboots,
        [switch]$KeepWindowOpen,
        [switch]$NoPassword      
    )

    if($PsCmdlet.ParameterSetName -eq "Package"){
        Invoke-Locally @PSBoundParameters
        return
    }

    $ClientRemotingStatus=Enable-RemotingOnClient $ComputerName
    if(!$ClientRemotingStatus.Success){return}

    try{
        if(!(Enable-RemotingOnRemote $ComputerName $Credential)){return}

        if($session -eq $null){
            $session = New-PSSession $ComputerName -Credential $Credential -Authentication credssp -SessionOption @{ApplicationArguments=@{RemoteBoxstarter="MyValue"}}
        }

        Setup-BoxstarterModuleAndLocalRepo $session
        
        Invoke-Remotely $session $Credential $PackageName $DisableReboots $NoPassword
    }
    finally{
        if($session -ne $null) {Remove-PSSession $Session}
        if($ClientRemotingStatus.Success){
            Disable-WSManCredSSP -Role Client
            if($ClientRemotingStatus.PreviousCSSPTrustedHosts -ne $null){
                Write-BoxstarterMessage "Reseting CredSSP Trusted Hosts to $($ClientRemotingStatus.PreviousCSSPTrustedHosts.Replace('wsman/',''))"
                Enable-WSManCredSSP -DelegateComputer $ClientRemotingStatus.PreviousCSSPTrustedHosts.Replace("wsman/","") -Role Client -Force
            }
            if($ClientRemotingStatus.PreviousTrustedHosts -ne $null){
                Write-BoxstarterMessage "Reseting wsman Trusted Hosts to $($ClientRemotingStatus.PreviousTrustedHosts)"
                Set-Item "wsman:\localhost\client\trustedhosts" -Value "$($ClientRemotingStatus.PreviousTrustedHosts)" -Force
            }
        }
    }
}

function Confirm-Choice ($message, $caption = $message) {
    $yes = new-Object System.Management.Automation.Host.ChoiceDescription "&Yes","Yes";
    $no = new-Object System.Management.Automation.Host.ChoiceDescription "&No","No";
    $choices = [System.Management.Automation.Host.ChoiceDescription[]]($yes,$no);
    $answer = $host.ui.PromptForChoice($caption,$message,$choices,0)

    switch ($answer){
        0 {return $true; break}
        1 {return $false; break}
    }    
}

function Invoke-Locally {
    param(
        [string]$PackageName,
        [PSCredential]$Credential,
        [switch]$Force,
        [switch]$DisableReboots,
        [switch]$KeepWindowOpen,
        [switch]$NoPassword      
    )
    if($PSBoundParameters.ContainsKey("Credential")){
        if(!($PSBoundParameters.ContainsKey("NoPassword"))){
            $PSBoundParameters.Add("Password",$PSBoundParameters["Credential"].Password)
        }
        $PSBoundParameters.Remove("Credential") | out-Null
    }
    if($PSBoundParameters.ContainsKey("Force")){
        $PSBoundParameters.Remove("Force") | out-Null
    }
    $PSBoundParameters.Add("BootstrapPackage", $PSBoundParameters.PackageName)
    $PSBoundParameters.Remove("PackageName") | out-Null

    Invoke-ChocolateyBoxstarter @PSBoundParameters
}

function Enable-RemotingOnClient($RemoteHostToTrust){
    $Result=@{
        Success=$False;
        PreviousTrustedHosts=$null;
        PreviousCSSPTrustedHosts=$null
    }

    try { $credssp = Get-WSManCredSSP } catch { $credssp = $_}
    if($credssp.Exception -ne $null){
        Write-BoxstarterMessage "Local Powershell Remoting is not enabled"
        if($Force -or (Confirm-Choice "Powershell remoting is not enabled locally. Should Boxstarter enable powershell remoting?"))
        {
            Write-BoxstarterMessage "Enabling local Powershell Remoting"
            Enable-PSRemoting -Force
        }else {
            Write-BoxstarterMessage "Not enabling local Powershell Remoting aborting package install"
            return $Result
        }
    }

    if($credssp -is [Object[]]){
        $idxHosts=$credssp[0].IndexOf(": ")
        if($idxHosts -gt -1){
            $credsspEnabled=$True
            $Result.PreviousCSSPTrustedHosts=$credssp[0].substring($idxHosts+2)
            $hostArray=$Result.PreviousCSSPTrustedHosts.Split(",")
            if($hostArray -contains "wsman/$RemoteHostToTrust"){
                $ComputerAdded=$True
            }
        }
    }

    if($ComputerAdded -eq $null){
        Write-BoxstarterMessage "Adding $RemoteHostToTrust to allowed credSSP hosts"
        Enable-WSManCredSSP -DelegateComputer $RemoteHostToTrust -Role Client -Force
    }

    $Result.PreviousTrustedHosts=(Get-Item "wsman:\localhost\client\trustedhosts").Value
    $hostArray=$Result.PreviousTrustedHosts.Split(",")
    if($hostArray.length -eq 1 -and $hostArray[0].length -eq 0) {
        $newHosts=$RemoteHostToTrust
    }
    elseif(!($hostArray -contains $RemoteHostToTrust)){
        $newHosts=$Result.PreviousTrustedHosts + "," + $RemoteHostToTrust
    }
    if($newHosts -ne $null) {
        Write-BoxstarterMessage "Adding $newHosts to allowed wsman hosts"
        Set-Item "wsman:\localhost\client\trustedhosts" -Value $newHosts -Force
    }

    $Result.Success=$True
    return $Result
}

function Enable-RemotingOnRemote ($ComputerName, $Credential){
    Write-BoxstarterMessage "Testing remoting access on $ComputerName"
    $remotingTest = Invoke-Command $ComputerName { Get-WmiObject Win32_ComputerSystem } -Credential $Credential -ErrorAction SilentlyContinue
    if($remotingTest -eq $null){
        Write-BoxstarterMessage "Powershell Remoting is not enabled or accesible on $ComputerName"
        $wmiTest=Invoke-WmiMethod -Computer $ComputerName -Credential $Credential Win32_Process Create -Args "cmd.exe" -ErrorAction SilentlyContinue
        if($wmiTest -eq $null){
            Throw @"
Unable at access remote computer via Powershell Remoting or WMI. 
You can enable it by running:
 Enable-PSRemoting -Force 
from an Administrator Powershell console on the remote computer.
"@
        }
        if($Force -or (Confirm-Choice "Powershell Remoting is not enabled on Remote computer. Should Boxstarter enable powershell remoting?")){
            Write-BoxstarterMessage "Enabling Powershell Remoting on $ComputerName"
            Enable-RemotePSRemoting $ComputerName $Credential
        }
        else {
            Write-BoxstarterMessage "Not enabling local Powershell Remoting on $ComputerName. Aborting package install"
            return $False
        }
    }
    else {
        Write-BoxstarterMessage "Remoting is accesible on $ComputerName"
    }
    return $True
}

function Setup-BoxstarterModuleAndLocalRepo($session){
    Write-BoxstarterMessage "Copying Bootstraper to $($Session.ComputerName)"
    ."7za" a -tzip "$env:temp\Boxstarter.zip" "$($Boxstarter.basedir)\boxstarter.Common"
    ."7za" a -tzip "$env:temp\Boxstarter.zip" "$($Boxstarter.basedir)\boxstarter.WinConfig"
    ."7za" a -tzip "$env:temp\Boxstarter.zip" "$($Boxstarter.basedir)\boxstarter.bootstrapper"
    ."7za" a -tzip "$env:temp\Boxstarter.zip" "$($Boxstarter.basedir)\boxstarter.chocolatey"
    ."7za" a -tzip "$env:temp\Boxstarter.zip" "$($Boxstarter.basedir)\boxstarter.config"
    ."7za" a -tzip "$env:temp\Boxstarter.zip" "$($Boxstarter.basedir)\license.txt"
    Invoke-Command -Session $Session { mkdir $env:temp\boxstarter -Force }
    Send-File "$env:temp\Boxstarter.zip" "Boxstarter\boxstarter.zip" $session
    Get-ChildItem "$($Boxstarter.LocalRepo)\*.nupkg" | % { 
        Write-BoxstarterMessage "Copying $($_.Name) to $($Session.ComputerName)"
        Send-File "$($_.FullName)" "Boxstarter\$($_.Name)" $session 
    }
    Invoke-Command -Session $Session {
        Set-ExecutionPolicy Bypass -Force
        mkdir $env:appdata\boxstarter -Force
        $shellApplication = new-object -com shell.application 
        $zipPackage = $shellApplication.NameSpace("$env:temp\Boxstarter\Boxstarter.zip") 
        $destinationFolder = $shellApplication.NameSpace("$env:appdata\boxstarter") 
        $destinationFolder.CopyHere($zipPackage.Items(),0x10)
        Import-Module $env:Appdata\Boxstarter\Boxstarter.Chocolatey\Boxstarter.Chocolatey.psd1
        Set-BoxstarterConfig -LocalRepo "$env:temp\boxstarter"
    }
}

function Invoke-Remotely($session,$Credential,$Package,$DisableReboots,$NoPassword){
    while($session.State -eq "Opened") {
        $exitCode = Invoke-Command $session {
            param($pkg,$password,$DisableReboots,$NoPassword)
            Import-Module $env:Appdata\Boxstarter\Boxstarter.Chocolatey\Boxstarter.Chocolatey.psd1
            Set-BoxstarterConfig -LocalRepo "$env:temp\boxstarter"
            Invoke-ChocolateyBoxstarter $pkg -Password $password -SuppressRebootScript -NoPassword:$NoPassword -DisableReboots:$DisableReboots
        } -ArgumentList $Package, $Credential.Password, $DisableReboots, $NoPassword
        
        if($exitCode -eq 3010) {
            $response=$null
            Write-BoxstarterMessage "Waiting for $($session.ComputerName) to respond to remoting..."
            Do{
                $response=Invoke-Command $session.ComputerName { Get-WmiObject Win32_ComputerSystem } -Credential $credential -ErrorAction SilentlyContinue
            }
            Until($response -ne $null)
            Remove-PSSession $session
            $session = New-PSSession $ComputerName -Credential $Credential -Authentication credssp -SessionOption @{ApplicationArguments=@{RemoteBoxstarter="MyValue"}}
        }
        else {
            Remove-PSSession $session
        }
    }
}