## A NixOS host declares its factories (ADR-048): services.fabriek renders
## the operator's config.toml, the same file a person keeps on any other
## host, and a unit per factory asked to start at boot. The module writes
## the file and the CLI reads it; nothing here checks what the CLI's own
## schema checks, so the two cannot drift.
{ self, nixpkgs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fabriek;

  ## The file, rendered here rather than by a derivation so that its text
  ## is a value of the evaluation: a scenario reads it without a build.
  ## Nested tables and arrays of tables included (ADR-061): a factory
  ## declared whole is roles, workflows with their stages, resources. A
  ## path (a prompt, a SKILL.md, a catalogue directory) becomes the store
  ## path Nix makes of it, which is what up wants of the file.
  scalar =
    v: !builtins.isAttrs v && !(builtins.isList v && v != [ ] && builtins.isAttrs (lib.head v));
  tomlValue =
    v:
    if builtins.isBool v then
      lib.boolToString v
    else if builtins.isInt v then
      toString v
    else if builtins.isPath v then
      builtins.toJSON "${v}"
    else if builtins.isList v then
      "[ ${lib.concatMapStringsSep ", " tomlValue v} ]"
    else
      builtins.toJSON v;
  tomlKey = k: if builtins.match "[A-Za-z0-9_-]+" k != null then k else builtins.toJSON k;
  tomlTables =
    prefix: attrs:
    let
      p = if prefix == "" then "" else "${prefix}.";
      scalars = lib.filterAttrs (_: scalar) attrs;
      tables = lib.filterAttrs (_: v: builtins.isAttrs v) attrs;
      arrays = lib.filterAttrs (
        _: v: builtins.isList v && v != [ ] && builtins.isAttrs (lib.head v)
      ) attrs;
    in
    lib.optional (prefix != "" && (scalars != { } || (tables == { } && arrays == { }))) (
      "[${prefix}]\n"
      + lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "${tomlKey k} = ${tomlValue v}") scalars)
      + "\n"
    )
    ++ lib.optionals (prefix == "") (
      lib.mapAttrsToList (k: v: "${tomlKey k} = ${tomlValue v}\n") scalars
    )
    ++ lib.concatLists (lib.mapAttrsToList (k: v: tomlTables "${p}${tomlKey k}" v) tables)
    ++ lib.concatLists (
      lib.mapAttrsToList (
        k: vs:
        map (
          v:
          "[[${p}${tomlKey k}]]\n"
          + lib.concatStringsSep "\n" (lib.mapAttrsToList (k2: v2: "${tomlKey k2} = ${tomlValue v2}") v)
          + "\n"
        ) vs
      ) arrays
    );
  ## A factory's table is its path, autoStart left out (the unit is this
  ## module's), and the declaration keys given.
  factoryTable = f: lib.filterAttrs (k: v: k != "autoStart" && v != null && v != { }) f;
  rendered = lib.concatStringsSep "\n" (
    tomlTables "" (
      {
        inherit (cfg) caps;
        factories = lib.mapAttrs (_: factoryTable) cfg.factories;
        credentials = lib.mapAttrs (_: c: { inherit (c) header file; }) cfg.credentials;
        catalogues = cfg.catalogues;
      }
      // lib.optionalAttrs (cfg.models != { }) { inherit (cfg) models; }
      // lib.optionalAttrs (cfg.specialists != { }) {
        specialists = lib.mapAttrs (_: s: lib.filterAttrs (_: v: v != null && v != [ ]) s) cfg.specialists;
      }
      // lib.optionalAttrs (cfg.skills != { }) {
        skills = lib.mapAttrs (_: s: lib.filterAttrs (_: v: v != null && v != [ ]) s) cfg.skills;
      }
    )
  );
  autoStarted = lib.filterAttrs (_: f: f.autoStart) cfg.factories;

  ## Every name the machine had as a constant, as a function of the
  ## factory's name (ADR-067 point 3). The index is the factory's position
  ## among the declared names.
  plan = lib.listToAttrs (
    lib.imap0 (
      idx: name:
      lib.nameValuePair name {
        inherit idx;
        bridge = "fb-${toString idx}";
        host = "10.77.${toString idx}.1";
        state = "/var/lib/nixcage/fabriek/${name}";
        etc = "/var/lib/fabriek/${name}";
      }
    ) (lib.attrNames cfg.factories)
  );

  ## What the machine program is told through the environment, per
  ## factory: the units load it and the CLI hands it to fabriek-container
  ## for the factory named.
  facts =
    name: p:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "${k}=${v}") {
        FABRIEK_FACTORY = name;
        FABRIEK_BRIDGE = p.bridge;
        FABRIEK_BRIDGE_HOST = p.host;
        FABRIEK_PROXY_PORT = toString cfg.ports.egress;
        FABRIEK_FORGEJO_PORT = toString cfg.ports.forgejo;
        FABRIEK_VALKEY_PORT = toString cfg.ports.valkey;
        FABRIEK_STATE = p.state;
        ## The host's one forge (ADR-068 point 1): where its state is, so
        ## the machine program takes the lock beside it.
        FABRIEK_FORGE_STATE = cfg.board.work;
        FABRIEK_ETC = p.etc;
        FABRIEK_RUN = "/run/fabriek/${name}";
        FABRIEK_FLOOR = "${cfg.floor}";
        ## What render evaluates a role's profile from: this repository and
        ## the nixpkgs it pins, and the system the profile is built for.
        FABRIEK_SELF = "${self}";
        FABRIEK_NIXPKGS = "${nixpkgs}";
        FABRIEK_SYSTEM = pkgs.stdenv.hostPlatform.system;
      }
    )
    + "\n";

  ## The declaration's own shape (fabriek.toml, ADR-058), as options: what
  ## the CLI's schema checks is checked there, so these are loose on
  ## purpose and refuse only what Nix itself cannot render.
  json = lib.types.attrsOf (
    lib.types.oneOf [
      lib.types.str
      lib.types.int
      lib.types.bool
      (lib.types.listOf lib.types.str)
    ]
  );
  names = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
  };
  textOrPath = lib.types.either lib.types.str lib.types.path;
