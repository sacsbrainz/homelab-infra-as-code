# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

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

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "Africa/Lagos";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_NG";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_NG";
    LC_IDENTIFICATION = "en_NG";
    LC_MEASUREMENT = "en_NG";
    LC_MONETARY = "en_NG";
    LC_NAME = "en_NG";
    LC_NUMERIC = "en_NG";
    LC_PAPER = "en_NG";
    LC_TELEPHONE = "en_NG";
    LC_TIME = "en_NG";
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

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.abuja = {
    isNormalUser = true;
    description = "solomon";
    extraGroups = [
      "networkmanager"
      "wheel"
      "incus-admin"
    ];
    packages = with pkgs; [ ];
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    wget
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  programs.git.enable = true;

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  # Allow Incus traffic through the firewall
  networking.firewall.interfaces.incusbr0.allowedTCPPorts = [
    53 # dns
    67 # dhcp
  ];
  networking.firewall.interfaces.incusbr0.allowedUDPPorts = [
    53 # dns
    67 # dhcp
  ];

  networking.firewall.allowedTCPPorts = [
    8443 # incus web ui
  ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Did you read the comment?

}
