# Manual Configuration Guide for Pi-hole, NPM, and Various Apps

## Pi-hole

1. **Find Your IP Address:**
   - Find your (hopefully static) IP address of the host server. 
   - Enter `YOURIP:83/admin` in your browser.

2. **Configuration Video:**
   - [Watch this video](https://www.youtube.com/watch?v=kKsHo6r4_rc) for a detailed walkthrough.

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

## Nginx Proxy Manager (NPM)

1. **Access NPM:**
   - Enter `MEDIASTACKIP:81` in your browser.
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
   - Just in case, here is the [orginal instruction to add pihole to the npm] (https://docs.techdox.nz/pihole-on-npm/#:~:text=To%20add%20Pi%2Dhole%20to,%22Add%20Proxy%20Host%22%20button).

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


## ARR Apps (Sonarr, Radarr, etc.)

1. **Initial Configuration:**
   - Create an account to log in.
   - Adjust root folder settings: `/data/media/*subfolder*` (e.g., TV for Sonarr, Movies for Radarr).
   - Note the API key under settings, General.

2. **Remote Mapping:**
   - Configure remote mapping under Download Client.
   - Example:
     ```
     Host        Remote Path      Local Path
     localhost   /torrent/        /data/torrent/
     ```
3. **Settings Adjustments:**
   - adjusting settings for the specifcs of each app can take a significant amount of time and depend heavily on preference. I recommend waiting until everything is configured before doing this, but it is up to you.


## Jellyfin

1. **Welcome Wizard:**
   - Configure Jellyfin with the welcome wizard.
   - Add media folders (e.g., Movies and TV).
   - Delay library scan until after basic setup.
   - Make sure there is at least a single admin account (usualy your own)
   - Make note of the jellyfin API token.

## Jellyseerr

1. **Welcome Wizard:**
   - Use the connect to Jellyfin button.
   - Connect Radarr and Sonarr using their IP address or domain name and API key.

## qBittorrent

1. **Access and Configure:**
   - Enter the correct domain into the browser.
   - Default credentials: `admin` / `adminadmin`.
   - If login fails, check the logs for the real password with the folowing command:
     ```sudo docker logs qbittorrent```
   - Configure settings, user login, and anonymous mode.
   - Optionally, disable CSRF protection if encountering unauthorized errors for some reason, if i would hit a bookmark or something to come this this adress, it comes up with a unauthorized error. When i clicked the url and hit enter, worked like a charm. To fix this (optional) go to tools, options, web ui tab, then about halfway down, theres a box checked for Enable Cross-Site Request Forgery (CSRF) protection. Unchecking that fixed the issue. buts its not critical so id recommend keeping it unless you have a reason to need this to work

## Configuring the VPN Connection

1. Hopefully in the future, i will have the installer.sh script handle this, but for now
   
2. **Edit Docker Compose:**
   - Open the Docker compose file:
     ```
     sudo nano docker-compose.yml
     ```
   - Adjust the following lines under the gluetun container. They do not all need to be entered, I would work top down, and configure as desired:
     ```yaml
     - SERVER_COUNTRIES=  # Comma separated list of countries
     - SERVER_REGIONS=    # Comma separated list of regions
     - SERVER_CITIES=     # Comma separated list of server cities
     - SERVER_HOSTNAMES=  # Comma separated list of server hostnames
     - SERVER_CATEGORIES= # Comma separated list of server categories
     ```

## Overview

1. **Final Steps and notes:**
   - Ensure all services are connected and configured.
   - Connect Prowlarr to all ARR apps.
   - Leave ARR qBittorrent connection to localhost.
   - start scanning all libraries in jellyfin, sonarr, radarr, jellyseerr. This may take a substantial amount of time. As in several days depending on your pcs power. please save this step for the very last. 
