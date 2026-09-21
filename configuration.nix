# Base system configuration shared by every host. Machine-specific settings
# live in hosts/<name>/, the desktop in gnome.nix, virtualization in vm.nix.

{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:

{
  imports = [
    ./gnome.nix
    ./llm.nix
    ./vm.nix
  ];

  # --- Boot and memory ---

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  # Compressed swap in RAM (no disk). Safety net against OOM when the
  # VM, model and host together approach total RAM.
  zramSwap.enable = true;

  # --- Networking ---

  networking.networkmanager.enable = true;
  services.tailscale = {
    enable = true;

    # To use a preauthorized key, set:
    # authKeyFile = "/run/secrets/tailscale_key";
    # Note: maximum expiry is 90 days
  };
  services.openssh.enable = true;

  # --- Locale, time and Nix ---

  time.timeZone = "Europe/Oslo";
  i18n.defaultLocale = "en_US.UTF-8";

  # Enable flakes
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # --- Desktop and input ---

  # Login screen. The sessions it offers come from gnome.nix (and later niri).
  services.xserver.enable = true;
  services.displayManager.gdm.enable = true;

  # Keyboard layout (X11 and Wayland)
  services.xserver.xkb = {
    layout = "no,us";
    variant = "";
  };
  console.keyMap = "no";

  services.flatpak.enable = true;

  # --- Audio and printing ---

  # Sound via PipeWire instead of PulseAudio.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Printing via CUPS, with the Canon inkjet driver.
  services.printing.enable = true;
  services.printing.drivers = [ pkgs.cnijfilter2 ];

  # --- Users ---

  # Set a password with passwd after first boot.
  users.users.scott = {
    isNormalUser = true;
    description = "scott";
    extraGroups = [
      "networkmanager"
      "wheel"
      "render"
      "video"
    ];
  };

  # --- Packages ---

  # Run unpatched dynamically linked binaries
  programs.nix-ld.enable = true;
  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # System-wide packages
  environment.systemPackages = with pkgs; [
    btrfs-progs
    git
    linux-wifi-hotspot
    ntfs3g
    parted
    proton-vpn
    proton-vpn-cli
    usbutils
    vim
    wget
    wireguard-tools
  ];

  # Release this system's stateful defaults come from. Do not bump this when
  # upgrading; see configuration.nix(5) before changing it.
  system.stateVersion = "25.11";

}
