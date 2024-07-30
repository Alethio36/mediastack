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
   - For local machine settings, search for "MY OS DNS settings."

6. **Upstream DNS in Pi-hole:**
   - Under Pi-hole settings and DNS, configure upstream DNS lookups.
   - Use a more private DNS if preferred.

7. **Using Pi-hole for DHCP:**
   - Beyond this manual's scope, but can be configured.
   - Might be a good option for static IP addresses.

## Nginx Proxy Manager (NPM)

1. **Access NPM:**
   - Enter `YOURDOMAIN.TLD:81` in your browser.
   - Default credentials: `admin@example.com` and `changeme`.

2. **Add Proxy Host:**
   - Click Hosts and then Add Proxy Host.
   - Domain name: `pihole.YOURDOMAIN.TLD`.
   - Scheme: `http`.
   - Forward Hostname/IP: Host IP address.
   - Port: `83`.

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
   - Change `IPADDRESS` to your static IP.

4. **Add Other Services:**
   - Repeat the above steps (excluding the Advanced configuration) for other services.
   - Example services: qbittorrent, Sonarr, Radarr, Prowlarr, Lidarr, Readarr, Bazarr, Jellyfin, Jellyseerr, NPM, Pi-hole.

5. **Testing Proxy Hosts:**
   - Test each proxy host in your browser.
   - Use incognito mode or a different browser to avoid cache issues.

6. **SSL Setup (using Cloudflare):**
   - Log into Cloudflare, go to API Tokens, and create a token using the "Edit Zone DNS" template.
   - Save the token.
   - In NPM, go to SSL Certificates, add a certificate, and select Let's Encrypt.
   - Domain name: `*.YOURDOMAIN.TLD`.
   - Email address: Your real email for Let's Encrypt.
   - Use DNS challenge with Cloudflare.
   - Add 120 to propagation settings, agree to TOS, and save.
   - Edit each host to use the new SSL certificate.

## ARR Apps (Sonarr, Radarr, etc.)

1. **Initial Configuration:**
   - Create an account to log in.
   - Adjust root folder settings: `/data/media/*subfolder*` (e.g., TV for Sonarr, Movies for Radarr).
   - Note the API key under settings.

2. **Remote Mapping:**
   - Configure remote mapping under Download Client.
   - Example:
     ```
     Host        Remote Path      Local Path
     localhost   /torrent/        /data/torrent/
     ```

## Jellyfin

1. **Welcome Wizard:**
   - Configure Jellyfin with the welcome wizard.
   - Add media folders (e.g., Movies and TV for Jellyseerr).
   - Delay library scan until after basic setup.

## Jellyseerr

1. **Welcome Wizard:**
   - Use the connect to Jellyfin button.
   - Connect Radarr and Sonarr using their IP address or domain name and API key.

## qBittorrent

1. **Access and Configure:**
   - Enter the correct domain into the browser.
   - Default credentials: `admin` / `adminadmin`.
   - If login fails, check the logs for the real password: `sudo docker logs qbittorrent`.
   - Configure settings, user login, and anonymous mode.
   - Optionally, disable CSRF protection if encountering unauthorized errors.

## Configuring the VPN Connection

1. **Edit Docker Compose:**
   - Open the Docker compose file: ```sudo nano docker-compose.yml```.
   - Adjust the following lines under the gluetun container:
     ```yaml
     - SERVER_COUNTRIES=  # Comma separated list of countries
     - SERVER_REGIONS=    # Comma separated list of regions
     - SERVER_CITIES=     # Comma separated list of server cities
     - SERVER_HOSTNAMES=  # Comma separated list of server hostnames
     - SERVER_CATEGORIES= # Comma separated list of server categories
     ```

## Overview

1. **Final Steps:**
   - Ensure all services are connected and configured.
   - Connect Prowlarr to all ARR apps.
   - Leave ARR qBittorrent connection to localhost.
