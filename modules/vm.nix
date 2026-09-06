## Building the machine one factory runs in (ADR-019).
##
## A function of the inputs cageworks pins and a spec describing one factory's
## machine, returning a NixOS configuration. It is a function rather than a
## nixosConfigurations attribute because a machine is per factory and per
## operator: how many cores it has and what port it answers on are not facts
## this repository can know.
##
## The guest is nixpkgs, microvm.nix, nixcage's host module and cageworks' own,
## which is what ADR-019 point 2 decides. Inside the VM nixcage is in exactly
## the situation ADR-003 built it for.
{
  nixpkgs,
  microvm,
  nixcage,
}:
spec:
nixpkgs.lib.nixosSystem {
  system = spec.system;
  modules = [
    microvm.nixosModules.microvm
    nixcage.nixosModules.host
    ./vm-guest.nix
    ## The guest is always Linux and the operator may not be. What starts a
    ## machine is a script that runs on the operator's host, so on macOS it has
    ## to be built from that host's packages: a runner made of Linux coreutils
    ## reaches for chattr and mkfs.ext4 and stops there.
    (nixpkgs.lib.mkIf (spec.hostSystem or spec.system != spec.system) {
      microvm.vmHostPackages = nixpkgs.legacyPackages.${spec.hostSystem or spec.system};
    })
    {
      cageworks.machine = builtins.removeAttrs spec [
        "system"
        "hostSystem"
        "workspaceRoots"
      ];
      ## Nothing of the operator's is shared in yet: no role works in this
      ## machine until PRD-004 phase 3, and a share nothing reads is a hole
      ## nobody asked for.
      nixcage.workspaceRoots = spec.workspaceRoots or [ ];
    }
  ];
}
