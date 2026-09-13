## pi-lsp, the pi extension that gives a role language-server tools
## (ADR-043). Declarative: servers come from lsp.json in the agent's
## directory, which is the per-role directory the machine builds, so what a
## role can start is what its specialists declared and nothing found in the
## tree.
##
## The npm tarball ships no lockfile, so the one beside this file is ours,
## made with `npm install --package-lock-only --legacy-peer-deps` over the
## package's runtime dependencies alone. Its peers (pi itself, pi-tui,
## typebox) are the pi in the closure and are not installed here; dev
## dependencies are stripped because the build runs no tests of its own.
{ pkgs }:
pkgs.buildNpmPackage {
  pname = "pi-lsp";
  version = "0.1.7";
  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/pi-lsp/-/pi-lsp-0.1.7.tgz";
    hash = "sha256-i5jlfxGgAhDZK5WhoCsY6Vt5bjTLjODy1CUeb36+0Ik=";
  };
  postPatch = ''
    ${pkgs.jq}/bin/jq 'del(.devDependencies, .scripts)' package.json > package.json.new
    mv package.json.new package.json
    cp ${./package-lock.json} package-lock.json
  '';
  npmDepsHash = "sha256-XkcNqe71bYveWuvufx4lEj1+6ostTt2Nx7DLo2u5ZxY=";
  npmFlags = [ "--legacy-peer-deps" ];
  dontNpmBuild = true;
  ## What pi loads: the extension's directory, with the shared helpers it
  ## imports by relative path beside it and node_modules above both.
  passthru.extension = "lib/node_modules/pi-lsp/extensions/pi-lsp";
  meta.license = pkgs.lib.licenses.mit;
}
