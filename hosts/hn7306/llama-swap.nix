# llama.cpp behind llama-swap: one OpenAI-compatible endpoint on port 8080
# that starts and stops llama-server per model. Runs next to Ollama during the
# migration; nothing points at it yet.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Vulkan (RADV) first; benchmark against ROCm (pkgs.llama-cpp-rocm) before
  # settling. rocmSupport is on globally (strix-halo.nix), so turn it off here
  # or the build gets both backends.
  vulkan = pkgs.llama-cpp.override {
    rocmSupport = false;
    vulkanSupport = true;
  };

  models = "/scratch/models";

  # llama-server splits --ctx-size across its slots, so each slot gets
  # local.llm.contextLength, the size Hermes checks against its 64,000 minimum.
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
  services.llama-swap = {
    enable = true;
    # Not "localhost", which can resolve to ::1; the clients use 127.0.0.1.
    listenAddress = "127.0.0.1";
    port = 8080;
    settings = {
      # A model on /scratch can take minutes to load the first time after boot.
      healthCheckTimeout = 600;

      models = {
        "qwen3.6-35b" = {
          cmd = server vulkan [
            "--model ${models}/qwen3.6-35b-a3b/Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf"
            "--mmproj ${models}/qwen3.6-35b-a3b/mmproj-F16.gguf"
            "--ctx-size ${toString (config.local.llm.contextLength * slots)}"
            "--parallel ${toString slots}"
            # Same sampling as Ollama's qwen3.6:35b, so benchmarks compare like
            # with like.
            "--temp 1.0"
            "--repeat-penalty 1.0"
          ];
          ttl = 1800;
        };

        "qwen3-coder-30b" = {
          cmd = server vulkan [
            "--model ${models}/qwen3-coder-30b-a3b/Qwen3-Coder-30B-A3B-Instruct-Q8_0.gguf"
            "--ctx-size ${toString (config.local.llm.contextLength * slots)}"
            "--parallel ${toString slots}"
            # Same sampling as Ollama's qwen3-coder:30b.
            "--temp 0.7"
            "--top-k 20"
            "--top-p 0.8"
            "--repeat-penalty 1.05"
          ];
          ttl = 1800;
        };

        # 85 GiB of weights: only fits under the 104 GiB GPU cap on its own.
        "deepseek-v4-flash" = {
          cmd = server vulkan [
            "--model ${models}/DeepSeek-V4-Flash-0731-GGUF/UD-IQ2_M/DeepSeek-V4-Flash-0731-UD-IQ2_M-00001-of-00003.gguf"
            "--ctx-size ${toString config.local.llm.contextLength}"
            "--parallel 1"
          ];
          ttl = 1800;
        };
      };

      # The two Qwen models stay loaded together (about 70 GiB plus context).
      # Exclusive: loading either unloads DeepSeek, and loading DeepSeek, which
      # is in the default group, unloads both. No VM while the pair is loaded.
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
