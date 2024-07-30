# Mediastack

This also assumes you have a Cloudflare domain and a NordVPN subscription.

## Prepping the host machine

Please note this has been written for a Debian12 OS. All other Linux distros may require some custom modifications.

This also assumes the OS has been installed and configured, with the user having sudo permissions. It would also be a good idea to put a static IP on the console, but it is not strictly required.

### Please install some prerequisite apps:
   - ```
     sudo apt install curl nano git openssh-server jq
     ```

- With SSH installed, it is easier to use your normal workstation. The rest of this tutorial assumes you have a normal workstation with standard capabilities.

- Download this git repo for local use, you can place it anywhere, but i recommend the user home directory:
 - ```
   sudo git clone https://github.com/alethio36/mediastack
   ```

   This should have created a folder called `mediastack` inside the folder you ran the previous command. Run the `ls` command to confirm.

### Getting Tokens

To prepare your NordVPN and Cloudflare tokens, follow the steps below:

#### NordVPN Token

1. **Log in to NordVPN**: Visit the [NordVPN website](https://nordvpn.com) and log in to your account.
2. **Access Token Generation**:
   - Navigate to the sidebar on the left and click on **Services**.
   - Select **NordVPN** from the services menu.
   - Scroll down to the **Setup VPN Manually** section. You will be prompted to verify your email.
   - Generate a new access token. You can choose between a 30-day token or an indefinite token. Note that if you choose an expiration token, you will need to redo this step once the token expires.
   - **Important**: This token will not be shown again, so make sure to copy it to your desktop or keep the page open until you complete this process.

#### Cloudflare Token

1. **Log in to Cloudflare**: Visit the [Cloudflare website](https://cloudflare.com) and log in to your account.
2. **Navigate to Zero Trust Section**:
   - Go to the **Cloudflare Zero Trust** section.
   - Under **Networks**, click on **Tunnels**.
3. **Create a New Tunnel**:
   - Choose the **Cloudflared** option.
   - Name the tunnel as desired.
   - Under **Install and Run Connectors**, copy the Docker command provided.
   - Paste this command into a notepad (alongside your NordVPN token) and remove everything that is NOT the token. The token will appear as a series of random characters.

Once you have obtained both tokens, you can proceed with setting up the mediastack.


### Running the installer script

Now back to the media server, make sure your SSH in and sudo works (a good test is to run the command `sudo whoami`; it should return "root". If not, please troubleshoot). 
   
   1. use this command to enter the medisatck folder
   ```
   cd mediastack
   ```

   2. use this command to run the installer script
   ```
   sudo bash installer.sh
   ```
  
   3. Hit option 1
  
   4. Hit option 2
  
   5. Hit option 4, and enter your NordVPN token
  
   6. Hit option 6, and enter your Cloudflare token
  
   7. Hit option 3. This may take a moment as it downloads all the containers. This option also makes sure to prune and clean up various files and images and updates to the latest image for all the apps.
  
   8. Hit option 7, and start the stack.
  
   9. Optional step: hit option 5 to run a DNS leak test on the running images. This will take a few minutes. Make sure to read the readout of each container. Also check the IP on each container just in case. at the moment, i need to reconfiure how every container works with the leak test. there may be some errors with certain apps. last i checked, the important stuff works.

### Congrats

everything is up and running! Please enter each app to configure (there is a file called appconfig for more info) it as needed from their respective web GUIs, especially Jellyfin, as we will be opening it to WAN in the next step.

### Cloudflare tunnell

Now, if you return to Cloudflare, it should have the connector loaded up. Hit next. From the next page, please enter your subdomain and domain (subdomain.domain.tld). Below, under service, select http, and under URL, enter "mediaserverip:8096" (making sure to add your media servers actual ip address. Then save the tunnel. Now Jellyfin is open to the World Wide Web. If you would like a second tunnel for Jellyseerr, please reach out to me to reconfigure for a second tunnel.

9. Unfortunately, I can’t find a way to auto-configure all the apps to work with each other. This must be done manually from the GUI of each app. Find the IP address of the host and append the correct port (i.e., 192.168.1.100:xxxx) to find each app. please check the appconfig more for info


# Script Goals

1. - [x] Install docker (done)
2. - [x] Install NordVPN and wireguard (done)
3. - [x] Pull the wireguard key and place it into compose file (done)
4. - [x] Update docker images
5. - [x] Prune docker images
6. - [ ] Configure storage options for containers (this will need to interact with the compose file) and create said directories as well (won’t know until needed for specifics). Unfortunately, this may be beyond the scope of this project.
7. - [x] Update host system (done)
8. - [x] Perform an IP and DNS leak test on all containers (done)
9. - [ ] Transfer a Windows Jellyfin to a Linux Jellyfin server (this was not done well and should be considered beyond the scope of this project)
10. - [x] Put in proper error handling in user interaction
11. - [ ] Add an option to change VPN tunnel options

# Stretch Goals

1. - [ ] Only install wanted apps
2. - [ ] Auto-configure all the ARR apps with each other (this is not going to happen, too complicated)
3. - [x] Setup DNS, proxy, and SSL with the apps for LAN access (this mediastack has the options for all these things but must be manually configured)
4. - [x] Setup Jellyfin and Jellyseerr to work with Cloudflare tunnel
5. - [ ] Setup a docker secrets for sensitive tokens

# Apps Involved 

- [x]  xxxx:xxxx # gluetun -vpn - VPN tunnel
- [x]  8085:8085 # qbittorrent -vpn - Torrenter
- [x]  8989:8989 # Sonarr -vpn - TV 
- [x]  7878:7878 # Radarr -vpn - Movie
- [x]  9696:9696 # Prowlarr -vpn - Torrent Indexer
- [x]  8686:8686 # Lidarr -vpn - Music
- [x]  8787:8787 # Readarr -vpn - Books
- [x]  6767:6767 # Bazarr -vpn - Subtitles
- [x]  8096:8096 # Jellyfin -no vpn - Media Player
- [x]  5055:5055 # Jellyseerr - no vpn - Media Grabber
- [x]  8191:8191 # Flaresolver - vpn - Cloudflare Captcha Solver
- [x]  80:80 443:443 81:81 (81 is the admin portal) # NPM (proxy) - no vpn - This routes your domains to services
- [x]  53:53 67:67 83:80 (83 is the external mgmt portal) # Pihole - no vpn - This is a DNS, DHCP, and adblocker
- [x]  noport:noport # Watchtower for automatic image updater

# Notes For Author

## Prereqs

- curl
- nano
- git
- wireguard
- docker
- nordvpn
- ssh
- docker

## Install NordVPN

sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)

It will ask for the sudo password.

Setup an access token to log in. Set to not expire (or do, but it will expire in 30 days).

## In Gluetun to Get Wireguard Key

https://gist.github.com/bluewalk/7b3db071c488c82c604baf76a42eaad3

There’s no legacy, log in via `nordvpn login --token *place token here*`.

Note, logging out invalidates the token unless you pass an argument, check on that before logging out of NordVPN via terminal:

```
nordvpn logout --persist-token
```

Keep your current access token valid after logging out. (default: false)
