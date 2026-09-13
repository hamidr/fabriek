## What every cage carries whatever the repository declares (ADR-030), now
## including the loop (ADR-035 point 2): pi's configuration directory with
## the extension in it and a models.json that points pi's provider at the
## proxy (ADR-029 point 6, ADR-037). Bound read-only into every supervised
## session at the path PI_CODING_AGENT_DIR names, so a repository that forgets
## the agent, the loop or the proxy still gets a role that starts.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fabriek.machine;
  plan = builtins.fromJSON config.environment.etc."fabriek/bridge.json".text;
  extension = "${pkgs.fabriek-factory}/lib/fabriek-factory/dist/extension/index.js";
  ## Which of pi's built-in providers answers at which allowed endpoint. Only
  ## the ones fabriek knows; an endpoint outside this table is reachable
  ## through the proxy but pi is not pointed at it.
  providers = {
    "api.anthropic.com" = "anthropic";
    "api.openai.com" = "openai";
  };
  routed = lib.filterAttrs (host: _: lib.elem host cfg.egress) providers;
  ## Where a session starts: on a model of the first routed provider, in
  ## declaration order of the table above. pi starts on no model unless
  ## told one, and a session with nobody at the keyboard cannot be asked.
  ## Which model is the machine's choice for now; a declaration cannot name
  ## one (ADR-029 pins the agent, not the model).
  defaultModels = {
    anthropic = "claude-sonnet-4-5";
    openai = "gpt-5";
  };
  startOn = lib.head ((lib.attrValues routed) ++ [ "anthropic" ]);
  settings = {
    mode = "0444";
    text = builtins.toJSON {
      defaultProvider = startOn;
      defaultModel = defaultModels.${startOn};
      ## A repository's own .pi is not the machine's to run: a session asks
      ## nobody, and what a role runs is declared, not found in the tree.
      defaultProjectTrust = "never";
    };
  };
in
{
  config = {
    nixcage.containerPackages = [ pkgs.pi-coding-agent ];

    ## Real files, not /etc's usual symlinks: a session binds the directory
    ## and a cage has no /etc/static for a symlink to land in.
    environment.etc."fabriek/pi/extensions/fabriek/index.ts" = {
      mode = "0444";
      text = ''
        // The loop (ADR-035). Built into the machine; nothing here is the
        // repository's to change.
        export { default } from "${extension}";
      '';
    };

    ## The decider's loop (ADR-034 point 1), in a directory of its own so a
    ## role's session never loads it. Same models.json: the decider reaches
    ## the model through the same proxy and is counted on its own address.
    environment.etc."fabriek/pi-decider/extensions/fabriek/index.ts" = {
      mode = "0444";
      text = ''
        export { default } from "${pkgs.fabriek-factory}/lib/fabriek-factory/dist/decider/index.js";
      '';
    };
    environment.etc."fabriek/pi/settings.json" = settings;
    environment.etc."fabriek/pi-decider/settings.json" = settings;
    environment.etc."fabriek/pi-decider/models.json" = {
      mode = "0444";
      source = config.environment.etc."fabriek/pi/models.json".source;
    };

    ## The credential is the proxy's to add; the placeholder only makes pi
    ## consider the provider configured. The path is the proxy's per-host
    ## location, so a request to the provider lands at the proxy and leaves
    ## the machine with the header the operator holds.
    environment.etc."fabriek/pi/models.json" = {
      mode = "0444";
      text = builtins.toJSON {
        providers = lib.mapAttrs' (
          host: provider:
          lib.nameValuePair provider {
            baseUrl = "http://${plan.proxy}/${host}";
            apiKey = "fabriek";
          }
        ) routed;
      };
    };
  };
}
