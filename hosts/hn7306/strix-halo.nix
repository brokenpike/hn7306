# Hardware and GPU tuning for the ASUS HN7306 (AMD Strix Halo).
{ pkgs, ... }:

{
  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    kernelParams = [
      "amd_iommu=off"
      # GPU-addressable memory cap: 80 GiB, in 4 KiB pages (80 * 262144).
      # Leaves room for a 24 GiB VM and the host. amdgpu.gttsize is deprecated
      # and ttm.pages_limit is the effective limit.
      "ttm.pages_limit=20971520"
    ];
  };

  # Lives in the system config because home-manager uses useGlobalPkgs.
  nixpkgs.config.rocmSupport = true;

  hardware = {
    enableRedistributableFirmware = true;
    amdgpu.opencl.enable = true;
    graphics = {
      enable = true;
      enable32Bit = true; # Replaced 'driSupport32Bit'
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
