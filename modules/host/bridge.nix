## A private network per cage (ADR-037), one bridge per factory (ADR-067).
##
## The host is at .1 on a factory's bridge, the decider at .2, and a role's
## cage at .10 onward in declaration order. A cage gets one port on this
## bridge and no other interface, so "no route off the host" is a fact
## about what a cage has rather than a rule about what it may do; what
## crosses between two ports is nixcage's (nixcage ADR-015, ADR-064).
##
## The bridge's index is the factory's position among the declared names,
## so its name fits an interface's fifteen characters whatever the factory
## is called, and two factories never share a subnet. The host's firewall
## is told each bridge and exactly the three ports a cage may reach on it.
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.fabriek;
in
{
  config = lib.mkIf cfg.enable {
    networking.bridges = lib.mapAttrs' (
      _: p: lib.nameValuePair p.bridge { interfaces = [ ]; }
    ) cfg.plan;
    networking.interfaces = lib.mapAttrs' (
      _: p:
      lib.nameValuePair p.bridge {
        ipv4.addresses = [
          {
            address = p.host;
            prefixLength = 24;
          }
        ];
      }
    ) cfg.plan;
    ## An empty bridge has no carrier, and networkd withholds an address
    ## from a link without one; every cage is a port that comes and goes,
    ## so the address has to be there before the first port is. The sysctl
    ## is the same fact from the services' side: they may bind the address
    ## before it is up.
    systemd.network.networks = lib.mapAttrs' (
      _: p: lib.nameValuePair "40-${p.bridge}" { networkConfig.ConfigureWithoutCarrier = true; }
    ) cfg.plan;
    boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;

    networking.firewall.interfaces = lib.mapAttrs' (
      _: p:
      lib.nameValuePair p.bridge {
        allowedTCPPorts = [
          cfg.ports.forgejo
          cfg.ports.valkey
          cfg.ports.egress
        ];
      }
    ) cfg.plan;
  };
}
