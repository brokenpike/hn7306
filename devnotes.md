# Dev notes

## Boxes VM has no internet while a Tailscale exit node is active (2026-09-20)

**Symptom:** The Windows VM in GNOME Boxes gets a DHCP lease on `virbr0`
(192.168.122.x) but cannot reach the internet. The host itself has internet.

**Cause:** Tailscale had an exit node selected (`nixoshpe`, 100.71.248.127).
Tailscale adds a routing table (52) and an ip rule that is consulted before the
main table:

    5270:  from all lookup 52

The exit node advertises 192.168.50.0/24 and 192.168.122.0/24, so table 52
contains `192.168.122.0/24 dev tailscale0`. The host therefore sent traffic for
the VM subnet into the Tailscale tunnel instead of out `virbr0`: DNS replies from
libvirt's dnsmasq and NAT return traffic never reached the VM. DHCP still worked
because it does not use a route lookup.

ProtonVPN was not involved (no wg/proton interface, no active VPN connection).

**How to diagnose:**

    tailscale status | grep -i exit         # is an exit node active?
    ip -4 rule                              # look for "lookup 52"
    ip -4 route get 192.168.122.81          # should say dev virbr0, not tailscale0

**Fix used:**

    sudo tailscale set --exit-node=

**Untested alternative** (keep the exit node, let local networks bypass it):

    sudo tailscale set --exit-node=nixoshpe --exit-node-allow-lan-access

**Side effect worth knowing:** while the exit node is on, LAN traffic to
192.168.50.0/24 also goes through it (same table 52 route).

## Removed commented-out config (2026-09-20)

The commented-out code was deleted to keep the files readable. It is still in
git history. To view a file as it was, for example:

    git show aeb7a94:configuration.nix

Things worth remembering from it:

- **ollama** (was in configuration.nix): tried `services.ollama` with
  `pkgs.ollama-rocm` (`pkgs.ollama-vulkan` was the alternative) and
  `loadModels` for ministral-3 14b/8b, mistral-medium-3.5 and gpt-oss:120b.
  `HSA_ENABLE_SDMA = "0"` was tried to improve GPU layer offload and did not
  help. `rocmOverrideGfx = "11.5.1"` was also tried. If revisiting, write it
  fresh.
- **Extra mounts** (configuration.nix): an NTFS disk at /home/scott/Scratch
  (`ntfs3`, uid=1000, gid=100) and a btrfs disk at /mnt/llms (with a tmpfiles
  rule for ownership). Both used `nofail` and `x-systemd.automount` so a
  missing disk does not block boot.
- **OVMF options** (vm.nix): `virtualisation.libvirtd.qemu.ovmf.*` are
  deprecated as of NixOS 26.06.
- **Flake inputs** (flake.nix): a `helix` input from master and the
  `Daaboulex/lmstudio-nix` flake were tried or considered and are not used.
  The `nixpkgs-stable` and `nixos-hardware` inputs still exist but nothing
  references them; the commented `nixos-hardware` profile line
  (`asus-proart-px13-hn7306eac`) and the `follows = "nixpkgs-stable"` option
  were deliberately kept in flake.nix.
- **Pulling one package from stable:**
  `inputs.nixpkgs-stable.legacyPackages."x86_64-linux".<pkg>` (was used for
  btop, chromium, vim, zeroad and firefox).
- **wl-clipboard-rs** did not enable helix's system clipboard; `wl-clipboard`
  does.
- **yazi** was configured with a helix opener (flavor theming was drafted but
  never enabled), then dropped.
- **Apps tried and dropped** (home.nix): gimp, inkscape, kdenlive, miro,
  signal-desktop/signald, tesseract, vivaldi, zed-editor, zellij, wine
  (`wineWow64Packages.staging`), plus `programs.openclaw` and thunderbird in
  configuration.nix.
- The helix theme `autumn_night_transparent` is still defined in home.nix but
  unused; the active theme is `ao` (the commented `#theme` line is kept as a
  reminder).

## GPU memory plan and zram swap (2026-09-20)

**Goal:** run a 24 GiB Windows VM (GNOME Boxes) and a ~60 GB local model at the
same time on 124 GiB of usable RAM. Strix Halo uses unified memory: VRAM is only
the 512 MiB BIOS carve-out, and the GPU borrows the rest as GTT.

