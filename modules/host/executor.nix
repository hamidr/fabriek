## The executor (ADR-034 point 2): uncaged, holds every credential of its
## factory, decides nothing. One unit per factory, as root, because it
## starts sessions through the machine program and reads the tokens up
## made. Restarted when it dies, and reconciles the board on every start
## before routing anything (ADR-033 point 4).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fabriek;
in
{
  config = lib.mkIf cfg.enable {
    ## The relay, for the machine program's factory-watch (ADR-039 point 2).
    environment.systemPackages = [ pkgs.fabriek-factory ];

    systemd.services = lib.mapAttrs' (
      name: _:
      lib.nameValuePair "fabriek-${name}-executor" {
        description = "The factory ${name}'s executor";
        wantedBy = [ "multi-user.target" ];
        after = [
          "fabriek-${name}-bus-acl.service"
          "fabriek-forge.service"
          "fabriek-${name}-state.service"
        ];
        wants = [
          "fabriek-${name}-bus-acl.service"
          "fabriek-forge.service"
        ];
        ## Not before up has prepared the factory for this start (profiles
        ## for this pin, accounts, tokens, passwords owned by their cages):
        ## a session started earlier fails, is deaf, or runs on last
        ## start's profile. up writes the mark last and restarts this unit
        ## on it; under /run on purpose, so a reboot is not prepared for
        ## the old pin (models/factory-lifecycle.qnt).
        unitConfig.ConditionPathExists = "/run/fabriek/${name}/prepared";
        path = [
          pkgs.git
          pkgs.fabriek-container
          "/run/current-system/sw"
        ];
        serviceConfig = {
          ## The factory's facts: where render wrote, the floor, the
          ## bridge; a unit sees no login shell's variables, and the
          ## sessions this starts run the machine program.
          EnvironmentFile = "/etc/fabriek/factories/${name}.env";
          ExecStart = "${pkgs.nodejs}/bin/node ${pkgs.fabriek-factory}/lib/fabriek-factory/dist/executor/main.js";
          Restart = "always";
          RestartSec = 5;
          Slice = "fabriek-${name}.slice";
        };
      }
    ) cfg.plan;
  };
}
