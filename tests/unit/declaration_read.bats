#!/usr/bin/env bats
# Reading a repository's declaration out of its history (ADR-020 point 3a).
#
# These are the only declaration tests that need nix and git, which is why the
# schema is tested separately and this file is small.

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

## A flake declaring one factory, with the name given so a test can tell which
## version of the file it is looking at.
write_flake() {
	local name="$1"
	cat >"$REPO/flake.nix" <<EOF
{
  outputs = { self }: {
    fabriek = {
      name = "$name";
      roles.builder = {
        command = [ "claude" ];
        provides = [ "build" ];
      };
    };
  };
}
EOF
}

commit_all() {
	git -C "$REPO" add -A
	git -C "$REPO" -c commit.gpgsign=false commit -qm "${1:-declare}"
}

@test "the declaration is read, and it is the repository's own" {
	write_flake acme
	commit_all
	run fabriek_declaration_read "$REPO"
	assert_success
	assert_output --partial "acme"
	assert_output --partial "builder"
}

# The reason ADR-020 pins the rev rather than evaluating the path. A bare
# git+file:// reference reads the working tree on a dirty repository and only
# warns about it, which would make the running factory one nobody committed.
@test "an edit that is not committed is not the declaration that is read" {
	write_flake acme
	commit_all
	write_flake uncommitted-edit
	run fabriek_declaration_read "$REPO"
	assert_success
	assert_output --partial "acme"
	refute_output --partial "uncommitted-edit"
}

# The reason the attribute is reached through getFlake. A "#fabriek"
# fragment resolves packages.<system>.fabriek first, and a repository that
# happens to build something of that name would shadow its own declaration.
@test "a package named fabriek does not shadow the declaration" {
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
    packages = {
      aarch64-darwin.fabriek = "shadow";
      x86_64-darwin.fabriek = "shadow";
      aarch64-linux.fabriek = "shadow";
      x86_64-linux.fabriek = "shadow";
    };
  };
}
EOF
	commit_all
	run fabriek_declaration_read "$REPO"
	assert_success
	assert_output --partial "acme"
	refute_output --partial "shadow"
}

@test "a repository declaring no factory is refused, and the message says so" {
	cat >"$REPO/flake.nix" <<'EOF'
{
  outputs = { self }: { };
}
EOF
	commit_all
	run fabriek_declaration_read "$REPO"
	assert_failure
	assert_output --partial "declares no factory"
}

@test "a repository with no commit has no declaration to read" {
	write_flake acme
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
	cat >"$REPO/flake.nix" <<'EOF'
{
  outputs = { self }: {
    fabriek = {
      name = "acme";
      roles.builder = {
        command = [ "claude" ];
        provides = [ "build" ];
      };
      systemPackages = [ "nmap" ];
    };
  };
}
EOF
	commit_all
	run fabriek_declaration_read "$REPO"
	assert_failure
	assert_output --partial "systemPackages"
}

@test "the rev a declaration was read from is what HEAD says" {
	write_flake acme
	commit_all
	run fabriek_declaration_rev "$REPO"
	assert_success
	assert_output "$(git -C "$REPO" rev-parse HEAD)"
}
