# llama.cpp behind llama-swap on gz302, the home LLM server: one
# OpenAI-compatible endpoint on port 8080 for Hermes, OpenCode and Open WebUI
# (local.llm.baseURL), shared on the tailnet with tailscale serve. The same
# Qwen pair and files as hosts/hn7306/llama-swap.nix; see there and
# devnotes.md for the benchmarks behind the choices.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Vulkan beat ROCm on hn7306. rocmSupport is on globally (strix-halo.nix),
  # so turn it off here or the build gets both backends.
  vulkan = pkgs.llama-cpp.override {
    rocmSupport = false;
    vulkanSupport = true;
  };

  # World-readable: the service runs as a DynamicUser.
  models = "/srv/models";

  # llama-server splits --ctx-size across its slots, so each slot gets
  # local.llm.contextLength, the size Hermes checks against its 64,000 minimum.
  # Two on Qwen3.6: Hermes and Open WebUI.
  slots = 2;

  server =
    backend: flags:
    lib.concatStringsSep " " (
      [
        (lib.getExe' backend "llama-server")
        "--port \${PORT}"
        "--n-gpu-layers 999"
        "--flash-attn on"
        "--jinja"
      ]
      ++ flags
    );
in
{
  systemd.tmpfiles.rules = [ "d ${models} 0755 scott users -" ];

  services.llama-swap = {
    enable = true;
    # Not "localhost", which can resolve to ::1; the clients use 127.0.0.1.
    listenAddress = "127.0.0.1";
    port = 8080;
    settings = {
      # Loading both models after boot takes a while.
      healthCheckTimeout = 600;

      # Adds llama-server's own output to the journal: model loads, errors and
      # per-request timings (the speed check in AGENTS.md).
      logToStdout = "both";

      # A dedicated server: load the pair at boot and never unload it (no ttl),
      # so no client waits for a model to load.
      hooks.on_startup.preload = [
        "qwen3.6-35b"
        "qwen3-coder-30b"
      ];

      models = {
        "qwen3.6-35b" = {
          cmd = server vulkan [
            "--model ${models}/qwen3.6-35b-a3b/Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf"
            "--mmproj ${models}/qwen3.6-35b-a3b/mmproj-F16.gguf"
            "--ctx-size ${toString (config.local.llm.contextLength * slots)}"
            "--parallel ${toString slots}"
            "--temp 1.0"
            "--repeat-penalty 1.0"
          ];
        };

        # OpenCode's model (local.llm.opencode.model). Q4 generated 51% faster
        # than Q8_0 on hn7306 with equal prompt speed. One slot: OpenCode is
        # its only user.
        "qwen3-coder-30b" = {
          cmd = server vulkan [
            "--model ${models}/qwen3-coder-30b-a3b/Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf"
            "--ctx-size ${toString config.local.llm.contextLength}"
            "--parallel 1"
            "--temp 0.7"
            "--top-k 20"
            "--top-p 0.8"
            "--repeat-penalty 1.05"
          ];
        };

        # The strongest open model that fits (2026-10-27): 179B, 6B active.
        # 87 GiB of weights, so it runs alone: loading it unloads the Qwen pair,
        # and the next Hermes or OpenCode request swaps the pair back. Not
        # preloaded. Sampling is Qwen's thinking-mode recommendation.
        "qwen3.8-flash-next" = {
          cmd = server vulkan [
            "--model ${models}/Qwen3.8-Flash-Next-GGUF/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf"
            "--ctx-size ${toString config.local.llm.contextLength}"
            "--parallel 1"
            "--temp 1.0"
            "--top-p 0.95"
            "--top-k 20"
            "--min-p 0.0"
            "--repeat-penalty 1.0"
          ];
          ttl = 1800;
        };
      };

      # Both stay loaded together, about 64 GiB with context.
      groups.qwen = {
        swap = false;
        exclusive = true;
        members = [
          "qwen3.6-35b"
          "qwen3-coder-30b"
        ];
      };
    };
  };
}
