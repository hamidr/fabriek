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
    "api.deepseek.com" = "deepseek";
  };
  routed = lib.filterAttrs (host: _: lib.elem host cfg.egress) providers;
  ## Where a session starts: on a model of the first routed provider, in
  ## declaration order of the table above. pi starts on no model unless
  ## told one, and a session with nobody at the keyboard cannot be asked.
  ## Which model is the operator's to name per endpoint in their own config
  ## (egressModels); this table is what stands when they name none. A
  ## declaration cannot name one (ADR-029 pins the agent, not the model).
  defaultModels = {
    anthropic = "claude-sonnet-4-5";
    openai = "gpt-5";
    deepseek = "deepseek-v4-flash";
  };
  startOn = lib.head ((lib.attrValues routed) ++ [ "anthropic" ]);
  startHost = lib.head ((lib.attrNames routed) ++ [ "api.anthropic.com" ]);
  ## One file for the machine program to read onto pi's argv, rather than
  ## a settings.json in each pi directory: pi locks that file to read it,
  ## and the directory is bound read-only, so its settings never arrived.
  modelText = builtins.toJSON {
    provider = startOn;
    model = cfg.egressModels.${startHost} or defaultModels.${startOn};
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

  ## The codegraph tools (ADR-049), the same way. The binary they spawn is
  ## the developer specialist's, on the role's PATH; a role without it is
  ## told so by the tools themselves.
  codegraphText = ''
    export { default } from "${pkgs.pi-codegraph}/${pkgs.pi-codegraph.extension}";
  '';

  ## What every role is told about working in a cage (ADR-054): the front
  ## of its system prompt, before the specialists' prompts. Here rather
  ## than bound into the cage as a file, because nothing in a cage read the
  ## file; a system prompt is read.
  guidance = ../role-guidance.md;

  ## A role's own pi directory (ADR-042 point 5): the loop and the models
  ## every role gets, and from its profile the prompt, the
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
      mkdir -p $out/extensions/fabriek $out/extensions/pi-lsp $out/extensions/pi-codegraph
      cat >$out/extensions/fabriek/index.ts <<'TS'
      ${loopText}TS
      cat >$out/extensions/pi-lsp/index.ts <<'TS'
      ${lspText}TS
      cat >$out/extensions/pi-codegraph/index.ts <<'TS'
      ${codegraphText}TS
      ln -s ${profile}/share/fabriek/specialist/lsp.json $out/lsp.json
      ln -s ${profile}/share/fabriek/specialist/tests.json $out/tests.json
      cp ${pkgs.writeText "models.json" modelsText} $out/models.json
      ln -s ${profile}/share/fabriek/specialist/skills $out/skills
      cat ${guidance} ${profile}/share/fabriek/specialist/APPEND_SYSTEM.md >$out/APPEND_SYSTEM.md
    '';
  ## The decider's own directory (ADR-034 point 1): its loop and the same
  ## models.json, one store path like a role's so the session can name it
  ## a root. The models ride on passthru for the suite, which evaluates and
  ## does not build.
  deciderDir = pkgs.runCommand "fabriek-pi-decider" { passthru.models = modelsText; } ''
    mkdir -p $out/extensions/fabriek
    cat >$out/extensions/fabriek/index.ts <<'TS'
    export { default } from "${pkgs.fabriek-factory}/lib/fabriek-factory/dist/decider/index.js";
    TS
    cp ${pkgs.writeText "models.json" modelsText} $out/models.json
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
        ## so a role's session never loads it: one store path like a role's,
        ## resolved by the machine program and handed to the session as a
        ## root, so the cage sees the loop the index imports (nixcage
        ## ADR-014). Same models.json as a role's: the decider reaches the
        ## model through the same proxy and is counted on its own address.
        "fabriek/pi-decider".source = deciderDir;
        "fabriek/model.json" = {
          mode = "0444";
          text = modelText;
        };
      };
  };
}
