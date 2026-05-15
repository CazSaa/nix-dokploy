# nix-dokploy

[![Build](https://github.com/el-kurto/nix-dokploy/actions/workflows/build.yml/badge.svg)](https://github.com/el-kurto/nix-dokploy/actions/workflows/build.yml)

A NixOS module that runs [Dokploy](https://dokploy.com/) using declarative systemd units.

NixOS-only — uses `systemd.services` and `systemd.tmpfiles` directly.

## Features

- `dokploy-stack.service` and `dokploy-traefik.service` systemd units
- Service ordering: `docker.service` → `dokploy-stack.service` → `dokploy-traefik.service`
- State directory creation via `systemd.tmpfiles`
- Clean stop/restart (containers removed on stop)
- No reliance on upstream shell scripts

![Service Dependencies](./Readme/systemctl-list-dependencies-dokploy.png)
![Service Status](./Readme/systemctl-status-dokploy.png)
![Docker Stack](./Readme/docker-stack-ps-dokploy.png)

## Requirements

- Docker enabled with `live-restore = false` (required for swarm)
- Rootless Docker is not supported (swarm limitation)

## Quick Start

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-dokploy.url = "github:el-kurto/nix-dokploy";
    nix-dokploy.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nix-dokploy, ... }: {
    nixosConfigurations.my-server = nixpkgs.lib.nixosSystem {
      modules = [
        nix-dokploy.nixosModules.default
        {
          virtualisation.docker.enable = true;
          virtualisation.docker.daemon.settings.live-restore = false;

          services.dokploy.enable = true;
          services.dokploy.database.passwordFile = "/var/lib/secrets/dokploy-db-password";
          services.dokploy.auth.secretFile = "/var/lib/secrets/dokploy-auth-secret";
        }
      ];
    };
  };
}
```

Generate secret files on the host before deploying:

```bash
mkdir -p /var/lib/secrets
openssl rand -base64 32 > /var/lib/secrets/dokploy-db-password
openssl rand -hex 32 > /var/lib/secrets/dokploy-auth-secret
```

Dokploy will be available at `http://your-server-ip:3000`

## Configuration

### General

| Option | Default | Description |
|--------|---------|-------------|
| `dataDir` | `/var/lib/dokploy` | Data directory |
| `image` | `dokploy/dokploy:v0.29.4` | Dokploy Docker image |
| `environment` | `{}` | Environment variables for the Dokploy container |
| `lxc` | `false` | LXC compatibility mode (e.g. Proxmox) |

```nix
services.dokploy.environment = {
  TZ = "Europe/Amsterdam";
};
```

### Port

| Option | Default | Description |
|--------|---------|-------------|
| `port` | `"3000:3000"` | Port binding for web UI |
| `hostPortMode` | `false` | Use `"host"` port mode instead of `"ingress"` |

Docker bypasses host firewall rules, so `"3000:3000"` exposes the port to the internet regardless of iptables/nftables.

Once Traefik is set up as a reverse proxy, disable direct access:

```nix
services.dokploy.port = null;
```

### Database Password

| Option | Default | Description |
|--------|---------|-------------|
| `database.passwordFile` | — (required) | Path to file containing the PostgreSQL password |
| `database.useInsecureHardcodedPassword` | `false` | Use the old hardcoded password (migration aid only) |

The password is stored as a Docker secret. Generate one before deploying:

```bash
openssl rand -base64 32 > /var/lib/secrets/dokploy-db-password
```

```nix
services.dokploy.database.passwordFile = "/var/lib/secrets/dokploy-db-password";
```

#### Upgrading from the old hardcoded password

Previous versions used a hardcoded password. On upgrade, `nixos-rebuild` will fail asking you to set `database.passwordFile` or enable `database.useInsecureHardcodedPassword`.

**Option A: Keep the old password temporarily**

```nix
services.dokploy.database.useInsecureHardcodedPassword = true;
```

A build warning will remind you to migrate.

**Option B: Migrate to a secure password**

Complete these steps in order. The old stack must still be running for step 2.

1. Generate a new password file:
   ```bash
   openssl rand -base64 32 > /var/lib/secrets/dokploy-db-password
   ```

2. Change the password in the running PostgreSQL container. As root, open a psql shell:
   ```bash
   docker exec -it $(docker ps --filter "name=dokploy_postgres" -q) psql -U dokploy -d dokploy
   ```
   Then set the password to match the contents of your password file:
   ```sql
   ALTER USER dokploy WITH PASSWORD 'contents-of-password-file';
   ```

   > Do not pass the password via command-line flags or environment variables — it
   > will be visible in the process list.

3. Deploy with `database.passwordFile` set.

#### Rotating the password

Docker secrets are immutable, so the deploy script won't update an existing secret. To rotate, run these steps as root:

1. Generate a new password file:
   ```bash
   openssl rand -base64 32 > /var/lib/secrets/dokploy-db-password
   ```
2. Change the password in the running PostgreSQL container:
   ```bash
   docker exec -it $(docker ps --filter "name=dokploy_postgres" -q) psql -U dokploy -d dokploy
   ```
   ```sql
   ALTER USER dokploy WITH PASSWORD 'contents-of-password-file';
   ```
3. Remove the stack: `docker stack rm dokploy`
4. Remove the old secret: `docker secret rm dokploy_postgres_password`
5. Redeploy with `nixos-rebuild switch`

### Auth Secret

| Option | Default | Description |
|--------|---------|-------------|
| `auth.secretFile` | — (required) | Path to file containing the Better Auth secret |
| `auth.useInsecureHardcodedSecret` | `false` | Use the old hardcoded secret (migration aid only) |

The secret is stored as a Docker secret. Generate one before deploying:

```bash
openssl rand -hex 32 > /var/lib/secrets/dokploy-auth-secret
```

```nix
services.dokploy.auth.secretFile = "/var/lib/secrets/dokploy-auth-secret";
```

#### Upgrading from the old hardcoded secret

Dokploy v0.29.3 added a `migrate-auth-secret` command for existing 2FA records. You must upgrade to v0.29.3 **before** migrating the secret.

**Step 1: Upgrade to v0.29.3 while keeping the old secret**

Pin the v0.29.3 image and add the temporary fallback:

> If your current nix-dokploy input does not yet have the `auth` options, you only need to set the `image` option below to upgrade Dokploy itself.

```nix
services.dokploy.image = "dokploy/dokploy:v0.29.3";
services.dokploy.auth.useInsecureHardcodedSecret = true;
```

Rebuild:

```bash
sudo nixos-rebuild switch
```

This deploys the v0.29.3 image with the old secret. Verify the container is running before proceeding.

**Step 2: Generate a new secret**

```bash
openssl rand -hex 32 > /var/lib/secrets/dokploy-auth-secret
```

**Step 3: Migrate existing 2FA records**

Run the migration inside the currently running v0.29.3 container:

```bash
DOKPLOY_CONTAINER=$(docker ps --filter "name=dokploy_dokploy" --format "{{.ID}}" | head -n1)
NEW_SECRET=$(cat /var/lib/secrets/dokploy-auth-secret)
docker exec \
    -e OLD_SECRET=better-auth-secret-123456789 \
    -e NEW_SECRET="$NEW_SECRET" \
    "$DOKPLOY_CONTAINER" \
    sh -c "cd /app && pnpm run migrate-auth-secret"
```

**Step 4: Switch to the secret file**

Remove `useInsecureHardcodedSecret` and set the secret file:

```nix
services.dokploy.auth.secretFile = "/var/lib/secrets/dokploy-auth-secret";
```

Rebuild:

```bash
sudo nixos-rebuild switch
```

All active sessions will be invalidated after this change. Users will need to log in again. 2FA remains functional.

#### Rotating the secret

Docker secrets are immutable, so the deploy script won't update an existing secret. To rotate, run these steps as root:

1. Generate a new secret file:
   ```bash
   openssl rand -hex 32 > /var/lib/secrets/dokploy-auth-secret
   ```
2. Migrate existing 2FA records in the running Dokploy container (same command as above).
3. Remove the stack: `docker stack rm dokploy`
4. Remove the old secret: `docker secret rm dokploy_auth_secret`
5. Redeploy with `nixos-rebuild switch`

### Swarm

| Option | Default | Description |
|--------|---------|-------------|
| `swarm.advertiseAddress` | `"private"` | IP address Docker Swarm advertises |
| `swarm.autoRecreate` | `false` | Recreate swarm on IP change during restart |

```nix
services.dokploy.swarm.advertiseAddress = "private";  # first private IP (default)
services.dokploy.swarm.advertiseAddress = "public";   # public IP via ifconfig.me

# custom command
services.dokploy.swarm.advertiseAddress = {
  command = "tailscale ip -4 | head -n1";
  extraPackages = [ pkgs.tailscale ];
};

# recreate swarm if IP changes (safe for single-node only)
services.dokploy.swarm.autoRecreate = true;
```

Using `"public"` exposes swarm management ports (2377, 7946, 4789) to the internet. Consider Tailscale/WireGuard or private networking instead.

### Traefik

| Option | Default | Description |
|--------|---------|-------------|
| `traefik.image` | `traefik:v3.6.17` | Traefik Docker image |
| `traefik.extraArgs` | `[]` | Extra `docker run` flags |
| `traefik.certificates` | `{}` | TLS certificate pairs |
| `traefik.dynamicConfig` | `{}` | Dynamic config as Nix attrsets (generates YAML) |
| `traefik.files` | `{}` | Files to place in the dynamic config directory |

#### Extra arguments

```nix
services.dokploy.traefik.extraArgs = [
  "-e CF_API_EMAIL=user@example.com"
  "-e CF_API_KEY=your_api_key"
  "-v /path/to/certs:/certs"
];
```

#### TLS Certificates

Creates a subdirectory under `traefik/dynamic/certificates/<name>/` with `chain.crt`, `privkey.key`, and a `certificate.yml`.

```nix
services.dokploy.traefik.certificates."cloudflare-origin" = {
  certFile = "/var/lib/secrets/cloudflare-origin-ca.pem";
  keyFile = "/var/lib/secrets/cloudflare-origin-ca-key.pem";
};
```

#### Dynamic Configuration

Each key becomes a `.yml` file in the Traefik dynamic config directory.

```nix
services.dokploy.traefik.dynamicConfig."cloudflare-client-auth" = {
  tls.options.default.clientAuth = {
    caFiles = [ "/etc/dokploy/traefik/dynamic/files/cloudflare-origin-pull-ca.pem" ];
    clientAuthType = "RequireAndVerifyClientCert";
  };
};
```

#### Files

Files are placed at `traefik/dynamic/files/<name>` on the host and visible in the container at `/etc/dokploy/traefik/dynamic/files/<name>`.

```nix
services.dokploy.traefik.files."cloudflare-origin-pull-ca.pem" = pkgs.fetchurl {
  url = "https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem";
  sha256 = "...";
};
```

## License

[MIT License](./LICENSE)

Dokploy itself is [Apache 2.0 with additional terms](https://github.com/Dokploy/dokploy/blob/canary/LICENSE.MD).
