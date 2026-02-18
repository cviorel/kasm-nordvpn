#!/bin/bash

# Start / Restart Stack Script
# Stops the container, removes the network, recreates it, and starts the container.

set -e

echo "Stopping gluetun container..."
docker compose down --remove-orphans 2>/dev/null || true

echo "Removing vpn network..."
docker network rm vpn 2>/dev/null || true

echo "Creating vpn network..."
docker network create \
  --driver=bridge \
  --opt icc=true \
  --subnet=172.20.0.0/16 \
  vpn 2>/dev/null || echo "Network already exists, continuing..."

echo "Starting gluetun container..."
docker compose up -d

echo "Stack restarted successfully!"
