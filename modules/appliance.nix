## The one machine every factory runs in (ADR-057).
##
## A function of the inputs fabriek pins and two facts: the guest's system
## and the host's, because the runner is a script that runs on the host and
## on macOS has to be made from that host's packages (vm.nix). Nothing of a
## factory, an operator or a host beyond that is evaluated here: what the
## factory is arrives as credentials at boot, what the host allows arrives
## on the hypervisor's command line, and factory-prepare renders the rest
## on the machine. The image is built once and fetched from the cache after.
{
  nixpkgs,
  microvm,
  nixcage,
  self,
}:
{
  system,
  hostSystem ? system,
}:
let
  machine =
    import ./vm.nix
      {
        inherit
          nixpkgs
          microvm
          nixcage
          self
          ;
      }
      {
        inherit system hostSystem;
        ## virtiofsd runs on a Linux host and nowhere else; a macOS host shares
        ## its store over 9p, which is qemu's own (ADR-057 point 1a).
        shareProto = if nixpkgs.lib.hasSuffix "-linux" hostSystem then "virtiofs" else "9p";
      };
in
{
  config = machine.config;
  runner = machine.config.microvm.declaredRunner;
  ## The system closure alone, for a host that fetches the image and roots it
  ## (ADR-057 point 5a).
  toplevel = machine.config.system.build.toplevel;
}
