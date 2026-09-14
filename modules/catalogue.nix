## What a role can be (ADR-042): the specialists and skills of every
## catalogue, and the one derivation a role gets from the specialists it
## names.
##
## A catalogue is a directory: specialists/<name>/default.nix and
## skills/<name>/default.nix, each a function of pkgs and of the other
## entries, so a tool is a package and a parent is a value. fabriek ships
## one; a repository may add its own with the same layout. Every refusal
## here names the entry it is about, because the person reading it is
## holding a directory and not a stack trace.
{ self }:
{
  ## The packages every tool resolves against: the machine's, not the
  ## repository's, because a specialist's kit is the machine's to pin like
  ## the floor is (ADR-030).
  pkgs,
  ## Catalogue directories beside the shipped one.
  extra ? [ ],
}:
let
  lib = pkgs.lib;
  catalogues = [ "${self}/catalogue" ] ++ extra;

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
    ];
    skills = [
      "tools"
      "src"
    ];
  };
  singular = kind: lib.removeSuffix "s" kind;

  ## name -> directory, for one kind across every catalogue. A name in two
  ## catalogues is refused rather than shadowed: a repository that quietly
  ## replaced a shipped specialist would be changing what every reader of
  ## the shipped one believes it means.
  entriesOf =
    kind:
    lib.foldl (
      acc: root:
      let
        dir = "${root}/${kind}";
        here = lib.mapAttrs (name: _: "${dir}/${name}") (
          lib.filterAttrs (_: type: type == "directory") (
            if builtins.pathExists dir then builtins.readDir dir else { }
          )
        );
        twice = lib.intersectLists (lib.attrNames acc) (lib.attrNames here);
      in
      if twice != [ ] then
        throw "${singular kind} ${lib.head twice} is declared twice: ${acc.${lib.head twice}} and ${here.${lib.head twice}}"
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
      name: dir:
      checked kind name dir (import "${dir}/default.nix" args)
      // {
        inherit name dir;
      }
    ) (entriesOf kind);

  ## Fixed so that a specialist extends another by value, and a skill is
  ## named by value from a specialist.
  catalogue = lib.fix (c: {
    skills = load "skills" { inherit pkgs; };
    specialists = load "specialists" {
      inherit pkgs;
      inherit (c) skills specialists;
    };
  });

  ## The description a skill's frontmatter carries, which is what pi shows
  ## the model and what a listing shows a person; read at evaluation so
  ## nothing has to be built to say it. Empty when the file has none, which
  ## the build refuses.
  describe =
    skill:
    let
      lines = lib.splitString "\n" (builtins.readFile "${skill.src}/SKILL.md");
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
      order = flatten (
        map (
          name:
          catalogue.specialists.${name}
            or (throw "role ${role} names specialist ${name}, which no catalogue declares; the catalogue offers: ${offered}")
        ) specialists
      );
      skillsOf = node: node.skills or [ ];
      toolsOf =
        node: map lib.getBin ((node.tools or [ ]) ++ lib.concatMap (s: s.tools or [ ]) (skillsOf node));
      skills = lib.foldl (acc: s: if lib.any (t: t.name == s.name) acc then acc else acc ++ [ s ]) [ ] (
        lib.concatMap skillsOf order
      );
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
    ## Forced here so that a name no catalogue has fails on any touch of
    ## the derivation, and not only when something reads the list.
    builtins.seq order builtins.seq servers.list pkgs.runCommand "fabriek-specialist-${role}"
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
