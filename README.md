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
