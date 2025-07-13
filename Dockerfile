FROM mcr.microsoft.com/dotnet/sdk:8.0-cbl-mariner2.0 AS build

# Author: scaleoutSean@Github, https://github.com/scaleoutsean/firemox

# Required module for the script to run
RUN pwsh -Command "Install-Module -Name PwshSpectreConsole -RequiredVersion 2.4.0 -AllowPrerelease"

# SolidFire account: must be allowed to perform at least volume (if not QoS-related) operations
# PVE account: must be allowed to add/remove storage pools, create, remove VGs 

# These are dummy credentials, replace with your environment variables. 
# Or hard-code all of them except the passwords which you can input at runtime.
ENV global:sfAccount="volumeMaster"  \ 
    global:sfAccountPass="what_eva" \
    global:pveAccount="root@pam" \ 
    global:pveAccountPass="what_eva" \ 
    global:sfAccountId="1" \
    global:sfVolumePrefix="dc1-"

RUN useradd -m appuser
USER appuser
COPY --chown=appuser:appuser *.ps1 ./modules /home/appuser/
COPY entrypoint.sh /usr/local/bin/docker-entrypoint.sh
WORKDIR /home/appuser/

# Add entrypoint script to load environment variables and then run the main script
# ENTRYPOINT ["pwsh", "-File", "firemox.ps1"]
ENTRYPOINT [ "/usr/local/bin/docker-entrypoint.sh" ]

