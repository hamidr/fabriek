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
    services.openssh = {
      enable = true;
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
      before = [ "sshd.service" ];
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
      '';
    };

    ## Where nixcage puts a role's worktree, so that asking for owned, bounded
    ## storage lands on the pool above rather than on the rootfs.
    nixcage.storage.dataset = "${pool}/state";

    system.stateVersion = "24.11";
  };
}
