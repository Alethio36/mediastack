# mediastack
## how to install the mediastack
please note this has been written for a debian12 OS, all other linux distros may require some custom modifications

this also assumes the os has been intalled and configured, with the user having sudo permissions. also, it would also be a good idea to put a static ip on the console, but not strictly required

this also assumes you have a cloudflare domain, and a nordvpn subscription

1) please install some prerequsites apps
   - sudo apt install curl nano git openssh-server

2) with ssh installed, it is easier to use your normal workstation, the rest of this tutorial assumes you have a normal workstation with standard capabilites

3) download this git repo for local use
    - sudo git clone https://github.com/alethio36/mediastack
      
   this should have created a folder called mediastack inside the folder you ran the previous command, run "ls" command to confirm

4) now would be a good idea to prepare your nordvpn and cloudflare tokens.
   for nordvpn, please go to their website and login. from there, under the left sidebar under services, click on nordvpn. scroll all the way down to "setup vpn manually" it will ask to verify your email. from there, you want to generate a new acess token. it will ask you to choose between a 30 day token or a indefinate token. it doesnt matter, but if you choose to have a expiration token if you need to update the vpn youll have to redo this step. also note, this token will not be able to be revealed again, so copy it to your desktop or leave the page open until your down.

   for cloudflare, please login, and find your way to the cloudflare zero trust section. under networks, click on tunnels, and create a new tunnell. pick the cloudflared option, name the tunnell whatever you want, and under install and run connectors, you want to copy the docker command, paste it into notepad (presumably where your nordvpn token is) and remove everthing that is NOT the token. the token will be a bunch of random charectors and look like nonsense. from there, please wait to finish setting up the mediastack

5) now back to the media server, make sure your ssh in and sudo works ( a good test is run the command "sudo whoami" it should return "root", if not, please troubleshoot)
   
       -  a) cd mediastack
       -  b) sudo bash installer.sh
       -  c) hit option 1
       -  d) hit option 2
       -  e) hit option 4, and enter your nordvpn token
       -  f) hit option 6, and enter your cloudflare token
       -  g) hit option 3, this may take a moment as it downloads all the containers, this option also makes sure to prune and clean up various files and images, and updates to the latest image for all the apps
       -  h) hit option 7, and start the stack
       -  i) optional step is hit option 5 to run a dns leak test on the runnining images. this will take a few minutes. make sure to read the readout of each container. also check the ip on each container just in case

7) congrats, everything is up and running, please enter each app to configure it as needed from their respective webguis. especially jellyfin, as we will be opening it to WAN in the next step
8) now, if you return to cloudflare, it should have connector loaded up and you should hit next, from the next page, please enter your subdomain, and domain (subdomain.domain.tld) and below under service, select http, and under url, enter "mediaserver:8096" then save tunnell. now jellyfin is open to the world wide web. if you would like a second tunell for jellyseer, please reach out to me to reconfigure for a second tunell



# prereqs
curl, nano, git, wireguard, docker, nordvpn, ssh, docker

# script goals
1) - [x] install docker (done)
2) - [x] install nordvpn and wireguard (done)
3) - [x] pull the wireguard key and place it into compose file (done)
4) - [x] update docker images
5) - [x] prune docker images
6) -  configure storage options for containers (this will need to interact with the compose file) and create said directories as well (wont know until needed for specifics)
7) - [x] update host system (done)
8) - [x] perform a ip and dns leak test on all containers (done)
9) - [ ] trasnfer a windows jellyfin to a linux jellyfin server

# stretch goals
1) - [] only install wanted apps
2) - [o] auto configure all the arr apps with eachother (this is not going to happen, to complicated)
3) - [] setup dns, proxy, and ssl with the apps for lan acess 
4) - [x] setup jellyfin and jellyseerr to work with cloudflare tunnell

# apps involved 

      - [x]  xxxx:xxxx # gluetun -vpn - vpn tunnell
      - [x]  8085:8085 # qbittorrent -vpn - torrenter
      - [x]  8989:8989 # Sonarr -vpn - tv 
      - [x]  7878:7878 # radarr -vpn - movie
      - [x]  9696:9696 # Prowlarr -vpn - torrent indexer
      - [x]  8686:8686 # lidarr -vpn - music
      - [x]  8787:8787 # readarr -vpn - books
      - [x]  6767:6767 # bazarr -vpn - subtitles
      - [x]  8096:8096 # jellyfin -no vpn - media player
      - [x]  5055:5055 # jellyseerr - no vpn - media grabber
      - [x]  8191:8191 # flaresolver - vpn - cloudflare captha solver





# notes

install nordvpn

sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)

will ask for sudo password

setup a acess token to login
set to not expire (or do, but will expire in 30 days


install dnsleak test
https://github.com/macvk/dnsleaktest

place into a volume and place it into docker compose file


in gluten to get wireguard key
https://gist.github.com/bluewalk/7b3db071c488c82c604baf76a42eaad3

theres no legacy, login via nordvpn login --token *place token here*

note, logging out invlidated the token unless you pass a arguement, check on that before logging out of nordvpn via terminal

nordvpn logout  --persist-token  Keep your current access token valid after logging out. (default: false)


