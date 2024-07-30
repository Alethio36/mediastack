how to manually configure apps to work 

pihole 

  a) find your (hopefully static) ip adress of the host server, once found go to your browswer and enter YOURIP:83/admin

  b) https://www.youtube.com/watch?v=kKsHo6r4_rc watch this video, dude runs through it very well

  c) for the dns record, make sure to use your host ip adress (this is where your running everything) and i would use your basic domain (YOURDOMAIN.TLD) this video showed a longer one

  d) for your cnamesi would suggest your service name, then domain name.  such as, jellyfin.YOURDOMAIN.TLD for example. but you can name your service whatever you want. just make sure to remember to name for future steps below

  e) for this DNS to work, on whatever machine you want to acess these records, you need to point your machines dns lookups to the host ip adress. some routers will let you do this on a network level, and that would make your life sooooooooo easy if thats the case. but not every router is the same. please consult your it professional or documentation for more information. if you use your local machine, a google search for "MY OS dns settings" will very easily turn up how to change your dns settings locally.

  f) in pihole, under settings and dns, you can configure upstream dns lookups ( such as, if pihole doesnt know the dns address, its looks "upstream" for the answer). you can use whatever you want, i prefer a more private dns to whatever crap my router uses, espcially if its a ISP provided router

  g) if you want to use pihole for DHCP, its beyond the scope of the manual for now, but you can configure it now. if you need a static ip adress, this might be a good option
  

npm (nginx proxy manager) 

   a) now, you should be able to go to your browser, enter YOURDOMAIN.TLD:81 and you should be at a NPM login page, here the default credentials are admin@example.com and password is changeme. it will prompt to change upon succesful login
   
   b) upon login, click hosts and then add proxy host
   
   c) add domain name (lets start with pihole, pihole.YOURDOMAIN.TLD) and click the little dropdown
   
   d) scheme should be http, forward hostname/ip is the host ip adress, and port is 83 (83 is pihole, please adjust per service)
   
   e) for pihole spcifically, click advanced and enter the below into the config box, please remember to adjust the ip with your host ip


   location / {
  proxy_pass http://IPADRESS:83/admin/;
  proxy_set_header Host $host;
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_hide_header X-Frame-Options;
  proxy_set_header X-Frame-Options "SAMEORIGIN";
  proxy_read_timeout 90;
}
location /admin {
  proxy_pass http://IPADRESS:83/admin/;
  proxy_set_header Host $host;
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_hide_header X-Frame-Options;
  proxy_set_header X-Frame-Options "SAMEORIGIN";
  proxy_read_timeout 90;
}