**Decision:** cap GPU-addressable memory at 80 GiB with
`boot.kernelParams = [ "ttm.pages_limit=20971520" ]` (80 GiB / 4 KiB pages),
set in hosts/hn7306/strix-halo.nix. The cap is not a reservation; the GPU only
takes what it needs. It leaves about 44 GiB for the VM and the host. Before
this the cap was 115 GiB, which overlapped the VM's memory.

- `amdgpu.gttsize` was dropped because it is deprecated. Verified after a reboot
  that `/sys/class/drm/card1/device/mem_info_gtt_total` reads 81920 MiB. If a
  future kernel ignores `ttm.pages_limit`, add `amdgpu.gttsize=81920` back.
- The budget is about 70 GiB for the model (60 GB of weights plus KV cache and
  compute buffers). If a model fails to load with an out-of-memory error, raise
  the cap to 88 GiB (`23068672`) and no higher, which leaves about 12 GiB for the
  host next to the 24 GiB VM.
- `amd_iommu=off` was kept as a performance workaround. It rules out PCI
  passthrough, which the iGPU could not do for a guest anyway.
- **zram swap** (`zramSwap.enable = true`) is compressed swap in RAM, not on any
  disk. The device is 62.5 GiB (50% of RAM), but only the compressed size is
  used. It is an OOM safety net, not extra capacity. If its "USED" column climbs
  into gigabytes, the machine is short on RAM.

**Check while running both workloads:**

    watch -n2 'free -g | head -2; echo GTT used: $(( $(cat /sys/class/drm/card1/device/mem_info_gtt_used) / 1024 / 1024 )) MiB; swapon --show --noheadings'

**Printer:** the Canon driver `cnijfilter2` belongs in
`services.printing.drivers`. A second copy in `environment.systemPackages` was
redundant and was removed.

## File layout and conventions (2026-09-20)

    flake.nix                      inputs and wiring only
    configuration.nix              shared base for every host
    gnome.nix                      GNOME session (GDM stays in configuration.nix)
    vm.nix                         libvirt, Boxes, SPICE, Windows guest tools
    home.nix                       Home Manager config for the user scott
    hosts/hn7306/default.nix       hostname, /scratch mount, imports the two below
    hosts/hn7306/hardware-configuration.nix   generated, do not edit
    hosts/hn7306/strix-halo.nix    AMD/ROCm/GPU tuning, asusd, lact, fwupd

Conventions:

- configuration.nix is grouped by topic with `# --- Section ---` headers.
- Only package lists are sorted alphabetically. `kernelParams`, the fish plugin
  list and other lists where order can matter, and statements themselves, are
  not sorted.
- `nixpkgs.config` stays in the system config, because Home Manager runs with
  `useGlobalPkgs = true`.
- A flake only sees git-tracked files, so `git add` a new file before building.
- `statix` still warns about repeated `services` and `programs` keys in
  configuration.nix and home.nix. That is intentional: merging unrelated
  services into one block would read worse.
- The `nixpkgs-stable` and `nixos-hardware` flake inputs are declared but unused.

**How to check a refactor changes nothing:** evaluate the config before and
after and diff it, for example
`nix eval --json .#nixosConfigurations.hn7306.config --apply '<probe>'`, where
the probe picks out sorted package names, kernel params, groups, services and
mounts. For order-only changes the toplevel `.drvPath` should be identical. Then
run `nixfmt --check` and `nix build .#nixosConfigurations.hn7306.config.system.build.toplevel --dry-run`.

## Plans: niri, nebula, a second computer

- **niri:** `programs.niri.enable` exists in nixpkgs (niri 26.04). Add a
  `niri.nix` next to gnome.nix and import it; it shows up as another session in
  GDM, so GNOME stays as a fallback. It needs its own bar and launcher set up in
  home.nix, and `gnomeExtensions.tiling-shell` is GNOME-only.
