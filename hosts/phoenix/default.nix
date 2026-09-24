# Settings specific to the Phoenix laptop.
{ inputs, pkgs, ... }:

{
  imports = [
    inputs.nixos-hardware.nixosModules.framework-13-7040-amd
    ./hardware-configuration.nix
  ];

  networking.hostName = "phoenix";

  boot.kernelPackages = pkgs.linuxPackages_latest;
}
