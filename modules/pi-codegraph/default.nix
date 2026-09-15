## pi-codegraph, the pi extension that gives a role the codegraph tools
## (ADR-049): codegraph_explore, codegraph_node, codegraph_callers and the
## rest, each answered by a `codegraph serve --mcp` it spawns from PATH
## against the worktree. pi has no MCP of its own and says to build the
## adapter as an extension; this is the community's, one file with no
## dependency beyond what pi hands every extension (typebox and its own
## types), so it is the tarball and nothing built.
{ pkgs }:
pkgs.stdenvNoCC.mkDerivation {
  pname = "pi-codegraph";
  version = "0.1.10";
  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@vndv/pi-codegraph/-/pi-codegraph-0.1.10.tgz";
    hash = "sha256-QV7TBdbzuZwdNNAffOqeoXRVKjeJumpNF4S57KzAGmU=";
  };
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r extensions LICENSE package.json $out/
    runHook postInstall
  '';
  ## What pi loads: the one file the package's `pi.extensions` names.
  passthru.extension = "extensions/codegraph.ts";
  meta.license = pkgs.lib.licenses.mit;
}
