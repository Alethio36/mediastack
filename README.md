# mediastack
step 1

install nordvpn

sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)

will ask for sudo password

setup a acess token to login
set to not expire (or do, but will expire in 30 days


install docker
install wireguard

install dnsleak test
https://github.com/macvk/dnsleaktest

place into a volume and place it into docker compose file


in gluten to get wireguard key
https://gist.github.com/bluewalk/7b3db071c488c82c604baf76a42eaad3

theres no legacy, login via nordvpn login --token *place token here*

note, logging out invlidated the token unless you pass a arguemtn, check on that before logging out of nordvpn via terminal

nordvpn logout  --persist-token  Keep your current access token valid after logging out. (default: false)


      - 8085:8085 # qbittorrent -vpn - torrenter
      - 8989:8989 # Sonarr -vpn - tv 
      - 7878:7878 # radarr -vpn - movie
      - 9696:9696 # Prowlarr -vpn - torrent indexer
      - 8686:8686 # lidarr -vpn - music
      - 8787:8787 # readarr -vpn - books
      - 6767:6767 # bazarr -vpn - subtitles
      - 1234:1234 # jellyfin -no vpn - media player
      - 1234:1234 # jellyseerr - no vpn - media grabber
                  # flaresolver - vpn - cloudflare captha solver


need to write a script to
1) install docker
2) install nordvpn and wireguard
3) pull the wireguard key and place it into compose file
4) update docker images
5) prune docker images
6) configure storage options for containers (this will need to interact with the compose file) and create said directories as well
7) update host system
8) perform a ip and dns leak test on all containers

stretch goals
1) only install wanted apps
2) auto configure all the arr apps with eachother
3) setup dns, proxy, and ssl with the apps
4) setup jellyfin and jellyseerr to work with cloudflare tunnell

