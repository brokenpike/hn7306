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
- What runs on it: Ollama on the ROCm build (local LLM server), Hermes Agent
  (a persistent assistant, native systemd service), libvirt and GNOME Boxes
  (a 24 GiB Windows VM used for Visure testing), Tailscale, zram swap.
- The user may add a second computer later and the niri window manager, and
  wants to try the nebula mesh VPN.

## Layout

```
flake.nix                  inputs and wiring only
configuration.nix          shared base for every host, grouped by topic
gnome.nix                  GNOME session (GDM stays in configuration.nix)
vm.nix                     libvirt, Boxes, SPICE, Windows guest tools
llm.nix                    options local.llm.*: the one model Ollama, Hermes and OpenCode share
hermes.nix                 Hermes Agent service (optional module)
home.nix                   Home Manager config for scott (includes OpenCode)
hosts/hn7306/default.nix   hostname, /scratch mount, imports the files below
hosts/hn7306/hardware-configuration.nix   GENERATED, never edit
hosts/hn7306/strix-halo.nix   GPU memory cap, ROCm, asusd, lact, fwupd
hosts/hn7306/ollama.nix    Ollama service, models stored in /scratch/ollama
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

## One model, set in one place

Hermes and OpenCode share one Ollama server, one model and one context size.
They are set once, per host, in `hosts/hn7306/default.nix` under `local.llm`
(`model`, `contextLength`, `extraModels`; options defined in `llm.nix`).
`ollama.nix`, `hermes.nix` and `home.nix` all read them. To change the model,
edit `local.llm.model` there; never hard-code a model name or context size in
the other files.

- Both tools must use the same model. Different names make Ollama unload and
  reload the model on every switch (`OLLAMA_MAX_LOADED_MODELS=1`).
- Hermes refuses any model with a context below 64,000 tokens; an assertion in
  `hermes.nix` enforces it.
- OpenCode only offers models declared in its config. `extraModels` lists the
  other installed models it may switch to.
- The user must `ollama pull <model>` first; nothing downloads automatically.

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
  says `library=ROCm`, and that `ollama ps` shows `100% GPU`.
- A Tailscale exit node routes the VM subnet (192.168.122.0/24) into the
  tunnel, which breaks the Windows VM's internet. Keep that in mind for any
  networking or nebula work; nebula's overlay subnet must not overlap
  192.168.50.0/24 (LAN), 192.168.122.0/24 (libvirt) or 100.64.0.0/10
  (Tailscale).
- GPU-addressable memory is capped at 80 GiB (`ttm.pages_limit=20971520` in
  `strix-halo.nix`). The cap is a ceiling, not a reservation; the 24 GiB VM and
  the model share the same 124 GiB.
- `services.ollama.models` was renamed `modelsDir`. Root has little free
  space, so model files live on `/scratch`.

## When you finish a task

Say which files you changed, what you verified and how, and any command the
user must run. If you made a decision worth remembering, add a short entry to
`devnotes.md`.
