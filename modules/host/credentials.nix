## A credential the operator renewed reaches the proxy without an up
## (ADR-072 points 3 and 4). The operator's push writes a temporary name in
## a directory of theirs and renames it, which a watch on the file's old
## inode never sees; the directory is watched, and sees the create and the
## move. The unit files every rendered factory's credentials again.
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
    systemd.tmpfiles.rules = [
      "d ${cfg.credentialsDir} 0700 ${
        if cfg.credentialsOwner == null then "root" else cfg.credentialsOwner
      } root -"
    ];

    systemd.paths.fabriek-credentials = {
      description = "A credential the operator keeps changed";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = cfg.credentialsDir;
        Unit = "fabriek-credential-refresh.service";
      };
    };

    systemd.services.fabriek-credential-refresh = {
      description = "File every factory's credentials again from the operator's files";
      environment.FABRIEK_CONFIG = "/etc/fabriek/config.toml";
      path = [
        pkgs.fabriek-container
        "/run/current-system/sw"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.fabriek-container}/bin/fabriek-container credential-refresh";
      };
    };
  };
}
