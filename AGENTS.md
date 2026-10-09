# AGENTS.md

Instructions for coding agents working in this repository. Read this before
making changes. For the history behind decisions, read `devnotes.md`.

## What this repo is

The NixOS + Home Manager configuration for one machine, as a flake. Nothing in
it is an application; every file is Nix (or docs).

- Machine: ASUS HN7306, AMD Ryzen AI MAX+ 395 (Strix Halo), Radeon 8060S iGPU,
  124 GiB unified memory. Hostname `hn7306`, single user `scott`.
- OS: NixOS unstable (26.11 pre-release), flakes, Home Manager as a NixOS
  module, Determinate Nix. GNOME desktop on GDM.
- What runs on it: llama.cpp behind llama-swap (local LLM server; Ollama kept
  only as a benchmark reference), Hermes Agent (a persistent assistant, native
  systemd service), Windows VMs for Visure testing (quickemu, one folder per VM
  under `/scratch/visure-clones`, about 16 GiB each; libvirt and GNOME Boxes are
  still installed), Tailscale, zram swap.
- A second host, `phoenix` (Framework 13 laptop), runs its own Ollama with
  `gpt-oss:20b`. The user may add the niri window manager, and wants to try
  the nebula mesh VPN.

## Layout

```
flake.nix                  inputs and wiring only
configuration.nix          shared base for every host, grouped by topic
gnome.nix                  GNOME session (GDM stays in configuration.nix)
vm.nix                     quickemu, libvirt, Boxes, SPICE, Windows guest tools, KVM MSRs
llm.nix                    options local.llm.*: server URL, models and context for Hermes and OpenCode
hermes.nix                 Hermes Agent service (optional module)
home.nix                   Home Manager config for scott (includes OpenCode)
hosts/hn7306/default.nix   hostname, /scratch mount, imports the files below
hosts/hn7306/hardware-configuration.nix   GENERATED, never edit
hosts/hn7306/strix-halo.nix   GPU memory cap, ROCm, asusd, lact, fwupd
hosts/hn7306/ollama.nix    Ollama (benchmark reference only), models in /scratch/ollama
hosts/hn7306/llama-swap.nix   llama.cpp via llama-swap on :8080, GGUFs in /scratch/models
devnotes.md                decision log: what was decided and why
```

## Conventions

- Format every Nix file you touch with `nixfmt`. Check with
  `nix run nixpkgs#nixfmt -- --check <files>`.
- Only package lists are alphabetized. Do not sort `boot.kernelParams`, the fish
  `plugins` list, `imports`, or `extraGroups`: order can matter there.
- `configuration.nix` is grouped by topic with `# --- Section ---` headers. Put
  new settings under the right section.
- Comments explain why, not what. Do not leave commented-out code; deleted code
  stays in git history, and lessons go in `devnotes.md`.
- Modules that take no arguments start with `_:`, not `{ ... }:`.
- A flake only sees git-tracked files. After creating a new file, `git add` it
  before evaluating or building.
- Machine-specific settings go in `hosts/<name>/`. Shared settings go in the
  root modules.
- Commit messages: lowercase, imperative summary line, then a body that says
  why. Do not commit or push unless asked.

## LLM settings, set in one place

Hermes and OpenCode share one server, one context size and, by default, one
model. They are set once per host in `hosts/<name>/default.nix` under
`local.llm` (`baseURL`, `model`, `opencode.model`, `contextLength`,
`extraModels`; options defined in `llm.nix`). `hermes.nix`, `home.nix` and the
host's server module (`llama-swap.nix` or `ollama.nix`) read them. Never
hard-code a URL, model name or context size in the other files.

- On hn7306 the names are llama-swap model IDs (`qwen3.6-35b`), defined in
  `llama-swap.nix`; on phoenix they are Ollama tags (`gpt-oss:20b`).
- `opencode.model` gives OpenCode its own model. Only use it for models the
  server keeps loaded together (a llama-swap group with `swap = false`).
  Otherwise every switch between the tools reloads a model.
- `contextLength` is per request. llama-server splits `--ctx-size` across
  slots, so `llama-swap.nix` multiplies it by the slot count.
- Hermes refuses any model with a context below 64,000 tokens; an assertion in
  `hermes.nix` enforces it.
- OpenCode only offers models declared in its config. `extraModels` lists the
  other models it may switch to.
- Nothing downloads automatically. On hn7306 the user downloads GGUFs into
  `/scratch/models` with `hf download` and adds an entry to `llama-swap.nix`;
  on phoenix, `ollama pull <model>`.

## Verify changes (safe, read-only)

```
nix run nixpkgs#nixfmt -- --check <files>
nix build .#nixosConfigurations.hn7306.config.system.build.toplevel --dry-run
nix eval --json .#nixosConfigurations.hn7306.config.<option>
```

`statix` warns about repeated `services` and `programs` keys in
`configuration.nix` and `home.nix`. That is intentional; do not merge them.

## Do not

- Run `nixos-rebuild`, `sudo`, or anything that changes the running system.
  Give the user the exact command instead. They apply changes themselves.
- Edit `hosts/hn7306/hardware-configuration.nix`, change `system.stateVersion`
  or `home.stateVersion`, or run `nix flake update` without being asked.
  `hermes-agent` moves daily and upstream calls it unstable; update it on
  purpose, then evaluate and test.
- Put secrets, tokens or API keys in any Nix option. They end up in the
  world-readable Nix store. Use a file outside the store with
  `services.hermes-agent.environmentFiles`.
- Touch `/var/lib/hermes`. It belongs to the `hermes` user, and the Hermes CLI
  must be run as `sudo -u hermes -H hermes`, never as `scott`.
- Delete git tags named `backup/*` or rewrite history that has been pushed.

## Things that already bit us (details in devnotes.md)

- Ollama silently fell back to CPU after a rebuild. After any change that
  restarts Ollama, the user should confirm
  `journalctl -u ollama --no-pager -o cat | grep 'inference compute' | tail -1`
  says `library=ROCm`, and that `ollama ps` shows `100% GPU`. For llama-swap,
  `journalctl -u llama-swap --no-pager -o cat | grep -E 'ggml_vulkan|offloaded'`
  should name the Radeon 8060S and offload all layers.
- A Tailscale exit node routes the VM subnet (192.168.122.0/24) into the
  tunnel, which breaks the internet of VMs on libvirt's bridge (`virbr0`).
  quickemu's default NAT (user-mode networking) connects from the host itself,
  so it isn't affected. Keep that in mind for any networking or nebula work;
  nebula's overlay subnet must not overlap 192.168.50.0/24 (LAN),
  192.168.122.0/24 (libvirt) or 100.64.0.0/10 (Tailscale).
- GPU-addressable memory is capped at 104 GiB (`ttm.pages_limit=27262976` in
  `strix-halo.nix`, raised from 80 GiB on 2026-10-06 for DeepSeek V4 Flash).
  The cap is a ceiling, not a reservation; the VMs and the model share the
  same 124 GiB, so a model above about 60 GiB and a VM must not run together.
  The llama-swap Qwen pair (about 65 GiB with context) plus one 16 GiB VM is
  the planned maximum; check the totals before adding models or slots to that
  group. DeepSeek (85 GiB) never runs next to a VM.
- `services.ollama.models` was renamed `modelsDir`. Root has little free
  space, so model files live on `/scratch`.

## When you finish a task

Say which files you changed, what you verified and how, and any command the
user must run. If you made a decision worth remembering, add a short entry to
`devnotes.md`.
