## What every cage carries whatever the repository declares (ADR-030), now
## including the loop (ADR-035 point 2): pi itself, and the floor, one store
## path with the loop's and the two extensions' index files, the decider's
## loop, and the guidance every role is told (ADR-054). Nothing of a factory
## is here: one floor serves every factory on the host (ADR-067), render
## composes each role's pi directory from it, the role's profile and the
## rendered models (modules/factory-render.sh), and the machine program
## hands the floor to the session as a store root so the cage sees what the
## index files import (nixcage ADR-014).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fabriek;
  extension = "${pkgs.fabriek-factory}/lib/fabriek-factory/dist/extension/index.js";
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

  deciderText = ''
    export { default } from "${pkgs.fabriek-factory}/lib/fabriek-factory/dist/decider/index.js";
  '';

  floor = pkgs.runCommand "fabriek-floor" { } ''
    mkdir -p $out/extensions/fabriek $out/extensions/pi-lsp $out/extensions/pi-codegraph \
      $out/decider/extensions/fabriek
    cat >$out/extensions/fabriek/index.ts <<'TS'
    ${loopText}TS
    cat >$out/extensions/pi-lsp/index.ts <<'TS'
    ${lspText}TS
    cat >$out/extensions/pi-codegraph/index.ts <<'TS'
    ${codegraphText}TS
    cat >$out/decider/extensions/fabriek/index.ts <<'TS'
    ${deciderText}TS
    cp ${../role-guidance.md} $out/guidance.md
  '';
in
{
  ## Read-only: the floor is the host's, named here so the suite can build
  ## it for real and the facts file can carry it.
  options.services.fabriek.floor = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    default = floor;
    description = "The store path every role's pi directory is composed from.";
  };

  config = lib.mkIf cfg.enable {
    nixcage.containerPackages = [ pkgs.pi-coding-agent ];
  };
}
