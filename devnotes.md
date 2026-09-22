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
  were deliberately kept in flake.nix. The profile itself was later enabled in
  hosts/hn7306/default.nix, pinned to an unmerged pull request (see "Internal
  speakers").
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
    llm.nix                        options local.llm.*: the one model shared by Ollama, Hermes, OpenCode
    hermes.nix                     Hermes Agent service (optional module)
    home.nix                       Home Manager config for the user scott (incl. OpenCode)
    AGENTS.md                      instructions for coding agents (OpenCode)
    hosts/hn7306/default.nix       hostname, /scratch mount, local.llm values, imports
    hosts/hn7306/hardware-configuration.nix   generated, do not edit
    hosts/hn7306/strix-halo.nix    AMD/ROCm/GPU tuning, asusd, lact, fwupd
    hosts/hn7306/ollama.nix        Ollama service, models on /scratch

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
- The `nixpkgs-stable` flake input is declared but unused. `nixos-hardware` is
  used by hosts/hn7306/default.nix and pinned to a pull request.

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
`nixpkgs-stable` is unused, so leave it out. `nixos-hardware` is pinned to a
commit (see "Internal speakers"), so updating it does nothing.

    cd ~/nixos-config
    nix flake update nixpkgs home-manager determinate
    nix build .#nixosConfigurations.hn7306.config.system.build.toplevel --dry-run
    sudo nixos-rebuild switch --flake ~/nixos-config

**After every switch, check the three things that break silently (no error, just
wrong behaviour):**

    ollama ps                                                      # want 100% GPU, not CPU
    sudo -u hermes -H hermes chat -Q --oneshot -q "Reply with exactly the single word: pong"
    wpctl status | grep -i "Internal Speakers"                     # still listed as a sink
    cat /sys/class/power_supply/BAT0/charge_control_end_threshold  # still 80

Then, only once all four pass:

    git add flake.lock && git commit

**Why each of these can break on an ordinary update, even though nothing in
this repo changed:**

- **Ollama on CPU:** the GPU-discovery race from "Ollama silently fell back to
  CPU" above. Any rebuild that restarts Ollama (most do, since
  `environment.systemPackages`/`ollama.package` versions bump with nixpkgs) can
  retrigger it.
- **Hermes:** `hermes-agent` has its own pinned nixpkgs and does not follow
  ours, so an ordinary `nixpkgs`/`home-manager` update cannot break it. It
  still needs updating deliberately and testing on its own
  (`nix flake update hermes-agent`, then the same chat check) because upstream
  calls it unstable and changes daily.
- **Speakers:** the nixos-hardware pin is to an exact commit
  (`github:toastal/nixos-hardware/9f6e7c0…`), which `nix flake update` cannot
  move, and its patches apply only below kernel 7.2, so any future kernel in
  nixpkgs (7.2 and up) should keep getting zero patches. A kernel bump is still
  worth re-checking once, since it is the one thing that changes the actual
  sound driver. Watch [nixos-hardware PR #2005](https://github.com/NixOS/nixos-hardware/pull/2005)
  for merging; once merged, switch the input back to
  `github:NixOS/nixos-hardware` and run `nix flake update nixos-hardware`.
- **Battery limit:** the profile's own service re-writes the threshold at every
  boot and after every suspend/resume, defaulting to 100%; `chargeUpto = 80` in
  hosts/hn7306/default.nix overrides that default, but a future edit to that
  option (or dropping it) silently reverts to 100%.

If an update goes wrong: `sudo nixos-rebuild switch --rollback`, pick the
previous generation in the boot menu, or `git checkout flake.lock`. A new kernel
needs a reboot to apply, and can occasionally regress on this GPU. A switch
restarts Hermes and Ollama, so update between tasks.

## Internal speakers: nixos-hardware PX13 profile, pinned to an unmerged PR (2026-09-21)

**Hardware.** DMI reports ASUS ProArt PX13 HN7306EAC. The internal speakers use
two TAS2783 amplifiers on SoundWire. Today the kernel log shows
`soundwire sdw-master-0-1: Program transport params failed: -22` and
`SmartAmp: ASoC error (-22)`, and PipeWire lists no internal speaker sink
(only HDMI and USB devices). The dock (WD19) and the Jabra headset work.

**The profile.** `nixos-hardware.nixosModules.asus-proart-px13-hn7306eac` fixes
this with 17 kernel patches taken from the AUR `linux-cachyos-px13` package,
and asserts kernel >= 7.0. It also sets `amd_pstate=active`, TPM2, iio sensors,
early amdgpu, a battery-threshold service (which may overlap with asusd's
charge limit) and ALSA UCM, WirePlumber and udev rules. The patches mean a
locally built kernel, so every kernel bump would recompile it.

**Tested 2026-09-21, and it fails.** With Linux 7.2.6, patch
`0003-removed-unused-fields` does not apply to `sound/soc/codecs/tas2783-sdw.c`
(2 of 4 hunks fail); with that patch dropped the next one fails too, so the
series is entangled. Linux 7.0 and 7.1 were removed from nixpkgs as
end-of-life, and older kernels fail the profile's assertion, so no kernel in
nixpkgs works with the released profile. The newest nixos-hardware (9ebcb77)
has the same patch list as the locked one (b2d7d02).

**The fix: NixOS/nixos-hardware PR #2005** ("drop patches @ Linux 7.2", by
toastal, opened 2026-08-22, still open and unreviewed on 2026-09-21). It applies
the patch list only when the kernel is older than 7.2, because the driver fixes
are now in the kernel, and moves the >= 7.0 assertion to the top of the profile.
Two files, +35/-31. Evaluated against this config it gives 0 patches, the same
kernel derivation as before (so still from the cache), no assertion failures and
no warnings; the only rebuilds are the initrd and module set (early amdgpu).

