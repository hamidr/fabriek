## One factory's machine, from the repository it works and the facts only the
## operator's host knows (ADR-040).
##
## The declaration is the repository's own 'cageworks' output, evaluated from
## the rev the machine flake's lock pins. Validation and the clamp run inside
## a derivation, by the same shell modules the operator's side used to run at
## every command, so a bad declaration fails the build with its own message
## and nothing on the machine ever evaluates a declaration again. What comes
## out is the spec vm.nix has always taken, plus the clamped declaration as a
## file on the machine and a profile per role built from its devShell, because
## a cage has no nix daemon (ADR-037) and cannot realise one itself.
{
  nixpkgs,
  microvm,
  nixcage,
  self,
}:
{
  ## The repository's flake, as an input of the machine flake.
  project,
  ## Path to local.json: factory, system, hostSystem, sshPort, authorizedKey,
  ## caps, credentials (host to header). Never a secret (ADR-025).
  local,
}:
let
  lib = nixpkgs.lib;
  facts = builtins.fromJSON (builtins.readFile local);
  hostPkgs = nixpkgs.legacyPackages.${facts.hostSystem};
  guestPkgs = nixpkgs.legacyPackages.${facts.system};

  declaration =
    project.cageworks
      or (throw "the repository ${facts.factory} works declares no factory: its flake has no 'cageworks' output");

  ## The spec, composed by modules/machine-spec.sh in a build. Import from
  ## derivation on purpose: the modules are the one description of what a
  ## declaration may say, and a second one in Nix would drift.
  specFile =
    hostPkgs.runCommand "cageworks-spec-${facts.factory}"
      {
        nativeBuildInputs = [
          hostPkgs.bash
          hostPkgs.jq
        ];
        declaration = builtins.toJSON declaration;
        passAsFile = [ "declaration" ];
      }
      ''
        for m in names sizes schema resources repo-declaration machine-spec; do
          . ${self}/modules/$m.sh
        done
        cageworks_machine_spec "$declarationPath" ${local} >"$out"
      '';
  spec = builtins.fromJSON (builtins.readFile specFile);

  ## A role's toolchain, realised here because the cage cannot. The devShell
  ## the role names (or 'default' when it names none, ADR-016) is taken apart
  ## into the packages it would have put on PATH; its shellHook is not run,
  ## because there is no shell to run it in. A named shell the flake lacks is
  ## a build failure that says which role asked for it; a missing default is a
  ## role with the floor alone (ADR-005, ADR-030).
  shellsOf = project.devShells.${facts.system} or { };
  profileOf =
    name: role:
    let
      shellName = role.shell or "default";
      shell =
        shellsOf.${shellName} or (
          if role ? shell then
            throw "role ${name} names devShell ${shellName}, which the repository does not define for ${facts.system}"
          else
            null
        );
      inputs =
        if shell == null then
          [ ]
        else
          (shell.buildInputs or [ ])
          ++ (shell.nativeBuildInputs or [ ])
          ++ (shell.propagatedBuildInputs or [ ]);
    in
    ## Forced here so that a role naming a shell the flake lacks fails at
    ## evaluation, where the message names the role, and not at the first
    ## build that happens to realise the profile.
    builtins.seq inputs (
      guestPkgs.buildEnv {
        name = "cageworks-role-${name}";
        paths = inputs;
        ignoreCollisions = true;
      }
    );
  profiles = builtins.mapAttrs profileOf (spec.declaration.roles or { });

  ## What the machine carries of all this beyond the spec: one profile per
  ## role. The declaration itself rides in the spec and vm-guest.nix writes
  ## it to the machine as a file.
  factoryModule = {
    environment.etc = lib.mapAttrs' (
      name: profile: lib.nameValuePair "cageworks/roles/${name}/profile" { source = profile; }
    ) profiles;
  };

  machine = import ./vm.nix {
    inherit
      nixpkgs
      microvm
      nixcage
      self
      ;
  } (spec // { modules = [ factoryModule ]; });
in
{
  inherit spec profiles;
  inherit (facts) hostSystem;
  config = machine.config;
  runner = machine.config.microvm.declaredRunner;
}
