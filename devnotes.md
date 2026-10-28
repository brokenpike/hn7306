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

**Correction (2026-10-04).** The cause above blames subnets advertised by the
exit node. On 2026-10-04 nixoshpe advertised only `0.0.0.0/0`, `::/0` and two
RFC 5737 example ranges (`192.0.2.0/24`, `198.51.100.0/24`), and the problem
was still there. The exit node's default route in table 52 is enough on its
own: table 52 is consulted before the main table, so it catches `virbr0`'s
subnet and the LAN as well. It hit plain LAN traffic too: SSH to
nixoshpe's LAN address (192.168.50.74) timed out while it was the exit node.

The "untested alternative" is now the fix, tested 2026-10-04: with
`--exit-node-allow-lan-access`, `ip route get` for 192.168.50.74 and
192.168.122.x goes out the LAN interface and `virbr0`. It is set in
configuration.nix through `services.tailscale.extraSetFlags`, together with
`--operator=scott` so scott and Trayscale (home.nix) can control Tailscale
without sudo. nixoshpe's side (exit node declared in its config, example
ranges dropped) is in its own repo, github.com/brokenpike/nix-hpe.

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

## guestfs-tools run on demand, not installed (2026-09-28)

`libguestfs` and `guestfs-tools` were in `vm.nix` and made every update heavy.
They were only used for `virt-sparsify`, to shrink the Windows/MSSQL qcow2
images every week or two (plus one `virt-filesystems`), so they were removed
from the system. Removing only `libguestfs` would not have helped, because
`guestfs-tools` depends on it. Nothing else in the config needs them. Run them
when needed:

    nix shell nixpkgs#guestfs-tools -c virt-sparsify in.qcow2 out.qcow2
    nix shell nixpkgs#guestfs-tools -c virt-filesystems -a disk.qcow2 --all --long -h

This uses the registry's nixpkgs (downloaded from the binary cache that day),
not this flake's pin, so the tools can be a different version from the system's
qemu. That is fine for working on image files offline. Do not sparsify the disk
of a running VM.

## vm.nix package cleanup (2026-09-28)

Reviewed `vm.nix` after the guestfs change and trimmed the package list:

- **`spice-protocol` removed.** It contains only C headers for building SPICE
  software, so installing it system-wide did nothing.
