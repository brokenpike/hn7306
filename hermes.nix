# Hermes Agent (Nous Research) as a native systemd service under its own
# "hermes" user, state in /var/lib/hermes. It talks to the local Ollama server
# (see hosts/hn7306/ollama.nix).
#
# Never put secrets in these options: they end up in the world-readable Nix
# store. Messaging tokens belong in a file outside the store, referenced with
# services.hermes-agent.environmentFiles.
_:

{
  services.hermes-agent = {
    enable = true;

    # Puts the `hermes` CLI on the system PATH. Run it as the service user,
    # never as yourself: Hermes keeps its session database owner-only (0600),
    # so any other user cannot save sessions or memory. Use:
    #   sudo -u hermes -H hermes chat
    addToSystemPackages = true;

    settings.model = {
      # A local OpenAI-compatible endpoint. Without this, Hermes searches its
      # built-in providers (including Nous Portal) for its helper tasks.
      provider = "custom";
      base_url = "http://127.0.0.1:11434/v1";
      # A general-purpose MoE model (about 3B active) that is also strong at
      # agentic coding. Pull it once with: ollama pull qwen3.6:35b
      default = "qwen3.6:35b";
      # Hermes refuses models with a context below 64,000 tokens (so
      # qwen2.5-coder:32b, at 32,768, does not work) and cannot read the value
      # from Ollama. Keep this equal to OLLAMA_CONTEXT_LENGTH in
      # hosts/hn7306/ollama.nix.
      context_length = 65536;
    };
  };
}
