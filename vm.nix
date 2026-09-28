{ pkgs, ... }:

{

  # dconf backs virt-manager's saved settings
  programs.dconf.enable = true;

  # Also makes virt-manager connect to qemu:///system on start
  programs.virt-manager.enable = true;

  # Let the user manage VMs (libvirtd) and use hardware acceleration (kvm)
  users.users.scott.extraGroups = [
    "libvirtd"
    "kvm"
  ];

  # VM managers, guest tools and SPICE/Windows guest support.
  # guestfs-tools (virt-sparsify) is left out: it made every update heavy and is
  # only needed now and then; run it with `nix shell nixpkgs#guestfs-tools`.
  environment.systemPackages = with pkgs; [
    adwaita-icon-theme
    gnome-boxes
    phodav
    quickemu
    spice
    spice-gtk
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
