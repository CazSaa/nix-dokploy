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
          services.dokploy.encryption.keyFile = "/var/lib/secrets/dokploy-encryption-key";
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
openssl rand -hex 32 > /var/lib/secrets/dokploy-encryption-key
```

Dokploy will be available at `http://your-server-ip:3000`

## Configuration

### General

| Option | Default | Description |
|--------|---------|-------------|
| `dataDir` | `/var/lib/dokploy` | Data directory |
| `image` | `dokploy/dokploy:v0.29.14` | Dokploy Docker image |
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

The password is stored as a Docker secret. Generate one before deploying:

```bash
openssl rand -base64 32 > /var/lib/secrets/dokploy-db-password
```

```nix
services.dokploy.database.passwordFile = "/var/lib/secrets/dokploy-db-password";
```

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

The secret is stored as a Docker secret. Generate one before deploying:

```bash
openssl rand -hex 32 > /var/lib/secrets/dokploy-auth-secret
```

```nix
services.dokploy.auth.secretFile = "/var/lib/secrets/dokploy-auth-secret";
```

> Since Dokploy v0.29.12, environment variables are encrypted at rest. Without a dedicated key the encryption key is derived from this secret, making it effectively immutable — which is why this module requires `encryption.keyFile` (see [Encryption Key](#encryption-key)).

#### Rotating the secret

> **Caution on Dokploy v0.29.12+:** any values encrypted under a key derived from this secret (only possible if you ran v0.29.12+ before `encryption.keyFile` was set) become unreadable after rotation. Dokploy re-encrypts such values with the dedicated key only when they are next saved — re-save them all before rotating.

Docker secrets are immutable, so the deploy script won't update an existing secret. To rotate, run these steps as root:

1. Generate a new secret value:
   ```bash
   NEW_SECRET=$(openssl rand -hex 32)
   ```
2. Migrate existing 2FA records in the running Dokploy container:
   ```bash
   DOKPLOY_CONTAINER=$(docker ps --filter "name=dokploy_dokploy" --format "{{.ID}}" | head -n1)
   docker exec \
       -e OLD_SECRET="$(cat /var/lib/secrets/dokploy-auth-secret)" \
       -e NEW_SECRET="$NEW_SECRET" \
       "$DOKPLOY_CONTAINER" \
       sh -c "cd /app && pnpm run migrate-auth-secret"
   ```
3. Update the secret file:
   ```bash
   echo "$NEW_SECRET" > /var/lib/secrets/dokploy-auth-secret
   ```
4. Remove the stack: `docker stack rm dokploy`
5. Remove the old secret: `docker secret rm dokploy_auth_secret`
6. Redeploy with `nixos-rebuild switch`

### Encryption Key

| Option | Default | Description |
|--------|---------|-------------|
| `encryption.keyFile` | — (required) | Path to file containing a dedicated encryption key |

Since Dokploy v0.29.12, environment variables are encrypted at rest (AES-256-GCM). This option provides a dedicated key for that encryption, stored as a Docker secret and passed to Dokploy via `ENCRYPTION_KEY_FILE`. Without it, Dokploy falls back to a key derived from the auth secret, coupling your stored data to a secret you may want to rotate — so this module requires it.

```bash
openssl rand -hex 32 > /var/lib/secrets/dokploy-encryption-key
```

```nix
services.dokploy.encryption.keyFile = "/var/lib/secrets/dokploy-encryption-key";
```

> **Never rotate this key.** Encrypted values cannot be re-keyed in bulk; a changed key makes them unreadable. Adding the key to an existing install is safe: values encrypted before the change (only possible if you previously overrode `image` to v0.29.12+) remain readable via the auth-secret-derived key and are re-encrypted with the dedicated key as each one is saved.
>
> Do **not** pass the key via `services.dokploy.environment` — those values end up world-readable in the Nix store.

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
