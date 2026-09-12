## The factory's TypeScript package: the executor, the extension, the decider,
## the relay and the TUI, in one package so the vocabulary and the bus
## messages are defined once (ADR-034 point 2).
##
## No npm and no lockfile. The package has no runtime dependency of its own:
## the bus is spoken over a socket, the forge over HTTP, and pi's types come
## from the pi that is already in the closure (ADR-035). node_modules is a
## derivation of symlinks into that package, so the same directory serves the
## build here and the developer's checkout.
{ pkgs }:
let
  pi = pkgs.pi-coding-agent;
  piModules = "${pi}/lib/node_modules/pi-monorepo";
  nodeModules = pkgs.runCommand "cageworks-factory-node-modules" { } ''
    mkdir -p $out/@earendil-works
    ln -s ${piModules}/node_modules/@types $out/@types
    ln -s ${piModules} $out/@earendil-works/pi-coding-agent
  '';
in
{
  inherit nodeModules;

  package = pkgs.stdenv.mkDerivation {
    pname = "cageworks-factory";
    version = "0.1.0";
    src = ./.;
    nativeBuildInputs = [
      pkgs.nodejs
      pkgs.typescript
    ];
    doCheck = true;
    buildPhase = ''
      ln -s ${nodeModules} node_modules
      tsc -p .
    '';
    checkPhase = ''
      node --test "dist/**/*.test.js"
    '';
    installPhase = ''
      mkdir -p $out/lib/cageworks-factory
      cp -r dist package.json $out/lib/cageworks-factory/
      ln -s ${nodeModules} $out/lib/cageworks-factory/node_modules
    '';
  };
}
