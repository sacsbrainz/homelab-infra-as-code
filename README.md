# homelab-infra-as-code

NixOS configs for my homelab. Moved away from Proxmox click-ops after 2+ years — everything is declarative now.

## Structure

```
hosts/
  _template/    starter config for new hosts
  abuja/        main server
scripts/
  mirror-github-to-forgejo.sh
secrets/        local only, gitignored
```

## Setup

Clone somewhere persistent:

```bash
git clone <repo-url> ~/homelab-infra-as-code
```

On the target host, point `/etc/nixos/configuration.nix` at the repo instead of managing configs in `/etc/nixos` directly:

```nix
{ ... }:
{
  imports = [
    /home/<user>/homelab-infra-as-code/hosts/<hostname>/configuration.nix
    ./hardware-configuration.nix
  ];
}
```

Then rebuild:

```bash
sudo nixos-rebuild switch
```

To add a new host, copy `hosts/_template/` to `hosts/<name>/` and edit.

---

## Hosts

### abuja

Main server. Runs Incus for containers/VMs and Forgejo as a local git server.

---

## Services

### Incus

Web UI uses mTLS — no passwords, just client certs.

The NixOS config auto-generates a client cert (`ui-admin`) via a systemd oneshot. After deploying, grab the cert bundle:

```bash
mkdir -p secrets/incus/clients/abuja
scp abuja@<host-ip>:/var/lib/incus-client-certs/ui-admin.pfx secrets/incus/clients/abuja/
scp abuja@<host-ip>:/var/lib/incus-client-certs/ui-admin.pfx.pass secrets/incus/clients/abuja/
```

Import the `.pfx` into your browser (password is in `.pfx.pass`), then hit `https://<host-ip>:8443/ui/`.

To regenerate:

```bash
sudo rm -f /var/lib/incus-client-certs/ui-admin.{key,crt,pfx,pfx.pass}
sudo systemctl restart incus-ui-client-cert.service
```

### Forgejo

Self-hosted git. Listens on `http://<host-ip>:7830`, uses SQLite, SSH via the host's OpenSSH on port 22.

First time after deploy:

```bash
sudo cat /var/lib/forgejo/admin-password
```

Log in as `abuja` at `http://<host-ip>:7830` and change the password.

#### Mirroring GitHub repos

`scripts/mirror-github-to-forgejo.sh` creates pull-mirrors of your GitHub repos. Forgejo handles re-syncing.

Create `scripts/.env`:

```bash
GITHUB_TOKEN=ghp_...   # repo + read:org scopes
FORGEJO_TOKEN=...      # from Forgejo → Settings → Applications
FORGEJO_URL=http://<host-ip>:7830
```

```bash
# dry run
DRY_RUN=true bash scripts/mirror-github-to-forgejo.sh

# for real
bash scripts/mirror-github-to-forgejo.sh
```

Idempotent — safe to re-run. `--help` for options.

---

## TODO

- [ ] Blocky (DNS ad blocking)
- [ ] CI/CD (Forgejo Actions)
- [ ] Secrets management (agenix)
- [ ] Immich setup
- [ ] Transmission setup
- [ ] Angie reverse proxy
- [ ] Tailscale
- [ ] Backups
- [ ] Monitoring
- [ ] More hosts