- **`dnsmasq` removed.** libvirt already puts its own dnsmasq on its PATH (the
  libvirt package's `binPath`) for the VM network (192.168.122.0/24), so the
  system copy only added an unused command. If the VM network loses DHCP or DNS
  after this, this is the change to look at.
- **`virt-manager` package line replaced by `programs.virt-manager.enable`.**
  The module installs the same package and also sets a system dconf default so
  virt-manager connects to `qemu:///system` on start. It is only a default, so
  connections already saved in virt-manager are kept. Note that the Boxes VMs
  (`win11-*`) live on `qemu:///session`, not `qemu:///system` (which has no VMs
  yet), so to see them in virt-manager add a "QEMU/KVM User session" connection.
  `programs.dconf.enable` stays, because the module adds a dconf database but
  does not turn dconf on (GNOME does anyway, but niri would not).

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

## Hermes MCP connection to Visure: use `auth = "oauth"`, not a static Bearer header (2026-09-23)

**What was staged and wrong.** An earlier edit to `hermes.nix` added
`mcpServers.visure` pointed at the Visure Authoring 8 test server's MCP
endpoint (`https://v5817.vegtamr.online/VisureAuthoring8/mcp`, see the Visure
VM's own `DEVNOTES.md`/`VISURE-VM-SETUP-GUIDE.md`) using
`headers.Authorization = "Bearer ${MCP_VISURE_API_KEY}"`, with the token meant
to come from `/etc/hermes-secrets/visure-mcp.env`. This was never built or
switched in (the change sat staged, uncommitted) and would not have worked:

- The server's own doc comments (`VisureWeb.xml`,
  `McpSessionBootstrap.ChooseAuthenticationMode`) say **"Bearer always wins
  when present."** Any `Authorization: Bearer` header is treated as an OAuth
  access token attempt; a static/arbitrary string there gets rejected, it
  never falls through to the legacy header-auth path.
- That legacy path (`Mcp.AllowHeaderAuth = true`) uses a *different* header
  pair entirely — `X-Visure-Username` / `X-Visure-Token` — and
  `McpUserSession.Token`'s doc comment says plainly: **for native auth, that
  token is the account's actual plaintext password.** Not a scoped API key.
  Wiring that up would have meant a real Visure account password sitting in
  a `.env` file.

**The fix:** Hermes has real OAuth 2.1 support (PKCE + dynamic client
registration / RFC 7591, or CIMD when the server supports it — see
`tools/mcp_oauth.py` in the hermes-agent source, and the `auth` option in the
NixOS module's `mcpServerType` submodule, `nix/moduleCommon.nix`). This is
the same mechanism Claude Desktop already uses successfully against this same
Visure server (see the Visure VM's own DEVNOTES, 2026-09-16 entry). Changed
`hermes.nix` to:

```nix
mcpServers.visure = {
  url = "https://v5817.vegtamr.online/VisureAuthoring8/mcp";
  auth = "oauth";
};
```

No `headers`, no `environmentFiles`, no secret file at all — tokens are
stored automatically in `$HERMES_HOME/mcp-tokens/` after a one-time
authorization. Verified by building the `hermes-config.yaml` derivation
directly (`nix-store --realize` on the `.drv` from a `--dry-run` build) and
confirming the generated JSON: `"visure":{"auth":"oauth","enabled":true,"url":"https://..."}`
with no headers/secrets present.

**To actually authorize, after `sudo nixos-rebuild switch`:**

    sudo -u hermes -H hermes mcp login visure

This runs the interactive OAuth flow (browser PKCE by default; `--flow
device` selects RFC 8628 device-code instead, for a fully headless box —
not needed here since this machine has a GUI session). It prints a URL,
you approve in a browser, and Hermes captures the token via a local
callback listener.

**General lesson for connecting any harness to any MCP server:** don't
assume a `mcpServers.<name>.headers` field is the right knob just because it
exists — check the *target* server's own auth precedence and what its
fallback header scheme actually authenticates with (grep any shipped `.xml`
XML-doc file or equivalent for the auth handler's doc comments) before
wiring up a static secret. A server offering "header auth" as a legacy
fallback does not imply that header takes an API key; here it took a
password. Prefer whatever OAuth support the harness has, if the server
offers OAuth at all.

## Ollama, Hermes and OpenCode on phoenix (2026-09-24)

phoenix (Framework 13, Ryzen 5 7640U, Radeon 760M, 38 GiB RAM, 512 MiB VRAM
carve-out) runs its own Ollama for now, so both agents work offline and without
hn7306. The plan is to point it at hn7306 later over a mesh network (nebula or
Tailscale), with a Claude account as a further source of tokens. That will need
a base URL option in llm.nix, since hermes.nix and home.nix hard-code
`http://127.0.0.1:11434/v1`.

- **Vulkan, not ROCm.** The 760M is gfx1103, which ROCm does not support without
  `HSA_OVERRIDE_GFX_VERSION`. `pkgs.ollama-vulkan` runs on it as is and comes
  from the cache.
- **Model `gpt-oss:20b`** (about 14 GB). hn7306's `qwen3.6:35b` is about 23 GB
  and would leave too little of the 38 GiB for the desktop. gpt-oss supports tool
  calling, which Hermes needs.
- **`OLLAMA_NUM_PARALLEL=1`** (hn7306 uses 2): each slot holds its own 64K
  context, and RAM is short. Hermes and OpenCode queue instead of running at
  once.
- **`OLLAMA_IGPU_ENABLE=1`.** Without it, Vulkan finds the 760M but Ollama
  logs `dropping integrated GPU; to enable, set OLLAMA_IGPU_ENABLE=1` and runs
  `library=cpu`. That happened on the first rebuild.
- **Speed, measured with `ollama run --verbose`.** Generation is about 13
  tokens/s, which is what the 760M's memory bandwidth allows. Prompt reading
  was 240 tokens/s (12K tokens in 50 s). Agents send 10-20K token prompts, so
  reading them is most of the wait.
- **`local.llm.reasoningEffort = "low"`** (new option in llm.nix, read by
  hermes.nix and home.nix). At its default of medium, gpt-oss spent 477 tokens
  thinking about a haiku. Hermes sends it as `reasoning_effort` (its custom
  provider asks for medium when unset); OpenCode gets it as a model option on
  the default model only. Null on hn7306, so nothing changes there. Hermes'
  `settings` type does not resolve `lib.mkIf`, so conditional keys there use
  `lib.optionalAttrs`.
- **Flash attention does not help here; removed.** With
  `OLLAMA_FLASH_ATTENTION=1` (log confirmed `flash_attn = enabled` on Vulkan),
  prompt reading was 236.6 tokens/s against 239.9 without it, and generation
  was unchanged. Test with new text each run: Ollama caches the prompt, and a
  repeated 12K-token prompt "reads" in 96 ms, which is meaningless as a
  benchmark. The same cache is why only an agent's first turn is slow, as long
  as the model stays loaded.
- Models stay in the default `/var/lib/ollama`; phoenix has one disk with room.

Check after the first rebuild: `journalctl -u ollama --no-pager -o cat | grep
'inference compute' | tail -1` should name the Vulkan library, and `ollama ps`
should show `100% GPU`. With only 512 MiB of VRAM, the GPU must use GTT memory
(shared system RAM). If `ollama ps` shows a CPU/GPU split, that is the limit to
look at.

## Visure VMs moved to quickemu; gh, socat, KVM MSRs (2026-10-02)

- **Visure VMs run in quickemu now, not GNOME Boxes.** Each VM is one folder
  plus a `.conf` in `/scratch/visure-clones` (disk, UEFI vars, TPM state,
  logs), started with `quickemu --vm <name>.conf`. The Boxes VM `win11-6` was
  reflink-copied to `visure8405817`; its Boxes definition stays as a fallback.
  libvirt and Boxes stay installed for the older VMs. The image and clone
  scripts live in `~/vms/visure-golden` (github.com/vegtamr-no/visure-golden).
- quickemu's default networking is QEMU user-mode NAT, so these VMs don't use
  `virbr0` and the Tailscale exit-node problem above doesn't apply to them.
  SSH goes through a fixed port forward per VM (`ssh_port=` in the conf, plus a
  `Host` alias in `~/.ssh/config`).
- **`boot.extraModprobeConfig = "options kvm ignore_msrs=1 ..."`** in vm.nix.
  quickemu warns at every start that Windows guests may crash on unhandled
  MSRs. Its `--ignore-msrs-always` writes `/etc/modprobe.d`, which NixOS
  doesn't keep, so the option is set here. `report_ignored_msrs=0` keeps the
  ignored accesses out of the kernel log. Takes effect after a reboot (or
  reloading `kvm`).
- **`socat`** (vm.nix) to talk to a running VM's QEMU monitor socket, for
  example to add a port forward without restarting it. **`gh`** (home.nix) for
  creating GitHub repos; it was run through `nix-shell -p gh` before.

## GPU memory cap raised to 104 GiB for DeepSeek V4 Flash (2026-10-06)

Supersedes the 80 GiB decision in "GPU memory plan and zram swap".

**Why:** to try DeepSeek V4 Flash 0731 (304B-parameter MoE) from
`unsloth/DeepSeek-V4-Flash-0731-GGUF`. Its 2-bit quants are about 85 GiB
(`UD-IQ2_XXS` 84.6, `UD-IQ2_M` 84.7 GiB), plus context and compute buffers:
roughly 90-95 GiB, which the 80 GiB cap could not hold. Framework's guide runs
it on the 128 GB Framework Desktop (same Ryzen AI Max+ 395); the difference was
only this cap, not the hardware. The 1-bit quants (`UD-IQ1_S` 76.9,
`UD-IQ1_M` 80.9 GiB) would not have fitted 80 GiB with any useful context
either, and lose much more quality.

**Now:** `ttm.pages_limit=27262976` (104 GiB). It leaves about 20 GiB for the
host. The user's decision: **a big model and a Windows VM do not run at the
same time.** `qwen3.6:35b` (22 GB) and a 16 GiB quickemu VM together still fit
easily. Check after the reboot: `mem_info_gtt_total` should read 106496 MiB.

**Compared on published scores (full precision):** Framework's suggestion for
its 64 GB model, Qwen3.5-122B-A10B, is not better than the `qwen3.6:35b`
already in use (SWE-bench Verified 72.0 vs 73.4, LiveCodeBench 78.9 vs 80.4,
Terminal-Bench 2.0 49.4 vs 51.5; ahead only on knowledge, MMLU-Pro 86.7 vs
85.2), and it would be about 3x slower (10B vs 3B active). DeepSeek V4 Flash
reports Terminal-Bench 2.1 at 82.7: a different test version, but a clearly
higher class. No scores exist for its 2-bit quants, so whether it beats
`qwen3.6:35b` here has to be tried.

**Runtime still open:** llama.cpp loads the three split GGUF files directly;
whether Ollama 0.34.4 supports the `deepseek_v4` architecture is unconfirmed,
and Ollama would need the parts merged into one file first.

## llama.cpp behind llama-swap, next to Ollama (2026-10-09)

**Plan:** move the daily backend to llama.cpp with llama-swap; keep Ollama,
started only on demand, as a reference for benchmarks and for catching poor
llama.cpp settings. The single-model rule may become two models (Hermes on
Qwen3.6, OpenCode on Qwen3-Coder). Restore point: tag `backup/pre-llama-swap`.

**Step 1 (this entry):** `hosts/hn7306/llama-swap.nix` serves
`127.0.0.1:8080`. Nothing points at it yet; Ollama, Hermes and OpenCode are
unchanged.

- Models in `/scratch/models`, IDs `qwen3.6-35b` (UD-Q8_K_XL + mmproj-F16),
  `qwen3-coder-30b` (Q8_0) and `deepseek-v4-flash` (UD-IQ2_M, 3 parts).
  Q8 for the 3B-active MoE models: speed hardly depends on the quant, and
  memory is plentiful. Plain Q8_0 is preferred for new downloads, because
  Unsloth's UD-Q8_K_XL keeps some tensors in BF16, which is weakly supported on
  gfx1151 under Vulkan; the UD file already downloaded stays until a benchmark
  says otherwise.
- Group `qwen` keeps both Qwen models loaded together (about 70 GiB plus
  context, so no VM meanwhile) and is exclusive with DeepSeek (85 GiB).
  `ttl = 1800` unloads idle models after 30 minutes, like Ollama but longer.
- llama-server splits `--ctx-size` across `--parallel` slots, so it gets
  `local.llm.contextLength * 2`; each slot keeps the 65,536 Hermes requires.
- Sampling flags copy Ollama's model defaults, so comparisons are fair.
- Vulkan build first. `nixpkgs.config.rocmSupport = true` would add ROCm to
  every llama-cpp build, so the override turns it off. Compare with
  `pkgs.llama-cpp-rocm` using llama-bench before settling. Both are cached.
- llama.cpp 0.6.0 (upstream switched to semver tags) knows `qwen35moe`,
  `qwen3moe` and `deepseek4`, the architectures in these GGUF files.
- The module runs llama-swap as a DynamicUser. `/dev/kfd` and
  `/dev/dri/renderD128` are mode 0666, so no extra groups are needed, and the
  model files are world-readable.

**Benchmark, ROCm vs Vulkan (2026-10-09):** llama-bench, Qwen3.6-35B-A3B
UD-Q8_K_XL, `-ngl 999 -fa 1 -p 2048 -n 128 -d 0,32768`, llama.cpp 0.6.0
(d812350), Mesa 26.2.4, ROCm 7.2.3. Tokens per second:

    test               Vulkan   ROCm
    pp2048               1239   1104
    tg128                45.7   42.5
    pp2048 @ d32768       671    688
    tg128 @ d32768       39.4   37.1

Vulkan wins three of four; ROCm's 2.5% at 32K is within noise. **Decision:
stay on Vulkan.** RADV reports `bf16: 0` and `KHR_coopmat` (matrix cores in
use). The UD-Q8_K_XL file benchmarks as plain Q8_0, so its few BF16 tensors do
not matter. The nixpkgs ROCm build has no rocWMMA flash-attention kernels;
revisit ROCm only if that changes. Qwen3-Coder (qwen3moe) not yet measured.

**Benchmark, Ollama vs llama.cpp, same file (2026-10-09):** both loaded
`Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` (imported into Ollama as
`qwen3.6-q4-bench`). Ollama numbers from `/api/generate` (2,015-token prompt,
128 generated, `num_ctx` 8192, mean of 3 runs); llama.cpp from llama-bench
(`-p 2048 -n 128 -fa 1`, Vulkan). Tokens per second:

    test        Ollama (ROCm)   llama.cpp (Vulkan)
    prompt          ~1300         1376 ± 75
    generate         44.1          59.0

Prompt processing is equal within noise; generation is 34% faster in
llama.cpp. API overhead is negligible (llama-swap served Q8 at 45.5 vs
llama-bench 45.7), so the methods compare. Net effect: llama.cpp runs Q8 at
Ollama's Q4 speed (45.7 vs 44.1). Keep Q8 for the agents. Rerun this check
after updating either package; keep `qwen3.6-q4-bench` in Ollama for it.

To repeat the Ollama side (fish; fetch jq once, two `nix run` calls in one
pipeline deadlock on the Nix eval cache):

    set JQ (nix build --no-link --print-out-paths nixpkgs#jq.bin)/bin/jq
    for i in 1 2 3
        $JQ -n --arg p (random)" "(string repeat -n 200 "The quick brown fox jumps over the lazy dog. ") \
            '{model:"qwen3.6-q4-bench",prompt:$p,stream:false,options:{num_ctx:8192,num_predict:128}}' \
        | curl -s localhost:11434/api/generate -d @- \
        | $JQ '{pp:(.prompt_eval_count/(.prompt_eval_duration/1e9)), tg:(.eval_count/(.eval_duration/1e9))}'
    end

## Hermes and OpenCode moved to llama-swap; per-tool model option (2026-10-09)

Step 2 of the llama.cpp migration. `llm.nix` gained two options:

- **`local.llm.baseURL`**, read by hermes.nix and home.nix instead of the
  hard-coded `127.0.0.1:11434/v1` (the phoenix entry above asked for this).
  The default stays Ollama's address, so phoenix is unchanged; hn7306 sets
  `http://127.0.0.1:8080/v1`. Pointing phoenix at hn7306 over the tailnet is
  now only this one setting.
- **`local.llm.opencode.model`**: OpenCode's own model, null = Hermes' model.
  The old rule "both tools must use one model" came from Ollama's
  `OLLAMA_MAX_LOADED_MODELS=1`. A llama-swap group with `swap = false` keeps
  two models loaded, so two models are now possible, but only within such a
  group. Left null on hn7306 for now, so behaviour does not change during the
  switch of backend; the candidate is `qwen3-coder-30b`.

Model names on hn7306 are now llama-swap IDs (`qwen3.6-35b`). OpenCode's
provider was renamed from `ollama` to `local` (`local/qwen3.6-35b`), since the
server is no longer Ollama. `extraModels` dropped the Ollama-only models
(gemma4, gpt-oss, the old qwen3-coder tag) and lists the llama-swap ones.
Ollama keeps running for now; making it start on demand only is step 4.

**Two models, plus Visure (same day):** OpenCode now uses `qwen3-coder-30b`
(`local.llm.opencode.model`), Hermes keeps `qwen3.6-35b`. Visure, if it can
use an OpenAI-compatible endpoint, reaches the same Qwen3.6 from the Windows
VM at `http://10.0.2.2:8080/v1`: quickemu's user-mode network forwards
10.0.2.2 to the host's 127.0.0.1, so llama-swap needs no change.

Trying DeepSeek in Hermes first showed why one group matters: Hermes on
DeepSeek and OpenCode on Qwen swapped the 85 GiB and 37 GiB models on every
switch between the tools (the first Hermes request took 2.5 minutes, mostly
loading). They do not fit together under the 104 GiB cap, and DeepSeek does
not fit next to a VM, so it stays a deliberate session choice for both tools.

To fit the Qwen pair next to the 16 GiB Visure VM, Coder changed to
`UD-Q4_K_XL` (17.6 GB; Q8_0 file kept) and one slot (OpenCode is its only
user; a second 64K slot is about 6 GiB of KV cache in f16). Measured: Qwen3.6
Q8 with 2 x 64K slots uses 40.9 GiB of GTT. Estimated pair: about 65 GiB, so
pair plus VM leaves about 43 GiB for the host. Coder Q8 with two slots would
have left about 24 GiB.

**Measured after the rebuild:** the Qwen pair loaded uses 63.6 GiB of GTT
(estimate was 63-64). Qwen3-Coder, llama-bench Vulkan, `-p 2048 -n 128`,
tokens per second:

    file          size       pp2048       tg128
    UD-Q4_K_XL   16.5 GiB   1316 ± 68     90.4
    Q8_0         30.3 GiB   1365 ± 35     59.8

Q4 generates 51% faster (the estimate from Qwen3.6 was 25-30%; plain
`qwen3moe` is more purely bandwidth-bound than the hybrid `qwen35moe`), with
prompt processing equal. Confirms Q4 for OpenCode.

## Ollama on demand only; llama-swap on the tailnet (2026-10-09)

Step 4 of the llama.cpp migration.

- **Ollama no longer starts at boot** on hn7306
  (`systemd.services.ollama.wantedBy = lib.mkForce [ ]` in ollama.nix), so it
  never holds GPU memory next to the Qwen pair or a VM. Start it for a
  benchmark with `sudo systemctl start ollama`, stop it afterwards. Its context
  and slot settings now mirror llama-swap's qwen3.6-35b instead of serving the
  agents. phoenix still starts its Ollama at boot.
- **llama-swap over the tailnet** with `tailscale serve`, not a Nix option:
  tailscaled stores the serve config and keeps it across reboots, and
  nixpkgs' `services.tailscale.serve` is built for Tailscale Services (`svc:`
  names, tagged nodes), too much for one machine. llama-swap keeps listening
  on 127.0.0.1 only; no firewall change. Set up (as scott, the operator):

      tailscale serve --bg --https=443 http://127.0.0.1:8080
      tailscale serve status

  Clients use `https://hn7306.heron-pickerel.ts.net/v1`. To remove:
  `tailscale serve --https=443 off`. Neither llama-swap nor llama-server has
  authentication, so every device on the tailnet can use the models and the
  `/ui` page (which can unload models). Restrict port 443 on hn7306 with a
  tailnet grant if devices other than the user's own join.

## Open WebUI, shared with tailnet guests (2026-10-09)

Step 5 of the llama.cpp migration. `hosts/hn7306/open-webui.nix` runs Open
WebUI 0.11.4 on `127.0.0.1:8081` (8080 is llama-swap), talking to
llama-swap through `local.llm.baseURL`. `tailscale serve --bg --https=8443
http://127.0.0.1:8081` publishes it as
`https://hn7306.heron-pickerel.ts.net:8443`.

- **Guests:** two people outside the tailnet get Open WebUI here and Jellyfin
  on nixoshpe through machine sharing. The tailnet policy (admin console,
  not in git) then gave `autogroup:member` everything and `group:guests`
  only `hn7306:8443` and `nixoshpe:8920`; the old `"src": ["*"]` would have
  included shared-in users and exposed llama-swap (no authentication),
  Nextcloud, AdGuard and SSH. The policy has tests for both. Superseded: see
  "Tailnet users vs shares" below; `autogroup:member` also covered Thor.
- **Accounts:** the first account created becomes admin, so create it
  before anyone else can reach the page. After that Open WebUI reported
  `enable_signup: false` despite `ENABLE_SIGNUP=True` (the variable only
  seeds the first start); guest accounts are created by the admin (Admin
  Panel, Users), so nobody else can register.
- **Default model `local.llm.model`** (qwen3.6-35b), Hermes' model: a guest's
  chat shares its two slots instead of loading another model. Picking
  deepseek-v4-flash would unload both Qwen models, so only qwen3.6-35b should
  be visible to users (Admin panel, Models).
- Ollama's API is off (`ENABLE_OLLAMA_API=False`): Ollama only runs for
  benchmarks, and the page would otherwise wait for it on every load.
- Most environment values only seed the database on the first start; later
  the admin panel wins. Setting `environment` replaces the module's default
  (telemetry off), so those three variables are repeated.
- Not in the binary cache (its license counts as unfree), so it builds
  locally: frontend and Python package, a few minutes. PyTorch (ROCm build,
  for the embedding models) comes from the cache, about 2.9 GiB.

## OpenCode 2: tried, deferred until it is in nixpkgs (2026-10-09)

**Not applied.** Prepared and checked, then reverted on 2026-10-12 at the
user's request: wait until nixpkgs packages OpenCode 2 instead of building it
from a separate flake input. The config still uses V1 fields, which V2 also
reads. What was found, for when it lands:

OpenCode 2 was not in nixpkgs (nixos-unstable had 1.18.35). It is published
on npm as `@opencode/cli` and tagged in github:anomalyco/opencode
(`v2.0.26`, branch `2.0`), whose flake builds it from source with Bun. The
tried approach: flake input `opencode` pinned to the tag, not following our
nixpkgs (the `node_modules` hash in upstream's `nix/hashes.json` only
matches the Bun version of upstream's nixpkgs), and
`programs.opencode.package` from it. It built in a few minutes, uncached.

**Config.** V2 reads V1 configs and converts them in memory. The native V2
fields, to switch home.nix to once V2 is installed: `providers` (was `provider`), `package =
"aisdk:@ai-sdk/openai-compatible"` (was `npm`), `settings.baseURL` (was
`options`), model `settings.reasoningEffort` (was `options`),
`agents.title.model` (was `small_model`), `update = "disable"` (was
`autoupdate = false`), and one ordered `permissions` list of
`{ action, resource, effect }` (was `permission.bash` etc.; `bash` is now
`shell`). The last matching rule still wins. A shell pattern ending in ` *`
now also matches the bare command, so `git diff` next to `git diff *` was
dropped. Checked with V2's own `opencode debug config` against the generated
file of both hosts, in a throwaway XDG directory: no warnings, values as
intended (phoenix keeps `reasoningEffort: low`).

**Other V2 changes that matter here:**

- **Background service.** V2 starts `opencode serve --service` (127.0.0.1,
  port 13420, random password in `~/.local/state/opencode/service-prod.json`)
  and keeps it running after the client exits; the client connects to it.
  After a rebuild that changes OpenCode, the old binary keeps running until
  `opencode service restart`. `--standalone` runs a private server instead.
- **Plugins:** V1 plugins do not load in V2. None were in use;
  `~/.config/opencode/{package.json,node_modules}` only held the
  `@opencode-ai/plugin` type package that V1 installs by itself, and can be
  deleted.
- **Sessions:** V2 uses the same `~/.local/share/opencode/opencode.db` as
  V1. Copy it before the first V2 start, so V1 sessions survive if V2 changes
  the database and a rollback to V1 is needed.
- Terminal UI settings move from `tui.json` to one `cli.json` (automatic);
  none were set.

## Wi-Fi hotspot needs DHCP and DNS open on the Wi-Fi card (2026-10-12)

An iPhone SE 3 cannot take internet over USB or Bluetooth from a computer
(iOS only shares, it never receives), so hn7306 shares its wired connection
as a Wi-Fi hotspot (`nmcli device wifi hotspot …`, NetworkManager "shared"
mode; needs a second uplink, here the USB Ethernet, because the card cannot
be client and hotspot at once). The iPhone reported "IP configuration
failure": NetworkManager's dnsmasq started (range 10.42.0.10-254) but the
firewall, which trusts only `lo`, dropped DHCP (UDP 67) and DNS (53) on
`wlp194s0`. Fixed with `networking.firewall.interfaces.wlp194s0` in
hosts/hn7306/default.nix (interface name is machine-specific). Nothing
listens on those ports unless the hotspot is on. Tested with temporary
iptables rules first. Clients' DNS goes through dnsmasq to Tailscale's DNS
(AdGuard); with nixoshpe as exit node their traffic goes through it too.

**Using it.** `nmcli device wifi hotspot …` creates a new profile on every
run (there were `Hotspot` and `Hotspot-1`), so start the saved one instead.
The profile is `iphone-hotspot` (renamed from `Hotspot-1`, SSID `iphone`,
`autoconnect no`, so it never starts by itself):

    nmcli connection up iphone-hotspot
    nmcli connection down iphone-hotspot
    nmcli -t -f NAME,DEVICE,STATE connection show --active | grep hotspot
    nmcli device wifi show-password      # also prints a QR code to scan
    ip neigh show dev wlp194s0           # connected clients
    ip route get 1.1.1.1 from 10.42.0.10 iif wlp194s0

The last line shows where clients' traffic leaves: the wired interface
(direct), `tailscale0` (exit node) or Proton's interface. Clients follow the
host's routing and DNS, VPN included; Proton's kill switch may block
forwarded traffic, and Proton plus the Tailscale exit node at once should be
avoided. The hotspot is IPv4 only, so there is no IPv6 path around a VPN.
A client running its own Tailscale exit node overrides all of this.

## Tailscale SSH on hn7306 (2026-10-12)

`services.tailscale.extraSetFlags = [ "--ssh" ]` in hosts/hn7306/default.nix
(lists merge, so the shared `--exit-node-allow-lan-access` and
`--operator=scott` from configuration.nix stay). It was already on at
runtime (`tailscale debug prefs`: `"RunSSH": true`, set by hand); this makes
it part of the config. Tailscale answers port 22 on the tailnet address and
authorizes by tailnet identity through the policy's `ssh` section (owner to
own devices, as a non-root user or root, in check mode); OpenSSH still
serves the LAN with its own keys and passwords. phoenix has it switched on
by hand (on 2026-10-12 it accepted `ssh scott@phoenix` with auth method
`none`, which only Tailscale SSH does), but not in its Nix config.
Verified 2026-10-13: `ssh scott@hn7306` from phoenix logs in.
In nix-hpe, a changed `extraSetFlags` did not rerun `tailscaled-set` at
the switch; if a flag seems missing after a rebuild, run
`sudo systemctl restart tailscaled-set`.

## Tailnet users vs shares; policy for guests (2026-10-11)

The tailnet policy lives in the admin console, not in git; this records it.

- **Users vs shares.** A *user* is a member of this tailnet: their devices
  join it, and `autogroup:member` covers them. A *share* gives one machine to
  someone who stays in their own tailnet. Guests should get shares only.
- **What the Users page showed (2026-10-11):** Thor Askey
  (thorinnnorway67@gmail.com) is an **Admin** member since 2024-04-01, and
  geirkepler4@gmail.com has a pending **user invitation** (Member) instead of
  a share. Either would get full access through the `autogroup:member` rule
  and could, as admin, change the policy. **Decision (2026-10-13):**
  **Thor was removed as a tailnet user** (no admin access any more) and
  is to get shares of hn7306 and nixoshpe instead. Later the same day
  Geir's user invite was revoked too, and he was sent a share of nixoshpe
  (Jellyfin); he already had hn7306.
  Accepted shares seen by the machines on 2026-10-13: Geir and vegtamr-no on
  hn7306, vegtamr-no on nixoshpe; Thor none. Unused invites expire after 30
  days (user invite links and machine share links); accepted shares and
  existing users do not expire.
- **The test account** vegtamr-no@github (Latitude 5400, Fedora, its own
  tailnet "vegtamr") failed the policy tests as a guest: Tailscale counted it
  as a member, apparently because GitHub logins look like members of a
  GitHub-based tailnet (`brokenpike.github`). Not confirmed.
- **Proposed fix, independent of who counts as a member:** give `*:*` to
  `brokenpike@github` explicitly instead of `autogroup:member`; guests
  (`group:guests`) get `hn7306:8443` and `nixoshpe:8920`; vegtamr-no also
  `hn7306:22`. `ssh` rules: owner to own devices as non-root only (no root,
  use sudo), vegtamr-no to `scott`, both in check mode. The `tests` block
  checks every guest's allowed and denied ports. **Not saved yet on
  2026-10-13:** hn7306's netmap still had `root` in the SSH rules and no
  port 22 rule for vegtamr-no; the saved version still gives
  `autogroup:member` `*:*` and had Thor's test removed. Check with
  `tailscale debug netmap` (`SSHPolicy`, `PacketFilter`).

## USB-C networking between laptops needs a USB4 cable (2026-10-12)

hn7306 has two USB4 controllers and the `thunderbolt_net` driver: a USB4 or
Thunderbolt cable to another USB4 laptop (phoenix's USB4 ports) gives a
`thunderbolt0` network link that `ipv4.method shared` can share, like the
hotspot (its firewall would need DHCP/DNS on `thunderbolt0` too). The
available cables are charging-only: nothing appeared in
`/sys/bus/thunderbolt/devices/`. Use the Wi-Fi hotspot until a "Thunderbolt
4" / "USB4 40Gbps" cable exists. For speed it only matters if the other
laptop's own link is slow: hn7306 measured 290 Mbit/s, the Latitude ~90.

## Visure VMs copied to phoenix (2026-10-12)

Both quickemu VMs were copied to phoenix `~/vms` (originals still in
`/scratch/visure-clones` on hn7306). `qemu-img convert -O qcow2` made each
disk self-contained: visure8305587 was an overlay on
`/scratch/visure-golden-v2/windows-11/disk.qcow2` (now flattened, 35.9
GiB), visure8405817 lost two old internal snapshots (`pre-virtio-scsi-fix`,
77 -> 44.7 GiB). Also copied: `OVMF_VARS.fd`, `tpm2-00.permall` (TPM
state), the `.conf`. Transport: the USB SSD stick at `/mnt/llms` (btrfs,
~460 MB/s, faster than gigabit rsync); on phoenix it was only detected on
the USB-A port of the Ethernet adapter. On phoenix: `ram="10G"`,
`cpu_cores="4"` (38 GiB, 6 cores), one VM at a time; visure8305587 got
`ssh_port="25587"`.

- **SSH from hn7306:** `~/.ssh/config` alias `v5587` (ProxyJump
  scott@phoenix, port 25587, `HostKeyAlias v5587`); phoenix answers with
  Tailscale SSH. `v5817` still points at hn7306's localhost:25817.
- **Vivia in the VM** (`vivia.exe` on 127.0.0.1:8000) can use hn7306's model:
  base URL `https://hn7306.heron-pickerel.ts.net/v1`, model `qwen3.6-35b`,
  any API key. Tested from inside the VM; tailnet DNS works through
  quickemu's NAT, no hosts entry needed. The first request after 30 idle
  minutes waits for the model to load.
- **Cloudflare tunnels run inside the VMs** (`cloudflared` with
  `C:\Users\Quickemu\.cloudflared\config.yml`): v5817 for visure8405817,
  `v5587` and `vivia-v5587.vegtamr.online` for visure8305587. Error 1033
  (HTTP 530) means no connector: either the VM is off or `cloudflared` is
  stuck (`/ready` on 127.0.0.1:20241 returned 503, no connections, although
  TCP 7844 to the edge was open). Fix proposed: `protocol: http2` in
  `config.yml` and a Windows service (`New-Service … tunnel run`) instead of
  a process started by hand, which also dies with the SSH session that
  started it. The VM's clock ran an hour ahead (time zone +01:00 without
  DST): `Set-TimeZone -Id "W. Europe Standard Time"`.
- **Original and copy share the tunnel credentials.** If both run
  `cloudflared`, Cloudflare spreads requests over two VMs with separate
  databases. Only one copy may run the tunnel. Which copy is the live one,
  and whether the originals on hn7306 are kept, was not decided when this was
  written.

**v5587 tunnel back (2026-10-13):** after the fix in the VM,
`v5587.vegtamr.online` and `/VisureAuthoring8/` answer 200 through
Cloudflare, and `vivia-v5587.vegtamr.online` reaches Vivia (FastAPI:
`/health`, `/docs` and `/openapi.json` 200, 404 at `/`). Vivia's `/docs` is
public on the internet with no login in front; Cloudflare Access on that
hostname would add one. `v5817` stays 530 while visure8405817 is off.

## llama-swap: llama-server output in the journal (2026-10-13)

The GPU check in AGENTS.md (`journalctl -u llama-swap | grep -E
'ggml_vulkan|offloaded'`) found nothing: llama-swap's `logToStdout`
defaults to `proxy`, which sends only its own request lines to stdout (and
so to the journal); llama-server's output stayed in llama-swap's internal
log (`/logs` shows the proxy part only). Set to `both` in
hosts/hn7306/llama-swap.nix. Takes effect on llama-swap's restart, i.e.
after the next switch, for models loaded after it.

Even with `both`, llama.cpp 0.6.0 (verbosity 3) prints no device or
`offloaded … layers` lines any more, so that check stays empty. GPU use is
shown instead by GTT memory (`mem_info_gtt_used` 23.8 GiB with Coder Q4
loaded) and the timings in the journal (Coder: 52 tokens/s generation and
700-1,200 tokens/s prompt processing on a 12.8K-token prompt). AGENTS.md
now uses that check.

**Update (2026-10-14): it works with a Deltaco USBC-1122** (1 m,
full-featured USB-C, USB 3.2 Gen 2 10 Gbit/s, e-marker; not a certified USB4
cable). hn7306 saw phoenix as `1-2` ("Linux phoenix"), link 2 x 10 Gbit/s =
20 Gbit/s, `thunderbolt0` up. NetworkManager gives both ends link-local
addresses by itself (hn7306 169.254.122.129 and fe80::…; phoenix
fe80::f565:9a19:379e:c01a), so no shared mode is needed just to copy
files: `rsync … 'scott@[fe80::…%thunderbolt0]:'`. OpenSSH answers there,
not Tailscale SSH, so phoenix needs hn7306's key in
`users.users.scott.openssh.authorizedKeys.keys` (now in
hosts/phoenix/default.nix); before that it had none, as every earlier login
went through Tailscale SSH. Use `-o HostKeyAlias=phoenix` so the known host
key matches.

## Translation models in llama-swap (2026-10-14)

Three small models for English <-> Norwegian, in llama-swap group
`translate` (`swap = true`: one at a time; `exclusive = false`: loading one
leaves the Qwen pair loaded, about 65 + at most 13 GiB). Loading a Qwen model
or DeepSeek unloads it (their groups are exclusive). All Q8_0: small dense
models lose more to quantization than the big MoEs, and Q8_0 is fast on
Vulkan (BF16 is not supported there). 16K context, one slot.

| Model ID | Source | Notes |
|---|---|---|
| `normistral-11b-translate` | ltg/normistral-11b-translate (University of Oslo), converted to GGUF | Fine-tuned for nb/nn/en in all directions. System message = target language: `bokmål`, `nynorsk` or `engelsk` (default); user message = text. Greedy (`--temp 0`). |
| `gemma-4-e4b` | unsloth/gemma-4-E4B-it-GGUF Q8_0 | General model, strong in Nordic languages; `--reasoning off`. ~35 tokens/s. |
| `translategemma-4b` | mradermacher/translategemma-4b-it-GGUF Q8_0 | Google's translation model; its template lists nb, nn, no. ~44 tokens/s. |

**TranslateGemma's template** only accepts structured user content
(`[{type, source_lang_code, target_lang_code, text}]`) and raises an error on
plain text, which Open WebUI sends. llama-swap.nix passes a plain Gemma
template (`--chat-template-file`, written with `pkgs.writeText`). The prompt
then carries the instruction; TranslateGemma's own wording works well:

    You are a professional English (en) to Norwegian Bokmål (nb) translator.
    Produce only the Norwegian Bokmål translation, without any additional
    explanations or commentary. Please translate the following English text
    into Norwegian Bokmål:

    <text>

**NorMistral conversion** (only safetensors on Hugging Face): llama.cpp's
`convert_hf_to_gguf.py` from the same source as the installed llama.cpp
0.6.0 (`pkgs.llama-cpp.src`), run with a `python3.withPackages` env (numpy,
sentencepiece, safetensors, transformers, torch, protobuf) from the pinned
nixpkgs, `PYTHONPATH=$src/gguf-py:$src`, `--outtype q8_0` directly (no
intermediate F16 file). Architecture `MistralForCausalLM`. Two fixes were needed:

- The repo has two chat templates: the real one in `chat_template.jinja`
  (`<s><source> {text}</source>\n\n## {target}:\n<target>`) and a stale
  one in `tokenizer_config.json` (`<instruction>`, `<system_prompt>`).
  transformers 5.17 also adds four tokens (ids 51200-51203,
  `<instruction>`, `</instruction>`, `<system_prompt>`,
  `</system_prompt>`) above the model's `vocab_size` 51200, which trips
  the converter's `assert max(tokenizer.vocab.values()) < vocab_size`.
  Fix: a folder `hf-fixed` with symlinks to the model files and a copy of
  `tokenizer_config.json` whose `chat_template` is `chat_template.jinja`;
  plus a scratch copy of the converter with that assert removed (ids at or
  above 51200 are skipped anyway, and the translation template never uses
  those tags).
- The pre-tokenizer hash is unknown to llama.cpp. ltg's own GGUF of
  normistral-11b-thinking uses `tokenizer.ggml.model = gpt2`,
  `tokenizer.ggml.pre = tekken` (Mistral NeMo's), so the scratch copy
  defaults to `tekken`. Confirmed by the output: bokmål -> nynorsk gives
  exactly the model card's example, "Kva er hovudstaden i Noreg?".

Result: 12.1 GB Q8_0, 16 tokens/s (dense 11B; Q6_K would be ~25% faster).
The repo also ships `pytorch_model.bin` (22.9 GB, same weights), which
the converter does not use. The originals (`hf`, 43 GB) and `hf-fixed` were
deleted after the test; another quantization (e.g. Q6_K) means downloading
the safetensors again and repeating both fixes.

Test sentence ("The requirement must be traceable to at least one test case,
and every change has to be approved by the project owner before release."):
TranslateGemma "Kravet må kunne spores tilbake til minst ett testtilfelle, og
hver endring må godkjennes av prosjektansvarlig før den blir publisert.";
Gemma 4 E4B "Kravet må spores til minst ett testtilfelle, og enhver endring
må godkjennes av prosjekteieren før utgivelse."

## Stay awake on mains power, suspend on battery (2026-10-14)

Goal: both laptops answer over the tailnet (Hermes, Open WebUI, llama-swap,
SSH, phoenix's VMs and their tunnels) while on mains power, and save power
on battery. A suspended machine is offline, Tailscale included, and
Wake-on-LAN would need the wired dock plus someone to send the packet, so
"low power" means awake with the screen off.

Found: phoenix had GNOME's defaults (suspend after 900 s, also on mains
power) and suspended twice on 2026-10-14 (13:07-13:16, 13:42-14:01), which
is when SSH to it timed out. hn7306 had "nothing" on mains power, set by
hand, outside Nix. Closing the lid on mains power suspended both (logind
default), and the login screen (GDM's own settings daemon) suspends after
15 minutes on mains power, so after a reboot a machine dropped off the
tailnet until someone logged in.

Now, shared by both hosts:

- configuration.nix "Power": logind `HandleLidSwitchExternalPower` and
  `HandleLidSwitchDocked` = ignore, `HandleLidSwitch` = suspend (battery);
  a dconf database in `programs.dconf.profiles.gdm` with
  `sleep-inactive-ac-type = nothing` for the login screen.
- home.nix `dconf.settings`: mains power never suspends, battery suspends
  after 1800 s, screen off after 600 s (`idle-delay`, a uint32, hence
  `lib.hm.gvariant.mkUint32`).
- Power profile: both were on `performance`. `balanced` is set once per
  machine (`powerprofilesctl set balanced`; power-profiles-daemon keeps
  it). The models run on the GPU, so the CPU profile barely affects them.

Reading GNOME settings over SSH: `gsettings` finds no schemas outside a
desktop session on NixOS; `dconf read /org/gnome/...` with
`DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus` shows stored
values (empty = GNOME default).

## libvirtd fails on phoenix: secrets key sealed to a reset TPM (2026-10-14)

**Symptom:** after the rebuild with the 2026-10-13 flake update, phoenix had
a failed `libvirtd.service`:

    TPM key integrity check failed. Key most likely does not belong to this TPM.
    Failed to set up credentials: Object is remote

**Cause:** libvirt's unit loads `/var/lib/libvirt/secrets/secrets-encryption-key`
with `LoadCredentialEncrypted`, and that key is sealed to the TPM. It was
created on 2026-03-11 (when the host was still called `framework`). Later a
BIOS upgrade on phoenix went wrong and needed the battery removed to
recover, which reset the TPM, so the old key can no longer be decrypted.
It went unnoticed for months because libvirtd had not been started since
2026-03-25; the libvirt upgrade in the flake update started it.
`virt-secret-init-encryption.service`, which creates the key, skips itself
while the old file exists ("start condition unmet").

**Fix:** move the key aside and let a new one be created for the current TPM:

    sudo mv /var/lib/libvirt/secrets/secrets-encryption-key \
            /var/lib/libvirt/secrets/secrets-encryption-key.old-tpm
    sudo systemctl start virt-secret-init-encryption libvirtd

Nothing was lost: the folder held only the key, no stored libvirt secrets.
Only the system libvirt (`qemu:///system`, virt-manager) was affected;
quickemu runs QEMU directly and GNOME Boxes uses the user session.

**Expect it again** on either laptop after anything that resets the TPM
(firmware update gone wrong, TPM cleared in the BIOS, battery or CMOS
removed). Other TPM-sealed things would fail the same way, e.g. a
TPM-unlocked LUKS volume or other `systemd-creds` secrets.

**Lid still suspended phoenix after the switch (same day):** closing the lid
on mains power suspended it (`systemd-logind: Lid closed. Suspending...`).
Not GNOME (no lid inhibitor held); the running logind still had the old
values (`busctl get-property org.freedesktop.login1 /org/freedesktop/login1
org.freedesktop.login1.Manager HandleLidSwitchExternalPower` returned `""`)
although `/etc/systemd/logind.conf` had `ignore`. `nixos-rebuild switch` does
not restart systemd-logind (a restart could end sessions), so **after any
logind change: `sudo systemctl kill -s HUP systemd-logind` (reload) or
reboot**, then check with the `busctl` line. hn7306 stayed awake only
because it was docked (external monitor, `HandleLidSwitchDocked=ignore`).
Confirmed on phoenix after the HUP: running value `ignore`, lid closed at
14:57 on mains power, "Lid closed" logged without a suspend, SSH answered.

**Laptop behaviour on battery (same day):** idle suspend on battery back to
GNOME's 15 minutes (was 30), and the power profile now follows the charger:
a udev rule on the ACPI adapter (`type == Mains`: `AC0` on hn7306, `ACAD` on
phoenix; the USB-C `ucsi-source-psy-*` supplies are type `USB` and change
with any phone, so they are not matched) starts `power-profile@power-saver`
when it goes offline and `power-profile@balanced` when it comes back. The
template service runs `powerprofilesctl set %i`; udev only starts it
(`systemctl start --no-block`) instead of calling the daemon itself. Booting
on battery fires no change event; power-profiles-daemon then keeps the last
profile. Check with `powerprofilesctl get` after unplugging and plugging in.

**Two more translation models (2026-10-15)**, also in group `translate`, Q8_0:

| Model ID | Source | Notes |
|---|---|---|
| `eurollm-9b` | mradermacher/EuroLLM-9B-Instruct-2512-GGUF (utter-project, Dec 2025 release; the original 2024 EuroLLM-9B-Instruct is older) | Chat model trained on the EU languages plus Norwegian; its own ChatML template. 9.7 GB. |
| `seed-x-ppo-7b` | mradermacher/Seed-X-PPO-7B-GGUF (ByteDance; PPO is the variant they recommend over Instruct) | Translation only, 28 languages incl. `nb` and `no`. 7.9 GB. |

**Seed-X has no chat template** and is trained on bare prompts that end in
a target-language tag, which is required:

    Translate the following English sentence into Norwegian Bokmal:
    <text> <nb>

ByteDance advises against multi-turn input and against unofficial
quantizations (Q8_0 is as close to the original as GGUF gets).
llama-swap.nix passes a template (`seedxTemplate`) that sends only the last
user message, unchanged, after the BOS token, so it works from Open WebUI
as long as the prompt itself has that shape.

**Not NLLB-200 (decided 2026-10-15).** Considered for the Japanese ->
Norwegian subtitle work and rejected: it is an encoder-decoder model
(M2M100) that llama.cpp cannot run (Python/CTranslate2 only, outside
llama-swap and Open WebUI), it translates strictly sentence by sentence
without context, it is weaker on colloquial dialogue, and its license
(CC-BY-NC 4.0) forbids commercial use. The LLMs above cover ja -> nb.

## Japanese audio -> Norwegian subtitles (2026-10-15)

Two steps: speech recognition to a Japanese .srt, then translation.

**1. Speech:** `whisperVulkan` in home.nix (`pkgs.whisper-cpp` with
`rocmSupport = false; vulkanSupport = true`, from the binary cache; the
global rocmSupport would otherwise add ROCm). Models in
/scratch/models/whisper: `ggml-large-v3.bin` (3.1 GB, best for Japanese;
large-v3-turbo is faster but weaker) and the Silero VAD
`ggml-silero-v6.2.0.bin`, which keeps Whisper from inventing text during
silence or music. Whisper itself only translates into English.

    ffmpeg -i video.mkv -vn -ac 1 -ar 16000 audio.wav
    whisper-cli -m /scratch/models/whisper/ggml-large-v3.bin -l ja \
      --vad --vad-model /scratch/models/whisper/ggml-silero-v6.2.0.bin \
      -osrt -of video.ja -f audio.wav

**2. Translation:** `srt-translate` (scripts/srt-translate.py, standard
library only, built with `pkgs.writers.writePython3Bin`; the server URL and
default model are substituted from `local.llm` at build time). It sends
40 subtitles per request with the previous 6 as context, takes numbers and
timestamps from the input only, retries an incomplete chunk in halves, and
wraps lines over 42 characters into two. `--via-english` goes source ->
English with `--model`, then English -> target line by line with
NorMistral (system message = target language).

    srt-translate video.ja.srt                 # -> video.nb.srt, Qwen3.6 direct
    srt-translate video.ja.srt --via-english   # Qwen3.6 -> English -> NorMistral

**Test (5 lines of dialogue, 2026-10-15):** direct Qwen3.6 got 昨日の会議
wrong ("dagens møte" instead of yesterday's) and phrased one line clumsily;
via English was correct and more natural ("møtematerialet fra i går",
"Jeg tar deg igjen snart", "i morges"), 9 s. Single sentences ja -> nb:
EuroLLM-9B natural on dialogue ("Vent litt, jeg er ikke klar enda. Gå du
først.") but one gender slip ("Denne kravet"); Seed-X-PPO weak in Norwegian
("Venteilen en lite", Danish-sounding "frigives"), maybe the unofficial
quantization ByteDance warns about. Default recommendation: --via-english.

## Flake update 2026-10-19

nixpkgs 2026-10-11 -> 2026-10-15, hermes-agent 6e7b83a -> 5fc490e,
home-manager, nixpkgs-stable, Determinate. Restore point: tag
`backup/pre-update-2026-10-19`. Done after first switching to the then
current config, so the update was the only change in its switch.

- **Kernel 7.2.9 -> 7.2.10** (reboot), **Mesa 26.2.4 -> 26.2.5**, ROCm clr
  7.2.3 -> 7.2.4, Ollama 0.40.3; llama.cpp 0.6.0 and whisper-cpp 1.9.5
  unchanged.
- **llama-swap 249 -> 262.** No breaking config change (`logToStdout` now
  also takes a comma list; `both` still valid). The NixOS module now runs
  `llama-swap -config … -validate` while building
  (`llama-swap-validated-config.yaml`), so a broken config fails the build
  instead of the service. Checked before switching: "config is valid: 8
  model(s)".
- **Open WebUI 0.11.4 -> 0.12.2**, with database migrations; backed up first
  (`systemctl stop open-webui`, `cp -a /var/lib/private/open-webui
  /scratch/backup/open-webui-2026-10-19`). Chats kept.
- Hermes used a tool after the update.

Benchmark after the switch (Qwen3.6 Q8, llama-bench, tokens/s; 9 Oct in
brackets): Vulkan pp2048 1205 (1239), tg128 45.9 (45.7), pp@32K 646 (671),
tg@32K 39.1 (39.4); ROCm 1059 (1104), 41.6 (42.5), 667 (688), 36.5 (37.1).
Within noise (llama-swap served 13 requests during the run); Vulkan stays.

## Third host: gz302, ASUS ROG Flow Z13 (2026-10-22)

ASUS ROG Flow Z13 GZ302EA: the same Strix Halo chip as hn7306 (Ryzen AI MAX+
395, Radeon 8060S), 128 GB, of which Linux sees about 121 GiB (hn7306: 124).
A tablet with a detachable Norwegian keyboard. Installed from the NixOS 26.05
ISO, dual-boot with Windows, one 954 GB NVMe: btrfs subvolumes `@`, `@home`,
`@nix`, `@log`, `@swap` on nvme0n1p7, its own ESP (450 MB) at nvme0n1p1.

- **Lean to start:** `hosts/gz302/` has the hardware config, a copy of
  hn7306's `strix-halo.nix` and nothing else: no llama-swap, Ollama, Open
  WebUI or Hermes, and `local.llm.model` stays null, so OpenCode is not
  configured. Add those from `hosts/hn7306/` when models are on disk; there
  is no /scratch disk, so they would go on the root btrfs.
- **No nixos-hardware profile** for the GZ302 exists (only the GV302X and
  GZ301VU Flows). The host imports the generic modules the Flow profiles are
  built from: `common-cpu-amd`, `common-cpu-amd-pstate`, `common-gpu-amd`,
  `common-pc-laptop`, `common-pc-ssd`, plus `hardware.sensor.iio` for screen
  rotation. Not supergfxd: there is no discrete GPU.
- **Not copied from hn7306:** `amd_iommu=off` (a performance workaround there;
  try it here only if the same problem appears), the hotspot firewall rule
  and Tailscale SSH.
- **The ttm cap is the same 104 GiB.** It is a ceiling, so it does nothing
  until a model needs it; with 121 GiB visible it leaves about 17 GiB for the
  host.
- **Btrfs mount options:** the installer mounted the subvolumes without
  options, so `/`, `/home` and `/nix` get `compress=zstd:3,noatime` in
  `hosts/gz302/default.nix`. Existing files stay uncompressed until rewritten.
  The `@swap` subvolume is mounted but holds no swap file; zram is the swap.
- **`system.stateVersion` moved to each host.** It was 25.11 in
  configuration.nix for every host; gz302 was installed with 26.05. hn7306 and
  phoenix keep 25.11. Checked: both evaluate to the same toplevel derivation
  as before the move.
- **Windows boot entry:** Windows has its own ESP (nvme0n1p6), so systemd-boot
  on nvme0n1p1 does not list it. Use the firmware boot menu, or add an entry
  later.
- **Charge limit 80%** (added after the first boot, which showed 100):
  `hardware.asus.battery.chargeUpto = 80` from nixos-hardware's
  `asus-battery` module, imported on its own because no profile brings it.
  asusd keeps its own limit as state in `/etc/asusd/asusd.ron`; set it to 80
  too (`asusctl battery limit 80`) so the two never fight, as on hn7306.

## gz302 becomes the home LLM server (2026-10-22)

gz302 will do little else, so it serves Hermes, OpenCode and Open WebUI on
the tailnet. hn7306 keeps its own llama-swap and Hermes for now (two separate
assistants with separate memories) until the user decides otherwise.

- **The Qwen pair, not one big MoE.** Considered: DeepSeek V4 Flash for
  everything. Rejected for now: at 2-bit (85 GiB) it leaves room for one 64K
  slot, so Hermes, OpenCode and Open WebUI would queue; it is several times
  slower per token than the 3B-active Qwen models, which matters most for the
  10-20K-token prompts agents send; and nobody has measured its 2-bit quality
  or speed here. Without VMs on gz302 it can be tried there freely later.
- **Same files as hn7306** (Qwen3.6 UD-Q8_K_XL + mmproj, Coder UD-Q4_K_XL),
  so hn7306's benchmarks apply and the files can be copied over the tailnet
  instead of downloaded. Stored in `/srv/models` (root btrfs; created by
  tmpfiles, owned by scott, world-readable for llama-swap's DynamicUser).
- **Loaded at boot, never unloaded:** `hooks.on_startup.preload` (llama-swap
  262) and no `ttl`. hn7306 unloads after 30 minutes to make room for VMs;
  gz302 has nothing else to make room for.
- **Open WebUI** on `https://gz302.heron-pickerel.ts.net:8443` via
  `tailscale serve`, no guests in the tailnet policy yet.

## gz302 was held at 15 W by Armoury Crate's saved mode (2026-10-22)

**Symptom:** with the Qwen pair loaded (64.5 GB GTT, so on the GPU), gz302
generates 14 tokens/s on qwen3.6-35b and 24 on qwen3-coder-30b; hn7306 does
about 45 and 52 with the same files and settings.

**Measured** (`nix run nixpkgs#amdgpu_top -- --gpu_metrics` during a
request): socket power pinned at 15.0 W, `current_gfx_maxfreq` 600 MHz (range
600-2900), `current_core_maxfreq` ~1550 MHz (`scaling_max_freq` 3.0 GHz of
5.19), uclk ~550 MHz, fclk ~650 MHz; `throttle_residency_spl`, `_sppt` and
`_fppt` counting, no thermal throttling (GPU 42 °C). Generation is
memory-bound, so the low uclk is what halves the speed.

**Ruled out, one at a time, all still 15 W:**
- platform profile `balanced` vs `performance` (both `asus-wmi` and
  `amd-pmf` registered as profile handlers; both followed);
- the power source: the Dell WD19S dock (USB-C PD, ~90 W), the battery and
  the ASUS charger alone (it feeds `AC0`, not a USB-C port) all give 15 W;
- rewriting the asus-armoury limits (`ppt_pl1_spl` 60, `ppt_pl2_sppt` 75,
  `ppt_pl3_fppt` 86, their defaults) via sysfs;
- unloading `amd_pmf` (and `amdxdna`, which depends on it), then switching
  profile and rewriting the asus-armoury limits again;
- `ryzenadj` 0.19.0 (supports Strix Halo; `--info` cannot read the metrics
  table without /dev/mem access) setting stapm/slow/fast to 60/75/86 W: it
  reported success and nothing changed.

The IOMMU is not involved: the GPU's group is already `identity`.
`amd_iommu=off` (hn7306) was not tried; it cannot explain a power cap.

**Cause and fix:** Armoury Crate (Windows) stores its operating mode in the
embedded controller, and the mode survives reboots and switching OS. A
power-saving mode left set in Windows capped the SoC at 15 W below
everything Linux can set; the asus-armoury values (60/75/86) and the
platform profile looked normal throughout. Setting **Turbo** in Armoury
Crate and booting back into NixOS fixed it with no change on the Linux side
(same BIOS GZ302EA.314, `amd_pmf` loaded, profile `balanced`):
qwen3.6-35b 40.5 tokens/s, qwen3-coder-30b 69 tokens/s, 45 W socket power,
gfxclk ~2180 MHz, uclk ~1000 MHz.

**If it comes back** (speed halves, socket power stuck at exactly 15.0 W in
`amdgpu_top --gpu_metrics` during a request): boot Windows, set Armoury
Crate to Turbo (or Performance), boot back. Do not chase it in Linux first;
nothing there reaches this limit. Anything in Windows that switches Armoury
Crate to Silent, e.g. its own battery rules, can bring it back.

**Profile on the Dell dock (measured after the fix):** keep `balanced`. On
the WD19S alone (USB-C PD, ~90 W) `balanced` draws ~45 W and gives
qwen3.6-35b 41.7 / qwen3-coder-30b 66.8 tokens/s generating, Coder 588
tokens/s reading a 12K prompt (Qwen3.6 892); the battery holds. `performance`
draws ~81 W: the battery discharges (~77 W) and `prochot` throttling kicks in,
so generation drops to 33-38 / 51-61 tokens/s; only Coder's prompt reading
gains (680). Same speeds on the dock as on the ASUS charger in `balanced`.

## Tailscale 1.104.2 ahead of nixpkgs; PHP2Shell; Tailworm (2026-10-26)

Three security items on the same day:

- **TS-2026-013** (Tailscale, 2026-10-21): compromised eMudhra intermediate
  certificates; fixed in 1.104.2. All hosts had 1.104.1.
- **PHP2Shell** (CVE-2026-109618/109619, 2026-10-21, CVSS 9.2,
  unauthenticated RCE, exploited from 2026-10-17): fixed in PHP 8.4.27.
  Only nixoshpe runs PHP (Nextcloud, 8.4.26); handled in nix-hpe. Follow-up
  CVE-2026-115560 has no fix yet; workaround `session.upload_progress` off.
- **"Tailworm"** (2026-10-25): 11 unpatched flaws published by a researcher,
  mainly Tailscale SSH (port forwarding can end up as root), also in 1.104.2.
  Needs control of a device the policy lets SSH in, i.e. one of the
  owner's own devices here. No bulletin or fix yet. Plan: OpenSSH keys for
  hn7306 and gz302 first, then `--ssh=false` (removing `--ssh` would not
  reset the setting; phoenix and gz302 had it on by hand).

**Why Tailscale comes from a second nixpkgs:** `nix flake update` to
nixpkgs 3ec6363 (2026-10-23) failed to evaluate: python `posthog` is marked
broken (`lib.versionAtLeast mcp.version "2"`), `chromadb` needs it and Open
WebUI needs chromadb; master was the same. Taking Open WebUI from the old
nixpkgs instead evaluated, but the update would also bring kernel 7.3,
compiled locally (the PX13 profile patches it again), plus onnxruntime:
hours of building and a kernel jump in the middle of a security fix. So the
main nixpkgs stays at fe13242 (2026-10-15), and a temporary input
`nixpkgs-tailscale` (nixos-unstable, locked at 3ec6363) supplies
`services.tailscale.package` for all hosts. Remove both after the next full
update, once posthog/chromadb work again.

## OpenSSH keys as a backup to Tailscale SSH (2026-10-26)

Decision: Tailscale SSH stays the main way in, despite "Tailworm" (its
flaws need control of a device the policy already lets SSH in). OpenSSH
keys are the backup for logins over the LAN or the USB4 cable, where
Tailscale SSH (which answers port 22 on the tailnet only) is not involved.
Before this, hn7306 and gz302 accepted no keys at all, only the password.

`users.users.scott.openssh.authorizedKeys.keys` in configuration.nix now
holds the keys of hn7306 and gz302 for every host in this repo (phoenix's
own block, hn7306's key only, was folded into it). nixoshpe gets the same
two in nix-hpe. phoenix's own key follows once it is reachable again.
Password login stays on as the last resort for now.

Test over the LAN (Tailscale SSH not involved), e.g. from hn7306:
`ssh -o HostKeyAlias=gz302 scott@<gz302 LAN address>`; it must log in
without asking for a password.

**gz302 follow-up (2026-10-26):** Open WebUI was still in onboarding (no
admin account; the first visitor would have become admin). The account was
created, Open WebUI turned sign-up off itself, and `ENABLE_SIGNUP` in
hosts/gz302/open-webui.nix now says "False" to match (it only seeds a fresh
install). Tailscale SSH, on by hand until now, is declared in
hosts/gz302/default.nix (`--ssh`), as on hn7306. Still open: phoenix and
the Visure VMs (Vivia) pointing at gz302 instead of hn7306, guests moved to
gz302, translation models and Whisper there, and backups of Hermes and Open
WebUI state.

**Qwen3.8-Flash-Next on gz302 (2026-10-27):** the strongest open model that
fits under the 104 GiB cap (179B incl. a 51B n-gram embedding, 6B active);
Kimi K3, GLM-5.2, DeepSeek V4.1 Flash and MiMo Pro need 200+ GiB even at
1-2 bit. UD-IQ4_XS (87 GiB, three split files) chosen over UD-Q3_K_XL: the
3-bit quality loss costs more than the 3 GiB it saves. First run, 64K
context, Vulkan: 23.6 tokens/s generation (Qwen3.6 Q8: 46). Only 60 GiB
shows in GTT; the other 27 GiB is the n-gram embedding, which llama.cpp keeps
on the CPU like every input embedding (anonymous memory of llama-server), so
low GTT is expected for this model and not a CPU fallback. With it loaded,
gz302 used 94 of 121 GiB RAM: room for more context, not for the Qwen pair
next to it. gz302 also has a 4 GiB VRAM carve-out in firmware; hn7306 has
none.
