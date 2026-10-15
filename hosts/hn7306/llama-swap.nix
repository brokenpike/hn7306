# llama.cpp behind llama-swap: one OpenAI-compatible endpoint on port 8080
# that starts and stops llama-server per model. Hermes, OpenCode and Open
# WebUI use it (local.llm.baseURL); Ollama is only a benchmark reference.
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

  # TranslateGemma's own template only accepts structured messages
  # (source_lang_code, target_lang_code, text) and errors on plain text, which
  # Open WebUI sends. This is the plain Gemma turn format instead; the
  # language instruction goes in the prompt (see devnotes.md).
  gemmaPlainTemplate = pkgs.writeText "gemma-plain.jinja" ''
    {{ bos_token }}
    {%- for message in messages -%}
    {%- if message['role'] == 'assistant' -%}
    {{ '<start_of_turn>model\n' + message['content'] | trim + '<end_of_turn>\n' }}
    {%- else -%}
    {{ '<start_of_turn>user\n' + message['content'] | trim + '<end_of_turn>\n' }}
    {%- endif -%}
    {%- endfor -%}
    {%- if add_generation_prompt -%}
    {{ '<start_of_turn>model\n' }}
    {%- endif -%}
  '';

  # Seed-X has no chat template and is trained on bare prompts ending in a
  # target-language tag ("…:\n<text> <nb>"); multi-turn input is discouraged.
  # This passes only the last user message, unchanged.
  seedxTemplate = pkgs.writeText "seed-x.jinja" ''
    {%- set ns = namespace(text="") -%}
    {%- for message in messages -%}
    {%- if message['role'] == 'user' -%}
    {%- set ns.text = message['content'] -%}
    {%- endif -%}
    {%- endfor -%}
    {{ bos_token }}{{ ns.text | trim }}
  '';

  # Translation models: one document per request, no long agent context.
  translateCtx = "16384";
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

      # The default ("proxy") keeps llama-server's own output out of the
      # journal. "both" adds it: model loads, errors and per-request timings
      # (the speed check in AGENTS.md).
      logToStdout = "both";

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

        # OpenCode's model (local.llm.opencode.model). Q4 and one slot keep the
        # Qwen pair near 65 GiB, so the 16 GiB Visure VM fits next to it. One
        # slot because OpenCode is its only user; the Q8_0 file is kept too.
        "qwen3-coder-30b" = {
          cmd = server vulkan [
            "--model ${models}/qwen3-coder-30b-a3b/Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf"
            "--ctx-size ${toString config.local.llm.contextLength}"
            "--parallel 1"
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

        # University of Oslo, fine-tuned for Bokmål/Nynorsk/English in all
        # directions. The system message is the target language ("bokmål",
        # "nynorsk" or "engelsk", the default); the user message is the text.
        # Converted from ltg/normistral-11b-translate (see devnotes.md).
        # Greedy decoding, as its model card uses.
        "normistral-11b-translate" = {
          cmd = server vulkan [
            "--model ${models}/normistral-11b-translate/normistral-11b-translate-Q8_0.gguf"
            "--ctx-size ${translateCtx}"
            "--parallel 1"
            "--temp 0"
          ];
          ttl = 1800;
        };

        # General multilingual model, good at Nordic languages for its size.
        # Thinking off: translation does not need it and it costs time.
        "gemma-4-e4b" = {
          cmd = server vulkan [
            "--model ${models}/gemma-4-e4b/gemma-4-E4B-it-Q8_0.gguf"
            "--ctx-size ${translateCtx}"
            "--parallel 1"
            "--reasoning off"
            "--temp 0.3"
          ];
          ttl = 1800;
        };

        # Google's translation model (55 languages, nb/nn/no included), with a
        # plain template so ordinary chat messages work.
        "translategemma-4b" = {
          cmd = server vulkan [
            "--model ${models}/translategemma-4b/translategemma-4b-it.Q8_0.gguf"
            "--chat-template-file ${gemmaPlainTemplate}"
            "--ctx-size ${translateCtx}"
            "--parallel 1"
            "--temp 0"
          ];
          ttl = 1800;
        };

        # Multilingual chat model trained on the EU languages plus Norwegian
        # (utter-project, December 2025 release). Its own ChatML template.
        "eurollm-9b" = {
          cmd = server vulkan [
            "--model ${models}/eurollm-9b/EuroLLM-9B-Instruct-2512.Q8_0.gguf"
            "--ctx-size ${translateCtx}"
            "--parallel 1"
            "--temp 0"
          ];
          ttl = 1800;
        };

        # ByteDance's translation model (28 languages, nb and no included),
        # the PPO variant they recommend. Prompt: "Translate the following
        # English sentence into Norwegian Bokmal:\n<text> <nb>"; the tag at
        # the end is required.
        "seed-x-ppo-7b" = {
          cmd = server vulkan [
            "--model ${models}/seed-x-ppo-7b/Seed-X-PPO-7B.Q8_0.gguf"
            "--chat-template-file ${seedxTemplate}"
            "--ctx-size ${translateCtx}"
            "--parallel 1"
            "--temp 0"
          ];
          ttl = 1800;
        };
      };

      # The two Qwen models stay loaded together (about 65 GiB with context).
      # Exclusive: loading either unloads DeepSeek, and loading DeepSeek, which
      # is in the default group, unloads both. No VM while DeepSeek is loaded.
      groups.qwen = {
        swap = false;
        exclusive = true;
        members = [
          "qwen3.6-35b"
          "qwen3-coder-30b"
        ];
      };

      # English <-> Norwegian translation, Q8_0 (small dense models lose
      # more to quantization than the big MoEs). One loaded at a time (swap),
      # next to the Qwen pair (not exclusive): at most ~13 GiB on top of its
      # ~65. Loading a Qwen model or DeepSeek unloads it.
      groups.translate = {
        swap = true;
        exclusive = false;
        members = [
          "normistral-11b-translate"
          "gemma-4-e4b"
          "translategemma-4b"
          "eurollm-9b"
          "seed-x-ppo-7b"
        ];
      };
    };
  };
}
