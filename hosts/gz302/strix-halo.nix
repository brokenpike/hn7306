# Hardware and GPU tuning for the ASUS GZ302 (AMD Strix Halo). Same chip as
# hn7306; see hosts/hn7306/strix-halo.nix for the reasoning behind each value.
{ pkgs, ... }:

{
  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    kernelParams = [
      # GPU-addressable memory cap: 104 GiB, in 4 KiB pages (104 * 262144), as
      # on hn7306. A ceiling, not a reservation; it only matters once a large
      # model runs here. This machine shows about 121 GiB to Linux, so it
      # leaves about 17 GiB for the host.
      "ttm.pages_limit=27262976"
    ];
  };

  # Lives in the system config because home-manager uses useGlobalPkgs.
  nixpkgs.config.rocmSupport = true;

  hardware = {
    enableRedistributableFirmware = true;
    amdgpu.opencl.enable = true;
    graphics = {
      enable = true;
      enable32Bit = true;
    };
  };

  services = {
    lact.enable = true;
    asusd.enable = true; # charge limiting
    fwupd.enable = true;
  };

  environment.systemPackages = with pkgs; [
    libdisplay-info
    rocmPackages.rocm-smi
  ];
}
