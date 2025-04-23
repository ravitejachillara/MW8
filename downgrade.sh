#!/bin/bash

# Script to downgrade n8n to version 1.78.1
# Exit on error
set -e

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print messages
print_message() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

# Main downgrade function
downgrade_n8n() {
    print_message "Starting n8n downgrade to version 1.78.1"
    
    # Stop the current n8n service
    print_message "Stopping n8n service..."
    systemctl stop n8n
    
    # Backup current n8n data (optional but recommended)
    print_message "Creating backup of n8n data..."
    BACKUP_DIR="/root/n8n_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p $BACKUP_DIR
    cp -r /root/.n8n/* $BACKUP_DIR/ 2>/dev/null || true
    
    # Uninstall current version
    print_message "Removing current n8n version..."
    npm uninstall -g n8n
    
    # Install specific version
    print_message "Installing n8n version 1.78.1..."
    npm install -g n8n@1.78.1
    
    # Verify the installed version
    INSTALLED_VERSION=$(n8n --version)
    print_message "Installed n8n version: $INSTALLED_VERSION"
    
    # Start the n8n service
    print_message "Starting n8n service..."
    systemctl start n8n
    sleep 5
    
    # Check service status
    SERVICE_STATUS=$(systemctl is-active n8n)
    if [ "$SERVICE_STATUS" = "active" ]; then
        print_message "n8n service is active and running."
    else
        print_warning "n8n service failed to start. Check logs with: journalctl -u n8n -n 50"
    fi
    
    print_message "Downgrade process completed. A backup of your previous n8n data is saved in $BACKUP_DIR"
}

# Execute the downgrade
downgrade_n8n
