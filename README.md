# homelab-infra-as-code

NixOS configurations for homelab hosts.

## Background

Moving from Proxmox "Click Ops" (used for 2+ years) to a declarative infrastructure. I have used NixOS as my daily driver for over 3 years.

## Structure

- `hosts/`: Host-specific configurations.
  - `_template/`: Reference template.
  - `abuja/`: Host `abuja`.

## Deployment

### Initial Setup

Clone the repository to a persistent location:

```bash
git clone <repo-url> ~/homelab-infra-as-code
```

### Configuration

Create a shim at `/etc/nixos/configuration.nix` that imports the specific host configuration. This avoids copying files manually.

Example `/etc/nixos/configuration.nix`:

```nix
{ ... }:
{
  imports = [
    /home/abuja/homelab-infra-as-code/hosts/abuja/configuration.nix
    ./hardware-configuration.nix
  ];
}
```

### Apply Changes

Run the rebuild command:

```bash
sudo nixos-rebuild switch
```

## Incus Web UI Access (mTLS)

Incus Web UI/API authentication is based on client TLS certificates (not a username/password).

On `abuja`, the NixOS config generates and trusts a browser client certificate (`ui-admin`) via a `systemd` oneshot unit.

### Import The Browser Certificate

After deploying (`sudo nixos-rebuild switch`), copy the bundle from the host and import it into your browser/OS keychain:

```bash
mkdir -p secrets/incus/clients/abuja
scp abuja@<host-ip>:/var/lib/incus-client-certs/ui-admin.pfx secrets/incus/clients/abuja/ui-admin.pfx
scp abuja@<host-ip>:/var/lib/incus-client-certs/ui-admin.pfx.pass secrets/incus/clients/abuja/ui-admin.pfx.pass
```

The PKCS#12 password is stored in `ui-admin.pfx.pass` (some browsers won't import a client cert bundle with an empty password).

Then visit `https://<host-ip>:8443/ui/` and select the client certificate when prompted.

To regenerate the cert bundle on the host:

```bash
sudo rm -f /var/lib/incus-client-certs/ui-admin.{key,crt,pfx,pfx.pass}
sudo systemctl restart incus-ui-client-cert.service
```

## Forgejo (Self-Hosted Git)

- **URL**: `http://<host-ip>:7830`
- **Database**: SQLite
- **Git over SSH**: Uses the host's OpenSSH server (port 22)

### First-Time Setup

1. Deploy: `sudo nixos-rebuild switch`
2. Retrieve the auto-generated admin password:
   ```bash
   sudo cat /var/lib/forgejo/admin-password
   ```
3. Visit `http://<host-ip>:7830` — log in as `abuja` and you'll be prompted to change your password
