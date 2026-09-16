## The machine a factory runs in (ADR-019, ADR-057).
##
## fabriek runs one VM per factory, on Linux and macOS alike, so that the
## isolation a factory gets does not depend on which laptop is open and so
## that two factories share no kernel, store or uid space. Inside it, nixcage
## is in exactly the situation ADR-003 built it for: an ordinary Linux host
## running nspawn cages natively.
##
## One image serves every factory (ADR-057): nothing of a factory, an
## operator or a host is evaluated into it. What the factory is arrives as
## credentials at boot and factory-prepare renders it under the state
## directory; what the host is (memory, cores, the ssh port) arrives on the
## hypervisor's command line from the runner's extraArgsScript. Every name
## below that once carried the factory's is a constant, because one machine
## runs one factory.
##
## What is here is the machine. What runs on it is nixcage's host module, which
## is imported beside this one and is not restated.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.fabriek.machine;

  ## Where the factory's state lives, unchanged by any of this. ADR-017 puts
  ## that directory on the pool and the storage primitive can only name a
  ## dataset for a path the pool already mounts, so a state root of our own
  ## would buy a tidier name and cost every existing factory its datasets
  ## (ADR-018).
  stateDir = "/var/lib/nixcage";

  ## One pool per machine and one machine per factory, so the pool needs no
  ## factory's name; a disk attached to the wrong machine is still refused
  ## below, by the hostid ZFS stamps on it at creation.
  pool = "fabriek";

  ## Where prepare renders what the build used to: the clamped declaration,
  ## the bridge plan, the proxy's configuration, the model, a pi directory
  ## per role (ADR-057 point 4). On the pool, so a restart finds it; read by
  ## the machine program through FABRIEK_ETC and included by the services.
  factoryDir = "/var/lib/fabriek/factory";

  ## The hypervisor arguments the host decides at run time (ADR-057 point
  ## 2): memory and cores from the clamped resources, the user-mode NIC with
  ## the ssh port forwarded, and one fw_cfg credential per file of point 3.
  ## Read from runtime.json in the directory the runner is started in, which
  ## fabriek up writes; the script is the image's and the facts are the
  ## host's. It runs on the host, so it is made of the host's packages, as
  ## the runner is (vm.nix): a macOS host cannot exec the guest's jq. qemu
  ## takes the last -m and -smp it is given, but on a Linux host the shares
  ## make the runner back the image's memory with one shared memfd NUMA
  ## node of the image's size, and qemu refuses a -m the nodes do not sum
  ## to. The memory above the image's is a second node of the same kind,
  ## which vhost-user-fs needs of every byte the guest has.
  hostPkgs = config.microvm.vmHostPackages;
  numaNode = hostPkgs.stdenv.hostPlatform.isLinux && config.microvm.shares != [ ];
  runtimeArgs = hostPkgs.writeShellScript "fabriek-runtime-args" ''
    set -eu
    r=runtime.json
    [ -f "$r" ] || { echo "fabriek: no $r in $PWD; fabriek up writes it" >&2; exit 1; }
    mem="$(${hostPkgs.jq}/bin/jq -r .mem "$r")"
    args="-m ''${mem}M -smp $(${hostPkgs.jq}/bin/jq -r .cpus "$r")"
    ${lib.optionalString numaNode ''
      if [ "$mem" -gt ${toString config.microvm.mem} ]; then
        args="$args -object memory-backend-memfd,id=fabriek-mem,size=$((mem - ${toString config.microvm.mem}))M,share=on"
        args="$args -numa node,memdev=fabriek-mem"
      fi
    ''}
    args="$args -netdev user,id=fabriek,hostfwd=tcp:127.0.0.1:$(${hostPkgs.jq}/bin/jq -r .sshPort "$r")-:22"
    args="$args -device virtio-net-pci,netdev=fabriek"
    while IFS=$'\t' read -r name file; do
      args="$args -fw_cfg name=opt/io.systemd.credentials/$name,file=$file"
    done < <(${hostPkgs.jq}/bin/jq -r '.credentials | to_entries[] | "\(.key)\t\(.value)"' "$r")
    printf '%s\n' "$args"
  '';

  ## Found by serial rather than by drive letter, because a drive letter moves
  ## when the volume list changes and the pool would then be created on top of
  ## the store.
  poolSerial = "fabriek-pool";
  poolDevice = "/dev/disk/by-id/virtio-${poolSerial}";

  ## The store's upper layer, found the same way. fabriek up makes the
  ## image as an empty file (ADR-057 point 2) and the machine puts the
  ## filesystem on it at first boot, so that a macOS host needs no mkfs.
  storeSerial = "fabriek-store";
  storeDevice = "/dev/disk/by-id/virtio-${storeSerial}";
  storeOverlay = "/nix/.rw-store";

  ## The one way a credential reaches this machine (ADR-025 point 1). The
  ## operator names a host and pipes the secret in; where it lands is the
  ## machine's business, so nothing on the operator's side spells the state
  ## directory nixcage owns (ADR-018).
  ##
  ## The secret is read from stdin and never from argv, because /proc is
  ## readable by everything here and an argument would be a secret every uid on
  ## the machine had.
  egressCredential = pkgs.writeShellApplication {
    name = "fabriek-egress-credential";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      host="''${1:-}"
      if [ -z "$host" ]; then
        echo "usage: fabriek-egress-credential <host>" >&2
        exit 1
      fi
      ## A host is one name. Anything carrying a slash or a dot-segment would
      ## reach a path, and this runs as root.
      case "$host" in
      */* | . | ..)
        echo "fabriek: not a host: $host" >&2
        exit 1
        ;;
      esac
      install -d -m 0700 ${stateDir}/egress
      install -m 0400 -o fabriek-egress -g fabriek-egress \
        /dev/stdin ${stateDir}/egress/"$host"
    '';
  };
in
{
  options.fabriek.machine = {
    shareProto = lib.mkOption {
      type = lib.types.enum [
        "virtiofs"
        "9p"
      ];
      default = "virtiofs";
      description = ''
        How the host's store reaches the machine (ADR-057 point 1a):
        virtiofs on a Linux host, 9p on macOS where virtiofsd does not run.
      '';
    };
    zfsArcMax = lib.mkOption {
      type = lib.types.int;
      default = 512;
      description = "ARC ceiling in MiB. Uncapped it would take half the machine.";
    };
    egressPort = lib.mkOption {
      type = lib.types.port;
      default = 8118;
      description = "Where on the bridge a role's agent finds the proxy.";
    };
  };

  imports = [
    ./bridge.nix
    ./board.nix
    ./bus.nix
    ./proxy.nix
    ./probes.nix
    ./floor.nix
    ./executor.nix
  ];

  config = {
    ## Where the machine program reads what prepare rendered, and the
    ## runtime args script the runner calls.
    environment.variables.FABRIEK_ETC = factoryDir;
    microvm.extraArgsScript = "${runtimeArgs}";

    ## The VM owns its store. The closure ships read-only and builds land in a
    ## persistent overlay, so nothing of the host's store is shared in and two
    ## factories cannot see each other's through it.
    ## The store (ADR-057 point 1a): the host's, shared read-only as the
    ## lower layer, with this machine's builds in a persistent overlay on
    ## store.img. Nothing of the closure is copied into a disk and a path
    ## the host holds is never fetched here. The host's db rides beside the
    ## store so nix sees a host path as valid and not only present. Both
    ## volumes are made by fabriek up at the size the caps allow; no
    ## interface and no forwarded port are declared here, the runtime args
    ## carry them.
    microvm = {
      hypervisor = "qemu";
      storeOnDisk = false;
      writableStoreOverlay = storeOverlay;
      shares = [
        {
          source = "/nix/store";
          mountPoint = "/nix/.ro-host/nix/store";
          tag = "ro-store";
          proto = cfg.shareProto;
        }
        {
          source = "/nix/var/nix/db";
          mountPoint = "/nix/.ro-host/nix/var/nix/db";
          tag = "ro-db";
          proto = cfg.shareProto;
        }
      ];

      volumes = [
        {
          image = "store.img";
          mountPoint = storeOverlay;
          serial = storeSerial;
          autoCreate = false;
        }
        {
          ## Unmounted here and taken over by the service below.
          image = "pool.img";
          mountPoint = null;
          serial = poolSerial;
          autoCreate = false;
        }
      ];

      interfaces = [ ];
      forwardPorts = [ ];
    };

    ## The upper layer is mounted by its serial, as the pool is found, and
    ## formatted in the initrd the first time it is seen empty, before the
    ## check and the mount that need a filesystem on it. An image with a
    ## filesystem is left alone, whatever it holds.
    fileSystems.${storeOverlay}.device = lib.mkForce storeDevice;
    boot.initrd.systemd = {
      initrdBin = [ pkgs.e2fsprogs ];
      services.fabriek-store-format = {
        description = "Put a filesystem on an empty store image";
        unitConfig.DefaultDependencies = false;
        requires = [ "${utils.escapeSystemdPath storeDevice}.device" ];
        after = [ "${utils.escapeSystemdPath storeDevice}.device" ];
        before = [
          "systemd-fsck@${utils.escapeSystemdPath storeDevice}.service"
          "${utils.escapeSystemdPath "/sysroot${storeOverlay}"}.mount"
        ];
        requiredBy = [ "${utils.escapeSystemdPath "/sysroot${storeOverlay}"}.mount" ];
        serviceConfig.Type = "oneshot";
        script = ''
          if ! blkid -p ${storeDevice} >/dev/null 2>&1; then
            mkfs.ext4 -q -L ${storeSerial} ${storeDevice}
          fi
        '';
      };
    };

    ## The overlay is the machine's default store, so the daemon, nix build
    ## at prepare and nixcage's closure query for every session all answer
    ## for a host path as valid (ADR-057 point 1a). Experimental in this nix;
    ## the measurement plan checks it on a machine.
    nix.settings.store = "local-overlay://?root=/&lower-store=${lib.escapeURL "local?root=/nix/.ro-host&read-only=true"}&upper-layer=${storeOverlay}/store";

    boot = {
      supportedFilesystems.zfs = true;
      ## Never adopt a pool that will not import cleanly. The service below
      ## refuses to recreate one for the same reason: a pool that is there and
      ## will not import is a fault to look at, and forcing it is how a role's
      ## worktrees are lost rather than found (ADR-017).
      zfs.forceImportRoot = false;
      ## ZFS tracks kernel releases behind the newest one, and a machine that
      ## fails to build is worse than one a release back.
      kernelPackages = lib.mkDefault pkgs.linuxPackages;
      kernelParams = [ "zfs.zfs_arc_max=${toString (cfg.zfsArcMax * 1048576)}" ];
    };

    ## ZFS wants a hostid; one image means one, and a pool made by this
    ## image imports on any machine running it, which is the point.
    networking = {
      hostName = "fabriek";
      hostId = "fab21e57";

      ## This machine has a link-local IPv6 address, no global one and no route,
      ## so an AAAA record is an address it cannot reach. The resolver answers
      ## with both families, the proxy takes the first, and every request
      ## through it fails with "Network is unreachable" behind a 502 the caller
      ## has no way to explain.
      ##
      ## Turned off rather than routed. ADR-025's way out is one proxy and one
      ## uid, and a second address family widens what the filter has to be right
      ## about to reach no endpoint anybody declared.
      enableIPv6 = false;
    };

    ## The way in. Password authentication is off and one key is trusted, which
    ## is the whole of the transport ADR-019 point 4 describes.
    ##
    ## The host keys live on the pool rather than on the rootfs. A machine that
    ## generates new ones every boot is a different machine every boot, and
    ## fabriek, which pins what it connected to, refuses the second one: a
    ## factory would stop and start exactly once.
    services.openssh = {
      enable = true;
      hostKeys = [
        {
          path = "${stateDir}/ssh/ssh_host_ed25519_key";
          type = "ed25519";
        }
      ];
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
      ## The operator's key arrives as a credential at boot (ADR-057 point
      ## 3), so the machine is reachable before anything else runs and no
      ## key is in the image.
      authorizedKeysFiles = [ "/run/credentials/@system/fabriek.authorized_keys" ];
    };

    systemd.services.fabriek-storage = {
      description = "Import or create the pool this factory's state lives on";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-modules-load.service" ];
      ## Nothing that touches the state may start before the pool carrying it
      ## is mounted, or it writes into the directory the pool is about to
      ## cover.
      before = [
        "sshd.service"
        ## Host keys are generated into the pool, so the pool has to be there
        ## before anything generates one.
        "sshd-keygen.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [
        config.boot.zfs.package
        pkgs.coreutils
        pkgs.util-linux
      ];
      script = ''
        set -eu

        if ! zpool list -H ${pool} >/dev/null 2>&1; then
          if ! zpool import -N -d /dev/disk/by-id ${pool} >/dev/null 2>&1; then
            ## A pool that is there and will not import is a fault to look at,
            ## never a device to reformat: zpool create would take every role's
            ## worktree with it.
            if zdb -l ${poolDevice} >/dev/null 2>&1; then
              echo "fabriek: a pool exists on ${poolDevice} but will not import; refusing to recreate it" >&2
              exit 1
            fi
            ## posixacl and xattr=sa are not tuning. A role reaches the
            ## repository's object database through a POSIX ACL (ADR-010), and
            ## ZFS refuses setfacl without them, so the factory would not work
            ## at all.
            zpool create -f \
              -o ashift=12 \
              -O compression=zstd \
              -O atime=off \
              -O acltype=posixacl \
              -O xattr=sa \
              -O mountpoint=none \
              ${pool} ${poolDevice}
          fi
        fi

        if ! zfs list -H ${pool}/state >/dev/null 2>&1; then
          zfs create -o mountpoint=${stateDir} ${pool}/state
        fi
        zfs mount -a
        mountpoint -q ${stateDir}
        chmod 0755 ${stateDir}

        ## Where this machine keeps its own identity, as opposed to the
        ## factory's work.
        mkdir -p ${stateDir}/ssh
        chmod 0700 ${stateDir}/ssh
      '';
    };

    ## Where nixcage puts a role's worktree, so that asking for owned, bounded
    ## storage lands on the pool above rather than on the rootfs.
    nixcage.storage.dataset = "${pool}/state";

    ## The uids nixcage allocates a principal from (ADR-004 in nixcage's
    ## tracker). Without it nixcage-container refuses every verb, so a machine
    ## that does not declare one is a machine where no role has a uid, no
    ## worktree can be asked for and the ledger has nowhere to live. It went
    ## unnoticed until the journal unit became the first thing on a factory's
    ## machine to call the primitive at boot.
    ##
    ## Far above the proxy's 500, so that a role can never be allocated the one
    ## uid the packet filter lets out (ADR-025), and far above every account
    ## NixOS makes for itself, since the range must not overlap what is here.
    nixcage.principalUidRange = {
      base = 700000;
      size = 64;
    };

    ## prepare evaluates the repository's devShell and catalogue at the rev
    ## and builds each role's profile here (ADR-057 point 5); the overlay
    ## store above is what makes the host's paths count.
    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
      "local-overlay-store"
      "read-only-local-store"
    ];

    ## git is on the machine's own PATH, not only inside the wrapper the
    ## supervisor runs with. It is already in this closure for that reason, so
    ## naming it here costs nothing and means an operator looking at a factory,
    ## or a proof making an origin on it, has the tool the machine's whole job
    ## is about.
    environment.systemPackages = [
      pkgs.git
      ## The machine program itself. Every role-, task- and factory- verb the
      ## CLI sends runs here, so this is what "the factory moves in" means.
      pkgs.fabriek-container
      egressCredential
    ];

    ## Who the proxy is (ADR-025 point 2). It exists here rather than beside
    ## the service because the firewall below is written in terms of it: the
    ## rule that lets anything out at all names this uid, so the uid is part of
    ## the machine rather than part of a service that may not have started.
    users.users.fabriek-egress = {
      isSystemUser = true;
      group = "fabriek-egress";
      ## Declared rather than allocated, because the rule below has to name it
      ## as a number: nftables resolves a user name when the ruleset is
      ## parsed, and the ruleset is parsed once at build time in a sandbox
      ## where no such user exists. A name there fails the build, which is how
      ## this was found.
      ##
      ## 500 is unassigned in nixpkgs' static table and is far below any
      ## principal range an operator would declare for roles, which nixcage
      ## allocates from and which starts in the hundreds of thousands. A role
      ## sharing this uid would be a role that may leave the machine.
      uid = 500;
      description = "Holds this factory's model credential and is the only way out";
    };
    users.groups.fabriek-egress = { };

    ## A name is resolved by whoever wants it, so the rules below reach DNS.
    ##
    ## NixOS points /etc/resolv.conf at systemd-resolved's stub, which resolves
    ## on everybody's behalf under its own uid. Under an egress policy written
    ## in uids that is a choice between two bad ends: let that daemon out and
    ## every uid on the machine has a channel to the internet through it, or
    ## do not and nothing here can resolve anything. The second is what was
    ## happening, and it took the proxy's own upstream with it -- nginx cannot
    ## reach a host whose name it cannot look up.
    ##
    ## The uplink file carries the same server DHCP handed us, and glibc reading
    ## it resolves in the asking process, so a query is that uid's packet and
    ## the rules below decide it exactly as they decide any other. Measured on a
    ## machine: root and the proxy resolve, a role's uid does not.
    environment.etc."resolv.conf".source = lib.mkForce "/run/systemd/resolve/resolv.conf";

    ## The machine drops egress and names the exceptions (ADR-025 point 3).
    ##
    ## It filters on uid and never on host, because a packet filter cannot
    ## resolve a name and an allowlist of names resolved at build time would be
    ## a list of addresses that moved. Which hosts may be reached is the
    ## proxy's to enforce, since the proxy is the thing that resolves them.
    ##
    ## A role has no place in this chain at all: its cage is on the bridge
    ## with one veth and no route (ADR-037), so this chain is about the
    ## machine's own processes, of which root and the proxy may leave.
    networking.nftables = {
      enable = true;
      tables.fabriek-egress = {
        family = "inet";
        content = ''
          chain output {
            type filter hook output priority filter; policy drop;

            ## The machine talking to itself, and to its cages over the
            ## bridge, never leaves.
            oifname "lo" accept
            oifname "fabriek-*" accept

            ## The far side of a connection something above was allowed to
            ## open.
            ct state established,related accept

            ## Substitution, and the machine's own business. The daemon runs
            ## as root and a cage cannot: a cage reaches the daemon's socket
            ## and asks for a store path, and a store path is content
            ## addressed, so what it can make root fetch is decided by a hash
            ## rather than by a URL it chose.
            meta skuid 0 accept

            ## The one uid that may reach a host on a factory's behalf. What
            ## it may reach is the proxy's allowlist, not this chain's. It is
            ## a number because the ruleset is checked at build time, where
            ## the name resolves to nothing.
            meta skuid ${toString config.users.users.fabriek-egress.uid} accept

            ## Everything else is dropped, which is every role, and every
            ## build user. A derivation that fetches from the network at build
            ## time does not build here; the substituter is the only source.
          }
        '';
      };
    };

    ## What the proxy's include reads, made before nginx opens it and again
    ## when prepare has rendered the endpoints (ADR-057 point 4). Which
    ## header carries which endpoint's credential is in the endpoints file
    ## prepare wrote from the operator's credential; the secret itself comes
    ## off the machine's own state directory, which the operator writes over
    ## ssh and no cage can read. Before prepare there is no file and nothing
    ## is written, which is a proxy with no endpoints.
    systemd.services.fabriek-egress-credentials = {
      description = "Compose this factory's credential headers for the egress proxy";
      wantedBy = [ "multi-user.target" ];
      before = [ "nginx.service" ];
      requiredBy = [ "nginx.service" ];
      after = [ "fabriek-storage.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [
        pkgs.coreutils
        pkgs.jq
      ];
      script = ''
        set -eu
        install -d -m 0750 -o fabriek-egress -g fabriek-egress /run/fabriek-egress
        endpoints=${factoryDir}/endpoints.json
        [ -f "$endpoints" ] || exit 0
        jq -r '.credentials | to_entries[] | "\(.key)\t\(.value)"' "$endpoints" |
        while IFS=$'\t' read -r host header; do
          conf=/run/fabriek-egress/$host.conf
          secret=${stateDir}/egress/$host
          : >"$conf"
          if [ -s "$secret" ]; then
            printf 'proxy_set_header %s "%s";\n' "$header" "$(cat "$secret")" >"$conf"
          fi
          chown fabriek-egress:fabriek-egress "$conf"
          chmod 0400 "$conf"
        done
      '';
    };

    system.stateVersion = "24.11";
  };
}
