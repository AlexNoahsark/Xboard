# Quick Deployment Guide with Docker Compose

This guide explains how to quickly deploy Xboard using Docker Compose. By default, it uses SQLite database, eliminating the need for a separate MySQL installation.

### 1. Environment Preparation

Install Docker:
```bash
curl -sSL https://get.docker.com | bash

# For CentOS systems, also run:
systemctl enable docker
systemctl start docker
```

### 2. Deployment Steps

1. Clone the `compose` branch. It already ships a ready-to-use `compose.yaml` (default bridge-network setup) plus the other `compose.*.sample.yaml` variants for different setups — no copy step needed unless you switch variants (see the table below):
   ```bash
   git clone -b compose --depth 1 https://github.com/AlexNoahsark/Xboard
   cd Xboard
   ```

2. Install database:  

- Quick installation (Recommended for beginners)
```bash
docker compose run -it --rm \
    -e ENABLE_SQLITE=true \
    -e ENABLE_REDIS=true \
    -e ADMIN_ACCOUNT=admin@demo.com \
    xboard php artisan xboard:install
```
- Custom configuration installation (Advanced users)
```bash
docker compose run -it --rm xboard php artisan xboard:install
```
> Please save the admin dashboard URL, username, and password shown after installation
> The `compose` branch ships **`compose.yaml`** (ready to use, default) plus **three** other templates — only copy one of these over `compose.yaml` if your setup needs it:
>
> | File | Network | When to use |
> |------|---------|-------------|
> | `compose.yaml` | bridge + ports `7001:7001` | bare docker, custom reverse proxy, aaPanel + Docker (default, used as-is) |
> | `compose.host.sample.yaml` | `network_mode: host` | aaPanel native (openresty on host) — `cp compose.host.sample.yaml compose.yaml` |
> | `compose.1panel.sample.yaml` | bridge + external `1panel-network` | 1Panel users (so the container can reach 1Panel-managed MySQL/Redis) — `cp compose.1panel.sample.yaml compose.yaml` |
> | `compose.split.sample.yaml` | multi-container (web/horizon/ws-server/redis split) | K8s migration, advanced scaling — `cp compose.split.sample.yaml compose.yaml` |
>
> The local `compose.yaml` is gitignored so your edits survive `git pull` when you do clone the repo.

3. Start services:
```bash
docker compose up -d
```

4. Access the site:
- Default port: 7001
- Website URL: http://your-server-ip:7001

### 3. Version Updates

```bash
cd Xboard
docker compose pull && docker compose up -d
```

The container always runs `php artisan xboard:update` (migrate + plugin install + version cache + theme refresh) on boot, so no extra command is required.

> **Using a `compose.yaml` from before 2026-04-19?** That template did not auto-run `xboard:update` on container start, so use the following command to upgrade instead:
> ```bash
> docker compose pull && docker compose run -it --rm web php artisan xboard:update && docker compose up -d
> ```

### 4. Version Rollback

1. Modify the version number in `docker-compose.yaml` to the version you want to roll back to
2. Execute: `docker compose up -d`

### Important Notes

- If you need to use MySQL, please install it separately and redeploy
- Code changes require service restart to take effect
- You can configure Nginx reverse proxy to use port 80 