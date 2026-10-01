## A factory's npm cache (ADR-046 point 1d): each artifact a lockfile names,
## fetched once by its integrity, laid out as npm's own cache so that
## `npm ci --offline` resolves from it read-only out of the store. Built on
## the host at render, beside the profiles; the artifacts are the ones
## modules/dependency-cache.sh let through, so every url here is on an
## allowed registry.
{
  nixpkgs,
  system,
  ## [ { url, integrity } ], each artifact once.
  artifacts,
}:
let
  pkgs = import nixpkgs { inherit system; };
  tarball =
    a:
    pkgs.fetchurl {
      inherit (a) url;
      hash = a.integrity;
    };
in
pkgs.runCommand "fabriek-npm-cache"
  {
    nativeBuildInputs = [ pkgs.nodejs ];
    tarballs = map tarball artifacts;
  }
  ''
    export HOME="$TMPDIR"
    for t in $tarballs; do
      npm cache add "$t" --cache "$out" --offline --logs-max=0 >/dev/null
    done
    ## npm's logs belong to the session that runs it, under its home.
    rm -rf "$out/_logs"
    mkdir -p "$out"
  ''
