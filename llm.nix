# The local LLM setup that Hermes and OpenCode share: which server, which
# models, how much context. Set the values once per host (in
# hosts/<name>/default.nix); hermes.nix, home.nix and the host's server module
# read them, so a model change is a one-line edit.
{ lib, ... }:

{
  options.local.llm = {
    baseURL = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:11434/v1";
      example = "http://127.0.0.1:8080/v1";
      description = ''
        OpenAI-compatible endpoint that Hermes and OpenCode use. The default is
        a local Ollama; hn7306 points it at llama-swap.
      '';
    };

    model = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "qwen3.6-35b";
      description = ''
        The model Hermes uses, and OpenCode too unless `opencode.model` is set.
        A name the server at `baseURL` knows: an Ollama tag, or a llama-swap
        model ID. Null leaves the tools unconfigured, for a host without a
        local server.
      '';
    };

    opencode.model = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "qwen3-coder-30b";
      description = ''
        A different model for OpenCode. Null means the same as `model`. Only
        set it if the server can keep both loaded at once (a llama-swap group
        with swap = false); otherwise every switch between the tools reloads a
        model.
      '';
    };

    contextLength = lib.mkOption {
      type = lib.types.ints.positive;
      default = 65536;
      description = ''
        Context size in tokens per request: what Hermes and OpenCode are told
        the model supports, and what the server gives each parallel slot.
        Hermes refuses anything below 64,000.
      '';
    };

    reasoningEffort = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "low"
          "medium"
          "high"
        ]
      );
      default = null;
      example = "low";
      description = ''
        How long a reasoning model such as gpt-oss thinks before answering, in
        both Hermes and OpenCode. Every agent step pays for it, so a slow GPU
        wants "low". Applies to `model` only. Null keeps each tool's default.
      '';
    };

    extraModels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "deepseek-v4-flash" ];
      description = ''
        Other models that OpenCode can be switched to. OpenCode only offers
        models declared in its config. Hermes needs no list.
      '';
    };
  };
}
