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
## The veth's host end is named "vb-<cage>" by nspawn when the cage is put
## on a bridge (a veth on no bridge would be "ve-<cage>"), and a cage is
## named after its role (names.sh bounds a role to what fits). The set below
## is keyed on that name and the address the executor hands the session,
## which is the same plan this file writes to /etc/fabriek/bridge.json for
## the executor to read.
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
  roles = lib.attrNames (cfg.declaration.roles or { });
  net = "10.77.0";
  bridge = "fabriek-${cfg.factory}";
  host = "${net}.1";
  cages = {
    decider = "${net}.2";
  }
  // lib.listToAttrs (lib.imap0 (i: r: lib.nameValuePair r "${net}.${toString (10 + i)}") roles);
  plan = {
    inherit bridge host cages;
    prefix = 24;
    proxy = "${host}:${toString cfg.egressPort}";
    forgejo = "${host}:${toString cfg.forgejoPort}";
    valkey = "${host}:${toString cfg.valkeyPort}";
  };
  members = lib.concatStringsSep ", " (
    lib.mapAttrsToList (name: addr: ''"vb-${name}" . ${addr}'') cages
  );
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
        prefixLength = plan.prefix;
      }
    ];
    ## An empty bridge has no carrier, and networkd withholds an address from
    ## a link without one; every cage is a port that comes and goes, so the
    ## address has to be there before the first port is. Found on a machine
    ## whose services all failed to bind. The sysctl is the same fact from
    ## the services' side: they may bind the address before it is up.
    systemd.network.networks."40-${bridge}".networkConfig.ConfigureWithoutCarrier = true;
    boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;

    ## The plan, for the executor that starts sessions and the proofs that
    ## check them. One copy, and the rules below are generated from the same
    ## attributes, so the two cannot disagree.
    environment.etc."fabriek/bridge.json".text = builtins.toJSON plan;

    networking.firewall.interfaces.${bridge}.allowedTCPPorts = [
      cfg.forgejoPort
      cfg.valkeyPort
      cfg.egressPort
    ];

    networking.nftables.tables.fabriek-cages = {
      family = "bridge";
      content = ''
        set cages {
          type ifname . ipv4_addr
          elements = { ${members} }
        }

        chain prerouting {
          type filter hook prerouting priority -300; policy accept;

          ## Rule 1: a cage speaks only as itself. Anything else on a cage's
          ## port is dropped before it is seen, IPv6 and ARP included, so an
          ## address cannot be claimed by the party it would bill.
          iifname "vb-*" ether type ip6 drop
          iifname "vb-*" ether type arp iifname . arp saddr ip != @cages drop
          iifname "vb-*" ether type ip iifname . ip saddr != @cages drop
        }

        chain forward {
          type filter hook forward priority 0; policy accept;

          ## Rule 2: a cage reaches the machine and never a peer. Findings go
          ## over the bus and work through the executor (ADR-033), so there
          ## is nothing for two cages to say to each other directly.
          iifname "vb-*" oifname "vb-*" drop
        }
      '';
    };
  };
}