**Upstream.** The driver is changing in mainline. Mark Brown applied two
tas2783-sdw fixes, tested on a PX13, to the sound tree branch `for-7.4` on
2026-09-09 (commits 3e56757584d6 and f4ffa3820949), and an ACP70 ACPI match for
tas2783 was applied for 7.2. Those reach mainline in the 7.4 merge window; there
is no exact date, and the AUR patches conflict because the driver moved under
them. Stable backports of individual fixes may arrive sooner in 7.2.x.

**Enabled.** flake.nix pins the `nixos-hardware` input to the PR's exact commit
(`github:toastal/nixos-hardware/9f6e7c04bd8624daacebd76a21c0e0137ecbc6af`, a
third-party fork; the diff was read first and touches only the profile), and
hosts/hn7306/default.nix imports
`inputs.nixos-hardware.nixosModules.asus-proart-px13-hn7306eac`. Because the URL
names a commit, `nix flake update nixos-hardware` does not move it.

**Not yet verified on the machine:** that the speakers actually work. After
`sudo nixos-rebuild switch` and a reboot (new kernel parameter `amd_pstate=active`
and a new initrd), check:

    wpctl status                                  # want "Internal Speakers (TAS2783)" among the sinks
    journalctl -k -b | grep -iE 'tas2783|sdw'     # the -22 errors should be gone
    cat /sys/class/power_supply/BAT*/charge_control_end_threshold    # still 80? the profile adds a battery-threshold service that may overlap asusd

If it works, a "tested on 7.2.6" comment on the PR helps get it merged.

**When the PR is merged:** change the input URL back to
`github:NixOS/nixos-hardware`, run `nix flake update nixos-hardware`, and
rebuild. If it is closed or the fork disappears, the input will fail to fetch;
then either pin a released nixos-hardware once it supports 7.2 or remove the
import (the speakers stop working, but a dock or headset still does).

The profile also enables `amd_pstate=active`, TPM2, iio sensors and early
amdgpu; the kernel patches themselves are gone on 7.2.

**After the first rebuild and reboot (2026-09-21):**

- **Speaker sink appears.** `wpctl status` now lists `Internal Speakers
  (TAS2783)` (pipewire node `alsa_output.pci-0000_c4_00.5-platform-amd_sdw.pro-output-2`),
  next to `Audio Coprocessor Pro`. WirePlumber's stored default sink was still
  the old `...pro-output-0` ("Audio Coprocessor Pro"), so pick the speakers in
  GNOME Settings > Sound, or `wpctl set-default <id>`.
- **SmartAmp capture errors remain, but do not loop.** The kernel log still has
  `SDW1-PIN4-CAPTURE-SmartAmp: ASoC error (-22)` / `Program transport params
  failed` (40 lines in the first boot minutes, none in the following minutes),
  clustered when something opens the profile's `Audio Coprocessor Pro` capture
  sources, for example the Sound settings panel. Treat it as noise if playback
  works; if it does not, this is the place to look.
- **The profile reset the charge limit to 100%.** Its `battery-charge-threshold`
  service (asus/battery.nix in nixos-hardware) writes the limit at boot and
  after suspend/hibernate, defaulting to 100, so `charge_control_end_threshold`
  and `asusctl battery info` both read 100% instead of asusd's 80%. Fixed with
  `hardware.asus.battery.chargeUpto = 80` in hosts/hn7306/default.nix. Until
  that is rebuilt, set it by hand with `asusctl battery limit 80`.
- Ollama still found the GPU after the reboot (`library=ROCm compute=gfx1151`).
