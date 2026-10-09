# Ollama on the ROCm build. No longer what Hermes and OpenCode use (that is
# llama-swap.nix); kept as a reference to benchmark llama.cpp against.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  services.ollama = {
    enable = true;
    package = pkgs.ollama-rocm;

    # Models are tens of GB, so keep them off the root disk. A fixed user is
    # needed to own a directory outside the service's own state directory.
    modelsDir = "/scratch/ollama";
    user = "ollama";
    group = "ollama";

    # The same context and slots as llama-swap's qwen3.6-35b, so benchmarks
    # compare like with like.
    environmentVariables = {
      OLLAMA_CONTEXT_LENGTH = toString config.local.llm.contextLength;
      OLLAMA_NUM_PARALLEL = "2";
      # A benchmark measures one model; a second would only take memory.
      OLLAMA_MAX_LOADED_MODELS = "1";
    };
  };

  # Started by hand for a benchmark (`sudo systemctl start ollama`), so it never
  # holds GPU memory next to llama-swap's models or a VM.
  systemd.services.ollama.wantedBy = lib.mkForce [ ];

  systemd.tmpfiles.rules = [ "d /scratch/ollama 0755 ollama ollama -" ];
}
