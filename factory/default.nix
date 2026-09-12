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
  inherit (pkgs) lib;
  pi = pkgs.pi-coding-agent;
  piModules = "${pi}/lib/node_modules/pi-monorepo";
  nodeModules = pkgs.runCommand "cageworks-factory-node-modules" { } ''
    mkdir -p $out/@earendil-works
    ln -s ${piModules}/node_modules/@types $out/@types
    ln -s ${piModules}/node_modules/typebox $out/typebox
    ln -s ${piModules} $out/@earendil-works/pi-coding-agent
  '';
in
{
  inherit nodeModules;

  package = pkgs.stdenv.mkDerivation {
    pname = "cageworks-factory";
    version = "0.1.0";
    ## The developer's checkout carries a node_modules link and a dist; a
    ## path: flake copies both, so they are filtered out of the source.
    src = builtins.path {
      path = ./.;
      name = "cageworks-factory-src";
      filter = path: _type: !(lib.hasSuffix "/node_modules" path || lib.hasSuffix "/dist" path);
    };
    nativeBuildInputs = [
      pkgs.nodejs
      pkgs.typescript
    ];
    doCheck = true;
    buildPhase = ''
      rm -rf node_modules dist
      ln -s ${nodeModules} node_modules
      tsc -p .
    '';
    checkPhase = ''
      cp src/relay/fixtures.json dist/relay/
      node --test "dist/**/*.test.js"
    '';
    installPhase = ''
      mkdir -p $out/lib/cageworks-factory $out/bin
      cp -r dist package.json $out/lib/cageworks-factory/
      cp src/relay/fixtures.json $out/lib/cageworks-factory/dist/relay/
      ln -s ${nodeModules} $out/lib/cageworks-factory/node_modules
      ## The programs the machine and the operator run by name.
      for prog in executor relay tui; do
        cat >$out/bin/cageworks-$prog <<EOF
      #!${pkgs.runtimeShell}
      exec ${pkgs.nodejs}/bin/node $out/lib/cageworks-factory/dist/$prog/main.js "\$@"
      EOF
        chmod +x $out/bin/cageworks-$prog
      done
    '';
  };
}
