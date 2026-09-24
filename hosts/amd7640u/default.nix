# Settings specific to the AMD7640U laptop.
{ inputs, pkgs, ... }:

{
  imports = [
    inputs.nixos-hardware.nixosModules.framework-13-7040-amd
    ./hardware-configuration.nix
  ];

  networking.hostName = "amd7640u";

  boot.kernelPackages = pkgs.linuxPackages_latest;
}
