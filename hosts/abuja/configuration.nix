# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Hide the menu - boots immediately to default entry
  boot.loader.timeout = 0;

  # Limit generations shown in menu (if timeout > 0)
  boot.loader.systemd-boot.configurationLimit = 5;

  networking.hostName = "abuja"; # hostname.

  # Enable nftables, required for Incus
  networking.nftables.enable = true;

  # Use networkd — routes follow whichever ethernet port has carrier.
  networking.useNetworkd = true;
  networking.useDHCP = false;
  systemd.network.wait-online.anyInterface = true;
  services.resolved.enable = false;
  systemd.network.networks."10-lan" = {
    matchConfig.Name = "enp*";
    address = [ "192.168.1.168/24" ];
    gateway = [ "192.168.1.1" ];
    networkConfig.DHCP = "no";
  };

  # Set your time zone.
  time.timeZone = "Africa/Lagos";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  # Used en_US instead of en_NG because en_NG does not support UTF-8.
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Enable Incus
  virtualisation.incus.enable = true;
  virtualisation.incus.ui.enable = true;
  virtualisation.incus.preseed = {
    config = {
      "core.https_address" = ":8443";
    };
    networks = [
      {
        config = {
          "ipv4.address" = "10.0.100.1/24";
          "ipv4.nat" = "true";
        };
        name = "incusbr0";
        type = "bridge";
      }
    ];
    profiles = [
      {
        devices = {
          eth0 = {
            name = "eth0";
            network = "incusbr0";
            type = "nic";
          };
          root = {
            path = "/";
            pool = "default";
            size = "35GiB";
            type = "disk";
          };
        };
        name = "default";
      }
    ];
    storage_pools = [
      {
        config = {
          source = "/var/lib/incus/storage-pools/default";
        };
        driver = "dir";
        name = "default";
      }
    ];
  };

  # Incus UI uses mTLS client certificates (not username/password).
  # Generate a browser-importable client cert (PFX) and trust it in Incus.
  #
  # Retrieve the bundle from:
  #   /var/lib/incus-client-certs/ui-admin.pfx
  #   /var/lib/incus-client-certs/ui-admin.pfx.pass
  #
  # Regenerate by deleting the files and restarting:
  #   sudo systemctl restart incus-ui-client-cert.service
  systemd.services.incus-ui-client-cert = {
    description = "Generate and trust Incus UI client certificate (ui-admin)";
    wantedBy = [ "multi-user.target" ];
    requires = [ "incus.service" ];
    after = [
      "incus.service"
      "incus-preseed.service"
    ];
    wants = [ "incus-preseed.service" ];

    path = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.openssl
      config.virtualisation.incus.clientPackage
    ];

    serviceConfig = {
      Type = "oneshot";

      # Give the interactive admin user access to the generated bundle.
      User = "abuja";
      Group = "incus-admin";

      StateDirectory = "incus-client-certs";
      StateDirectoryMode = "0750";
      UMask = "0077";
    };

    script = ''
      set -euo pipefail

      CERT_DIR="/var/lib/incus-client-certs"
      NAME="ui-admin"

      KEY="''${CERT_DIR}/''${NAME}.key"
      CRT="''${CERT_DIR}/''${NAME}.crt"
      PFX="''${CERT_DIR}/''${NAME}.pfx"

      if [[ ! -s "''${KEY}" || ! -s "''${CRT}" ]]; then
        echo "Generating Incus UI client certificate: ''${NAME}"

        openssl req \
          -x509 -newkey rsa:4096 \
          -sha256 -days 3650 -nodes \
          -subj "/CN=${config.networking.hostName}-''${NAME}" \
          -addext "basicConstraints = critical, CA:FALSE" \
          -addext "extendedKeyUsage = clientAuth" \
          -addext "keyUsage = digitalSignature" \
          -keyout "''${KEY}" \
          -out "''${CRT}"
      fi

      if [[ ! -s "''${PFX}" ]]; then
        # Some browser/UI import paths refuse empty PKCS#12 passwords; also, some
        # clients have trouble importing OpenSSL 3 defaults (PBES2/AES/SHA256).
        # Keep a per-host password file and export with widely supported PBE/MAC.
        PASS_FILE="''${CERT_DIR}/''${NAME}.pfx.pass"
        if [[ ! -s "''${PASS_FILE}" ]]; then
          openssl rand -base64 24 > "''${PASS_FILE}"
        fi

        openssl pkcs12 \
          -export \
          -out "''${PFX}" \
          -inkey "''${KEY}" \
          -in "''${CRT}" \
          -name "${config.networking.hostName}-''${NAME}" \
          -keypbe PBE-SHA1-3DES \
          -certpbe PBE-SHA1-3DES \
          -macalg sha1 \
          -passout "file:''${PASS_FILE}"
      fi

      # Trust the cert in Incus if it's not already present.
      incus admin waitready --timeout=60 >/dev/null

      FP="$(openssl x509 -noout -fingerprint -sha256 -in "''${CRT}" | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')"
      FP_SHORT="''${FP:0:12}"

      existingFp=""
      while IFS=, read -r trustName trustFp; do
        trustName="$(printf '%s' "''${trustName}" | tr '[:upper:]' '[:lower:]')"
        trustFp="$(printf '%s' "''${trustFp}" | tr -d ':' | tr '[:upper:]' '[:lower:]')"

        # Found exact name match; decide if it matches our cert.
        if [[ "''${trustName}" == "''${NAME}" ]]; then
          existingFp="''${trustFp}"
          break
        fi
      done < <(incus config trust list -f csv,noheader -c n,f)

      if [[ -n "''${existingFp}" ]]; then
        # Incus may display fingerprints shortened; treat prefix matches as equal.
        if [[ "''${existingFp}" == "''${FP}" || "''${FP}" == "''${existingFp}"* ]]; then
          exit 0
        fi

        echo "Replacing Incus trusted client cert for name ''${NAME} (old fp: ''${existingFp}, new fp: ''${FP_SHORT}...)"
        incus config trust remove "''${existingFp}"
      else
        # If the cert is already trusted under a different name, we're good.
        while IFS=, read -r _ trustFp; do
          trustFp="$(printf '%s' "''${trustFp}" | tr -d ':' | tr '[:upper:]' '[:lower:]')"
          if [[ "''${trustFp}" == "''${FP}" || "''${FP}" == "''${trustFp}"* ]]; then
            exit 0
          fi
        done < <(incus config trust list -f csv,noheader -c n,f)
      fi

      echo "Trusting Incus UI client certificate: ''${NAME}"
      set +e
      incus config trust add-certificate "''${CRT}" --name "''${NAME}" --type client
      rc=$?
      set -e

      if [[ $rc -ne 0 ]]; then
        # Race/duplicate safe: treat as success if the cert is now present.
        while IFS=, read -r _ trustFp; do
          trustFp="$(printf '%s' "''${trustFp}" | tr -d ':' | tr '[:upper:]' '[:lower:]')"
          if [[ "''${trustFp}" == "''${FP}" || "''${FP}" == "''${trustFp}"* ]]; then
            exit 0
          fi
        done < <(incus config trust list -f csv,noheader -c n,f)
        exit $rc
      fi
    '';
  };

  services.forgejo = {
    enable = true;
    lfs.enable = true;
    settings = {
      server = {
        HTTP_PORT = 7830;
        SSH_PORT = lib.head config.services.openssh.ports;
      };
      service.DISABLE_REGISTRATION = true;
      "git.timeout" = {
        DEFAULT = 3600;
        MIGRATE = 3600;
        MIRROR = 3600;
        CLONE = 3600;
        PULL = 3600;
      };
    };
  };

  # Blocky — DNS ad blocker.
  # Point your router's DHCP DNS at this machine's IP for network-wide blocking.
  services.blocky = {
    enable = true;
    settings = {
      upstreams.groups.default = [
        "https://one.one.one.one/dns-query"
        "https://dns.google/dns-query"
      ];

      bootstrapDns = [
        {
          upstream = "https://one.one.one.one/dns-query";
          ips = [
            "1.1.1.1"
            "1.0.0.1"
          ];
        }
        {
          upstream = "https://dns.google/dns-query";
          ips = [
            "8.8.8.8"
            "8.8.4.4"
          ];
        }
      ];

      blocking = {
        denylists.ads = [
          "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
          "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/pro.txt"
        ];
        clientGroupsBlock.default = [ "ads" ];
        blockType = "zeroIp";
      };

      caching = {
        minTime = "5m";
        prefetching = true;
      };

      # Bind to localhost + LAN IP only (Incus dnsmasq owns 10.0.100.1:53).
      ports.dns = "127.0.0.1:53,192.168.1.168:53";
    };
  };

  # Route the host's own lookups through Blocky.
  networking.nameservers = [ "127.0.0.1" ];

  # Immich — self-hosted photo & video backup.
  services.immich = {
    enable = true;
    host = "0.0.0.0";
    openFirewall = true; # auto-open port 2283
  };

  # Auto-create admin user on first boot; password saved to:
  systemd.services.forgejo.preStart =
    let
      adminCmd = "${lib.getExe config.services.forgejo.package} admin user";
      passwordFile = "/var/lib/forgejo/admin-password";
    in
    ''
      if [[ ! -s "${passwordFile}" ]]; then
        ${pkgs.openssl}/bin/openssl rand -base64 32 > "${passwordFile}"
        chmod 600 "${passwordFile}"
      fi
      ${adminCmd} create --admin \
        --username "${config.networking.hostName}" \
        --email "${config.networking.hostName}@localhost" \
        --password "$(tr -d '\n' < ${passwordFile})" \
        --must-change-password || true
    '';

  users.users.abuja = {
    isNormalUser = true;
    description = "solomon";
    extraGroups = [
      "wheel"
      "incus-admin"
    ];
    packages = with pkgs; [
      btop
      openssl
      zellij
      jq
      busybox
      dig
    ];
  };

  nixpkgs.config.allowUnfree = true;

  environment.shellAliases = {
    nu = "sudo nixos-rebuild switch";
  };

  environment.systemPackages = with pkgs; [
    wget
  ];

  programs.git.enable = true;

  services.openssh.enable = true;

  networking.firewall.interfaces.incusbr0.allowedTCPPorts = [
    53 # dns
    67 # dhcp
  ];
  networking.firewall.interfaces.incusbr0.allowedUDPPorts = [
    53 # dns
    67 # dhcp
  ];

  networking.firewall.allowedTCPPorts = [
    53 # blocky dns
    7830 # forgejo
    8443 # incus web ui
  ];
  networking.firewall.allowedUDPPorts = [
    53 # blocky dns
  ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Did you read the comment?

}
