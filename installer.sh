#!/bin/bash

# Function to install Docker
install_docker() {
    # Update package index
    sudo apt-get update

    # Install prerequisites
    sudo apt-get install -y ca-certificates curl 

    # Create directory for Docker's GPG key
    sudo install -m 0755 -d /etc/apt/keyrings

    # Download Docker's GPG key
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc

    # Set appropriate permissions for Docker's GPG key
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # Add Docker repository to Apt sources
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Update package index again after adding Docker repository
    sudo apt-get update

    # Install Docker packages
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# Function to install NordVPN
install_nordvpn() {
    # Download NordVPN installation script
    curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh -o nordvpn_install.sh

    # Execute NordVPN installation script
    sudo sh nordvpn_install.sh

    # Clean up
    rm nordvpn_install.sh
}

# Function to install WireGuard
install_wireguard() {
    sudo apt install wireguard -y
}

# Function to install DNS checker tool
install_dns_checker() {
    # Ensure directory /ms4/tools exists
    sudo mkdir -p /ms4/tools

    # Download DNS leak test script
    sudo curl -o /ms4/tools/dnsleaktest.sh https://raw.githubusercontent.com/macvk/dnsleaktest/master/dnsleaktest.sh
    
    # Set execute permissions for the script
    sudo chmod +x /ms4/tools/dnsleaktest.sh
}


# Function to update installed applications
update_applications() {
    # Update package index
    sudo apt-get update

    # Upgrade installed packages
    sudo apt-get upgrade -y
}

# Function to update Docker images
update_docker_images() {
    # stopping the mediastack
    echo "Stopping mediastack..."
    sudo docker compose down
    # remove all container volumes
    sudo docker rm -vf $(sudo docker ps -aq)
    # remove all images
    sudo docker rmi -f $(sudo docker images -aq)
    # pulling all new images
    # sudo docker compose pull
    # prune any orphans
    sudo docker image prune -af
    echo "Images have been pruned and updated, please remember to start applications"
}

# Function to return to the main menu
return_to_menu() {
    echo ""
    echo "Returning to the main menu..."
    echo ""
    main_menu
}

configure_docker_compose() {
    # Check if NordVPN token file exists
    token_file="/ms4/information/nordvpntoken.txt"
    if [[ -f "$token_file" ]]; then
        # NordVPN token file exists
        while true; do
            echo "A NordVPN token file was found. Do you want to use the token from the file? (yes/no)"
            read -r use_token_from_file
            if [[ $use_token_from_file == "yes" ]]; then
                # Read NordVPN token from file
                nordvpn_token=$(<"$token_file")
                echo "Using NordVPN token from file."
                break
            elif [[ $use_token_from_file == "no" ]]; then
                # Prompt user for NordVPN token
                echo "Please obtain your NordVPN authentication token from the NordVPN website and enter it below:"
                read -p "Enter your NordVPN authentication token: " nordvpn_token
                break
            else
                echo "Invalid choice. Please enter 'yes' or 'no'."
            fi
        done
    else
        # Prompt user for NordVPN token
        echo "Please obtain your NordVPN authentication token from the NordVPN website and enter it below:"
        read -p "Enter your NordVPN authentication token: " nordvpn_token
    fi

    # Run NordVPN login command with the provided token
    echo "Logging into NordVPN using the provided token..."
    nordvpn login --token "$nordvpn_token"

    # Set NordVPN technology to NordLynx
    echo "Setting NordVPN technology to NordLynx..."
    nordvpn set technology nordlynx

    # Make a connection to establish a key
    nordvpn connect

    # Get NordLynx private key
    echo "Retrieving NordLynx private key..."
    private_key=$(sudo wg show nordlynx private-key)

    # Logout of NordVPN
    nordvpn logout --persist-token

    # Create directory if it doesn't exist
    info_directory="/ms4/information"
    sudo mkdir -p "$info_directory"

    # Write NordVPN token to file if it was entered manually
    if [[ $use_token_from_file != "yes" ]]; then
        echo "$nordvpn_token" | sudo tee "$info_directory/nordvpntoken.txt" > /dev/null
    fi

    # Write NordLynx private key to file
    echo "$private_key" | sudo tee "$info_directory/wireguardprivatekey.txt" > /dev/null

    # Escape special characters in the private key
    escaped_private_key=$(printf '%s\n' "$private_key" | sed 's:[\&/]:\\&:g;$!s/$/\\/')

    # Use sed to replace the placeholder with the NordLynx private key
    sed -i "s|WIREGUARD_PRIVATE_KEY=.*|WIREGUARD_PRIVATE_KEY=$escaped_private_key|g" docker-compose.yml

    echo "NordVPN token and WireGuard private key have been saved in the /ms4/information directory."
}

run_dns_leak_test() {
    # Check if dnsleaktest.sh script exists
    dns_leak_test_script="/ms4/tools/dnsleaktest.sh"
    if [[ ! -f "$dns_leak_test_script" ]]; then
        echo "DNS leak test script not found: $dns_leak_test_script"
        return 1
    fi

    # Get list of running containers excluding flaresolverr and gluetun
    running_containers=$(sudo docker ps --format "{{.Names}}" | grep -v -e "gluetun" -e "flaresolverr" -e "cloudflared")

    # Check if there are any running containers
    if [[ -z "$running_containers" ]]; then
        echo "No running containers found (excluding gluetun and flaresolverr)."
        return 1
    fi

    # Loop through each running container (excluding gluetun) and execute the DNS leak test script
    for container in $running_containers; do
        echo "Running DNS leak test in container: $container"
        sudo docker exec "$container" /bin/bash tools/dnsleaktest.sh
    done
}


# Function to set up Cloudflare token
setup_cloudflare_token() {
    # Check if the token file already exists
    token_file="/ms4/information/cloudflare_token.txt"
    if [[ -f "$token_file" ]]; then
        echo "Cloudflare token file already exists."
        while true; do
            read -p "Do you want to use the existing Cloudflare token? (Y/N): " use_existing_token

            # Convert user input to uppercase
            use_existing_token=$(echo "$use_existing_token" | tr '[:lower:]' '[:upper:]')

            if [[ "$use_existing_token" == "Y" ]]; then
                # Read the token from the file
                cloudflare_token=$(<"$token_file")
                echo "Using existing Cloudflare token."
                break
            elif [[ "$use_existing_token" == "N" ]]; then
                # Prompt the user to enter a new token
                echo "Please obtain your Cloudflare token from the Cloudflare dashboard and enter it below:"
                echo "You can find instructions on how to generate a Cloudflare token in the Cloudflare documentation."
                echo "Enter the Cloudflare token when prompted."
                read -p "Enter your Cloudflare token: " cloudflare_token
                break
            else
                echo "Invalid choice. Please enter 'Y' or 'N'."
            fi
        done
    else
        # Prompt the user to enter a new token
        echo "Please obtain your Cloudflare token from the Cloudflare dashboard and enter it below:"
        echo "You can find instructions on how to generate a Cloudflare token in the Cloudflare documentation."
        echo "Enter the Cloudflare token when prompted."
        read -p "Enter your Cloudflare token: " cloudflare_token
    fi

    # Check if the token is provided
    if [[ -z "$cloudflare_token" ]]; then
        echo "No Cloudflare token provided. Exiting."
        return 1
    fi

    # Create the directory if it doesn't exist
    info_directory="/ms4/information"
    sudo mkdir -p "$info_directory"

    # Create a file named 'cloudflare_token.txt' and place the token in it
    echo "$cloudflare_token" | sudo tee "$token_file" > /dev/null
    echo "Cloudflare token has been saved to $token_file"

    # Add the token to the Docker Compose file after TUNNEL_TOKEN=
    sed -i "s|TUNNEL_TOKEN=.*|TUNNEL_TOKEN=$cloudflare_token|g" docker-compose.yml
    echo "Cloudflare token has been added to the Docker Compose file."
}


manage_docker_operations() {
    echo "Do you want to start or stop the Docker Compose?"
    echo "1. Start"
    echo "2. Stop"
    echo "3. Return to main menu"
    read -p "Enter your choice (1, 2, or 3): " choice

    case $choice in
        1)
            # Start Docker Compose
            echo "Starting Docker Compose..."
            sudo docker compose up -d
            ;;
        2)
            # Stop Docker Compose
            echo "Stopping Docker Compose..."
            sudo docker compose down
            ;;
        3)
            echo "Returning to the main menu..."
            ;;
        *)
            echo "Invalid choice. Please enter 1 to start, 2 to stop, or 3 to return to the main menu."
            manage_docker_operations
            ;;
    esac
}


