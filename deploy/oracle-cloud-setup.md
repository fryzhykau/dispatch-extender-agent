# Oracle Cloud Free Tier — Relay Deployment Guide

This guide deploys the Dispatch Relay to an Oracle Cloud always-free VM so Cowork/Dispatch can reach it directly from the cloud sandbox.

## 1. Provision the VM

1. Sign up at [cloud.oracle.com](https://cloud.oracle.com) (free tier, no credit card required for always-free resources)
2. Create a Compute instance:
   - **Shape:** VM.Standard.E2.1.Micro (always free) or Ampere A1 (up to 4 OCPUs / 24 GB free)
   - **OS:** Oracle Linux 8 or Ubuntu 22.04
   - **Network:** Use the default VCN or create one
   - **SSH:** Upload your public key
3. Note the **public IP address** after provisioning

## 2. Firewall / Security List

### OCI Security List (cloud-level firewall)

Add an ingress rule:
- **Source CIDR:** `0.0.0.0/0`
- **Protocol:** TCP
- **Destination Port:** `443`

### OS-level firewall (iptables)

```bash
sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT
sudo netfilter-persistent save
```

## 3. Install Dependencies

```bash
# Node.js 20 LTS
curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -   # Oracle Linux
# or: curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -   # Ubuntu
sudo yum install -y nodejs   # Oracle Linux
# or: sudo apt install -y nodejs   # Ubuntu

# nginx
sudo yum install -y nginx   # Oracle Linux
# or: sudo apt install -y nginx   # Ubuntu

# certbot (Let's Encrypt)
sudo yum install -y certbot python3-certbot-nginx   # Oracle Linux
# or: sudo apt install -y certbot python3-certbot-nginx   # Ubuntu
```

## 4. Deploy the Relay

```bash
# Create a system user
sudo useradd -r -m -s /bin/bash dispatch

# Clone or copy the project
sudo mkdir -p /opt/dispatch-extender-agent
sudo chown dispatch:dispatch /opt/dispatch-extender-agent

sudo -u dispatch git clone https://github.com/your-repo/dispatch-extender-agent.git /opt/dispatch-extender-agent
# or: scp -r ./relay ./worker ./lib ./package*.json user@your-vm:/opt/dispatch-extender-agent/

cd /opt/dispatch-extender-agent
sudo -u dispatch npm install --production
```

## 5. Configure the Relay

Edit `/opt/dispatch-extender-agent/relay/config.json`:

```json
{
  "port": 7070,
  "adminSecret": "<generate-a-64-char-hex-secret>",
  "sharedSecret": "<generate-a-different-64-char-hex-secret>",
  "legacyAuthEnabled": true,
  "relayUrl": "https://relay.yourdomain.com",
  "discovery": { "enabled": false },
  "keepAwake": { "enabled": false },
  "tls": { "enabled": false }
}
```

Generate secrets:
```bash
openssl rand -hex 32   # run twice, one for each secret
```

Key settings for cloud:
- `discovery.enabled: false` — UDP broadcast doesn't work across the internet
- `keepAwake.enabled: false` — server VM, not a laptop
- `tls.enabled: false` — nginx handles TLS
- `relayUrl` — the public URL workers and the skill will use

## 6. Set Up nginx + TLS

```bash
# Point your domain to the VM's public IP (A record in DNS)
# Then get a certificate:
sudo certbot --nginx -d relay.yourdomain.com

# Copy the nginx config template
sudo cp /opt/dispatch-extender-agent/deploy/nginx.conf.template /etc/nginx/conf.d/dispatch-relay.conf

# Replace the domain placeholder
sudo sed -i 's/RELAY_DOMAIN/relay.yourdomain.com/g' /etc/nginx/conf.d/dispatch-relay.conf

# Remove the default server block if it conflicts
sudo rm -f /etc/nginx/conf.d/default.conf

# Test and reload
sudo nginx -t && sudo systemctl reload nginx
```

## 7. Set Up systemd Service

```bash
sudo cp /opt/dispatch-extender-agent/deploy/dispatch-relay.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable dispatch-relay
sudo systemctl start dispatch-relay

# Check status
sudo systemctl status dispatch-relay
sudo journalctl -u dispatch-relay -f
```

## 8. Configure Workers

On each worker machine, update `worker-config.json`:

```json
{
  "coordinatorHost": "wss://relay.yourdomain.com",
  "apiKey": "<per-machine-api-key-from-enrollment>"
}
```

Enroll machines via the relay API:
```bash
curl -s -X POST https://relay.yourdomain.com/admin/enroll \
  -H "Authorization: Bearer <admin-secret>" \
  -H "Content-Type: application/json" \
  -d '{"machineId": "my-desktop", "agentName": "CodeBot"}'
```

Copy the returned `apiKey` into the worker's config.

## 9. Update the Orchestrate Skill

Re-run the setup wizard on the coordinator machine to regenerate the skill with the cloud `relayUrl`, or manually update `~/.claude/skills/orchestrate/SKILL.md` to reference the cloud URL.

## 10. Verify

```bash
# From any machine:
curl -s https://relay.yourdomain.com/status \
  -H "Authorization: Bearer <admin-secret>"

# Should return [] (empty array, no workers connected yet)
# Start a worker — it should appear in the status response
```

## Maintenance

```bash
# View logs
sudo journalctl -u dispatch-relay --since "1 hour ago"

# Restart relay
sudo systemctl restart dispatch-relay

# Update code
cd /opt/dispatch-extender-agent
sudo -u dispatch git pull
sudo -u dispatch npm install --production
sudo systemctl restart dispatch-relay

# Renew TLS certificate (auto-renewed by certbot, but manual if needed)
sudo certbot renew
```

## Costs

Oracle Cloud always-free tier includes:
- 2x AMD Micro instances (1 OCPU, 1 GB RAM each) — **always free**
- OR up to 4 Ampere A1 OCPUs + 24 GB RAM — **always free**
- 10 TB outbound data/month — more than enough
- No credit card required for always-free resources

The relay is lightweight (~50 MB memory, minimal CPU). A single Micro instance is more than sufficient.
