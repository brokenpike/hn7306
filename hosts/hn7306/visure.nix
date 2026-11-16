# Visure X from the vendor's air-gapped bundle (Docker Compose), for testing
# on this machine. The bundle and its scripts stay the source of truth for the
# stack and its upgrades; Nix pins which bundle runs (version + sha256), the
# container engine, the domain, the ports and the host names, and wraps the
# vendor's install and upgrade steps in one command, `sudo visure`.
# See devnotes.md, "Visure X on Docker Compose" and "Visure X on Podman".
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # A new bundle: put the tar in /scratch/iso, change these two lines
  # (sha256sum of the whole tar), rebuild, then `sudo visure upgrade`.
  bundle = {
    version = "dev-test-22";
    sha256 = "67a2d5ed671677ce0cfee3be170c0797f4ce8946a58aed91c01d16a6be2853ad";
  };
  tarball = "/scratch/iso/visure-x-airgap-${bundle.version}.tar";

  # "podman" (rootful, behind its Docker-compatible socket) or "docker", the
  # engine the vendor supports. Switching keeps nothing: the images and the
  # data volumes live in each engine's own storage.
  engine = "podman";
  podman = engine == "podman";

  # One directory per unpacked bundle; `current` points at the one that runs,
  # `previous` at the one before the last upgrade. Root has little free space.
  root = "/scratch/visure";
  domain = "visurecloud.local";
  # 8443 is taken on tailscale0 by `tailscale serve` (Open WebUI).
  httpPort = 8082;
  httpsPort = 9443;
  # What the compose file publishes without an address: nginx, the S3 API of
  # SeaweedFS (9010) and Grafana (3100, observability profile only).
  publicPorts = [
    httpPort
    httpsPort
    9010
    3100
  ];
  # No wildcard in /etc/hosts: one name per tenant.
  tenants = [
    "administration"
    "t1"
    "t2"
    "t3"
  ];

  # The vendor scripts call `docker` and `docker compose`. With Podman they
  # get the real Docker CLI, talking to Podman's socket at /run/docker.sock.
  dockerCli = if podman then pkgs.docker-client else config.virtualisation.docker.package;
  engineUnit = if podman then "podman.socket" else "docker.service";

  # Podman answers the vendor scripts in two ways they reject, though the
  # result is right (tested with Podman 6.1.4, devnotes.md):
  #  - its version (6.x) fails prerequisites.sh's "Docker Engine >= 24";
  #    its API level, 1.44, is Docker Engine 25's, which is reported instead;
  #  - `load` prints `Loaded image: localhost/mongo:7.0`, every image of a
  #    multi-image archive on one line separated by commas, with no newline,
  #    where load-images.sh looks for one `Loaded image: mongo:7.0` per line.
  # One thing in the bundle itself needs Docker: nginx resolves the service
  # names at each request through `resolver 127.0.0.11`, Docker's embedded
  # DNS. Podman has none there (aardvark-dns listens on the network's
  # gateway), so every request hung. `compose` gets an override that mounts
  # a copy of nginx.compose.conf with the resolver the nginx image reads
  # from the container's /etc/resolv.conf; the bundle's files stay as
  # shipped, since SHA256SUMS covers them.
  # Everything else goes to the Docker CLI unchanged.
  nginxOverride = pkgs.writeText "visure-podman-nginx.yml" ''
    services:
      nginx:
        volumes:
          - ''${VISURE_PODMAN_NGINX_CONF}:/etc/nginx/templates/nginx.conf.template:ro
        environment:
          - NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1
          - NGINX_ENVSUBST_FILTER=^(VISURE_(DOMAIN|HTTPS_PORT)|NGINX_LOCAL_RESOLVERS)
  '';

  dockerShim = pkgs.writeShellApplication {
    name = "docker";
    runtimeInputs = [
      dockerCli
    ]
    ++ (with pkgs; [
      coreutils
      diffutils
      gnugrep
      gnused
    ]);
    text = ''
      real=${lib.getExe' dockerCli "docker"}
      if [[ ''${1:-} == version && $* == *'{{.Server.Version}}'* ]]; then
        # No answer from Podman stays an empty answer, as prerequisites.sh expects.
        v="$("$real" version --format '{{.Server.Version}}')" || exit 1
        echo "25.0.0+podman.$v"
      elif [[ ''${1:-} == compose ]]; then
        # After the bundle's compose file, add the override that points
        # nginx at Podman's DNS server (see nginxOverride).
        args=("$@")
        for ((i = 1; i < ''${#args[@]}; i++)); do
          if [[ ''${args[i - 1]} == -f && ''${args[i]} == */docker-compose.yml ]]; then
            infra="$(cd "$(dirname "''${args[i]}")" && pwd)"
            conf="$(dirname "$infra")/.podman-nginx.compose.conf"
            # A literal ''${NGINX_LOCAL_RESOLVERS}, for the nginx image's envsubst.
            # shellcheck disable=SC2016
            resolver='resolver ''${NGINX_LOCAL_RESOLVERS} '
            sed "s/resolver 127\.0\.0\.11 /$resolver/" \
              "$infra/nginx/nginx.compose.conf" > "$conf.new"
            grep -qF "$resolver" "$conf.new" || {
              echo "docker (visure shim): $infra/nginx/nginx.compose.conf has no 'resolver 127.0.0.11' line any more; update visure.nix" >&2
              exit 1
            }
            if cmp -s "$conf.new" "$conf"; then rm "$conf.new"; else mv "$conf.new" "$conf"; fi
            export VISURE_PODMAN_NGINX_CONF="$conf"
            args=("''${args[@]:0:i+1}" -f ${nginxOverride} "''${args[@]:i+1}")
            break
          fi
        done
        exec "$real" "''${args[@]}"
      elif [[ ''${1:-} == load ]]; then
        "$real" "$@" | sed -u -e 's/\(.\)Loaded image: /\1\nLoaded image: /g' \
          -e '/Loaded image: /s/,/\nLoaded image: /g' \
          -e 's#Loaded image: \(localhost\|docker\.io/library\|docker\.io\)/#Loaded image: #g'
        echo
      else
        exec "$real" "$@"
      fi
    '';
  };

  visure = pkgs.writeShellApplication {
    name = "visure";
    # The vendor scripts run with this PATH too, so their tools are pinned.
    runtimeInputs =
      lib.optional podman dockerShim
      ++ [ dockerCli ]
      ++ (with pkgs; [
        bash # systemd gives the service no PATH; the vendor scripts are run with bash
        coreutils
        curl
        findutils
        gawk
        gnugrep
        gnused
        gnutar
        gzip
        iproute2
        lsof
        openssl
        perl # shasum, which the vendor scripts prefer over sha256sum
        systemd
      ]);
    text = ''
      ${lib.optionalString podman ''
        # Podman's own socket, not /run/docker.sock: after a switch from
        # Docker, a socket Docker left there kept the symlink from being made.
        export DOCKER_HOST=unix:///run/podman/podman.sock
      ''}
      root=${root}
      version=${bundle.version}
      tarball=${tarball}
      dir="$root/visure-x-airgap-$version"
      compose_file="$root/current/infra/docker-compose.yml"

      die() { echo "visure: $*" >&2; exit 1; }
      need_root() { [[ $EUID -eq 0 ]] || die "run as root: sudo visure $*"; }

      current_version() {
        [[ -f $root/current/VERSION ]] || return 0
        awk '/^version:/ { print $2 }' "$root/current/VERSION"
      }

      unpack() {
        [[ -f $tarball ]] || die "$tarball is missing; copy the bundle there first"
        if [[ -d $dir ]]; then
          echo "── $dir is already unpacked"
          return
        fi
        echo "── Verifying $tarball against the hash pinned in visure.nix…"
        echo "${bundle.sha256}  $tarball" | sha256sum -c --strict
        tmp="$(mktemp -d "$root/.unpack.XXXXXX")"
        tar -xf "$tarball" -C "$tmp"
        [[ -d $tmp/visure-x-airgap-$version ]] \
          || die "the tar holds no visure-x-airgap-$version/ directory"
        mv "$tmp/visure-x-airgap-$version" "$dir"
        rmdir "$tmp"
      }

      # The host's Ollama is a benchmark reference, started by hand, on
      # 127.0.0.1: the containers never reach it, so no default LLM server.
      no_default_ollama() {
        grep -q '^OLLAMA_BASE_URL=' "$1/infra/.env" || echo 'OLLAMA_BASE_URL=' >> "$1/infra/.env"
      }

      case "''${1:-status}" in
        status)
          echo "pinned:  $version (${engine})"
          echo "current: $(current_version) ($(readlink "$root/current" || echo none))"
          if [[ -f $compose_file && $EUID -eq 0 ]]; then
            docker compose -f "$compose_file" ps
          fi
          ;;

        install)
          need_root install
          ! docker volume inspect infra_mongo-data > /dev/null 2>&1 \
            || die "volume infra_mongo-data exists: an installation is already here"
          # The same bundle again, with no data yet (after a failed start, or
          # a switch of engine), only loads the images again: load-images.sh
          # keeps infra/.env, the administrator hash and the certificate.
          if [[ -e $root/current && $(readlink -f "$root/current") != "$dir" ]]; then
            die "$(current_version) is installed; use: sudo visure upgrade"
          fi
          unpack
          cd "$dir"
          # Prints the administrator password once, at the end: save it.
          ./load-images.sh --domain ${domain} \
            --http-port ${toString httpPort} --https-port ${toString httpsPort}
          no_default_ollama "$dir"
          bash infra/preflight.sh
          ln -sfn "$dir" "$root/current"
          systemctl start visure
          echo "── Next: https://administration.${domain}:${toString httpsPort} (license, chapter 7)"
          ;;

        upgrade)
          need_root upgrade
          shift
          old="$(readlink -f "$root/current")" || die "nothing installed; use: sudo visure install"
          [[ $old != "$dir" ]] || die "$version is already the current installation"
          unpack
          mkdir -p "$root/backups"
          # Stops the stack, backs it up, loads and verifies the images,
          # carries infra/.env and the certificate over, starts the new one.
          # Extra arguments go to upgrade.sh (e.g. --allow-unlicensed).
          (cd "$dir" && ./upgrade.sh --from "$old" --backup-dir "$root/backups" "$@")
          no_default_ollama "$dir"
          ln -sfn "$old" "$root/previous"
          ln -sfn "$dir" "$root/current"
          systemctl restart visure
          echo "── Keep $old and the backup in $root/backups until $version is confirmed."
          ;;

        rollback)
          need_root rollback
          [[ -n ''${2:-} ]] || die "usage: sudo visure rollback <backup dir under $root/backups>"
          [[ -e $root/previous ]] || die "no previous installation recorded"
          (cd "$root/current" && ./upgrade.sh --rollback "$2")
          ln -sfn "$(readlink -f "$root/previous")" "$root/current"
          rm "$root/previous"
          echo "── Rolled back to $(current_version). Set the same version and hash in"
          echo "   visure.nix again and rebuild, or visure.service refuses to start."
          ;;

        # For visure.service. Refuses a version other than the pinned one, so
        # the running stack always matches the configuration; never pulls, so
        # a missing image fails instead of coming from a registry.
        up)
          [[ -f $compose_file ]] || die "nothing installed; use: sudo visure install"
          [[ $(current_version) == "$version" ]] \
            || die "running $(current_version), visure.nix pins $version: sudo visure upgrade"
          cd "$root/current"
          bash infra/preflight.sh
          docker compose -f infra/docker-compose.yml up -d --no-build --pull never
          ;;
        stop)
          [[ -f $compose_file ]] || exit 0
          docker compose -f "$compose_file" stop
          ;;

        # Anything else of the guide: sudo visure compose logs -f gateway
        compose)
          need_root compose
          shift
          docker compose -f "$compose_file" "$@"
          ;;

        # A new administrator password, printed once, its hash written in the
        # database and in infra/.env; the sign-in counters cleared. For a
        # password that was lost (guide §8). The stack must be running.
        reset-admin-password)
          need_root reset-admin-password
          [[ -f $compose_file ]] || die "nothing installed; use: sudo visure install"
          cd "$root/current"
          bash infra/set-admin-password.sh --reset infra/.env
          ;;

        *)
          die "usage: visure [status|install|upgrade|rollback <dir>|compose <args>|reset-admin-password]"
          ;;
      esac
    '';
  };

  ports = lib.concatMapStringsSep "," toString publicPorts;
