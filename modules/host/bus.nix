## The bus: one nats-server for the host, an account per factory (ADR-033,
## ADR-069). Control plane only, JetStream with a memory store and no file
## store at all, so a restart is an empty bus and every actor re-announces
## itself as it always has.
##
## An account is a subject namespace of its own with its own JetStream
## memory, its own connection and subscription bounds, and no imports or
## exports, so one factory's subjects are unreachable from another's by
## construction. Who may say what inside an account is a user's permissions
## (modules/bus.sh), rendered by prepare into a file this configuration
## includes and read at the next reload.
##
## Every include is resolved against the directory of the configuration
## file that names it, so the configuration lives beside the factories'
## rendered directories and includes each by its relative path. The file a
## factory has not written yet exists and is empty, which is an account
## with no user.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fabriek;
  ## Where the configuration is read from, which is what the includes are
  ## relative to: /var/lib/fabriek, holding one directory per factory.
  root = "/var/lib/fabriek";
  account = name: ''
    ${name} {
      jetstream { max_mem: ${toString cfg.bus.memory} }
      limits { max_connections: ${toString cfg.bus.connections}, max_subscriptions: ${toString cfg.bus.subscriptions} }
      include "${name}/nats-users.conf"
    }
  '';
  configText = ''
    ## Rendered by services.fabriek; a factory's users are its own file.
    server_name: fabriek
    host: 0.0.0.0
    port: ${toString cfg.ports.bus}
    http: 127.0.0.1:${toString cfg.ports.busMonitor}
    jetstream {
      store_dir: "${cfg.bus.store}"
      max_memory_store: ${toString (cfg.bus.memory * (lib.length (lib.attrNames cfg.plan)) + 67108864)}
      max_file_store: 0
    }
    accounts {
      ${lib.concatStringsSep "\n" (map account (lib.attrNames cfg.plan))}
    }
  '';
  configFile = pkgs.writeText "fabriek-nats.conf" configText;
in
{
  options.services.fabriek.bus = {
    memory = lib.mkOption {
      type = lib.types.int;
      default = 134217728;
      description = ''
        Bytes of JetStream memory one factory's account may hold
        (ADR-069 point 2). The operator's, fixed at this host's build:
        a declaration asks for no bus resources and nothing clamps.
      '';
    };
    connections = lib.mkOption {
      type = lib.types.int;
      default = 64;
      description = "Connections one factory's account may hold at once.";
    };
    subscriptions = lib.mkOption {
      type = lib.types.int;
      default = 512;
      description = "Subscriptions one factory's account may hold at once.";
    };
    store = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nats";
      description = "Where JetStream keeps what it must; nothing here is a file store.";
    };
    ## Read-only: what a scenario reads instead of parsing the file.
    text = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = configText;
      description = "The configuration the host's one nats-server runs with.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.nats = {
      isSystemUser = true;
      group = "nats";
      description = "Runs the host's bus";
    };
    users.groups.nats = { };

    ## The configuration where the includes resolve from, and an empty
    ## include per factory so that a factory never brought up is an account
    ## with no user rather than a server that will not start.
    systemd.tmpfiles.rules = [
      "d ${root} 0755 root root -"
      "L+ ${root}/nats.conf - - - - ${configFile}"
      "d ${cfg.bus.store} 0700 nats nats -"
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (name: p: [
        "d ${p.etc} 0755 root root -"
        "f ${p.etc}/nats-users.conf 0644 root root -"
      ]) cfg.plan
    );

    systemd.services.nats = {
      description = "The host's bus";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.nats-server}/bin/nats-server -c ${root}/nats.conf -P /run/nats/nats.pid";
        ## A factory's prepare writes its users and asks for this: the
        ## server reads every include again and the connections of every
        ## other factory are untouched (ADR-069 point 3).
        ExecReload = "${pkgs.nats-server}/bin/nats-server --signal reload=/run/nats/nats.pid";
        Restart = "on-failure";
        User = "nats";
        Group = "nats";
        RuntimeDirectory = "nats";
        StateDirectory = "nats";
      };
    };

    environment.systemPackages = [
      pkgs.natscli
      pkgs.nats-server
    ];
  };
}
