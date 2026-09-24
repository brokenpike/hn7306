# Hermes Agent (Nous Research) as a native systemd service under its own
# "hermes" user, state in /var/lib/hermes. It talks to the local Ollama server
# (see hosts/<name>/ollama.nix).
#
# Never put secrets in these options: they end up in the world-readable Nix
# store. Messaging tokens belong in a file outside the store, referenced with
# services.hermes-agent.environmentFiles.
{ config, lib, ... }:

let
  llm = config.local.llm;
in
{
  assertions = [
    {
      assertion = llm.model != null;
      message = "hermes.nix needs local.llm.model to be set for this host.";
    }
    {
      # Hermes rejects smaller windows at chat time (MINIMUM_CONTEXT_LENGTH).
      assertion = llm.contextLength >= 64000;
      message = "Hermes refuses models with a context below 64,000 tokens; raise local.llm.contextLength.";
    }
  ];

  services.hermes-agent = {
    enable = true;

    # Puts the `hermes` CLI on the system PATH. Run it as the service user,
    # never as yourself: Hermes keeps its session database owner-only (0600),
    # so any other user cannot save sessions or memory. Use:
    #   sudo -u hermes -H hermes chat
    addToSystemPackages = true;

    settings = {
      model = {
        # A local OpenAI-compatible endpoint. Without this, Hermes searches its
        # built-in providers (including Nous Portal) for its helper tasks.
        provider = "custom";
        base_url = "http://127.0.0.1:11434/v1";
        # Both come from llm.nix and are set per host. Hermes cannot read the
        # context from Ollama and would otherwise assume 256,000 tokens.
        default = llm.model;
        context_length = llm.contextLength;
      };
    }
    # Hermes sends this to Ollama as reasoning_effort; unset, it asks for
    # medium. The settings type does not resolve lib.mkIf, so it would end up
    # in config.yaml literally.
    // lib.optionalAttrs (llm.reasoningEffort != null) {
      agent.reasoning_effort = llm.reasoningEffort;
    };

    # Real OAuth 2.1 (PKCE + dynamic client registration), not a static
    # header. Confirmed 2026-09-23: the Visure server's auth precedence is
    # "Authorization: Bearer always wins when present" over its legacy
    # X-Visure-Username/X-Visure-Token header pair, so a static Bearer
    # secret here would just be rejected as an invalid OAuth token, never
    # falling through to header auth. Worse, that legacy header pair's
    # "token" is literally the account's plaintext password for native
    # (non-SSO) auth (VisureWeb.xml: McpUserSession.Token doc comment) — not
    # a scoped API key — so it's the wrong direction to go even if it did
    # work. `auth = "oauth"` uses the same DCR + PKCE flow Claude Desktop
    # already uses successfully against this server; tokens are stored in
    # $HERMES_HOME/mcp-tokens/, never in the Nix store or a secrets file.
    mcpServers.visure = {
      url = "https://v5817.vegtamr.online/VisureAuthoring8/mcp";
      auth = "oauth";
    };
  };
}
