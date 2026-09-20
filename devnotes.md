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
