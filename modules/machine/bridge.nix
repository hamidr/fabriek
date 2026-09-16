## A private network per cage (ADR-037).
##
## One bridge per factory, the machine at .1 on it, the decider at .2, and a
## role's cage at .10 onward in declaration order. A cage gets one veth on
## this bridge and no other interface, so "no route off the machine" is a
## fact about what a cage has rather than a rule about what it may do.
##
## What crosses between two ports of this bridge is nixcage's (nixcage
## ADR-015, ADR-064): a cage's port is pinned to its address and isolated
## where its veth is made, in a table nixcage keeps at runtime, so a frame
## whose source is not its port's address is dropped before it is seen and
## cage to cage never crosses. The rules used to be declared here, keyed on
## the name nixcage gives a veth; a second copy would drift, and a reload of
## this ruleset recreated it empty.
##
## The machine's own firewall is what is the factory's here: it drops a new
## connection on an interface it was not told about, so the bridge is named
## to it with exactly the three ports a cage may reach.
{
  config,
  lib,
  ...
}:
let
  cfg = config.fabriek.machine;
  ## One bridge per machine and one machine per factory: a constant name,
  ## which the egress chain's "fabriek-*" also matches.
  bridge = "fabriek0";
  host = "10.77.0.1";
  prefix = 24;
in
{
  options.fabriek.machine = {
    forgejoPort = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Where on the bridge the board answers.";
    };
    valkeyPort = lib.mkOption {
      type = lib.types.port;
      default = 6379;
      description = "Where on the bridge the bus answers.";
    };
  };

  config = {
    networking.bridges.${bridge}.interfaces = [ ];
    networking.interfaces.${bridge}.ipv4.addresses = [
      {
        address = host;
        prefixLength = prefix;
      }
    ];
    ## An empty bridge has no carrier, and networkd withholds an address from
    ## a link without one; every cage is a port that comes and goes, so the
    ## address has to be there before the first port is. Found on a machine
    ## whose services all failed to bind. The sysctl is the same fact from
    ## the services' side: they may bind the address before it is up.
    systemd.network.networks."40-${bridge}".networkConfig.ConfigureWithoutCarrier = true;
    boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;

    ## What the machine program renders the plan with: the bridge's name
    ## and where the services answer, the same numbers the services bind.
    environment.variables = {
      FABRIEK_BRIDGE = bridge;
      FABRIEK_BRIDGE_HOST = host;
      FABRIEK_PROXY_PORT = toString cfg.egressPort;
      FABRIEK_FORGEJO_PORT = toString cfg.forgejoPort;
      FABRIEK_VALKEY_PORT = toString cfg.valkeyPort;
    };

    networking.firewall.interfaces.${bridge}.allowedTCPPorts = [
      cfg.forgejoPort
      cfg.valkeyPort
      cfg.egressPort
    ];
  };
}
