#!/bin/bash

# Stop Stack Script
# Stops the gluetun container and removes the vpn network.

set -e

echo "Stopping gluetun container..."
docker compose down --remove-orphans 2>/dev/null || true

echo "Removing vpn network..."
docker network rm vpn 2>/dev/null || true

echo "Stack stopped successfully!"
