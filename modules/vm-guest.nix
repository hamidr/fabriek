## The machine one factory runs in (ADR-019).
##
## cageworks builds and runs one VM per factory, on Linux and macOS alike, so
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
  cfg = config.cageworks.machine;

  ## Where the factory's state lives, unchanged by any of this. ADR-017 puts
  ## that directory on the pool and the storage primitive can only name a
  ## dataset for a path the pool already mounts, so a state root of our own
  ## would buy a tidier name and cost every existing factory its datasets
  ## (ADR-018).
  stateDir = "/var/lib/nixcage";

  ## The pool is named after the factory, so a disk that ends up attached to
  ## the wrong machine refuses to import rather than being adopted.
  pool = "cageworks-${cfg.factory}";

  ## Found by serial rather than by drive letter, because a drive letter moves
  ## when the volume list changes and the pool would then be created on top of
  ## the store.
  poolSerial = "cageworks-pool";
  poolDevice = "/dev/disk/by-id/virtio-${poolSerial}";
in
{
  options.cageworks.machine = {
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
    sshPort = lib.mkOption {
      type = lib.types.port;
      description = "The host port cageworks reaches this machine on.";
    };
    authorizedKey = lib.mkOption {
      type = lib.types.str;
      description = ''
        The one public key that reaches this machine. cageworks owns the way in
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
      description = "Where on loopback a role's agent finds the proxy.";
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

  config = {
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
      hostName = "cageworks-${cfg.factory}";
      hostId = builtins.substring 0 8 (builtins.hashString "sha256" cfg.factory);
    };

    ## The way in. Password authentication is off and one key is trusted, which
    ## is the whole of the transport ADR-019 point 4 describes.
    ##
    ## The host keys live on the pool rather than on the rootfs. A machine that
    ## generates new ones every boot is a different machine every boot, and
    ## cageworks, which pins what it connected to, refuses the second one: a
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

    systemd.services.cageworks-storage = {
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
              echo "cageworks: a pool exists on ${poolDevice} but will not import; refusing to recreate it" >&2
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

    ## Who the proxy is (ADR-025 point 2). It exists here rather than beside
    ## the service because the firewall below is written in terms of it: the
    ## rule that lets anything out at all names this uid, so the uid is part of
    ## the machine rather than part of a service that may not have started.
    users.users.cageworks-egress = {
      isSystemUser = true;
      group = "cageworks-egress";
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
    users.groups.cageworks-egress = { };

    ## The machine drops egress and names the exceptions (ADR-025 point 3).
    ##
    ## It filters on uid and never on host, because a packet filter cannot
    ## resolve a name and an allowlist of names resolved at build time would be
    ## a list of addresses that moved. Which hosts may be reached is the
    ## proxy's to enforce, since the proxy is the thing that resolves them.
    ##
    ## A role's session runs under its allocated uid on this machine's own
    ## network stack, because nixcage passes no --private-network and maps the
    ## session onto that uid. So a role needs no rule: it is denied by there
    ## being no rule for it, which is the only kind of denial that stays true
    ## when a role is added.
    networking.nftables = {
      enable = true;
      tables.cageworks-egress = {
        family = "inet";
        content = ''
          chain output {
            type filter hook output priority filter; policy drop;

            ## The proxy is on this machine, so a role reaching it never
            ## leaves. This is also what keeps the machine able to talk to
            ## itself at all.
            oifname "lo" accept

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
            meta skuid ${toString config.users.users.cageworks-egress.uid} accept

            ## Everything else is dropped, which is every role, and every
            ## build user. A derivation that fetches from the network at build
            ## time does not build here; the substituter is the only source.
          }
        '';
      };
    };

    ## The proxy (ADR-025 point 2). A cage holds no credential, so it cannot
    ## speak TLS to the model itself and have the request authenticated: it
    ## speaks plain HTTP to this, on loopback, and this speaks TLS onward with
    ## the credential added.
    ##
    ## One listener and one location per endpoint rather than a port each. A
    ## port each would be a number to allocate, record and keep stable across
    ## a change to the allowlist, and a path is none of those.
    ##
    ## The upstream is a literal host, so nginx resolves it when it starts. A
    ## variable would make it resolve per request and would also stop nginx
    ## rewriting the location away, which is the part worth having. What that
    ## costs is a restart when an address moves.
    services.nginx = lib.mkIf (cfg.egress != [ ]) {
      enable = true;
      user = "cageworks-egress";
      group = "cageworks-egress";
      recommendedProxySettings = true;
      virtualHosts."cageworks-egress" = {
        listen = [
          {
            addr = "127.0.0.1";
            port = cfg.egressPort;
          }
        ];
        extraConfig = lib.concatMapStrings (host: ''
          location /${host}/ {
            proxy_pass https://${host}/;
            proxy_set_header Host ${host};
            ## The credential, written at run time and never in the store. It
            ## is always written, empty when nobody holds one, because nginx
            ## refuses to start on an include it cannot read.
            include /run/cageworks-egress/${host}.conf;
          }
        '') cfg.egress;
      };
    };

    ## What the include above reads, made before nginx opens it. The secret
    ## comes off the machine's own state directory, which the operator writes
    ## and no cage can read.
    systemd.services.cageworks-egress-credentials = lib.mkIf (cfg.egress != [ ]) {
      description = "Compose this factory's credential headers for the egress proxy";
      wantedBy = [ "multi-user.target" ];
      before = [ "nginx.service" ];
      requiredBy = [ "nginx.service" ];
      after = [ "cageworks-storage.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.coreutils ];
      script = ''
        set -eu
        install -d -m 0750 -o cageworks-egress -g cageworks-egress /run/cageworks-egress
        ${lib.concatMapStrings (host: ''
          conf=/run/cageworks-egress/${host}.conf
          secret=${stateDir}/egress/${host}
          : >"$conf"
          ${
            lib.optionalString (cfg.egressHeaders ? ${host}) ''
              if [ -s "$secret" ]; then
                printf 'proxy_set_header %s "%s";\n' \
                  ${lib.escapeShellArg cfg.egressHeaders.${host}} "$(cat "$secret")" >"$conf"
              fi
            ''
          }
          chown cageworks-egress:cageworks-egress "$conf"
          chmod 0400 "$conf"
        '') cfg.egress}
      '';
    };

    system.stateVersion = "24.11";
  };
}