# Main menu function
main_menu() {
    echo "Welcome to the Mediastack management script!"
    echo "Please select an option:"
    echo "1. Install Docker, NordVPN, WireGuard, and DNS Checker Tool"
    echo "2. Update existing installations"
    echo "3. Update Docker images"
    echo "4. Configure Docker Compose with NordVPN key"
    echo "5. Run a leak test"
    echo "6. Setup cloudflare tunnell"
    echo "7. start or stop the mediastack"
    echo "8. Exit"
    read -p "Enter your choice: " choice

    case $choice in
        1)
            install_docker
            install_nordvpn
            install_wireguard
            install_dns_checker
            return_to_menu
            ;;
        2)
            echo "Updating existing installations..."
            update_applications
            return_to_menu
            ;;
        3)
            echo "Updating Docker images..."
            update_docker_images
            return_to_menu
            ;;
        4)
            echo "Configuring Docker Compose..."
            configure_docker_compose
            return_to_menu
            ;;
        5) 
           run_dns_leak_test
           return_to_menu
            ;;
        6)
           setup_cloudflare_token
           return_to_menu
            ;;
        7)
           manage_docker_operations
           return_to_menu
            ;;
        8) 
           echo "Exiting."
           exit 0
            ;;
        *)
            echo "Invalid option. Please try again."
            main_menu
            ;;
    esac
}

# Start with the main menu
main_menu
