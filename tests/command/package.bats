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
