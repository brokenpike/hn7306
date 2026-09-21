# Local LLM server: Ollama on the ROCm build. Hermes (hermes.nix) talks to it.
{ pkgs, ... }:

{
  services.ollama = {
    enable = true;
    package = pkgs.ollama-rocm;

    # Models are tens of GB, so keep them off the root disk. A fixed user is
    # needed to own a directory outside the service's own state directory.
    modelsDir = "/scratch/ollama";
    user = "ollama";
    group = "ollama";

    environmentVariables = {
      # Agents need a long context; the default is far too small. Hermes
      # refuses models below 64,000 tokens.
      OLLAMA_CONTEXT_LENGTH = "65536";

      # Hermes and OpenCode share one model and are often busy at once. Two
      # slots stop them queueing behind each other; each slot holds its own
      # context, so memory is roughly the weights plus two contexts.
      OLLAMA_NUM_PARALLEL = "2";

      # Never try to keep a second model loaded next to the first: both tools
      # must use the same model name, or Ollama reloads it on every switch.
      OLLAMA_MAX_LOADED_MODELS = "1";
    };
  };

  systemd.tmpfiles.rules = [ "d /scratch/ollama 0755 ollama ollama -" ];
}
