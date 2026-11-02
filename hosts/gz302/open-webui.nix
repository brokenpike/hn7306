# Open WebUI: a chat page in front of llama-swap. Listens on localhost only;
# tailscale serve publishes it as https://gz302.heron-pickerel.ts.net:8443.
# Unlike hn7306's, no tailnet guests are allowed to reach it yet.
{
  config,
  inputs,
  pkgs,
  ...
}:

let
  llm = config.local.llm;
in
{
  services.open-webui = {
    # TEMPORARY, see the nixpkgs-openwebui input in flake.nix. Imported with
    # this system's nixpkgs settings (unfree, ROCm), so the package is the
    # same one the main nixpkgs built before posthog broke.
    package =
      (import inputs.nixpkgs-openwebui {
        inherit (pkgs.stdenv.hostPlatform) system;
        config = config.nixpkgs.config;
      }).open-webui;
    enable = true;
    host = "127.0.0.1";
    # 8080 is llama-swap.
    port = 8081;

    # Most of these seed Open WebUI's database on the first start only; after
    # that the admin panel's values win (its "persistent config").
    environment = {
      # Setting environment replaces the module's defaults, so keep them.
      ANONYMIZED_TELEMETRY = "False";
      DO_NOT_TRACK = "True";
      SCARF_NO_ANALYTICS = "True";

      WEBUI_URL = "https://gz302.heron-pickerel.ts.net:8443";

      OPENAI_API_BASE_URL = llm.baseURL;
      # llama-swap has no keys, but Open WebUI wants one set.
      OPENAI_API_KEY = "none";
      # No Ollama here; without this every page load waits for it to time out.
      ENABLE_OLLAMA_API = "False";

      # Hermes' model, so a chat shares its slots.
      DEFAULT_MODELS = llm.model;

      # The admin account exists (created 2026-10-26); Open WebUI then turned
      # sign-up off itself. Further accounts: Admin Panel, Users. This only
      # seeds a fresh install; the database value wins afterwards.
      ENABLE_SIGNUP = "False";
      DEFAULT_USER_ROLE = "pending";
    };
  };
}
