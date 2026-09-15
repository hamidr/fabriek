## One factory's machine, from the repository it works and the facts only the
## operator's host knows (ADR-040).
##
## The declaration is the repository's fabriek.toml, read from the rev the
## machine flake's lock pins (ADR-058). Validation and the clamp run inside
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
  machinePkgs = nixpkgs.legacyPackages.${facts.system};

  ## fabriek.toml at the repository's root, at the rev the machine flake's
  ## lock pins; the flake's fabriek output is not read, and a repository
  ## still declaring through it is told so rather than built with no roles.
  declarationFile = "${project}/fabriek.toml";
  declaration =
    if builtins.pathExists declarationFile then
      builtins.fromTOML (builtins.readFile declarationFile)
    else
      throw (
        "the repository ${facts.factory} works has no fabriek.toml at its root"
        + (if project ? fabriek then "; the flake output is no longer read" else "")
      );

  ## The spec, composed by modules/machine-spec.sh in a build. Import from
  ## derivation on purpose: the modules are the one description of what a
  ## declaration may say, and a second one in Nix would drift.
  specFile =
    hostPkgs.runCommand "fabriek-spec-${facts.factory}"
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
        fabriek_machine_spec "$declarationPath" ${local} >"$out"
      '';
  spec = builtins.fromJSON (builtins.readFile specFile);

  ## Who a role is (ADR-042): the specialists it names, composed from the
  ## shipped catalogue and the repository's own when it declares one, into
  ## one derivation carrying their tools, prompts and skills. Resolved
  ## against the machine's packages, because a specialist's kit is the
  ## machine's to pin like the floor is; a name no catalogue has is a build
  ## failure naming the role.
  catalogue = import ./catalogue.nix { inherit self; } {
    pkgs = machinePkgs;
    extra = lib.optional (spec.declaration ? catalogue) "${project}/${spec.declaration.catalogue}";
  };
  specialistOf =
    name: role:
    catalogue.compose {
      role = name;
      specialists = role.specialists or [ ];
    };
  specialists = builtins.mapAttrs specialistOf (spec.declaration.roles or { });

  ## A role's toolchain, realised here because the cage cannot. The devShell
  ## the role names (or 'default' when it names none, ADR-016) is taken apart
  ## into the packages it would have put on PATH; its shellHook is not run,
  ## because there is no shell to run it in. A named shell the flake lacks is
  ## a build failure that says which role asked for it; a missing default is a
  ## role with the floor alone (ADR-005, ADR-030). The specialists' kit sits
  ## in front of the shell's tools, and the floor under both.
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
      ## stdenv hands a shell its inputs as dev outputs, which is what a
      ## build links against and not what a cage runs; a profile is made of
      ## the bin outputs, where ip and curl are. Not lib.getBin: it honours
      ## an output already chosen, and stdenv has chosen dev.
      binOf = p: p.bin or p.out or p;
      inputs =
        if shell == null then
          [ ]
        else
          map binOf (
            (shell.buildInputs or [ ])
            ++ (shell.nativeBuildInputs or [ ])
            ++ (shell.propagatedBuildInputs or [ ])
          );
    in
    ## Forced here so that a role naming a shell the flake lacks fails at
    ## evaluation, where the message names the role, and not at the first
    ## build that happens to realise the profile.
    builtins.seq inputs (
      machinePkgs.buildEnv {
        name = "fabriek-role-${name}";
        paths = [ specialists.${name} ] ++ inputs;
        ignoreCollisions = true;
      }
    );
  profiles = builtins.mapAttrs profileOf (spec.declaration.roles or { });

  ## What the machine carries of all this beyond the spec: one profile per
  ## role. The declaration itself rides in the spec and machine/default.nix writes
  ## it to the machine as a file.
  ## The decider's policy (ADR-034 point 5): one file the declaration names,
  ## read out of the pinned repository at build time, so the policy a run used
  ## is part of the image like the rest of the declaration.
  policy = spec.declaration.decider.policy or null;
  policyModule = lib.optionalAttrs (policy != null) {
    environment.etc."fabriek/decider-policy.md".source = "${project}/${policy}";
  };
  factoryModule = {
    environment.etc =
      lib.mapAttrs' (
        name: profile: lib.nameValuePair "fabriek/roles/${name}/profile" { source = profile; }
      ) profiles
      // (policyModule.environment.etc or { });
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
  inherit spec profiles specialists;
  inherit (facts) hostSystem;
  config = machine.config;
  runner = machine.config.microvm.declaredRunner;
}
