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
    # TEMPORARY: Open WebUI from the last nixpkgs where it evaluates. Since
    # 2026-10-19 python posthog is marked broken (it does not support mcp 2),
    # and chromadb, which Open WebUI needs, depends on it. Pinned to a commit,
    # so nix flake update leaves it alone. Remove it and its use in both
    # hosts' open-webui.nix once posthog is fixed (NixOS/nixpkgs#578265).
    nixpkgs-openwebui.url = "github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df";
    # Hex voice dictation (Anomaly, the OpenCode team), not in nixpkgs. It must
    # follow our nixpkgs: built against an older glibc than the system's
    # graphics drivers, it finds no Vulkan adapter and its window won't open.
    hex = {
      url = "github:anomalyco/hex";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
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
        latitude5400 = mkHost ./hosts/latitude5400;
      };
    };
}
