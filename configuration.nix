# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:

{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    #./vm.nix
  ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;

  boot.kernelParams = [
    # The kernel module parameter gttsize is a is deprecated and will be removed in the future.
    #"amdgpu.gttsize=120000"
    "amd_iommu=off"
    "amdgpu.gttsize=117760"
    "ttm.pages_limit=33554432"

    # specified as 4KiB pages: 120 GB GTT
    #options ttm pages_limit=31457280
    # specified as 4KiB pages: 60 GB pre-allocated
    #options ttm page_pool_size 15728640
  ];
  boot.loader.efi.canTouchEfiVariables = true;
  # Kernel selection
  boot.kernelPackages = pkgs.linuxPackages_latest;
  # Strix halo related settings
  nixpkgs.config.rocmSupport = true;
  hardware.amdgpu.opencl.enable = true;
  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true; # Replaced 'driSupport32Bit'
  services.lact.enable = true;

  networking.hostName = "hn7306"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "Europe/Oslo";
  #  Enable flakes
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  # Enable the X11 windowing system.
  services.xserver.enable = true;

  # Enable the GNOME Desktop Environment.
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  services.desktopManager.gnome.extraGSettingsOverrides = ''
    [org.gnome.mutter]
    experimental-features=['scale-monitor-framebuffer', 'xwayland-native-scaling']
  '';
  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "no,us";
    variant = "";
  };
  /*
    services.ollama = {
      enable = true;
      package = pkgs.ollama-rocm; # or set pkgs.ollama-vulkan
      #package = pkgs.ollama-vulkan;
      loadModels = [
        "ministral-3:14b"
        "ministral-3:8b"
        "mistral-medium-3.5"
        "gpt-oss:120b"

      ];
      #rocmOverrideGfx = "11.5.1";
      environmentVariables = {
        # Hopefully helps with offloading layers to GPU, it didn't
        HSA_ENABLE_SDMA = "0";
        OLLAMA_DEBUG = "1";
      };
    };
  */

  # Configure console keymap
  console.keyMap = "no";

  # Enable CUPS to print documents.
  services.printing.enable = true;
  services.fwupd.enable = true;
  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.scott = {
    isNormalUser = true;
    description = "scott";
    extraGroups = [
      "networkmanager"
      "wheel"
      "render"
      "video"
      "libvirtd"
    ];
    packages = with pkgs; [
      #  thunderbird
    ];
  };
  users.groups.libvirtd.members = [ "scott" ];
  users.groups.kvm.members = [ "scott" ];
  # Install fox.
  #programs.firefox.enable = true;
  #programs.openclaw.enable = true;
  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    wget
    linux-wifi-hotspot
    git
    libdisplay-info
    rocmPackages.rocm-smi
    ntfs3g

    #inputs.helix.packages."${pkgs.stdenv.hostPlatform.system}".helix
    #inputs.nixpkgs-stable.packages."${pkgs.stdenv.hostPlatform.system}".firefox
  ];
  fileSystems =
    let
      ntfs-drives = [
        "/home/scott/Scratch"
      ];
    in
    lib.genAttrs ntfs-drives (path: {
      options = [
        "uid=1000" # REPLACE "$UID" WITH YOUR ACTUAL UID!
        # "nofail"
      ];
    });
  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;

  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Did you read the comment?

}