- **nebula:** `services.nebula.networks.<name>` (nebula 1.10.3), no global
  enable. Never commit certificates or keys (the remote is on GitHub); keep
  them under /etc/nebula and keep the CA key off the machines. The overlay
  address, cert paths and lighthouse role are per-host. A lighthouse needs UDP
  4242 open. Pick an overlay subnet that does not overlap 192.168.50.0/24 (LAN),
  192.168.122.0/24 (libvirt) or 100.64.0.0/10 (Tailscale). Overlapping ranges
  caused the VM networking problem above.
- **second computer:** add `hosts/<name>/` with its own hardware configuration,
  hostname and mounts, and a second `nixosConfigurations` entry in flake.nix
  (a small `mkHost` helper avoids repeating the module list). The username
  `scott` is hard-coded in home.nix, vm.nix and configuration.nix.

## Hermes Agent with Ollama (2026-09-20)

**What was set up:**

- flake.nix has a `hermes-agent` input (`github:NousResearch/hermes-agent`) and
  its `nixosModules.default`. It brings its own pinned nixpkgs and does not
  follow ours. The first build downloads about 1.4 GiB and builds about 1,200
  small derivations (npm/Python packages); there is no Nous binary cache.
- hosts/hn7306/ollama.nix runs Ollama on the ROCm build with models stored in
  `/scratch/ollama` (root has only about 100 GB free) and
  `OLLAMA_CONTEXT_LENGTH=65536`. Note `services.ollama.models` was renamed to
  `modelsDir`.
- hermes.nix runs Hermes as a native service under its own `hermes` user, state
  in `/var/lib/hermes`, pointed at `http://127.0.0.1:11434/v1`. The default model
  is `qwen3.6:35b` (a general 35B MoE, about 3B active, 22 GB, 256K context,
  tools and thinking) with `context_length = 65536`, equal to the server's
  `OLLAMA_CONTEXT_LENGTH`. It started as `gpt-oss:120b` (65 GB, from the old
  Ollama config). Container mode was not used because it needs Docker.
- **Hermes refuses any model with a context under 64,000 tokens**
  (`MINIMUM_CONTEXT_LENGTH` in agent/model_metadata.py). `qwen2.5-coder:32b`
  (trained context 32,768) therefore does not work, and setting a smaller
  `context_length` makes chat fail immediately. Lying to Hermes with a larger
  value would push the model past its trained context.

**First run, after `sudo nixos-rebuild switch`:**

    ollama pull qwen3.6:35b           # nothing is downloaded automatically
    journalctl -u hermes-agent -f     # is the gateway healthy?
    sudo -u hermes -H hermes chat     # run it as the service user, see below

**Always run the CLI as the `hermes` user.** Hermes forces `state.db` (and its
WAL files) to owner-only `0600` on every start (`_secure_state_db_files` in
hermes_state.py), with no setting to change it. Run as `scott`, even as a member
of the `hermes` group, it prints "Session store unavailable" and does not save
sessions, memory or past-session search. The NixOS module's shared-group model
does not work for the database in native mode; upstream's container mode avoids
this by running the CLI as the service user inside the container. Running via
`sudo -u hermes` also keeps the agent's commands under the unprivileged
`hermes` user, not `scott`. `scott` is therefore no longer in the `hermes`
group. If typing the password each time gets tiresome, a sudo rule letting
`scott` run commands as `hermes` without a password is an option, but it is an
auth-policy change, so it was not added.

Verified on 2026-09-20: `hermes chat -Q --oneshot -q ...` answered from
`gpt-oss:120b`. The first request took about 2 minutes while Ollama loaded the
65 GB model.

**The flake input moves quickly.** hermes-agent was locked at `b787fb9`, then
`afc3b7c`, then `a782e2e` within one day. Update it deliberately with
`nix flake update hermes-agent`, check that it evaluates
(`nix build .#nixosConfigurations.hn7306.config.system.build.toplevel --dry-run`),
rebuild, and test before committing the new lock.

**Things to know:**

- The service runs `hermes gateway`. No messaging platform is configured, so
  it is untested whether it idles quietly or restarts in a loop. Check the
  journal. Tokens for Telegram/Slack/etc. go in a file outside the Nix store,
  referenced with `services.hermes-agent.environmentFiles`; never in Nix options.
- Isolation: `ProtectSystem=strict`, `NoNewPrivileges`, write access only to its
  own state directory. `ProtectHome` is off, but `/home/scott` is mode 0700, so
  the `hermes` user cannot read it.
