# xCloud Infrastructure

Docker Compose stack for the xCloud VPS.

## Server target

- VPS IP: `46.225.19.105`
- Server user: `xcloud`
- Install path: `/opt/xcloud-infra`
- Domain: `xcloud.gg`

## Expected DNS

Point these records to `46.225.19.105`:

```text
auth.xcloud.gg
netbird.xcloud.gg
*.netbird.xcloud.gg
pgadmin.xcloud.gg
dockhand.xcloud.gg
```

## First deploy on the VPS

```bash
cd /opt
sudo git clone https://github.com/xc0-marius/xcloud-infra.git
sudo bash /opt/xcloud-infra/scripts/init-paths.sh
cd /opt/xcloud-infra
sudo -u xcloud cp .env.example .env
sudo -u xcloud nano .env
sudo -u xcloud nano netbird/config/config.yaml
sudo -u xcloud nano netbird/dashboard.env
sudo -u xcloud nano netbird/proxy.env
sudo -u xcloud bash scripts/up.sh
```

If the repo already exists:

```bash
cd /opt/xcloud-infra
git pull
sudo bash scripts/init-paths.sh
sudo -u xcloud bash scripts/up.sh
```

## Scripts

```bash
bash scripts/init-paths.sh   # create folders, touch required files, fix ownership and permissions
bash scripts/up.sh           # safe start with dependency waits
bash scripts/down.sh         # stop stack in service-safe order
bash scripts/restart.sh      # down then up
bash scripts/nuke.sh         # destructive Docker-volume/image rebuild
```

For a full destructive rebuild that also wipes bind-mounted app data:

```bash
PURGE_BIND_DATA=1 bash scripts/nuke.sh
```

## Required firewall ports

```text
80/tcp
443/tcp
3478/udp
9987/udp
30033/tcp
```

## Secrets

Do not commit `.env`. The repo contains `.env.example` only.
