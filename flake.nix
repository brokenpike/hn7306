{
  description = "A simple NixOS flake";

  inputs = {
    # NixOS official package source, using the nixos-25.11 branch here
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
    nixpkgs.url =    "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";
    #helix.url = "github:helix-editor/helix/master"; 
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    # lmstudio = {
	  #   url = "github:Daaboulex/lmstudio-nix";
	  #   inputs.nixpkgs.follows = "nixpkgs";
    # };
  };
		
  outputs = { self, determinate, nixpkgs, nixpkgs-stable, home-manager, ... }@inputs: {
    # Please replace my-nixos with your hostname
    nixosConfigurations = { 
     nixos = nixpkgs.lib.nixosSystem {
      specialArgs = {inherit inputs;};
      modules = [
        determinate.nixosModules.default
        # Import the previous configuration.nix we used,
        # so the old configuration file still takes effect
        ./configuration.nix
        home-manager.nixosModules.home-manager
        {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = { inherit inputs; };
              home-manager.users.scott = ./home.nix;
        }
      ];
    };
   }; 
  };
}