- Upstream calls this a "Tier 2" platform where commits to `main` may break
  it. It is pinned by flake.lock; update deliberately with
  `nix flake update hermes-agent` and rebuild.
- Ollama unloads an idle model after about 5 minutes by default, so a 60 GB
  model reloads on the next request. `OLLAMA_KEEP_ALIVE` changes that, at the
  cost of holding the memory.
- The 80 GiB GPU cap (see the GPU section) covers the model and its KV cache. A
  64K context on a 120B model may need the cap raised to 88 GiB.
- To switch to llama.cpp later, replace ollama.nix with `services.llama-cpp`
  (with `--jinja`) and change `base_url` and the model name in hermes.nix.

## Ollama silently fell back to CPU after a rebuild (2026-09-21)

**Symptom:** Everything was slow. `ollama ps` showed `100% CPU` and the GPU's
memory use stayed near 1 GiB. The Ollama log had, at the working start (20:23),
`inference compute … library=ROCm compute=gfx1151 … AMD Radeon 8060S`, and at
the restart during a later rebuild (21:57), only `library=cpu`. Ollama
discovers GPUs once at start and never retries, so every model after that ran
on CPU. `rocm-smi` showed the GPU healthy and the environment was unchanged.
Probable cause (not proven): `/dev/kfd` and the render node were recreated
during the rebuild at that same second, so Ollama started without them.

**After any rebuild that restarts Ollama, check the GPU:**

    journalctl -u ollama --no-pager -o cat | grep 'inference compute' | tail -1   # want library=ROCm
    ollama ps                                                                     # want 100% GPU

If it says cpu, `sudo systemctl restart ollama` fixed it. The next rebuild
restarted Ollama and found the GPU again. If it recurs, order the unit after
`systemd-udev-settle.service`.

**Measured 2026-09-21** (Ollama 0.34.2, ROCm, `OLLAMA_NUM_PARALLEL=2`,
context 65,536, Windows VM running):

| Model | Weights | GPU memory in use | Generation | Prompt reading (6.4-6.7K tok) |
|---|---|---|---|---|
| `qwen3.6:35b` on CPU | 22 GB | not on GPU | 20 tok/s | 79 tok/s |
| `qwen3.6:35b` | 22 GB | 26 GiB | 57-74 tok/s | 997 tok/s |
| `qwen3-coder:30b` | 18 GB | 31 GiB | 49-60 tok/s | 1,242 tok/s |

Prompt reading is what makes an agent feel slow on CPU: a 64K prompt would take
roughly 14 minutes at 79 tok/s. `qwen3.6:35b` needs less memory than the smaller
`qwen3-coder:30b` because its attention cache is much smaller. With the VM
(24 GiB) and the model loaded, the machine used about 59 GiB of 124.

**Model choice.** General MoE `qwen3.6:35b` was chosen as the one model shared by
Hermes and OpenCode over the coder-only `qwen3-coder:30b`. Reported benchmarks
for the coder variant are lower on general knowledge and reasoning (MMLU-Pro
70.6 vs 78.4, GPQA 51.6 vs 70.4 against Qwen3-30B-A3B-Instruct-2507), which
matters for Hermes's non-coding work. Both must use the same model name, or
Ollama reloads the model on every switch. Its coding quality against the coder
model is untested beyond a few small prompts. Also installed: `gpt-oss:120b`,
`gpt-oss:20b`, `gemma4:31b`, `qwen2.5-coder:32b` (unusable with Hermes).

## OpenCode (2026-09-21)

Set up in home.nix with `programs.opencode` (Home Manager), which writes
`~/.config/opencode/opencode.json`. It uses the same Ollama server and the same
model as Hermes: `ollama/qwen3.6:35b`, with `limit.context = 65536`.

- **Same model name in both tools.** With `OLLAMA_MAX_LOADED_MODELS=1`, two
  different names make Ollama unload and reload the model on every switch.
  `small_model` is set to the same model for that reason too. Both now read
  `local.llm.model` (see "Changing the model" below).
