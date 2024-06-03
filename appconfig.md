how to manually configure apps to work 

1) pihole
  a) find your ip adress of the host server, once found go to your browswer and enter YOURIP:83/admin

  b) on the left hand side, click on domains, and enter your prefered domain into the domain section, click add domain as wildcard, then add to whitelist (feel free to leave a comment if desired)
  
  c) in your pc settings, make sure to adjust your dns settings to point to this pihole instance. the ip of the host should do the trick
  
  d) there are addblock settings, feel free to adjust as wanted. but that is beyond the scope of this manual
  

3) npm
   a) now, you should be able to go to your browser, enter YOURDOMAIN.TLD:81 and you should be at a NPM login page, here the default credentials are admin@example.com and password is changeme. it will prompt to change upon succesful login
   
   b) upon login, click hosts and then add proxy host
   
   c) add domain name (for example, pihole.YOURDOMAIN.TLD) and click the little dropdown
   
   d) scheme should be http, forward hostname/ip is the host ip adress, and port is 83 (83 is pihole, please adjust per service)
   
   e) now for pihole spcifically, click advanced and enter the below into the config box, please remember to adjust the ip with your host ip
   

   location / {
  proxy_pass http://YOURIP:83/admin/;
  proxy_set_header Host $host;
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_hide_header X-Frame-Options;
  proxy_set_header X-Frame-Options "SAMEORIGIN";
  proxy_read_timeout 90;
}
location /admin {
  proxy_pass http://YOURIP:83/admin/;
  proxy_set_header Host $host;
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_hide_header X-Frame-Options;
  proxy_set_header X-Frame-Options "SAMEORIGIN";
  proxy_read_timeout 90;
}

  f) now please hit save, and follow the same instrutions (minus step e) for every other desired service. i suggest copying the ip adress to just paste it every time. 
  
  g) as a precaution, please test each proxy host in your browser, it should connect right away, i wouldnt recommend configuring each service unless you want to just yet. just make sure you can connect. 
  
  h) at this moment, ssl has not been set up just yet, i personally cant test due to my current setup, to be filled out soon hopefully. if not, there are many guides online for this. you will need to own a domain for this. this is not strictly needed for a functioning mediastack
  

4) sonarr, radarr, lidarr, prowlarr, readarr
   
  a) now is a good time to configure each of these services, please start by creating a account to login
  
  b) adjust the root folder settings, i believe you will need to add /data/torrent/subfolder and /data/media/subfolder
  
  c) take note of where the api key is, you will need this in the coming steps
  
  d) feel free to adjust each services settings as you wish, this can be a fiddly and time consuming project, i sugesst doing this after you have this whole mediastack up and running


6) jellyfin
   
  a) configure jellyfin with the welcome wizard, add the media folders (i recommend adding movies and tv for jellyseerr, you can add more and configure later)
  

8) jellyseerr
   
  a) follow the welcome wizard, you can use connect to jellyfin button on the bottom, connect radarr and sonarr here, you will need api key for this


10) qbitrorrent
    
  a) you should enter the correct domain into the browser
  
  b) the login page should be there, username is admin, password is adminadmin
  
  c) now when the login fails, go to the host cli, and enter sudo docker logs qbittorrent , this should reveal the real password. enter that into the password field and login
  
  d) i would confgure all settings to your liking at this point, take note a user login, and enabling anonymous mode.
  
  e) make sure to connect the ARR apps to this
  

12) from here, everything should be configured to work on a basic level. i recommend going over the ARR apps and finish configuring to your liking. dont forget to connect prowlarr to everything as well. please note to leave the ARR qbittorrent connection to localhost
