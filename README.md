# Mediastack

This also assumes you have a Cloudflare domain and a NordVPN subscription. and i need to fill this section out more

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
   - Navigate to the sidebar on the left and click on **NORDVPN** under **Services**.
   - Scroll down to the **Setup VPN Manually** section. You will be prompted to verify your email.
     <img width="864" alt="chrome_BE6A6ufspi" src="https://github.com/user-attachments/assets/2e315243-db6d-4ebb-a780-f91932943f64">
   - Generate a new access token. You can choose between a 30-day token or an indefinite token. Note that if you choose an expiration token, you will need to redo this step once the token expires.
     <img width="841" alt="chrome_iLzf3QaitP" src="https://github.com/user-attachments/assets/11881cce-1134-4b80-993a-ef98eaebef8c">
   - **Important**: This token will not be shown again, so make sure to copy it to your desktop on notepad or something.

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

everything is up and running! You may now go to each app in your browser to configure (more info is below on app configuration) as needed from their respective web GUIs, especially Jellyfin, as we will be opening it to WAN in the next step.

### Cloudflare tunnell

Now, if you return to Cloudflare, it should have the connector loaded up. Hit next. From the next page, please enter your subdomain and domain (subdomain.domain.tld). Below, under service, select http, and under URL, enter "mediaserverip:8096" (making sure to add your media servers actual ip address. Then save the tunnel. Now Jellyfin is open to the World Wide Web. If you would like a second tunnel for Jellyseerr, im not sure how to do that yet.

### Unfortunately 

I can’t find a way to auto-configure all the apps to work with each other. This must be done manually from the GUI of each app. More info below in the . . .

#   Configuring your now running apps

## Manual Configuration Guide for Pi-hole, NPM, and Various Apps

### Pi-hole

1. **Find Your IP Address:**
   - Find your (hopefully static) IP address of the host server. 
   - Enter `YOURIP:83/admin` in your browser.

2. **Configuration Video:**
   - [Watch this video](https://www.youtube.com/watch?v=kKsHo6r4_rc) for a detailed walkthrough.
   - This tutoiral also is very brief on how to use PI-hole, there is a lot it can do and if you want the most out of it, check out their documentation or relevant guides on youtube

3. **DNS Record:**
   - Use your host IP address (where everything is running).
   - Use your basic domain (e.g., `YOURDOMAIN.TLD`).

4. **CNAMEs:**
   - Suggestion: `service.YOURDOMAIN.TLD` (e.g., `jellyfin.YOURDOMAIN.TLD`).
   - Remember the service name for future steps.

5. **DNS Configuration on Client Machines:**
   - Point your machine's DNS lookups to the host IP address.
   - Some routers allow network-level DNS configuration.
   - Consult your IT professional or documentation for more information.
   - For local machine settings, search for "My OS DNS settings."

6. **Upstream DNS in Pi-hole:**
   - Under Pi-hole settings and DNS, configure upstream DNS lookups.
   - Use a more private DNS if preferred.

7. **Using Pi-hole for DHCP:**
   - Beyond this manual's scope, but can be configured.
   - Might be a good option for static IP addresses.

### Nginx Proxy Manager (NPM)

1. **Access NPM:**
   - Enter `MEDIASTACKIP:81` in your browser (Eg. 192.168.1.41:81).
   - Default credentials: `admin@example.com` and `changeme`.

2. **Add Proxy Host:**
   - Click Hosts and then Add Proxy Host.
   - Domain name: `pihole.YOURDOMAIN.TLD`.
   - Scheme: `http`.
   - Forward Hostname/IP: Host IP address.
   - Port: `83`.
   - <img width="454" alt="chrome_8ETkiE4paU" src="https://github.com/user-attachments/assets/05937549-1708-44a4-aa14-d0e6979c7f75">

3. **Advanced Configuration for Pi-hole:**
   - In the Advanced tab, enter the following:
     ```nginx
     location / {
       proxy_pass http://IPADDRESS:83/admin/;
       proxy_set_header Host $host;
       proxy_set_header X-Real-IP $remote_addr;
       proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
       proxy_hide_header X-Frame-Options;
       proxy_set_header X-Frame-Options "SAMEORIGIN";
       proxy_read_timeout 90;
     }
     location /admin {
       proxy_pass http://IPADDRESS:83/admin/;
       proxy_set_header Host $host;
       proxy_set_header X-Real-IP $remote_addr;
       proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
       proxy_hide_header X-Frame-Options;
       proxy_set_header X-Frame-Options "SAMEORIGIN";
       proxy_read_timeout 90;
     }
     ```
   - Change `IPADDRESS` to your (hopefully) static IP.
   - Just in case, here is the [orginal instruction to add pihole to the npm](https://docs.techdox.nz/pihole-on-npm/).

4. **Add Other Services:**
   - Repeat the above steps (excluding the Advanced configuration for Pihole) for other services.
   - Example services: qbittorrent, Sonarr, Radarr, Prowlarr, Lidarr, Readarr, Bazarr, Jellyfin, Jellyseerr, NPM, Pihole.

5. **Testing Proxy Hosts:**
   - Test each proxy host in your browser.
   - Use incognito mode or a different browser to avoid cache issues.

6. **SSL Setup (using Cloudflare):**
   - Log into Cloudflare, go to API Tokens, and create a token using the "Edit Zone DNS" template. Please also rename the token, in case you need to change it later.
   - <img width="377" alt="chrome_XYAq3ZpMOB" src="https://github.com/user-attachments/assets/4c47417c-66b4-4f3c-b553-6c59b71c1ee6">
   - <img width="245" alt="chrome_15dxMjsvu1" src="https://github.com/user-attachments/assets/dcf7584c-e5d1-4934-82a9-676a005f8c0f">
   - <img width="807" alt="chrome_LlyJTl3W3X" src="https://github.com/user-attachments/assets/c7f487ef-782a-4f83-acef-b1f375aea91d">
   - Save the token, cloudflare will NOT show it again.
   - In NPM, go to SSL Certificates, add a certificate, and select Let's Encrypt.
   - Domain name: `*.YOURDOMAIN.TLD`.
   - Email address: Your real email for Let's Encrypt.
   - Use DNS challenge with Cloudflare.
   - <img width="433" alt="chrome_nLIvjL2XP6" src="https://github.com/user-attachments/assets/98ff851c-0bb7-4ebb-9263-a259524b4f43">
   - Add `120` to propagation settings, agree to TOS, and save. It may take a minute or two to confirm, thats normal.
   - Edit each host to use the new SSL certificate.
   - <img width="461" alt="chrome_MMXlnLInsL" src="https://github.com/user-attachments/assets/494aabca-6998-4f09-b197-583c4b81f49e">


### ARR Apps (Sonarr, Radarr, etc.)

1. **Initial Configuration:**
   - Create an account to log in.
   - Adjust root folder settings: `/data/media/*subfolder*` (e.g., TV for Sonarr, Movies for Radarr).
   - Note the API key under settings, General.

2. **Remote Mapping:**
   - Configure remote mapping under Download Client.
   - It should be something like this:
     ```
     Host        Remote Path      Local Path
     localhost   /torrent/        /data/torrent/
     ```
3. **Settings Adjustments:**
   - adjusting settings for the specifcs of each app can take a significant amount of time and depend heavily on preference. I recommend waiting until everything is configured before doing this, but it is up to you.
   - This guide is widley recommended if you are not sure where to start. (TRaSH Guides)[https://trash-guides.info/]
  
4. **Add a download client**
   - Go to settings, Download clients, and add qbittorrent, it should look something like this:
    <img width="518" alt="chrome_4jDj92l7wD" src="https://github.com/user-attachments/assets/796b1b1c-d34d-4ddc-9b0b-c182e603db51">
     
6. **Integrate prowlarr**
   - In Prowlarr, go to settings, apps, and add each service. For sync level I recommend Full Sync
 

### Jellyfin

1. **Welcome Wizard:**
   - Configure Jellyfin with the welcome wizard.
   - Add media folders (e.g., Movies and TV).
   - Delay library scan until after basic setup.
   - Make sure there is at least a single admin account (usualy your own)
   - Make note of the jellyfin API token.

### Jellyseerr

1. **Welcome Wizard:**
   - Use the connect to Jellyfin button.
   - Connect Radarr and Sonarr using their IP address or domain name and API key.

### qBittorrent

1. **Access and Configure:**
   - Enter the correct domain into the browser.
   - Default credentials: `admin` / `adminadmin`.
   - If login fails, check the logs for the real password with the folowing command:
     ```sudo docker logs qbittorrent```
   - Configure settings, user login, and anonymous mode.
   - Optionally, disable CSRF protection if encountering unauthorized errors for some reason, if i would hit a bookmark or something to come this this adress, it comes up with a unauthorized error. When i clicked the url and hit enter, worked like a charm. To fix this (optional) go to tools, options, web ui tab, then about halfway down, theres a box checked for Enable Cross-Site Request Forgery (CSRF) protection. Unchecking that fixed the issue. buts its not critical so id recommend keeping it unless you have a reason to need this to work

### Configuring the VPN Connection

1. Hopefully in the future, i will have the installer.sh script handle this, but for now
   
2. **Edit Docker Compose:**
   - Open the Docker compose file:
     ```
     sudo nano docker-compose.yml
     ```
   - Adjust the following lines under the gluetun configuration. They do not all need to be entered, I would work top down, and configure as desired:
     ```yaml
     - SERVER_COUNTRIES=  # Comma separated list of countries
     - SERVER_REGIONS=    # Comma separated list of regions
     - SERVER_CITIES=     # Comma separated list of server cities
     - SERVER_HOSTNAMES=  # Comma separated list of server hostnames
     - SERVER_CATEGORIES= # Comma separated list of server categories
     ```

### Overview

1. **Final Steps and notes:**
   - Ensure all services are connected and configured.
     make sure to connect Prowlarr to all ARR apps.
   - Leave ARR qBittorrent connection to localhost.
   - start scanning all libraries in jellyfin, sonarr, radarr, jellyseerr. This may take a substantial amount of time. As in several days depending on your pcs power. please save this step for the very last.
   - perhaps run a final dns leak check from `installer.sh` just to make sure



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
- [x]  xxxx:xxxx # Watchtower for automatic image updater

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
