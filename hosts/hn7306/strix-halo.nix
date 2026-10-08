# Hardware and GPU tuning for the ASUS HN7306 (AMD Strix Halo).
{ pkgs, ... }:

{
  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    kernelParams = [
      "amd_iommu=off"
      # GPU-addressable memory cap: 104 GiB, in 4 KiB pages (104 * 262144).
      # Fits DeepSeek V4 Flash at 2-bit (85 GiB plus context) and leaves about
      # 20 GiB for the host, so a big model and a VM must not run together.
      # amdgpu.gttsize is deprecated; ttm.pages_limit is the effective limit.
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
