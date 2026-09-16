## A private network per cage (ADR-037).
##
## One bridge per factory, the machine at .1 on it, the decider at .2, and a
## role's cage at .10 onward in declaration order. A cage gets one veth on
## this bridge and no other interface, so "no route off the machine" is a
## fact about what a cage has rather than a rule about what it may do.
##
## Two rules are load-bearing and are the bridge's, not egress's. The first
## drops a packet whose source is not the address its port was given, because
## spend is attributed by address and without it a cage bills a peer. The
## second drops cage to cage. Both are in the bridge family, because traffic
## between two ports of one bridge never reaches the inet hooks.
##
## The veth's host end is named by nixcage from a hash of the cage's name
## (nixcage ADR-013). Which cages there are is the factory's, and the factory
## arrives at boot (ADR-057), so the set below is declared empty here and
## filled by factory-prepare from the plan it renders (modules/
## factory-render.sh), with nft add element; the same plan is written for
## the executor to read, so the two cannot disagree.
##
## The machine's own firewall is the third party here: it drops a new
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

    networking.nftables.tables.fabriek-cages = {
      family = "bridge";
      content = ''
        ## Filled by factory-prepare: nft add element bridge fabriek-cages
        ## cages { "nc-..." . 10.77.0.10, ... }, from the rendered plan.
        set cages {
          type ifname . ipv4_addr
        }

        chain prerouting {
          type filter hook prerouting priority -300; policy accept;

          ## Rule 1: a cage speaks only as itself. Anything else on a cage's
          ## port is dropped before it is seen, IPv6 and ARP included, so an
          ## address cannot be claimed by the party it would bill.
          iifname "nc-*" ether type ip6 drop
          iifname "nc-*" ether type arp iifname . arp saddr ip != @cages drop
          iifname "nc-*" ether type ip iifname . ip saddr != @cages drop
        }

        chain forward {
          type filter hook forward priority 0; policy accept;

          ## Rule 2: a cage reaches the machine and never a peer. Findings go
          ## over the bus and work through the executor (ADR-033), so there
          ## is nothing for two cages to say to each other directly.
          iifname "nc-*" oifname "nc-*" drop
        }
      '';
    };
  };
}
