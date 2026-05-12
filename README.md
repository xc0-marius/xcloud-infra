# xCloud Infrastructure

Docker Compose stack for `xcloud.gg` on the Hetzner VPS `46.225.19.105`.

## Services

- Traefik with deSEC DNS-01 ACME
- PostgreSQL
- Redis
- Authentik
- NetBird server, dashboard, and reverse proxy
- TeamSpeak 6
- pgAdmin
- Dockge

## Expected DNS

Point these records to `46.225.19.105`:

```text
auth.xcloud.gg
netbird.xcloud.gg
*.netbird.xcloud.gg
pgadmin.xcloud.gg
dockhand.xcloud.gg
```

## Clone to the VPS

Run as user `xcloud`:

```bash
cd /opt
sudo git clone https://github.com/xc0-marius/xcloud-infra.git
sudo chown -R xcloud:xcloud /opt/xcloud-infra
cd /opt/xcloud-infra
sudo ./scripts/prepare.sh
```

Then edit secrets and NetBird configuration:

```bash
sudo nano /opt/xcloud-infra/.env
sudo nano /opt/xcloud-infra/netbird/config/config.yaml
sudo nano /opt/xcloud-infra/netbird/dashboard.env
sudo nano /opt/xcloud-infra/netbird/proxy.env
```

## Start the stack

```bash
cd /opt/xcloud-infra
./scripts/up.sh
```

## Stop the stack

```bash
./scripts/down.sh
```

## Restart the stack

```bash
./scripts/restart.sh
```

## Destructive rebuild

This removes Compose-managed containers, named volumes, orphan containers, and images referenced by the compose file. Bind-mounted application data is preserved by default.

```bash
./scripts/nuke.sh
```

To also purge bind-mounted app data:

```bash
PURGE_BIND_DATA=1 ./scripts/nuke.sh
```

## Required firewall ports

```text
80/tcp
443/tcp
3478/udp
9987/udp
30033/tcp
```

## Notes

- `.env`, `acme/acme.json`, and NetBird runtime config files are intentionally gitignored.
- `scripts/prepare.sh` creates missing runtime files and sets ownership/permissions.
- `pgadmin/data` is owned by UID/GID `5050:5050` because the pgAdmin container writes as that user.
