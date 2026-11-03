## What a role can be (ADR-042): the specialists and skills of every
## catalogue, and the one derivation a role gets from the specialists it
## names.
##
## A catalogue is a directory that says so: a default.nix calling the
## constructor handed to it as `fabriek.catalogue`, at the protocol version
## this file speaks, naming where its specialists and skills live. Each
## entry is a default.nix of its own, a function of pkgs and of the other
## entries, so a tool is a package and a parent is a value. fabriek ships
## one catalogue, the base; a repository or an operator may add others,
## and a specialist of theirs is one here only when it reaches the base
## through extends. Every refusal here names the directory or the entry it
## is about, because the person reading it is holding one and not a stack
## trace.
{ self }:
{
  ## The packages every tool resolves against: the machine's, not the
  ## repository's, because a specialist's kit is the machine's to pin like
  ## the floor is (ADR-030).
  pkgs,
  ## Catalogue directories beside the shipped one.
  extra ? [ ],
  ## The operator's specialists and skills declared in TOML (ADR-061 point
  ## 3), as the credential's JSON: tools by nixpkgs attribute, a prompt or
  ## a SKILL.md by path or as text.
  declared ? {
    specialists = { };
    skills = { };
  },
}:
let
  lib = pkgs.lib;
  base = toString "${self}/catalogue";

  ## The protocol a catalogue's default.nix is written against. The
  ## constructor tags what it is given and nothing more: the checks run
  ## where the directory is known, so a refusal can name it.
  version = 1;
  protocol = {
    catalogue = args: { __fabriekCatalogue = true; } // args;
  };
  catalogueKeys = [
    "version"
    "specialists"
    "skills"
  ];

  ## What a directory is as a catalogue: where each kind of entry lives,
  ## and whether it is the base. Anything short of a default.nix calling
  ## the constructor at this version is refused as not a catalogue, never
  ## read as an empty one.
  catalogueOf =
    dir:
    let
      root = toString dir;
      file = "${root}/default.nix";
      fn = import file;
      got = if builtins.isFunction fn then fn { fabriek = protocol; } else null;
      tagged = builtins.isAttrs got && (got.__fabriekCatalogue or false);
      unknown = lib.subtractLists catalogueKeys (
        lib.attrNames (removeAttrs got [ "__fabriekCatalogue" ])
      );
    in
    if !builtins.pathExists file then
      throw "catalogue ${root}: has no default.nix, so it is not a catalogue"
    else if !tagged then
      throw "catalogue ${root}: default.nix does not call fabriek.catalogue"
    else if unknown != [ ] then
      throw "catalogue ${root}: ${lib.head unknown} is not something a catalogue declares"
    else if !(got ? version) then
      throw "catalogue ${root}: declares no version"
    else if got.version != version then
      throw "catalogue ${root}: speaks protocol version ${toString got.version}; this fabriek speaks ${toString version}"
    else
      {
        specialists = toString (got.specialists or "${root}/specialists");
        skills = toString (got.skills or "${root}/skills");
        base = root == base;
      };
  catalogues = map catalogueOf ([ base ] ++ extra);

  ## What a TOML entry becomes: the node a directory's default.nix would
  ## have returned. A tool is looked up by name and refused with the
  ## nearest attribute nixpkgs has; text becomes a file in the store.
  package =
    kind: name: attr:
    pkgs.${attr} or (throw "${kind} ${name}: tool ${attr} is not a package of nixpkgs");
  fileOf = filename: value: if lib.hasPrefix "/" value then value else builtins.toFile filename value;
  declaredSkills = lib.mapAttrs (
    name: entry:
    let
      file = fileOf "SKILL.md" entry.skill;
    in
    {
      inherit name file;
      dir = "config.toml";
      base = false;
      tools = map (package "skill" name) (entry.tools or [ ]);
      ## Copied into a directory of its own, as a skill's is, so the build
      ## finds SKILL.md where every skill has it.
      src = pkgs.runCommand "fabriek-skill-${name}" { } ''
        mkdir $out
        cp ${
          builtins.path {
            path = file;
            name = "SKILL.md";
          }
        } $out/SKILL.md
      '';
    }
  ) (declared.skills or { });
  declaredSpecialists =
    c:
    lib.mapAttrs (
      name: entry:
      {
        inherit name;
        dir = "config.toml";
        base = false;
        extends = map (
          p: c.specialists.${p} or (throw "specialist ${name} extends ${p}, which no catalogue declares")
        ) (entry.extends or [ ]);
        tools = map (package "specialist" name) (entry.tools or [ ]);
        skills = map (
          k: c.skills.${k} or (throw "specialist ${name} names skill ${k}, which no catalogue declares")
        ) (entry.skills or [ ]);
      }
      // lib.optionalAttrs (entry ? prompt) { prompt = fileOf "PROMPT.md" entry.prompt; }
      // lib.optionalAttrs (entry ? model) { model = entry.model; }
    ) (declared.specialists or { });

  ## The keys an entry may carry. Anything else is a misspelling or a
  ## feature that does not exist, and both are refused by name.
  schema = {
    specialists = [
      "extends"
      "tools"
      "skills"
      "prompt"
      "lsp"
      "tests"
      "model"
    ];
    skills = [
      "tools"
      "src"
    ];
  };
  singular = kind: lib.removeSuffix "s" kind;

  ## name -> { dir, base }, for one kind across every catalogue. A name in
  ## two catalogues is refused rather than shadowed: a repository that
  ## quietly replaced a shipped specialist would be changing what every
  ## reader of the shipped one believes it means.
  entriesOf =
    kind:
    lib.foldl (
      acc: cat:
      let
        dir = cat.${kind};
        here =
          lib.mapAttrs
            (name: _: {
              dir = "${dir}/${name}";
              inherit (cat) base;
            })
            (
              lib.filterAttrs (_: type: type == "directory") (
                if builtins.pathExists dir then builtins.readDir dir else { }
              )
            );
        twice = lib.intersectLists (lib.attrNames acc) (lib.attrNames here);
      in
      if twice != [ ] then
        throw "${singular kind} ${lib.head twice} is declared twice: ${acc.${lib.head twice}.dir} and ${here.${lib.head twice}.dir}"
      else
        acc // here
    ) { } catalogues;

  checked =
    kind: name: dir: entry:
    let
      unknown = lib.subtractLists schema.${kind} (lib.attrNames entry);
    in
    if unknown == [ ] then
      entry
    else
      throw "${singular kind} ${name}: ${lib.head unknown} is not something a ${singular kind} declares (${dir}/default.nix)";

  load =
    kind: args:
    lib.mapAttrs (
      name:
      { dir, base }:
      checked kind name dir (import "${dir}/default.nix" args)
      // {
        inherit name dir base;
      }
    ) (entriesOf kind);

  ## Fixed so that a specialist extends another by value, and a skill is
  ## named by value from a specialist. The TOML-declared entries join by
  ## the same rule as a second directory: a name twice is refused.
  once =
    kind: dirs: toml:
    let
      twice = lib.intersectLists (lib.attrNames dirs) (lib.attrNames toml);
    in
    if twice != [ ] then
      throw "${singular kind} ${lib.head twice} is declared twice: ${dirs.${lib.head twice}.dir} and config.toml"
    else
      dirs // toml;
  catalogue = lib.fix (c: {
    skills = once "skills" (load "skills" { inherit pkgs; }) declaredSkills;
    specialists = once "specialists" (load "specialists" {
      inherit pkgs;
      inherit (c) skills specialists;
    }) (declaredSpecialists c);
  });

  ## The description a skill's frontmatter carries, which is what pi shows
  ## the model and what a listing shows a person; read at evaluation so
  ## nothing has to be built to say it. Empty when the file has none, which
  ## the build refuses.
  describe =
    skill:
    let
      lines = lib.splitString "\n" (builtins.readFile (skill.file or "${skill.src}/SKILL.md"));
      described = lib.filter (l: lib.hasPrefix "description:" l) lines;
    in
    skill
    // {
      description =
        if described == [ ] then "" else lib.trim (lib.removePrefix "description:" (lib.head described));
    };
  skillsDescribed = lib.mapAttrs (_: describe) catalogue.skills;

  ## Parents before children, left to right, each name once; so a diamond
  ## yields its top once. The path from a root is carried so that a cycle
  ## is refused as the cycle rather than as infinite recursion.
  flatten =
    roots:
    let
      go =
        path: acc: node:
        if lib.elem node.name path then
          throw "specialists extend in a cycle: ${lib.concatStringsSep " -> " (path ++ [ node.name ])}"
        else if lib.elem node.name acc.seen then
          acc
        else
          let
            parents = lib.foldl (go (path ++ [ node.name ])) acc (node.extends or [ ]);
          in
          {
            seen = parents.seen ++ [ node.name ];
            order = parents.order ++ [ node ];
          };
    in
    (lib.foldl (go [ ]) {
      seen = [ ];
      order = [ ];
    } roots).order;

  ## One derivation for one role: bin/ from every tool of every specialist
  ## and skill in the flattened set, share/fabriek/specialist/ with the
  ## prompts in order and each skill by name. The bin collision check and
  ## the skill frontmatter check run in the build, where the files are.
  compose =
    { role, specialists }:
    let
      offered = lib.concatStringsSep ", " (lib.attrNames catalogue.specialists);
      named = map (
        name:
        catalogue.specialists.${name}
          or (throw "role ${role} names specialist ${name}, which no catalogue declares; the catalogue offers: ${offered}")
      ) specialists;
      ## The base's roots, what a specialist from elsewhere is told to
      ## extend when it reaches none of the base.
      roots = lib.concatStringsSep ", " (
        lib.attrNames (lib.filterAttrs (_: s: s.base && (s.extends or [ ]) == [ ]) catalogue.specialists)
      );
      grounded =
        node:
        if lib.any (n: n.base) (flatten [ node ]) then
          node
        else
          throw "specialist ${node.name} extends nothing of fabriek's catalogue; extend ${roots} or one of its descendants";
      order = flatten (map grounded named);
      skillsOf = node: node.skills or [ ];
      toolsOf =
        node: map lib.getBin ((node.tools or [ ]) ++ lib.concatMap (s: s.tools or [ ]) (skillsOf node));
      skills = lib.foldl (acc: s: if lib.any (t: t.name == s.name) acc then acc else acc ++ [ s ]) [ ] (
        lib.concatMap skillsOf order
      );
      ## The model name a role's specialists give (ADR-072 point 2): the
      ## last one set in composition order, a child over its parents. The
      ## operator's endpoint says what the name means, so only its shape is
      ## checked here.
      modelName = lib.foldl (
        acc: node:
        if node ? model then
          if builtins.match "[A-Za-z0-9][A-Za-z0-9-]*" node.model != null then
            node.model
          else
            throw "specialist ${node.name} names model ${node.model}, which is not a model name"
        else
          acc
      ) "" order;
      prompt = lib.concatMapStrings (
        node: lib.optionalString (node ? prompt) "## ${node.name}\n\n${builtins.readFile node.prompt}\n"
      ) order;
      ## One line per tool: which specialist brought it, and its path.
      toolLines = lib.concatMapStrings (
        node: lib.concatMapStrings (t: "${node.name}\t${t}\n") (toolsOf node)
      ) order;
      skillLines = lib.concatMapStrings (s: "${s.name}\t${s.src}\n") skills;
      ## The language servers (ADR-043): pi-lsp's own shape, one entry per
      ## id across the flattened set. The same id from two specialists is
      ## two opinions about one binary, so it is refused naming both.
      servers =
        lib.foldl
          (
            acc: node:
            lib.foldl (
              inner: server:
              let
                owner = inner.owners.${server.id} or null;
              in
              if owner != null then
                throw "role ${role}: server ${server.id} is declared by ${owner} and by ${node.name}"
              else
                {
                  owners = inner.owners // {
                    ${server.id} = node.name;
                  };
                  list = inner.list ++ [
                    (
                      {
                        enabled = true;
                        args = [ ];
                        cwd = "{root}";
                      }
                      // server
                    )
                  ];
                }
            ) acc (node.lsp or [ ])
          )
          {
            owners = { };
            list = [ ];
          }
          order;
      lspJson = builtins.toJSON {
        version = 1;
        servers = servers.list;
      };
      ## What a test is and how tests run (ADR-044): three lists, each the
      ## union across the flattened set in order, each pattern once. Empty
      ## lists are a declaration too: no guard.
      testsOf = key: lib.unique (lib.concatMap (node: (node.tests or { }).${key} or [ ]) order);
      testsJson = builtins.toJSON {
        files = testsOf "files";
        source = testsOf "source";
        command = testsOf "command";
      };
    in
    ## Forced here so that a name no catalogue has, or a tool nixpkgs
    ## lacks, fails on any touch of the derivation, and not only when
    ## something reads the list.
    builtins.seq order builtins.seq servers.list builtins.seq toolLines pkgs.runCommand
      "fabriek-specialist-${role}"
      {
        inherit
          prompt
          toolLines
          skillLines
          lspJson
          testsJson
          ;
        passAsFile = [
          "prompt"
          "toolLines"
          "skillLines"
          "lspJson"
          "testsJson"
        ];
        ## What the role is, said at evaluation: a check on the operator's
        ## host and a listing read these and build nothing.
        passthru = {
          order = map (node: node.name) order;
          ## Where the last specialist named came from: its directory, or
          ## config.toml; what show prints as the source.
          source = (lib.last order).dir;
          model = modelName;
          tools = lib.concatMap toolsOf order;
          skillsDescribed = map describe skills;
          servers = map (s: s.id) servers.list;
          promptText = prompt;
        };
      }
      ''
        mkdir -p $out/bin $out/share/fabriek/specialist/skills
        cp "$promptPath" $out/share/fabriek/specialist/APPEND_SYSTEM.md
        cp "$lspJsonPath" $out/share/fabriek/specialist/lsp.json
        cp "$testsJsonPath" $out/share/fabriek/specialist/tests.json
        ${lib.optionalString (
          modelName != ""
        ) "echo ${lib.escapeShellArg modelName} > $out/share/fabriek/specialist/model"}

        declare -A owner ownerPath
        while IFS=$'\t' read -r specialist tool; do
          [ -d "$tool/bin" ] || continue
          for f in "$tool"/bin/*; do
            name="$(basename "$f")"
            if [ -n "''${owner[$name]:-}" ]; then
              if [ "''${ownerPath[$name]}" != "$tool" ]; then
                echo "role ${role}: bin/$name comes from ''${owner[$name]} (''${ownerPath[$name]}) and from $specialist ($tool)" >&2
                exit 1
              fi
              continue
            fi
            owner[$name]="$specialist"
            ownerPath[$name]="$tool"
            ln -s "$f" "$out/bin/$name"
          done
        done <"$toolLinesPath"

        while IFS=$'\t' read -r name src; do
          if [ ! -f "$src/SKILL.md" ]; then
            echo "skill $name: $src has no SKILL.md" >&2
            exit 1
          fi
          if ! sed -n '2,/^---$/p' "$src/SKILL.md" | grep -q '^description: *[^ ]'; then
            echo "skill $name: SKILL.md declares no description, so pi would drop it" >&2
            exit 1
          fi
          ln -s "$src" "$out/share/fabriek/specialist/skills/$name"
        done <"$skillLinesPath"
      '';
in
{
  inherit (catalogue) specialists skills;
  inherit skillsDescribed compose;
}