dont forget to change the ip adress to your (hopefully) static ip to the pihole location (the same on as the docker host, or the machine this whole thing is running on

just in case, below is orginal instruction to add pihole to the npm
https://docs.techdox.nz/pihole-on-npm/#:~:text=To%20add%20Pi%2Dhole%20to,%22Add%20Proxy%20Host%22%20button.

  f) now please hit save, and follow the same instrutions (minus step e) for every other desired service. i suggest copying the ip adress to just paste it every time. listed below is a list of all services to add for your convenience


  qbittorrent
  Sonarr
  radarr
  Prowlarr 
  lidarr 
  readarr
  bazarr
  jellyfin
  jellyseerr
  npm
  pihole
  
  
  g) as a precaution, please test each proxy host in your browser, it should connect right away, i wouldnt recommend configuring each service unless you want to just yet. just make sure you can connect. i highly suggest using a second type of browser (such as firefox if you use chrome, or vice versa) and opening a ingocnito window. this is a easy way to make sure cookies and site data dont mess with you, especially if something isnt going well
  
  h) now once all your services are confirmed working within the proxy, lets sep up ssl to make reaching each website easier.  this assumes you are using cloudflare, if you are not, there should be a guide somewhere to your specific domain provider, but all i know is cloudflare. log into cloudflare, and in the right top area click the account icon then my profile, then on the left hand side, API tokens

  i) hit create token, use the edit zone DNS template, then change the zone resources specific  zone to your domain name of choice. i also recommend to change the name of the token, its on the top of the page after token name, theres a rather small edit icon thats easy to miss. name it something easy to identify for you later just in case you need to change it later. continue on to create token, but make sure to either leave this page open or copy the token somehwere, cloudflare will NOT let you see it again

  j)
    1) now back to npm, click on the ssl certificates section on the top bar, then click add ssl certificate, and select lets encrypt in the dropdown
    2) under domain name, please put *.YOURDOMAIN.TLD (that asterisk is important, and needed) then click the dropdown that comes up, should just be what you typed out
    3) enter your real email adress for lets encrypt
    4) click the use dns challenge button and choose your dns provider as cloudflare
    5) for the credentials file content, it should have populated the right text already that looks like this (subject to change i suppose, but as of mid 2024 this is it, if npm looks different, trust that, if its empty, use this) then just replace the example token text with your actual token. make sure there are no trailing spaces or anything extra when you copy and paste
       Cloudflare API token
       dns_cloudflare_api_token=0123456789abcdef0123456789abcdef01234567

  6) add 120 to propagation settings, then agree to TOS, then hit save. it might take a minute or so to do its thing
  7) now that is saved and ready to use, head back to hosts, and proxy hosts, and under each host, click the 3 dots, edit, hit the ssl tab, choose the ssl cert you just made, then check all 4 tabs, then hit save.
  8) as a double check measure, make sure all the domains work just in case
        
        
  ARR apps
   
  a) now is a good time to configure each of these services, please start by creating a account to login
  
  b) adjust the root folder settings, i believe you will need to add /data/media/*subfolder* (tv for sonarr, movies for radarr etc)
  
  c) take note of where the api key is, you will need this in the coming steps, its under settings, general, and about the middle of the page
  
  d) feel free to adjust each services settings as you wish, this can be a fiddly and time consuming project, i sugesst doing this after you have this whole mediastack up and running

  e) you will also need to set a remote mapping from where the radarr things downloads are, and where the download client thinks things are. settins under download client on the bottom (if you dont do this and check logs, it sounds like a permissions issue. drove. me. nuts. but the gist of it is, 
  
  Host        Remote Path      Local Path
  localhost   /torrent/        /data/torrent/


jellyfin 
   
  a) configure jellyfin with the welcome wizard, add the media folders (i recommend adding movies and tv for jellyseerr, you can add more and configure later) id recomment waiting to scan the libraries until after basic setup is done. it can take bloody ages.
  

jellyseerr 
   
  a) follow the welcome wizard, you can use connect to jellyfin button on the bottom, connect radarr and sonarr here, you will need api key for this

  b) you can connect sonarr and radarr now, you will need their ip adress or use the domain name, and the api key. these can be edited later if you are being creative about following this (admittedly) loose guideline


qbitrorrent 
    
  a) you should enter the correct domain into the browser
  
  b) the login page should be there, username is admin, password is adminadmin
  
  c) now when the login fails, go to the host cli, and enter sudo docker logs qbittorrent , this should reveal the real password. enter that into the password field and login
  
  d) i would confgure all settings to your liking at this point, take note a user login, and enabling anonymous mode. also, for some reason, if i would hit a bookmark or something, it comes up with a unauthorized error, when i clicked the url and hit enter, worked like a charm. to fix this (optional) go to tools, options, web ui tab, then about halfway down, theres a box checked for Enable Cross-Site Request Forgery (CSRF) protection. unchecking that fixed the issue. buts its not critical so id recommend keeping it unless you have a reason to need this to work
  
  e) make sure to connect the ARR apps to this in their respective domains
  
Configuring the VPN connection.
  a) so hopefully i will have this function in the installer script soon, but just incase you find yourself here in this WIP, open the docker compose (sudo nano docker-compose.yml) and under the gluetun container, adjust the following lines to your satisfaction

      - SERVER_COUNTRIES=  # Comma separated list of countries
      - SERVER_REGIONS= # Comma separated list of regions
      - SERVER_CITIES= # Comma separated list of server cities
      - SERVER_HOSTNAMES= # Comma separated list of server hostnames
      - SERVER_CATEGORIES= # Comma separated list of server categories

overview

A) from here, everything should be configured to work on a basic level. i recommend going over the ARR apps and finish configuring to your liking. dont forget to connect prowlarr to everything as well. please note to leave the ARR qbittorrent connection to localhost.
