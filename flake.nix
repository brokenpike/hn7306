{
  description = "NixOS flake for ASUS HN7306 (Strix Halo) with Home Manager, on unstable";

  inputs = {
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
    # Main package set (unstable channel)
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware";
      inputs.nixpkgs.follows = "nixpkgs";
      #inputs.nixpkgs.follows = "nixpkgs-stable";
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
      ...
    }@inputs:
    {
      # Attribute name must match networking.hostName
      nixosConfigurations = {
        hn7306 = nixpkgs.lib.nixosSystem {
          specialArgs = { inherit inputs; };
          modules = [
            determinate.nixosModules.default
            # Machine-specific settings (hostname, disks, hardware and GPU tuning)
            ./hosts/hn7306
            # Shared base configuration (imports the desktop and VM modules)
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
            #nixos-hardware.nixosModules.asus-proart-px13-hn7306eac
          ];
        };
      };
    };
}
