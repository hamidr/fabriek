#!/usr/bin/env bats
# Reading a repository's declaration out of its history (ADR-020 point 3a).
#
# These are the only declaration tests that need git and nix's TOML reader,
# which is why the schema is tested separately and this file is small.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/schema.sh
	source "$FABRIEK_ROOT/modules/schema.sh"
	# shellcheck source=../../modules/resources.sh
	source "$FABRIEK_ROOT/modules/resources.sh"
	# shellcheck source=../../modules/repo-declaration.sh
	source "$FABRIEK_ROOT/modules/repo-declaration.sh"
	REPO="$TEST_TEMP_DIR/acme"
	mkdir -p "$REPO"
	git init -q "$REPO"
	git -C "$REPO" config user.name factory
	git -C "$REPO" config user.email factory@invalid
}

teardown() {
	teardown_temp_dir
}

## A declaration of one factory, with the name given so a test can tell which
## version of the file it is looking at (ADR-058: fabriek.toml at the root,
## no flake needed).
write_declaration() {
	local name="$1"
	cat >"$REPO/fabriek.toml" <<EOF
name = "$name"

[roles.builder]
command = ["claude"]
provides = ["build"]
EOF
}

commit_all() {
	git -C "$REPO" add -A
	git -C "$REPO" -c commit.gpgsign=false commit -qm "${1:-declare}"
}

@test "the declaration is read, and it is the repository's own" {
	write_declaration acme
	commit_all
	run fabriek_declaration_read "$REPO"
	assert_success
	assert_output --partial "acme"
	assert_output --partial "builder"
}

# The reason ADR-020 pins the rev rather than reading the path: the running
# factory is one somebody committed.
@test "an edit that is not committed is not the declaration that is read" {
	write_declaration acme
	commit_all
	write_declaration uncommitted-edit
	run fabriek_declaration_read "$REPO"
	assert_success
	assert_output --partial "acme"
	refute_output --partial "uncommitted-edit"
}

# The flake output is never read (ADR-058 point 2): a repository that still
# declares through it is told so, rather than left wondering why its roles
# are missing.
@test "a repository with only a fabriek flake output is refused, and told the output is not read" {
	cat >"$REPO/flake.nix" <<'EOF'
{
  outputs = { self }: {
    fabriek = {
      name = "acme";
      roles.builder = {
        command = [ "claude" ];
        provides = [ "build" ];
      };
    };
  };
}
EOF
	commit_all
	run fabriek_declaration_read "$REPO"
	assert_failure
	assert_output --partial "no fabriek.toml"
	assert_output --partial "flake output is no longer read"
}

@test "a repository declaring no factory is refused naming the file and the rev" {
	echo "# nothing" >"$REPO/README.md"
	commit_all
	run fabriek_declaration_read "$REPO"
	assert_failure
	assert_output --partial "no fabriek.toml at $(git -C "$REPO" rev-parse HEAD)"
	refute_output --partial "flake output"
}

# nix's own parse error is what names the line; discarding it would leave
# "is not TOML" for a file of two hundred lines.
@test "a declaration that is not TOML is refused with the line that broke it" {
	printf 'name = "acme"\n[roles.builder\nprovides = ["build"]\n' >"$REPO/fabriek.toml"
	commit_all
	run fabriek_declaration_read "$REPO"
	assert_failure
	assert_output --partial "fabriek.toml"
	assert_output --partial "2 | [roles.builder"
}

@test "a repository with no commit has no declaration to read" {
	write_declaration acme
	run fabriek_declaration_read "$REPO"
	assert_failure
	assert_output --partial "no commit"
}

@test "a repository that is not there is refused by path" {
	run fabriek_declaration_read "$TEST_TEMP_DIR/absent"
	assert_failure
	assert_output --partial "absent"
}

# A declaration that is read but not valid fails as a declaration, not as a
# missing output: the two are different mistakes and say so differently.
@test "a committed declaration that breaks the schema is refused by key" {
	write_declaration acme
	echo 'systemPackages = ["nmap"]' >>"$REPO/fabriek.toml"
	commit_all
	run fabriek_declaration_read "$REPO"
	assert_failure
	assert_output --partial "systemPackages"
}

@test "the rev a declaration was read from is what HEAD says" {
	write_declaration acme
	commit_all
	run fabriek_declaration_rev "$REPO"
	assert_success
	assert_output "$(git -C "$REPO" rev-parse HEAD)"
}
