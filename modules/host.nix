## A NixOS host declares its factories (ADR-048): services.fabriek renders
## the operator's config.toml, the same file a person keeps on any other
## host, and a unit per factory asked to start at boot. The module writes
## the file and the CLI reads it; nothing here checks what the CLI's own
## schema checks, so the two cannot drift.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fabriek;

  ## The file, rendered here rather than by a derivation so that its text
  ## is a value of the evaluation: a scenario reads it without a build. The
  ## schema is three kinds of value and one level of table, which is all
  ## TOML this needs.
  tomlValue =
    v:
    if builtins.isInt v then
      toString v
    else if builtins.isList v then
      "[ ${lib.concatMapStringsSep ", " tomlValue v} ]"
    else
      builtins.toJSON v;
  tomlKey = k: if builtins.match "[A-Za-z0-9_-]+" k != null then k else builtins.toJSON k;
  tomlPairs =
    attrs: lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "${tomlKey k} = ${tomlValue v}") attrs);
  tomlTable = name: attrs: "[${name}]\n${tomlPairs attrs}\n";
  rendered = lib.concatStringsSep "\n" (
    [ (tomlTable "caps" cfg.caps) ]
    ++ lib.mapAttrsToList (
      name: f: tomlTable "factories.${tomlKey name}" { inherit (f) path; }
    ) cfg.factories
    ++ lib.mapAttrsToList (
      host: c: tomlTable "credentials.${tomlKey host}" { inherit (c) header file; }
    ) cfg.credentials
    ++ lib.optional (cfg.models != { }) (tomlTable "models" cfg.models)
  );
  autoStarted = lib.filterAttrs (_: f: f.autoStart) cfg.factories;
in
{
  options.services.fabriek = {
    enable = lib.mkEnableOption "fabriek, a factory of named roles per repository, on this host";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.fabriek;
      defaultText = lib.literalExpression "pkgs.fabriek";
      description = "The launcher the units run and a person types.";
    };

    caps = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.str
          lib.types.int
          (lib.types.listOf lib.types.str)
        ]
      );
      default = { };
      example = {
        memory = "16G";
        cores = 8;
        egress = [ "api.anthropic.com" ];
      };
      description = ''
        What a factory may cost on this host: the [caps] section, the same
        fields a repository may ask for, clamped against these (ADR-020).
      '';
    };

    credentials = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            header = lib.mkOption {
              type = lib.types.str;
              description = "The header the credential travels in, at the proxy.";
            };
            file = lib.mkOption {
              type = lib.types.str;
              description = "A path on this host holding the credential; never the value (ADR-025).";
            };
          };
        }
      );
      default = { };
      description = "Per endpoint, which header carries the credential and which file holds it.";
    };

    models = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "api.anthropic.com" = "claude-opus-5";
      };
      description = "Per endpoint, the model a session starts on; a declaration cannot name one (ADR-029).";
    };

    factories = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption {
              type = lib.types.str;
              description = "The checkout on this host whose origin the factory's machine clones (ADR-032).";
            };
            autoStart = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Bring this factory's machine up at boot and down at shutdown, as a unit.";
            };
          };
        }
      );
      default = { };
      description = "The factories registered on this host, by name.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."fabriek/config.toml".text = rendered;
    environment.systemPackages = [ cfg.package ];

    ## One unit per factory asked for: the same program a person runs, on
    ## the same file and the same state, so `fabriek ps` sees both.
    systemd.services = lib.mapAttrs' (
      name: _:
      lib.nameValuePair "fabriek-${name}" {
        description = "The machine the factory ${name} runs in";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "nix-daemon.service"
        ];
        wants = [ "network-online.target" ];
        environment = {
          FABRIEK_CONFIG = "/etc/fabriek/config.toml";
          FABRIEK_MACHINES = "/var/lib/fabriek/machines";
        };
        path = [ pkgs.nix ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${cfg.package}/bin/fabriek up ${name}";
          ExecStop = "${cfg.package}/bin/fabriek down ${name}";
          StateDirectory = "fabriek";
        };
      }
    ) autoStarted;
  };
}
