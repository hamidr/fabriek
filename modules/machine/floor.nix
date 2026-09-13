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
  settingsText = builtins.toJSON {
    defaultProvider = startOn;
    defaultModel = defaultModels.${startOn};
    ## A repository's own .pi is not the machine's to run: a session asks
    ## nobody, and what a role runs is declared, not found in the tree.
    defaultProjectTrust = "never";
  };
  settings = {
    mode = "0444";
    text = settingsText;
  };
  ## The credential is the proxy's to add; the placeholder only makes pi
  ## consider the provider configured. The path is the proxy's per-host
  ## location, so a request to the provider lands at the proxy and leaves
  ## the machine with the header the operator holds.
  modelsText = builtins.toJSON {
    providers = lib.mapAttrs' (
      host: provider:
      lib.nameValuePair provider {
        baseUrl = "http://${plan.proxy}/${host}";
        apiKey = "fabriek";
      }
    ) routed;
  };
  loopText = ''
    // The loop (ADR-035). Built into the machine; nothing here is the
    // repository's to change.
    export { default } from "${extension}";
  '';

  ## The language-server extension (ADR-043), loaded the way the loop is:
  ## a real index.ts re-exporting the store path, because pi resolves an
  ## extension's imports from where it found the file, and a symlink into
  ## the store would leave vscode-jsonrpc unresolvable.
  lspText = ''
    export { default } from "${pkgs.pi-lsp}/${pkgs.pi-lsp.extension}/index.ts";
  '';

  ## A role's own pi directory (ADR-042 point 5): the loop, the models and
  ## the settings every role gets, and from its profile the prompt, the
  ## skills and the language servers of who it is. One store path per
  ## role, resolved by the machine program like the profile is, so what the
  ## cage binds carries no symlink into an /etc it does not have.
  roles = lib.attrNames (cfg.declaration.roles or { });
  piDirOf =
    role:
    let
      profile = config.environment.etc."fabriek/roles/${role}/profile".source;
    in
    pkgs.runCommand "fabriek-pi-${role}" { } ''
      mkdir -p $out/extensions/fabriek $out/extensions/pi-lsp
      cat >$out/extensions/fabriek/index.ts <<'TS'
      ${loopText}TS
      cat >$out/extensions/pi-lsp/index.ts <<'TS'
      ${lspText}TS
      ln -s ${profile}/share/fabriek/specialist/lsp.json $out/lsp.json
      cp ${pkgs.writeText "settings.json" settingsText} $out/settings.json
      cp ${pkgs.writeText "models.json" modelsText} $out/models.json
      ln -s ${profile}/share/fabriek/specialist/skills $out/skills
      ln -s ${profile}/share/fabriek/specialist/APPEND_SYSTEM.md $out/APPEND_SYSTEM.md
    '';
in
{
  config = {
    nixcage.containerPackages = [ pkgs.pi-coding-agent ];

    environment.etc =
      lib.listToAttrs (
        map (role: lib.nameValuePair "fabriek/roles/${role}/pi" { source = piDirOf role; }) roles
      )
      // {
        ## The decider's loop (ADR-034 point 1), in a directory of its own
        ## so a role's session never loads it. Real files, not /etc's usual
        ## symlinks: a session binds the directory and a cage has no
        ## /etc/static for a symlink to land in. Same models.json as a
        ## role's: the decider reaches the model through the same proxy and
        ## is counted on its own address.
        "fabriek/pi-decider/extensions/fabriek/index.ts" = {
          mode = "0444";
          text = ''
            export { default } from "${pkgs.fabriek-factory}/lib/fabriek-factory/dist/decider/index.js";
          '';
        };
        "fabriek/pi-decider/settings.json" = settings;
        "fabriek/pi-decider/models.json" = {
          mode = "0444";
          text = modelsText;
        };
      };
  };
}
