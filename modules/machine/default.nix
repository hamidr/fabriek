## The machine one factory runs in (ADR-019).
##
## fabriek builds and runs one VM per factory, on Linux and macOS alike, so
## that the isolation a factory gets does not depend on which laptop is open and
## so that two factories share no kernel, store or uid space. Inside it, nixcage
## is in exactly the situation ADR-003 built it for: an ordinary Linux host
## running nspawn cages natively.
##
## What is here is the machine. What runs on it is nixcage's host module, which
## is imported beside this one and is not restated.
{
  config,
  lib,
  pkgs,
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

  ## The pool is named after the factory, so a disk that ends up attached to
  ## the wrong machine refuses to import rather than being adopted.
  pool = "fabriek-${cfg.factory}";

  ## Found by serial rather than by drive letter, because a drive letter moves
  ## when the volume list changes and the pool would then be created on top of
  ## the store.
  poolSerial = "fabriek-pool";
  poolDevice = "/dev/disk/by-id/virtio-${poolSerial}";

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
    factory = lib.mkOption {
      type = lib.types.str;
      description = "The factory this machine exists to run. Names its pool.";
    };
    cpus = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Cores, as the factory asked and the operator allowed.";
    };
    mem = lib.mkOption {
      type = lib.types.int;
      default = 8192;
      description = "Memory in MiB, as the factory asked and the operator allowed.";
    };
    diskSize = lib.mkOption {
      type = lib.types.int;
      default = 65536;
      description = "Size in MiB of each volume this machine is given.";
    };
    declaration = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = ''
        The factory's declaration, validated and clamped by the build
        (ADR-040). The bridge's address plan and the bus's users are derived
        from its roles, and the machine program reads it from
        /etc/fabriek/declaration.json rather than evaluating anything.
      '';
    };
    sshPort = lib.mkOption {
      type = lib.types.port;
      description = "The host port fabriek reaches this machine on.";
    };
    authorizedKey = lib.mkOption {
      type = lib.types.str;
      description = ''
        The one public key that reaches this machine. fabriek owns the way in
        because it owns the VM, and this is that: a key made per factory, so no
        factory holds another factory's way in.
      '';
    };
    zfsArcMax = lib.mkOption {
      type = lib.types.int;
      default = 512;
      description = "ARC ceiling in MiB. Uncapped it would take half the machine.";
    };
    egressHeaders = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Which header carries the credential for which endpoint, as the
        operator's own config says (ADR-025). The value is never here: the
        machine reads it from its state directory at run time, so nothing
        about a credential is in the store or in a build log.
      '';
    };
    egressPort = lib.mkOption {
      type = lib.types.port;
      default = 8118;
      description = "Where on the bridge a role's agent finds the proxy.";
    };
    egress = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        The hosts this factory's agents may reach, as the repository declared
        them and the operator allowed them (ADR-025). Empty is a machine that
        reaches nothing, which is what an operator who has named no endpoints
        has asked for.
      '';
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
    ## The declaration, on the machine as a file (ADR-040).
    environment.etc."fabriek/declaration.json".text = builtins.toJSON cfg.declaration;

    ## The VM owns its store. The closure ships read-only and builds land in a
    ## persistent overlay, so nothing of the host's store is shared in and two
    ## factories cannot see each other's through it.
    microvm = {
      hypervisor = "qemu";
      vcpu = cfg.cpus;
      mem = cfg.mem;
      writableStoreOverlay = "/nix/.rw-store";

      volumes = [
        {
          image = "store.img";
          mountPoint = "/nix/.rw-store";
          size = cfg.diskSize;
        }
        {
          ## Unmounted here and taken over by the service below. microvm.nix
          ## makes a filesystem on every volume it creates and has no mkfs.zfs
          ## to make one with, so this arrives carrying an ext4 superblock that
          ## zpool overwrites.
          image = "pool.img";
          mountPoint = null;
          serial = poolSerial;
          size = cfg.diskSize;
        }
      ];

      interfaces = [
        {
          type = "user";
          id = "cw0";
          mac = "02:00:00:00:00:01";
        }
      ];

      forwardPorts = [
        {
          from = "host";
          host.port = cfg.sshPort;
          guest.port = 22;
        }
      ];
    };

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

    ## ZFS wants one per machine, and every factory's machine is a different
    ## one. Derived from the factory's name so that rebuilding a machine does
    ## not change the identity of the pool it imports.
    networking = {
      hostName = "fabriek-${cfg.factory}";
      hostId = builtins.substring 0 8 (builtins.hashString "sha256" cfg.factory);

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
    };
    users.users.root.openssh.authorizedKeys.keys = [ cfg.authorizedKey ];

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

    ## The machine's own way of being handed a secret. Present only where
    ## there is somewhere to reach, which is the same condition the proxy has.
    ## The supervisor reads a factory's declaration by evaluating the flake it
    ## is committed in (ADR-020), and it does that here rather than on the
    ## operator's host. A machine whose nix refuses these reads no declaration
    ## at all: no role resolves, no worktree is prepared and no session starts,
    ## and what it says while failing is that the repository declares no
    ## factory.
    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
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
    ]
    ++ lib.optionals (cfg.egress != [ ]) [ egressCredential ];

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

    ## What the include above reads, made before nginx opens it. The secret
    ## comes off the machine's own state directory, which the operator writes
    ## and no cage can read.
    systemd.services.fabriek-egress-credentials = lib.mkIf (cfg.egress != [ ]) {
      description = "Compose this factory's credential headers for the egress proxy";
      wantedBy = [ "multi-user.target" ];
      before = [ "nginx.service" ];
      requiredBy = [ "nginx.service" ];
      after = [ "fabriek-storage.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.coreutils ];
      script = ''
        set -eu
        install -d -m 0750 -o fabriek-egress -g fabriek-egress /run/fabriek-egress
        ${lib.concatMapStrings (host: ''
          conf=/run/fabriek-egress/${host}.conf
          secret=${stateDir}/egress/${host}
          : >"$conf"
          ${lib.optionalString (cfg.egressHeaders ? ${host}) ''
            if [ -s "$secret" ]; then
              printf 'proxy_set_header %s "%s";\n' \
                ${lib.escapeShellArg cfg.egressHeaders.${host}} "$(cat "$secret")" >"$conf"
            fi
          ''}
          chown fabriek-egress:fabriek-egress "$conf"
          chmod 0400 "$conf"
        '') cfg.egress}
      '';
    };

    system.stateVersion = "24.11";
  };
}
