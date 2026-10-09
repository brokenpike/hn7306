# Open WebUI: a chat page in front of llama-swap, for the user's own devices
# and the guests in the tailnet policy (group:guests may reach port 8443 on
# this machine and nothing else). Listens on localhost only; tailscale serve
# publishes it as https://hn7306.heron-pickerel.ts.net:8443.
{ config, ... }:

let
  llm = config.local.llm;
in
{
  services.open-webui = {
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

      WEBUI_URL = "https://hn7306.heron-pickerel.ts.net:8443";

      OPENAI_API_BASE_URL = llm.baseURL;
      # llama-swap has no keys, but Open WebUI wants one set.
      OPENAI_API_KEY = "none";
      # Ollama only runs for benchmarks; without this every page load waits
      # for it to time out.
      ENABLE_OLLAMA_API = "False";

      # Hermes' model, so a chat shares its slots instead of loading another
      # model and unloading the agents'.
      DEFAULT_MODELS = llm.model;

      # Guests sign up themselves and wait as "pending" until the admin (the
      # first account created) approves them.
      ENABLE_SIGNUP = "True";
      DEFAULT_USER_ROLE = "pending";
    };
  };
}
