## One role's profile, built by the machine's own daemon at prepare
## (ADR-057 point 5): the devShell the role names, taken apart into the
## packages it would have put on PATH, unioned with the kit of the
## specialists it names. What the build under ADR-040 did for every role at
## once, this does for one, from the repository at the pin, so a cage that
## has no daemon (ADR-037) is handed a toolchain it could not realise.
##
## Evaluated by fabriek-container with --restrict-eval and the URIs it may
## reach named (ADR-057 point 6): the clone at the rev and the repository's
## locked inputs. fabriek and its nixpkgs are two store paths the image
## names, on the search path, so nothing of fabriek's own lock is fetched
## here: a getFlake on fabriek would fetch every input it locks, from the
## machine, for every factory (measured 2026-09-16). The flake is read
## only when the commit has one, so a repository without a flake is a role
## with its specialists alone.
{
  ## fabriek itself, for the catalogue, and the nixpkgs it pins.
  self,
  nixpkgs,
  ## The repository's clone and the rev the pin names.
  clone,
  rev,
  system,
  role,
  ## The role's table of the declaration: specialists, shell.
  specialists ? [ ],
  shell ? null,
  ## The repository's own catalogue, a path under it, or null (ADR-042).
  catalogue ? null,
  ## The operator's specialists and skills declared in TOML, and catalogue
  ## directories of the operator's own, as store paths (ADR-061).
  declared ? {
    specialists = { };
    skills = { };
  },
  catalogues ? [ ],
}:
let
  pkgs = import nixpkgs { inherit system; };
  lib = pkgs.lib;
  ## The commit's tree, for the catalogue: a fetch, not the flake, so a
  ## repository without a flake still has one (ADR-058 point 3).
  source = builtins.fetchGit {
    url = "file://${clone}";
    inherit rev;
  };
  project = builtins.getFlake "git+file://${clone}?rev=${rev}";
  ## fabriek's first, the operator's, the repository's (ADR-061 point 5).
  composed = import "${self}/modules/catalogue.nix" { inherit self; } {
    inherit pkgs declared;
    extra = catalogues ++ lib.optional (catalogue != null) "${source}/${catalogue}";
  };
  kit = composed.compose { inherit role specialists; };
  ## stdenv hands a shell its inputs as dev outputs, which is what a build
  ## links against and not what a cage runs; a profile is made of the bin
  ## outputs, where ip and curl are. Not lib.getBin: it honours an output
  ## already chosen, and stdenv has chosen dev.
  binOf = p: p.bin or p.out or p;
  ## The devShell the role names, or default when it names none and the
  ## repository has one (ADR-016); a repository with no flake, or no
  ## default, is a role with its specialists alone. A named shell the flake
  ## lacks is a refusal naming the role.
  ## Asked with hasAttr and not with `or`: `or` also swallows an error in
  ## evaluating the attribute, and a refused fetch of the flake's input
  ## then reads as a devShell the repository does not define (measured
  ## 2026-09-16).
  ## readDir and not pathExists: pathExists answers false to a fetch
  ## restricted mode refused, and the refusal must be the error.
  shells =
    if
      (builtins.readDir source) ? "flake.nix" && project ? devShells && project.devShells ? ${system}
    then
      project.devShells.${system}
    else
      { };
  devShell =
    if shell != null then
      if shells ? ${shell} then
        shells.${shell}
      else
        throw "role ${role} names devShell ${shell}, which the repository does not define for ${system}"
    else if shells ? default then
      shells.default
    else
      null;
  inputs =
    if devShell == null then
      [ ]
    else
      map binOf (
        (devShell.buildInputs or [ ])
        ++ (devShell.nativeBuildInputs or [ ])
        ++ (devShell.propagatedBuildInputs or [ ])
      );
in
builtins.seq inputs (
  pkgs.buildEnv {
    name = "fabriek-role-${role}";
    paths = [ kit ] ++ inputs;
    ignoreCollisions = true;
  }
)
