# The local LLM that Ollama, Hermes and OpenCode share. Set the values once per
# host (in hosts/<name>/default.nix); ollama.nix, hermes.nix and home.nix read
# them, so a model change is a one-line edit.
{ lib, ... }:

{
  options.local.llm = {
    model = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "qwen3.6:35b";
      description = ''
        The Ollama model that Hermes and OpenCode both use by default. Use the
        same name in both tools: with a single loaded model, two names make
        Ollama unload and reload it on every switch. Null leaves the tools
        unconfigured, for a host without a local Ollama.
      '';
    };

    contextLength = lib.mkOption {
      type = lib.types.ints.positive;
      default = 65536;
      description = ''
        Context size in tokens: the Ollama server's OLLAMA_CONTEXT_LENGTH, and
        what Hermes and OpenCode are told the model supports. Hermes refuses
        anything below 64,000.
      '';
    };

    extraModels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "gemma4:31b" ];
      description = ''
        Other installed models that OpenCode can be switched to. OpenCode only
        offers models declared in its config. Hermes needs no list.
      '';
    };
  };
}
