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

    # Other pulled models OpenCode can switch to (`ollama list`). OpenCode
    # only offers models declared here; switching unloads gpt-oss.
    extraModels = [
      "qwen2.5-coder:7b"
    ];
  };

  # Keyboard layout for Phoenix (US)
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };
  console.keyMap = "us";

  # hn7306's key, for OpenSSH logins that do not go through Tailscale SSH,
  # e.g. over the USB4 cable (thunderbolt0, link-local addresses).
  users.users.scott.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAnRfgI8QRF1wKIhfrGQwSckCDk1JV0eCIbtDw8y3ZFw scott@hn7306"
  ];

  # Release this system's stateful defaults come from. Do not bump this when
  # upgrading; see configuration.nix(5) before changing it.
  system.stateVersion = "25.11";
}
