{
  description = "Shared NixOS configurations with Home Manager, on unstable";

  inputs = {
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
    # Main package set (unstable channel)
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    nixos-hardware = {
      # Pinned to an unmerged pull request (NixOS/nixos-hardware#2005) that
      # makes the ProArt PX13 profile build on Linux 7.2, where its kernel
      # patches no longer apply. When it is merged, switch back to
      # "github:NixOS/nixos-hardware" and run `nix flake update nixos-hardware`.
      url = "github:toastal/nixos-hardware/9f6e7c04bd8624daacebd76a21c0e0137ecbc6af";
      inputs.nixpkgs.follows = "nixpkgs";
      #inputs.nixpkgs.follows = "nixpkgs-stable";
    };
    # Tier 2 upstream: commits to main can break it, so update it on purpose
    # (nix flake update hermes-agent). Deliberately does not follow our nixpkgs.
    hermes-agent.url = "github:NousResearch/hermes-agent";
    # TEMPORARY: Tailscale 1.104.2 (security bulletin TS-2026-013) ahead of the
    # main nixpkgs, which cannot move yet: on nixpkgs from 2026-10-23 Open
    # WebUI fails to evaluate (python posthog broken by mcp 2). OpenCode 2
    # comes from here too. Remove this input and its uses in configuration.nix
    # and home.nix after the next full update.
    nixpkgs-tailscale.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      determinate,
      nixpkgs,
      nixpkgs-stable,
      home-manager,
      nixos-hardware,
      hermes-agent,
      ...
    }@inputs:
    let
      mkHost =
        hostModule:
        nixpkgs.lib.nixosSystem {
          specialArgs = { inherit inputs; };
          modules = [
            determinate.nixosModules.default
            hermes-agent.nixosModules.default
            hostModule
            ./configuration.nix
            home-manager.nixosModules.home-manager
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs = { inherit inputs; };
                users.scott = ./home.nix;
              };
            }
          ];
        };
    in
    {
      # Attribute names must match each host's networking.hostName.
      nixosConfigurations = {
        hn7306 = mkHost ./hosts/hn7306;
        phoenix = mkHost ./hosts/phoenix;
        gz302 = mkHost ./hosts/gz302;
      };
    };
}
