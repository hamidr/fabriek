#!/usr/bin/env bats
# What the two packaged programs source is what the package ships. Both are
# built by nix, so a module added to the tree but not to package.nix fails
# only when an operator runs the installed CLI; this asks the same question
# at test time.

load ../test_helper/common

@test "every module a program sources is in the packaged lib" {
	local lib
	lib="$(nix build --no-link --print-out-paths --impure --expr '
    (import '"$FABRIEK_ROOT"'/modules/package.nix {
      pkgs = import (builtins.getFlake (toString '"$FABRIEK_ROOT"')).inputs.nixpkgs { };
      self = builtins.getFlake (toString '"$FABRIEK_ROOT"');
    }).lib'"'"'
  ')"
	local missing=""
	local module
	while IFS= read -r module; do
		[ -f "$lib/$module" ] || missing="$missing $module"
	done < <(grep -ho 'FABRIEK_LIB/[a-z-]*\.sh' "$FABRIEK_ROOT/fabriek" "$FABRIEK_ROOT/fabriek-container" "$FABRIEK_ROOT"/modules/*.sh | sed 's|FABRIEK_LIB/||' | sort -u)
	[ -z "$missing" ] || {
		echo "not packaged:$missing"
		return 1
	}
}

# The CLI reads the operator's checkout with git (the origin, the pin, the
# declaration at the commit), and a unit on a NixOS host has no PATH but
# the wrapper's (measured 2026-09-16: "has no origin" from the pc's unit,
# with git nowhere on its PATH).
@test "every tool the CLI runs is on the wrapper's PATH" {
	local cli
	cli="$(nix build --no-link --print-out-paths --impure --expr '
    (import '"$FABRIEK_ROOT"'/modules/package.nix {
      pkgs = import (builtins.getFlake (toString '"$FABRIEK_ROOT"')).inputs.nixpkgs { };
      self = builtins.getFlake (toString '"$FABRIEK_ROOT"');
    }).cli
  ')"
	# The wrapper prefixes PATH with one store path per package; each tool
	# is looked for by its package's name there.
	local package missing=""
	for package in git- jq- nix- openssh- coreutils- gawk- gnused- gnugrep- findutils- perl-; do
		grep -q "/nix/store/[a-z0-9]*-$package[0-9]" "$cli/bin/fabriek" || missing="$missing ${package%-}"
	done
	[ "$(uname)" != Linux ] || grep -q "/nix/store/[a-z0-9]*-util-linux-[0-9]" "$cli/bin/fabriek" || missing="$missing util-linux"
	[ -z "$missing" ] || {
		echo "not on the wrapper's PATH:$missing"
		return 1
	}
}