in
lib.mkMerge [
  {
    # Started by hand (`sudo systemctl start visure`), like Ollama: it needs
    # 16 GB, which the Qwen pair and a VM already nearly use up.
    systemd.services.visure = {
      description = "Visure X (Docker Compose stack, ${engine})";
      requires = [ engineUnit ];
      after = [ engineUnit ];
      wantedBy = lib.mkForce [ ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe visure} up";
        ExecStop = "${lib.getExe visure} stop";
        TimeoutStartSec = "15min";
      };
    };

    environment.systemPackages = [ visure ];

    networking.hosts."127.0.0.1" = lib.concatMap (t: [
      "${t}.${domain}"
      "mcp-${t}.${domain}"
    ]) tenants;

    systemd.tmpfiles.rules = [ "d ${root} 0750 root root -" ];
  }

  (lib.mkIf podman {
    virtualisation.podman = {
      enable = true;
      # /run/docker.sock, for the Docker CLI and Compose. Socket-activated:
      # Podman runs only while something talks to it.
      dockerSocket.enable = true;
      # upgrade.sh re-tags the outgoing images so a rollback needs no old bundle.
      autoPrune.enable = false;
    };
    # About 14 GB of images per version, and the data volumes.
    virtualisation.containers.storage.rootful.settings.storage.graphroot =
      "/scratch/containers/storage";

    # Published ports bypass the NixOS firewall (they are forwarded, not
    # delivered), and Podman has no default address to publish them on.
    # Drop what reaches them from outside before the forwarding: this machine,
    # the containers and quickemu VMs (at 10.0.2.2, from loopback) still do.
    networking.firewall.extraCommands = ''
      ip46tables -t mangle -N visure-local 2> /dev/null || true
      ip46tables -t mangle -F visure-local
      ip46tables -t mangle -A visure-local -i lo -j RETURN
      ip46tables -t mangle -A visure-local -i podman+ -j RETURN
      ip46tables -t mangle -A visure-local -j DROP
      ip46tables -t mangle -D PREROUTING -p tcp -m multiport --dports ${ports} -j visure-local 2> /dev/null || true
      ip46tables -t mangle -A PREROUTING -p tcp -m multiport --dports ${ports} -j visure-local
    '';
    networking.firewall.extraStopCommands = ''
      ip46tables -t mangle -D PREROUTING -p tcp -m multiport --dports ${ports} -j visure-local 2> /dev/null || true
      ip46tables -t mangle -F visure-local 2> /dev/null || true
      ip46tables -t mangle -X visure-local 2> /dev/null || true
    '';
  })

  (lib.mkIf (!podman) {
    virtualisation.docker = {
      enable = true;
      # Socket-activated: the daemon only runs once something talks to it.
      enableOnBoot = false;
      autoPrune.enable = false;
      daemon.settings = {
        data-root = "/scratch/docker";
        # Ports the compose file publishes without an address go on loopback
        # only; quickemu VMs still reach them at 10.0.2.2.
        ip = "127.0.0.1";
        log-driver = "json-file";
        log-opts = {
          max-size = "50m";
          max-file = "3";
        };
      };
    };
    systemd.tmpfiles.rules = [ "d /scratch/docker 0710 root root -" ];
  })
]
