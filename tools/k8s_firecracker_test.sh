#!/bin/bash
# Wrapper script for k8s_firecracker_test.py

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="${SCRIPT_DIR}/k8s_firecracker_test.py"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Check for required commands
for cmd in python3 curl wget; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is required but not installed." >&2
        echo "Please install it and try again." >&2
        exit 1
    fi
done

# Make sure the Python script is executable
chmod +x "${PYTHON_SCRIPT}"

# Check if firecracker is installed
FIRECRACKER_PATH=""
if command -v firecracker &> /dev/null; then
    FIRECRACKER_PATH=$(which firecracker)
elif [ -f "/usr/local/bin/firecracker" ]; then
    FIRECRACKER_PATH="/usr/local/bin/firecracker"
elif [ -f "/usr/bin/firecracker" ]; then
    FIRECRACKER_PATH="/usr/bin/firecracker"
fi

if [ -z "$FIRECRACKER_PATH" ]; then
    echo "Firecracker is not installed. Would you like to install it? (y/n)"
    read -r answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        echo "Installing Firecracker..."
        ARCH=$(uname -m)
        RELEASE_URL="https://github.com/firecracker-microvm/firecracker/releases"
        LATEST=$(curl -s $RELEASE_URL | grep -o 'tag/v[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1 | cut -d'/' -f2)
        
        # Download Firecracker binary
        wget -O firecracker "${RELEASE_URL}/download/${LATEST}/firecracker-${LATEST}-${ARCH}"
        chmod +x firecracker
        mv firecracker /usr/local/bin/
        FIRECRACKER_PATH="/usr/local/bin/firecracker"
        
        echo "Firecracker installed successfully at $FIRECRACKER_PATH!"
    else
        echo "Firecracker is required to run this script." >&2
        exit 1
    fi
else
    echo "Found Firecracker at $FIRECRACKER_PATH"
fi

# Create firecracker directory if it doesn't exist
mkdir -p /var/lib/firecracker

echo "Starting Kubernetes Firecracker Test Environment..."
# Run the Python script with all arguments passed to this script
exec "${PYTHON_SCRIPT}" "$@"
