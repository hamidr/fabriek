## Building the machine every factory runs in (ADR-019, ADR-057).
##
## A function of the inputs fabriek pins and a spec naming the guest's and
## the host's system, returning a NixOS configuration. It is a function
## rather than a nixosConfigurations attribute because the runner is built
## from the host's packages, and which host is not a fact this repository
## can know; everything else about a machine is decided at run time.
##
## The machine is nixpkgs, microvm.nix, nixcage's host module and fabriek' own,
## which is what ADR-019 point 2 decides. Inside the VM nixcage is in exactly
## the situation ADR-003 built it for.
{
  nixpkgs,
  microvm,
  nixcage,
  ## This repository itself, so the machine can carry the machine program built
  ## from it. Every role-, task- and factory- verb lives in that program and
  ## runs on the machine, so a machine without it answers "command not found"
  ## to the whole CLI (PRD-004 phase 3).
  self,
}:
spec:
nixpkgs.lib.nixosSystem {
  system = spec.system;
  modules = [
    microvm.nixosModules.microvm
    nixcage.nixosModules.host
    ## The name nixcage gives a cage's veth is nixcage's function (ADR-013);
    ## the bridge's rules key on it.
    { _module.args.vethHostName = nixcage.lib.vethHostName; }
    ./machine
    ## Built from the same package.nix the flake's own overlay imports, so
    ## there is one description of the program even though there are two places
    ## that ask for it. Referring to the flake's overlay attribute from inside
    ## the function that builds the machine would close a loop.
    {
      nixpkgs.overlays = [
        (final: _prev: {
          fabriek-container =
            (import ./package.nix {
              pkgs = final;
              inherit self;
            }).container;
          ## The TypeScript half, for the loop the floor carries (ADR-035)
          ## and the executor, the decider and the relay beside it.
          fabriek-factory = (import ../factory { pkgs = final; }).package;
          ## The language-server extension every role's pi directory
          ## loads (ADR-043).
          pi-lsp = import ./pi-lsp { pkgs = final; };
          ## The codegraph tools beside it (ADR-049).
          pi-codegraph = import ./pi-codegraph { pkgs = final; };
        })
      ];
    }
    ## The machine is always Linux and the operator may not be. What starts a
    ## machine is a script that runs on the operator's host, so on macOS it has
    ## to be built from that host's packages: a runner made of Linux coreutils
    ## reaches for chattr and mkfs.ext4 and stops there.
    (nixpkgs.lib.mkIf (spec.hostSystem or spec.system != spec.system) {
      microvm.vmHostPackages = nixpkgs.legacyPackages.${spec.hostSystem or spec.system};
    })
    {
      fabriek.machine.shareProto = spec.shareProto or "virtiofs";
      ## What factory-render evaluates a role's profile from (ADR-057 point
      ## 5): this repository and the nixpkgs it pins, two paths in the store
      ## the machine shares, and the system the profile is built for. The
      ## floor is named in floor.nix.
      environment.variables = {
        FABRIEK_SELF = "${self}";
        FABRIEK_NIXPKGS = "${nixpkgs}";
        FABRIEK_SYSTEM = spec.system;
      };
      ## A role's worktree is under nixcage's own state, not a workspace root
      ## (modules/role-worktree.sh), so none is shared in.
      nixcage.workspaceRoots = [ ];
    }
  ];
}
