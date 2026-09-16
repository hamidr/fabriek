## The executor (ADR-034 point 2): uncaged, holds every credential, decides
## nothing. One unit, as root, because it starts sessions through the machine
## program and reads the tokens fabriek up made. It is restarted when it
## dies, and reconciles the board on every start before routing anything
## (ADR-033 point 4).
{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = {
    ## The relay, for the machine program's factory-watch (ADR-039 point 2).
    environment.systemPackages = [ pkgs.fabriek-factory ];

    systemd.services.fabriek-executor = {
      description = "This factory's executor";
      wantedBy = [ "multi-user.target" ];
      after = [
        "fabriek-bus-acl.service"
        "forgejo.service"
        "fabriek-storage.service"
      ];
      wants = [
        "fabriek-bus-acl.service"
        "forgejo.service"
      ];
      ## Not before factory-prepare has prepared the factory for this boot
      ## (profiles for these credentials, accounts, tokens, passwords owned
      ## by their cages): a session started earlier fails, is deaf, or runs
      ## on last boot's profile. Prepare writes the mark last and restarts
      ## this unit on it. Under /run on purpose: a mark on the pool survived
      ## a reboot with new credentials, and the lifecycle model
      ## (models/vm-lifecycle.qnt) found the executor starting on it.
      unitConfig.ConditionPathExists = "/run/fabriek/prepared";
      ## Everything the machine program is told through the environment
      ## (where prepare rendered the factory, the floor, the bridge); a unit
      ## sees no login shell's variables, and the sessions this starts run
      ## that program.
      environment = lib.filterAttrs (n: _: lib.hasPrefix "FABRIEK_" n) config.environment.variables;
      path = [
        pkgs.git
        pkgs.fabriek-container
        "/run/current-system/sw"
      ];
      serviceConfig = {
        ExecStart = "${pkgs.nodejs}/bin/node ${pkgs.fabriek-factory}/lib/fabriek-factory/dist/executor/main.js";
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
