# Kasm Workspaces — gluetun VPN Sidecar (NordVPN / WireGuard)

Routes traffic from specific Kasm Workspaces through a NordVPN WireGuard tunnel
by running [qmcgaw/gluetun](https://github.com/qdm12/gluetun) as a sidecar
container on a shared Docker bridge network.  
This mirrors the approach described in the [Kasm VPN Sidecar documentation](https://docs.kasm.com/docs/1.18.1/how-to/vpn_sidecar#setting-up-a-vpn-container)
but uses gluetun instead of `ghcr.io/bubuntux/nordvpn`.

---

## Architecture

```
[Kasm Workspace container]
        │  (default route → 172.20.0.2)
        ▼
[gluetun container  172.20.0.2]  ←── Docker bridge network "vpn" (172.20.0.0/16)
        │
        ▼
  NordVPN WireGuard endpoint (NordLynx)
```

Both containers share the `vpn` bridge network. Three cooperating mechanisms
enforce VPN-only connectivity (kill switch):

1. **gluetun's built-in firewall** drops all non-VPN outbound traffic whenever
   the WireGuard tunnel is not established — enabled by default, no extra config needed.
2. **Workspace routing** — a `Docker Exec Config` runs at session start and
   replaces the workspace's default route with one pointing exclusively to
   gluetun (`172.20.0.2`). If gluetun is stopped or the tunnel drops, packets
   are silently dropped; there is no fallback internet path.
3. **Network isolation** — "Restrict Image to Docker Network → vpn" ensures the
   workspace never has an interface on a network with a direct internet gateway.

---

## Prerequisites

- Docker and Docker Compose v2 installed on the Kasm Workspaces host
- A NordVPN account with an **access token**  
  ([generate one here](https://my.nordaccount.com/dashboard/nordvpn/access-tokens))
- `curl` and `jq` available on the host (to extract the WireGuard key)

---

## Step 1 — Obtain your WireGuard private key

NordVPN's WireGuard protocol (NordLynx) uses a key that is tied to your account,
not to a specific connection.  Run the following on any machine with internet
access:

```bash
curl --silent \
     --user "token:<YOUR_NORDVPN_ACCESS_TOKEN>" \
     https://api.nordvpn.com/v1/users/services/credentials \
  | jq -r '.nordlynx_private_key'
```

Copy the 44-character base64 string that is returned.

---

## Step 2 — Create the `.env` file

```bash
cp .env.example .env
```

Open `.env` and set `WIREGUARD_PRIVATE_KEY` to the key retrieved above:

```dotenv
WIREGUARD_PRIVATE_KEY=<your 44-char base64 WireGuard private key>
```

> **Optional:** change `SERVER_COUNTRIES` in `.env` to route through a different
> country. Valid country names are listed in the
> [gluetun NordVPN provider docs](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/nordvpn.md).

---

## Step 3 — Create the Docker network and start gluetun

The `vpn` network must exist before the container starts and must **also be
present on every Kasm Agent** that will run VPN-enabled workspaces.

> **Why `iptables/post-rules.txt` is required**  
> gluetun is a VPN client, not a router. By default its `FORWARD` chain has
> policy `DROP`, and it has no `POSTROUTING` NAT for traffic arriving from other
> containers.  Three rules in `iptables/post-rules.txt` are automatically loaded
> by gluetun on start to fix this:
>
> | Rule | Purpose |
> |------|---------|
> | `FORWARD -i eth0 -o tun0 -j ACCEPT` | Allow workspace packets in from the bridge, out through the tunnel |
> | `FORWARD -i tun0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT` | Allow return packets back to the workspace |
> | `POSTROUTING -o tun0 -j MASQUERADE` | Rewrite source IP so packets appear to come from gluetun before entering WireGuard |
>
> Without these, workspace containers can reach `172.20.0.2` but all forwarded
> packets are silently dropped by the `FORWARD DROP` policy.

```bash
bash start.sh
```

Verify the tunnel is up:

```bash
docker logs gluetun --tail 30
# Should show: "Wireguard setup is complete" then "Public IP address is..."
```

---

## Step 4 — Configure Kasm Workspaces

Log in to the Kasm admin UI and navigate to **Admin → Workspaces → Workspaces**.

### 4a — Clone the target workspace

Click the arrow next to the workspace you want to VPN-enable and choose
**Clone**.  Rename `Friendly Name` to something like `Chrome - VPN`.

### 4b — Docker Run Config Override (JSON)

Point the workspace DNS at gluetun's built-in encrypted resolver (`172.20.0.2`).
This avoids DNS leaks — queries never leave via any path other than the tunnel:

```json
{
  "dns": [
    "172.20.0.2"
  ]
}
```

> gluetun runs an encrypted DNS-over-HTTPS resolver on `172.20.0.2:53` that is
> only reachable within the `vpn` bridge network.  Do **not** use external DNS
> addresses here; they would require the masquerade routing to already be working
> before a hostname can be resolved.

### 4c — Docker Exec Config (JSON)  ← kill switch

This runs inside the workspace container at first launch (as root) and
**replaces** the Docker-assigned default route with one that points exclusively
to gluetun.  This is the key enforcement step:

```json
{
  "first_launch": {
    "user": "root",
    "privileged": true,
    "cmd": "bash -c 'ip route delete default && ip route add default via 172.20.0.2'"
  }
}
```

- `ip route delete default` — removes the Docker bridge gateway so there is no
  direct internet path.
- `ip route add default via 172.20.0.2` — all internet-bound traffic now flows
  through gluetun exclusively.

If gluetun is down or the WireGuard tunnel drops, gluetun's own firewall blocks
all outbound traffic.  Either way, the workspace has no internet access until
the VPN is fully re-established.  **There is no leak path.**

`172.20.0.2` is the static IP assigned to the gluetun container in
`docker-compose.yml`.

### 4d — Restrict to the VPN network

At the bottom of the workspace settings, enable **Restrict Image to Docker
Network** and select the `vpn` network created in Step 3.

Save the workspace.

---

## Step 5 — Test

Launch the newly cloned workspace.  Inside it, open a terminal (or browser
navigation bar) and check the public IP:

```bash
curl https://icanhazip.com
```

The returned IP must **not** match the public IP of the Kasm host — it should
resolve to a NordVPN server in the country set by `SERVER_COUNTRIES` in `.env`.

### Kill switch verification

To confirm the workspace has no internet path when the VPN is down:

1. Stop gluetun on the host:
   ```bash
   docker stop gluetun
   ```
2. Inside the running workspace, try to reach the internet:
   ```bash
   curl --max-time 5 https://icanhazip.com
   ```
   This must **time out or fail** — no IP should be returned.
3. Restart gluetun and confirm connectivity resumes:
   ```bash
   docker start gluetun
   ```

---

## Managing the stack

| Action | Command |
|--------|---------|
| Start / restart | `bash start.sh` |
| Stop and remove network | `bash stop.sh` |
| View logs | `docker logs -f gluetun` |
| View container status | `docker compose ps` |

---

## Configuration reference

| Variable | Description |
|----------|-------------|
| `WIREGUARD_PRIVATE_KEY` | NordLynx WireGuard private key (base64, 44 chars) |
| `SERVER_COUNTRIES` | Comma-separated list of exit countries (e.g. `Italy`) |
| `VPN_SERVICE_PROVIDER` | `nordvpn` (fixed) |
| `VPN_TYPE` | `wireguard` (fixed — uses NordLynx) |
| `FIREWALL_OUTBOUND_SUBNETS` | Subnets gluetun and attached containers may reach *without* going through the VPN tunnel — set to `172.20.0.0/16` so workspace↔gluetun LAN traffic is allowed while all internet traffic is still forced through WireGuard |

Full gluetun environment variable reference:  
<https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/nordvpn.md>
