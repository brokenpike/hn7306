# Settings specific to the Phoenix laptop.
{ inputs, pkgs, ... }:

{
  imports = [
    inputs.nixos-hardware.nixosModules.framework-13-7040-amd
    ./hardware-configuration.nix
    ./ollama.nix
    ../../hermes.nix
  ];

  networking.hostName = "phoenix";

  boot.kernelPackages = pkgs.linuxPackages_latest;

  # The one model Ollama, Hermes and OpenCode share. Change it here, then pull
  # it with `ollama pull <name>` and rebuild.
  local.llm = {
    # About 14 GB, so it fits in 38 GiB of RAM next to the desktop; hn7306's
    # qwen3.6:35b would not leave enough. Supports tool calling, which Hermes
    # needs.
    model = "gpt-oss:20b";

    # At medium it spent 477 tokens thinking about a haiku; at about 13
    # tokens/s that is most of every agent step.
    reasoningEffort = "low";
  };
}
