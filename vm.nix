{ config, pkgs, ... }:

{

  # dconf backs virt-manager's saved settings
  programs.dconf.enable = true;

  # Let the user manage VMs (libvirtd) and use hardware acceleration (kvm)
  users.users.scott.extraGroups = [
    "libvirtd"
    "kvm"
  ];

  # VM managers, guest tools and SPICE/Windows guest support
  environment.systemPackages = with pkgs; [
    adwaita-icon-theme
    dnsmasq
    gnome-boxes
    guestfs-tools
    libguestfs
    phodav
    quickemu
    spice
    spice-gtk
    spice-protocol
    virt-manager
    virt-viewer
    virtio-win
    win-spice
  ];

  # libvirt with TPM emulation (needed for Windows 11)
  virtualisation = {
    libvirtd = {
      enable = true;
      qemu = {
        swtpm.enable = true;
      };
    };
    spiceUSBRedirection.enable = true;
  };
  services.spice-vdagentd.enable = true;

}