in
{
  imports = [
    ./host/state.nix
    ./host/bridge.nix
    ./host/bus.nix
    ./host/board.nix
    ./host/proxy.nix
    ./host/probes.nix
    ./host/floor.nix
    ./host/executor.nix
  ];

  options.services.fabriek = {
    enable = lib.mkEnableOption "fabriek, a factory of named roles per repository, on this host";

    ## Read-only: what the other files of this module key on.
    plan = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      readOnly = true;
      default = plan;
      description = "Per factory, the bridge, the address, the state and the rendered directory.";
    };
    ports = {
      forgejo = lib.mkOption {
        type = lib.types.port;
        default = 3000;
        description = "Where on a factory's bridge its board answers.";
      };
      valkey = lib.mkOption {
        type = lib.types.port;
        default = 6379;
        description = "Where on a factory's bridge its bus answers.";
      };
      egress = lib.mkOption {
        type = lib.types.port;
        default = 8118;
        description = "Where on a factory's bridge a role's agent finds the proxy.";
      };
    };

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
            ## The declaration, in fabriek.toml's own words (ADR-061 point
            ## 1): given here, the repository must carry none.
            roles = lib.mkOption {
              type = lib.types.attrsOf json;
              default = { };
              description = "The roles, as [roles.<name>] of fabriek.toml: provides, specialists, shell, replicas, command.";
            };
            workflows = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    stages = lib.mkOption {
                      type = lib.types.listOf json;
                      default = [ ];
                    };
                    budget = lib.mkOption {
                      type = json;
                      default = { };
                    };
                    consults = lib.mkOption {
                      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
                      default = { };
                    };
                  };
                }
              );
              default = { };
              description = "The workflows, as [workflows.<name>] of fabriek.toml.";
            };
            resources = lib.mkOption {
              type = json;
              default = { };
              description = "What this factory asks of the machine, as [resources] of fabriek.toml.";
            };
            decider = lib.mkOption {
              type = json;
              default = { };
              description = "The decider's table: policy, a file of the repository.";
            };
            catalogue = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "The repository's own catalogue, a path inside it.";
            };
          };
        }
      );
      default = { };
      description = "The factories registered on this host, by name.";
    };

    ## The operator's own specialists and skills (ADR-061 point 3), and
    ## catalogue directories with ADR-042's layout (point 4).
    specialists = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            extends = names;
            tools = names;
            skills = names;
            prompt = lib.mkOption {
              type = lib.types.nullOr textOrPath;
              default = null;
              description = "The prompt, as text or a path to a Markdown file.";
            };
          };
        }
      );
      default = { };
      description = "Specialists of the operator's own: tools by nixpkgs attribute, parents and skills by name.";
    };
    skills = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            tools = names;
            skill = lib.mkOption {
              type = textOrPath;
              description = "The SKILL.md, as text or a path to it.";
            };
          };
        }
      );
      default = { };
      description = "Skills of the operator's own, in the Agent Skills format.";
    };
    catalogues = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = "Catalogue directories of the operator's own, with fabriek's layout.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc = {
      "fabriek/config.toml".text = rendered;
    }
    // lib.mapAttrs' (
      name: p: lib.nameValuePair "fabriek/factories/${name}.env" { text = facts name p; }
    ) plan;
    environment.systemPackages = [
      cfg.package
      pkgs.git
      pkgs.fabriek-container
    ];

    ## The CLI reaches the machine program as root through sudo, for this
    ## one program and this one group (ADR-067 point 1); SETENV so the
    ## factory's facts pass. A person beside the unit is a member.
    users.groups.fabriek = { };
    security.sudo.extraRules = [
      {
        groups = [ "fabriek" ];
        commands = [
          {
            command = "/run/current-system/sw/bin/fabriek-container";
            options = [
              "NOPASSWD"
              "SETENV"
            ];
          }
        ];
      }
    ];

    ## One unit per factory asked for at boot: the same program a person
    ## runs, on the same file, so `fabriek ps` sees both. up runs as root
    ## here and needs no sudo; the checkout is the operator's and git
    ## refuses a directory another uid owns unless told, for this one
    ## path, that it is safe.
    systemd.services = lib.mapAttrs' (
      name: f:
      lib.nameValuePair "fabriek-${name}" {
        description = "The factory ${name}, brought up at boot";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "nix-daemon.service"
          "fabriek-${name}-state.service"
        ];
        wants = [ "network-online.target" ];
        environment = {
          FABRIEK_CONFIG = "/etc/fabriek/config.toml";
          GIT_CONFIG_COUNT = "1";
          GIT_CONFIG_KEY_0 = "safe.directory";
          GIT_CONFIG_VALUE_0 = f.path;
        };
        path = [
          pkgs.nix
          pkgs.fabriek-container
          "/run/current-system/sw"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          EnvironmentFile = "/etc/fabriek/factories/${name}.env";
          ExecStart = "${pkgs.fabriek-container}/bin/fabriek-container factory-up ${name}";
          ExecStop = "${pkgs.fabriek-container}/bin/fabriek-container factory-down ${name}";
          Slice = "fabriek-${name}.slice";
        };
      }
    ) autoStarted;
  };
}