- **Runs as `scott`**, unlike Hermes, so the permissions matter. Edits, web
  fetches and web searches ask first; bash asks first except `git status`,
  `git diff` and `git log`; `git push`, `rm` and `sudo` are denied. Reading files
  is allowed by default except `.env`. `share = "disabled"` stops sessions being
  uploaded to opencode.ai and `autoupdate = false` because nixpkgs pins the
  version. Bash rules are matched top to bottom with the last match winning;
  the generated JSON sorts keys, so `"*"` comes first.
- **Compound commands need every part allowed.** A piped command such as
  `git status --short | grep -c x` is rejected because `grep` falls under the
  `"*": ask` rule. In the interactive UI that shows as a prompt.
- **Tested in an isolated sandbox** (own XDG directories, real binary 1.18.31,
  real config): it answered from `qwen3.6:35b`; `git status --short` ran
  unprompted; `rm` was denied and the file survived. Each call took about 40
  seconds in that run, most of it start-up.
- **Second computer:** the config points at `127.0.0.1:11434`, so a machine
  without a local Ollama needs its own endpoint (or the enclave's) in its
  OpenCode settings. A host that leaves `local.llm.model` null gets no OpenCode.

## Changing the model (2026-09-21)

The model and context are defined once, per host, as the options
`local.llm.model`, `local.llm.contextLength` (default 65536) and
`local.llm.extraModels` (options in llm.nix, values in
hosts/hn7306/default.nix). `ollama.nix` (`OLLAMA_CONTEXT_LENGTH`), `hermes.nix`
(`default`, `context_length`) and `home.nix` (OpenCode `model`, `small_model`,
model list) all read them, so nothing is duplicated any more.

**To switch model permanently:**

    ollama pull <model>      # nothing downloads automatically
    # edit local.llm.model in hosts/hn7306/default.nix, then:
    sudo nixos-rebuild switch --flake ~/nixos-config

Hermes needs a context of at least 64,000 tokens; an assertion in hermes.nix
fails the build with a clear message if `contextLength` is lower.

**Without a rebuild** (session only): `sudo -u hermes -H hermes chat -m <model>`
or `/model custom:<name>` in a Hermes chat; `opencode -m ollama/<model>` or
`/models` in OpenCode, but only for models listed in `extraModels`, because
OpenCode does not discover models (without any declared it reports "Provider
not found"). Ollama serves any installed model on request, loading it on
demand; nothing is loaded when idle, and each switch to another model reloads
it. Neither tool can "follow whatever Ollama has loaded".

Tested by evaluation: overriding `local.llm.model` changed Ollama, Hermes and
OpenCode together; `contextLength = 32768` failed the assertion; a null model
turned OpenCode off without error.


## Updating daily (2026-09-21)

Daily `nix flake update` plus a rebuild is fine on nixos-unstable, but two
things had to be fixed first (both in configuration.nix):

- **Boot partition.** `/boot` is only 446 MB (58% used with 27 generations and
  no limit). Each generation keeps a kernel and initrd there, and
  `linuxPackages_latest` brings a new one every few days, so a full partition
  would make a rebuild fail at the bootloader step. Now
  `boot.loader.systemd-boot.configurationLimit = 10`.
- **Garbage collection.** It was off, and the root disk was 81% full (store
  99 GB). Now `nix.gc` runs weekly with `--delete-older-than 14d`, and
  `nix.optimise.automatic` deduplicates the store. NixOS's gc options do work
  with Determinate Nix here (they create the `nix-gc` service and timer).
  Rollback is limited to 14 days and 10 boot entries.

**Routine.** Update everything except hermes-agent, which is unstable upstream
and changes daily; update it on purpose with `nix flake update hermes-agent`.
`nixpkgs-stable` and `nixos-hardware` are unused, so leave them out.

    cd ~/nixos-config
    nix flake update nixpkgs home-manager determinate
    nix build .#nixosConfigurations.hn7306.config.system.build.toplevel --dry-run
    sudo nixos-rebuild switch --flake ~/nixos-config
    ollama ps                          # after a request: want 100% GPU
    git add flake.lock && git commit   # only after it works

If an update goes wrong: `sudo nixos-rebuild switch --rollback`, pick the
previous generation in the boot menu, or `git checkout flake.lock`. A new kernel
needs a reboot to apply, and can occasionally regress on this GPU. A switch
restarts Hermes and Ollama, so update between tasks.

