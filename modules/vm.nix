## Building the machine one factory runs in (ADR-019).
##
## A function of the inputs fabriek pins and a spec describing one factory's
## machine, returning a NixOS configuration. It is a function rather than a
## nixosConfigurations attribute because a machine is per factory and per
## operator: how many cores it has and what port it answers on are not facts
## this repository can know.
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
      fabriek.machine = builtins.removeAttrs spec [
        "system"
        "hostSystem"
        "workspaceRoots"
        "notes"
        "modules"
      ];
      ## Nothing of the operator's is shared in yet: no role works in this
      ## machine until PRD-004 phase 3, and a share nothing reads is a hole
      ## nobody asked for.
      nixcage.workspaceRoots = spec.workspaceRoots or [ ];
    }
  ]
  ## What a factory adds to its own machine beyond the spec: the declaration
  ## as a file and a profile per role (factory.nix). A list so that vm.nix
  ## keeps taking a spec and knows nothing about what a factory is.
  ++ (spec.modules or [ ]);
}
