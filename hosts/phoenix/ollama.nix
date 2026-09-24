# Local LLM server: Ollama on the Vulkan build. Hermes (hermes.nix) and
# OpenCode (home.nix) talk to it.
{ config, pkgs, ... }:

{
  services.ollama = {
    enable = true;
    # ROCm does not support the Radeon 760M (gfx1103) without a GFX version
    # override; Vulkan runs on it as is.
    package = pkgs.ollama-vulkan;

    environmentVariables = {
      # Vulkan finds the 760M, but Ollama drops integrated GPUs by default and
      # silently falls back to the CPU.
      OLLAMA_IGPU_ENABLE = "1";

      # Agents need a long context; the default is far too small. Set in
      # llm.nix, and Hermes refuses models below 64,000 tokens.
      OLLAMA_CONTEXT_LENGTH = toString config.local.llm.contextLength;

      # Only 38 GiB of RAM, shared with the desktop. Each parallel slot holds
      # its own context, so allow one; Hermes and OpenCode queue instead.
      OLLAMA_NUM_PARALLEL = "1";

      # Both tools must use the same model name, or Ollama reloads it on every
      # switch.
      OLLAMA_MAX_LOADED_MODELS = "1";
    };
  };
}
