## The executor (ADR-034 point 2): uncaged, holds every credential, decides
## nothing. One unit, as root, because it starts sessions through the machine
## program and reads the tokens cageworks up made. It is restarted when it
## dies, and reconciles the board on every start before routing anything
## (ADR-033 point 4).
{
  config,
  pkgs,
  ...
}:
{
  config = {
    ## The relay, for the machine program's factory-watch (ADR-039 point 2).
    environment.systemPackages = [ pkgs.cageworks-factory ];

    systemd.services.cageworks-executor = {
      description = "This factory's executor";
      wantedBy = [ "multi-user.target" ];
      after = [
        "cageworks-bus-acl.service"
        "forgejo.service"
        "cageworks-storage.service"
      ];
      wants = [
        "cageworks-bus-acl.service"
        "forgejo.service"
      ];
      ## Not before cageworks up has prepared the factory (accounts, tokens,
      ## passwords owned by their cages): a session started earlier fails or
      ## is deaf. Prepare writes the mark last and restarts this unit on it;
      ## on every later boot the mark is already there.
      unitConfig.ConditionPathExists = "/var/lib/nixcage/prepared";
      path = [
        pkgs.git
        pkgs.cageworks-container
        "/run/current-system/sw"
      ];
      serviceConfig = {
        ExecStart = "${pkgs.nodejs}/bin/node ${pkgs.cageworks-factory}/lib/cageworks-factory/dist/executor/main.js";
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
