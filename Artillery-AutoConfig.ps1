<#
Sets up Docker on a Windows host and creates a new container running Artillery on Server Core.

Prerequisite e: Make sure BIOS-based virtualization options are enabled. Otherwise, you'll see an error when trying to build container images.
#>

# 1. Enable Hyper-V

if($(Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V |Select-Object -ExpandProperty State) -match "Enabled"){
    Write-Host -ForegroundColor Green "Hyper-V already enabled. Moving on to install docker"
}
else{
    Write-Host "Enabling Hyper-V.  Please follow the prompt once enabled and reboot before continuing."
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
}

# 2. Enable Containers feature

if($(Get-WindowsOptionalFeature -Online -FeatureName Containers | Select-Object -ExpandProperty State) -match "Enabled"){
    Write-Host -ForegroundColor Green "Containers feature is already enabled."
}
else{
    Write-Host "Enabling Containers feature."
    Enable-WindowsOptionalFeature -Online -FeatureName Containers -All
}

# 3. Check for Docker
if(-not (Test-Path "C:\Program Files\docker\dockerd.exe")){

    # 3a. Install Docker if not found
    #Source: https://docs.microsoft.com/en-us/virtualization/windowscontainers/manage-docker/configure-docker-daemon#install-docker

    Write-Host -ForegroundColor Yellow "Docker not installed - installing now"

    #Download software
    Invoke-WebRequest "https://master.dockerproject.org/windows/x86_64/docker.zip" -OutFile "$env:TEMP\docker.zip" -UseBasicParsing
    Expand-Archive -Path "$env:TEMP\docker.zip" -DestinationPath $env:ProgramFiles

    # Add to path
    $env:path += ";$env:ProgramFiles\Docker"
    $existingMachinePath = [Environment]::GetEnvironmentVariable("Path",[System.EnvironmentVariableTarget]::Machine)
    [Environment]::SetEnvironmentVariable("Path", $existingMachinePath + ";$env:ProgramFiles\Docker", [EnvironmentVariableTarget]::Machine)

    dockerd --register-service
    Start-Service Docker

    if(Get-Service Docker){
        Write-Host -ForegroundColor Green "Docker successfully installed"
    }
    else{
        Write-Host -ForegroundColor Red "Docker failed to install. Exiting"
        exit
    }
}
else{
    Write-Host -ForegroundColor Green "Docker already installed. Proceeding to next step."
}

# 4. Set up Artillery
function artilleryConfig{
# 4a. Check if Artillery container is already running
    #Initial Setup
    $containerRunning = 0
    $artilleryDockerFileLocation = $PSScriptRoot + "\artillery-docker"
    $artilleryDockerFile = Get-Content $($artilleryDockerFileLocation + "\dockerfile")
    $currentlyListeningPorts = Get-NetTCPConnection -State Listen | Where-Object {$_.RemoteAddress -eq "0.0.0.0"} |Select-Object -ExpandProperty LocalPort
    [System.Collections.ArrayList]$artilleryPorts = @()
    #Compare ports to make sure we don't try to listen on anything that is currently active
    $newExposeLine = ""
    $exposeRegex = "EXPOSE.*"
    foreach($line in $artilleryDockerFile){
        if($line -imatch $exposeRegex){
            $artilleryPorts = $line -split '\s+' | Where-Object {$_ -match "\d+"}
            [System.Collections.ArrayList]$portsToNotExpose = @(Compare-Object -ExcludeDifferent -IncludeEqual $artilleryPorts $currentlyListeningPorts | Select-Object -ExpandProperty InputObject)

            #If honeyports are already being used, exclude them from Artillery ports
            foreach($duplicatePort in $portsToNotExpose){
                $artilleryPorts.Remove($duplicatePort)
            }

            #Build new Expose line
            $newExposeLine = "EXPOSE"
            $dockerRunPorts = ""
            foreach($port in $artilleryPorts){
                $newExposeLine += " " + $port
                $dockerRunPorts += "-p " + $port + ":" + $port + " "
            }
        }
    }

    #Check to see if Docker image exists
    $imagesRes = Invoke-Expression 'docker images artillery-docker' -ErrorAction SilentlyContinue
    if(($imagesRes | Where-Object {$_ -imatch "artillery\-docker*"})){
        #Check if it is running
        if(docker ps -f ancestor=artillery-docker | Where-Object {$_ -imatch "artillery\-docker*"}){
            $containerRunning = 1
            Write-Host -ForegroundColor Green "Artillery image already exists and is running.  No need for additional configuration."   
        }
        else{
            Write-Host -ForegroundColor Yellow "Artillery image exists, but is not running. Starting now..."
        }
    }
    else{
        if($newExposeLine -ne ""){
            Write-Host -ForegroundColor Yellow "Port conflict in Artillery config - writing new Expose line to not affect running services"
            $artilleryDockerFile -replace $exposeRegex, $newExposeLine | Set-Content $($artilleryDockerFileLocation + "\dockerfile")
        }   
        Set-Location $artilleryDockerFileLocation
        Write-Host "Building container"
        $dockerBuildStr = "docker build -t artillery-docker $artilleryDockerFileLocation"
        Invoke-Expression $dockerBuildStr -ErrorAction SilentlyContinue
    }

    #Start container if it isn't already running
    if($containerRunning -eq 0){
        $dockerRunCMD = "docker run $dockerRunPorts -dt artillery-docker python 'C:\program files (x86)\Artillery\artillery.py'"
        Invoke-Expression $dockerRunCMD -ErrorAction SilentlyContinue
        if(docker ps -f ancestor=artillery-docker | Where-Object {$_ -imatch "artillery\-docker*"}){
            Write-Host -ForegroundColor Green "Successfully started container"
            
            $resetPortFwd = "netsh interface portproxy reset"
            Invoke-Expression $resetPortFwd
            Write-Host "Reset existing port forwarding configuration. Setting up port forwarding to newly built container for all honeyports available on this host."
            
            $containerID = docker ps -f ancestor=artillery-docker --format '{{.ID}}'
            $containerIP = docker inspect -f "{{ .NetworkSettings.Networks.nat.IPAddress }}" $containerID
            
            #Open Windows Firewall for Artillery Ports
            Write-Host "Opening Windows firewall for Artillery Ports. If you disable this container, make sure you run 'Remove-NetFirewallRule -DisplayName `"ArtilleryPorts`"'!!"
            if(Get-NetFirewallRule -DisplayName 'ArtilleryPorts' -ErrorAction SilentlyContinue){
                #Remove rule and create new one just in case ports have changed
                Remove-NetFirewallRule -DisplayName 'ArtilleryPorts'
            }
            New-NetFirewallRule -DisplayName 'ArtilleryPorts' -Profile @('Domain', 'Private') -Direction Inbound -Action Allow -Protocol TCP -LocalPort $artilleryPorts -Enabled True | Out-Null
            $auditPolicyExpression = "Auditpol /set /category:`"System`" /SubCategory:`"Filtering Platform Connection`" /success:enable /failure:enable"
            Invoke-Expression $auditPolicyExpression | Out-Null
            foreach($port in $artilleryPorts){
                $portFwdCommand = "netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$port connectaddress=$containerIP connectport=$port"
                Invoke-Expression $portFwdCommand | Out-Null
            }
        }
        else{
            Write-Host -ForegroundColor Red "ERROR - Container did not start successfully."   
        }
    }
}

artilleryConfig



