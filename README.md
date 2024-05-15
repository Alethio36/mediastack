# mediastack
step 1

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

# stretch goals
1) - [] only install wanted apps
2) - [] auto configure all the arr apps with eachother
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


