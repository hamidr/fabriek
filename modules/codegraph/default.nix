## codegraph, the index a role queries its worktree through (ADR-049): a
## tree-sitter graph of symbols, calls and files in one SQLite file under
## the tree, with a CLI and an MCP server over it. Upstream ships one
## self-contained tarball per platform, a vendored node beside the bundle,
## which is what the installer distributes; building from npm would need
## the tree-sitter WASM build and a hash of its dependency tree for nothing
## the tarball lacks.
##
## Wrapped so that nothing in it reaches off the machine: a cage has no
## route (ADR-037), and a binary that tried the update check and the
## telemetry queue anyway would log a failure at every call.
{ pkgs }:
let
  inherit (pkgs) lib stdenvNoCC;
  version = "1.6.0";
  assets = {
    aarch64-darwin = {
      suffix = "darwin-arm64";
      hash = "sha256-HHMDNRLVX2e+BHF+gVMui+r3vm+4Ux9RoXn6IwZK1IA=";
    };
    x86_64-linux = {
      suffix = "linux-x64";
      hash = "sha256-3jOR957UJiLZN+bNW3ZCp+qLt9FHNgfoC4ebpz7yFrA=";
    };
    aarch64-linux = {
      suffix = "linux-arm64";
      hash = "sha256-bck1p7jxph5oileLmOo0aA6y4217kdsHnWT0AR8aZo8=";
    };
  };
  asset =
    assets.${stdenvNoCC.hostPlatform.system}
      or (throw "codegraph: no release for ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "codegraph";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://github.com/colbymchenry/codegraph/releases/download/v${version}/codegraph-${asset.suffix}.tar.gz";
    inherit (asset) hash;
  };
  sourceRoot = "codegraph-${asset.suffix}";

  ## The vendored node on Linux is a dynamic ELF; darwin's needs nothing.
  nativeBuildInputs = [
    pkgs.makeWrapper
  ]
  ++ lib.optionals stdenvNoCC.hostPlatform.isLinux [ pkgs.autoPatchelfHook ];
  buildInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
  ];

  dontConfigure = true;
  dontBuild = true;

  ## The bundle stays whole under libexec; the launcher resolves its own
  ## symlink back to the bundle before it execs node.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/libexec/codegraph" "$out/bin"
    cp -a . "$out/libexec/codegraph/"
    makeWrapper "$out/libexec/codegraph/bin/codegraph" "$out/bin/codegraph" \
      --set CODEGRAPH_TELEMETRY 0 \
      --set CODEGRAPH_NO_UPDATE_CHECK 1
    runHook postInstall
  '';

  meta = {
    description = "Pre-indexed code knowledge graph and MCP server for coding agents";
    homepage = "https://github.com/colbymchenry/codegraph";
    license = lib.licenses.mit;
    mainProgram = "codegraph";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames assets;
  };
}
