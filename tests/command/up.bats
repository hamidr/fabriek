#!/usr/bin/env bats
# fabriek up, down, ps and fetch on the host (ADR-067). The CLI names the
# factory and hands it to the machine program through sudo; what it does
# itself is the operator's side of the checkout: a remote at the factory's
# clone, fetched as the operator into refs the factory's name owns, so
# the factory's branches are seen with git and nothing writes the checkout
# but the operator's own fetch.
#
# sudo is stubbed and answers as the machine program would; git is real.

load ../test_helper/common

setup() {
	setup_temp_dir
	stub_nixcage
	declare_repository
	# The machine program's answers: up says what render said and where
	# the clone is; status says running or stopped. The stub is one script
	# for every verb, so it keys on the first word after the program.
	CLONE="$TEST_TEMP_DIR/state/factories/acme"
	cat >"$STUB_DIR/sudo" <<STUB
#!/usr/bin/env bash
while [ \$# -gt 0 ]; do
	case "\$1" in
	-*) shift ;;
	*=*) printf '%s\\n' "\$1" >>"$SUDO_ENV"; shift ;;
	*) break ;;
	esac
done
printf '%s ' "\$@" >>"$NIXCAGE_CALLS"
printf '\\n' >>"$NIXCAGE_CALLS"
case "\$2" in
factory-up)
	[ -e "$TEST_TEMP_DIR/refuse-up" ] && { echo "fabriek-container: a declaration the schema refuses: cores" >&2; exit 1; }
	echo "fabriek: egress asked for api.openai.com, which this host does not allow; dropped"
	git clone -q "$REPO" "$CLONE" 2>/dev/null || true
	git -C "$CLONE" -c commit.gpgsign=false -c user.name=builder -c user.email=b@invalid branch -q builder/one 2>/dev/null || true
	touch "$TEST_TEMP_DIR/running"
	echo "acme: prepared"
	;;
factory-down) rm -f "$TEST_TEMP_DIR/running"; echo "acme has stopped" ;;
factory-status) [ -e "$TEST_TEMP_DIR/running" ] && echo "acme: running at abc" || echo "acme: stopped" ;;
factory-clone)
	if [ -e "$TEST_TEMP_DIR/in-a-machine" ]; then
		printf '%s\n%s\n' "$TEST_TEMP_DIR/forge.git" "$TEST_TEMP_DIR/fetch-token"
	else
		echo "$CLONE"
	fi
	;;
esac
STUB
	chmod +x "$STUB_DIR/sudo"
	cat >"$FABRIEK_CONFIG" <<EOF
[caps]
memory = "16G"
cores = 8

[factories.acme]
path = "$REPO"
EOF
}

teardown() {
	teardown_temp_dir
}

declare_repository() {
	REPO="$TEST_TEMP_DIR/acme"
	mkdir -p "$REPO"
	git init -q -b main "$REPO"
	git -C "$REPO" config user.name operator
	git -C "$REPO" config user.email operator@invalid
	cat >"$REPO/fabriek.toml" <<'EOF'
name = "acme"
[roles.builder]
provides = ["build"]
EOF
	git -C "$REPO" add -A
	git -C "$REPO" -c commit.gpgsign=false commit -qm declare
}

@test "up hands the factory to the machine program, prints what it printed, and says the factory is running" {
	run_fabriek up acme
	assert_success
	assert_output --partial "api.openai.com, which this host does not allow"
	assert_output --partial "acme is running"
	run nixcage_calls
	assert_line "/run/current-system/sw/bin/fabriek-container factory-up acme"
	run sudo_env
	assert_line "FABRIEK_FACTORY=acme"
}

@test "up -u moves the pin: the flag reaches the machine program" {
	run_fabriek up -u acme
	assert_success
	run nixcage_calls
	assert_line "/run/current-system/sw/bin/fabriek-container factory-up acme --update"
}

# ADR-067 point 5: the operator observes the factory's branches in their
# own checkout. up adds a remote at the clone and fetches it, as the
# operator, into refs under the factory's name; nothing in the factory
# writes the checkout.
@test "up adds a remote at the factory's clone to the checkout and fetches its branches under the factory's name" {
	run_fabriek up acme
	assert_success
	run git -C "$REPO" remote get-url fabriek-acme
	assert_output "$CLONE"
	run git -C "$REPO" config --get-all remote.fabriek-acme.fetch
	assert_line "+refs/heads/*:refs/heads/fabriek/acme/*"
	assert_line "+refs/fabriek/*:refs/fabriek/acme/*"
	run git -C "$REPO" rev-parse --verify refs/heads/fabriek/acme/builder/one
	assert_success
	# The checked-out branch and the tree are the operator's alone.
	run git -C "$REPO" status --porcelain
	assert_output ""
	run git -C "$REPO" rev-parse --abbrev-ref HEAD
	assert_output main
}

@test "fetch refreshes the factory's refs in the checkout and does nothing else" {
	run_fabriek up acme
	assert_success
	git -C "$CLONE" -c commit.gpgsign=false -c user.name=b -c user.email=b@invalid commit -q --allow-empty -m more
	local head
	head="$(git -C "$CLONE" rev-parse HEAD)"
	: >"$NIXCAGE_CALLS"
	run_fabriek fetch acme
	assert_success
	run git -C "$REPO" rev-parse refs/heads/fabriek/acme/main
	assert_output "$head"
	[ ! -s "$NIXCAGE_CALLS" ]
}

@test "ps fetches too, and names every factory the operator declared with what the machine program says of it" {
	run_fabriek ps
	assert_success
	assert_line "acme	stopped"
	run_fabriek up acme
	run_fabriek ps
	assert_success
	assert_line "acme	running at abc"
	run_fabriek ps --json
	assert_success
	run jq -c 'map([.factory, .state, .rev])' <<<"$output"
	assert_output '[["acme","running","abc"]]'
}

@test "a declaration the machine program refuses stops up naming the key, and adds no remote" {
	touch "$TEST_TEMP_DIR/refuse-up"
	run_fabriek up acme
	assert_failure
	assert_output --partial "cores"
	run git -C "$REPO" remote
	refute_output --partial fabriek-acme
}

@test "down hands the factory to the machine program and removes the remote from the checkout" {
	run_fabriek up acme
	run_fabriek down acme
	assert_success
	assert_output --partial "acme has stopped"
	run nixcage_calls
	assert_line "/run/current-system/sw/bin/fabriek-container factory-down acme"
	run git -C "$REPO" remote
	refute_output --partial fabriek-acme
	# What was fetched stays: the refs are the operator's now.
	run git -C "$REPO" rev-parse --verify refs/heads/fabriek/acme/builder/one
	assert_success
}

@test "a factory nobody declared here is refused before the machine program is asked" {
	run_fabriek up widgets
	assert_failure
	assert_output --partial "widgets"
	[ ! -f "$NIXCAGE_CALLS" ]
}

@test "up with no factory named takes the one declared, and with two asks which" {
	run_fabriek up
	assert_success
	run nixcage_calls
	assert_line "/run/current-system/sw/bin/fabriek-container factory-up acme"
	printf '[factories.widgets]\npath = "%s"\n' "$REPO" >>"$FABRIEK_CONFIG"
	run_fabriek up
	[ "$status" -eq 2 ]
	assert_output --partial "which factory"
}

# The host's sudo rule allows one program by its path (ADR-067 point 1),
# and sudo resolves a bare name in the caller's PATH. From a checkout's
# devshell that PATH begins with the checkout, so a bare name ran the
# unwrapped script as root, with no tool on its PATH (seen 2026-09-22:
# forgejo run as root, "not supposed to be run as root").
@test "the machine program is asked for by the path the host's rule names, whatever PATH holds" {
	run_fabriek up acme
	assert_success
	run nixcage_calls
	assert_line "/run/current-system/sw/bin/fabriek-container factory-up acme"
}

# A factory in a nixcage machine of its own (ADR-070 point 8): its clone is
# on a disk the host does not read, so the checkout's remote is the forge,
# fetched with the read-only token the host made for the fabriek group.
@test "in a machine, up adds a remote at the forge and fetches its branches and record with the host's token" {
	touch "$TEST_TEMP_DIR/in-a-machine"
	echo token >"$TEST_TEMP_DIR/fetch-token"
	git init -q --bare -b main "$TEST_TEMP_DIR/forge.git"
	git -C "$REPO" push -q "$TEST_TEMP_DIR/forge.git" main main:builder/one
	git -C "$REPO" push -q "$TEST_TEMP_DIR/forge.git" main:refs/fabriek/record
	run_fabriek up acme
	assert_success
	run git -C "$REPO" remote get-url fabriek-acme
	assert_output "$TEST_TEMP_DIR/forge.git"
	run git -C "$REPO" config "credential.$TEST_TEMP_DIR/forge.git.helper"
	assert_output --partial "cat $TEST_TEMP_DIR/fetch-token"
	git -C "$REPO" rev-parse --verify -q refs/heads/fabriek/acme/builder/one
	git -C "$REPO" rev-parse --verify -q refs/fabriek/acme/record
	[ "$(git -C "$REPO" branch --show-current)" = main ]
}

@test "in a machine, down takes the forge's credential helper away with the remote" {
	touch "$TEST_TEMP_DIR/in-a-machine"
	echo token >"$TEST_TEMP_DIR/fetch-token"
	git init -q --bare -b main "$TEST_TEMP_DIR/forge.git"
	git -C "$REPO" push -q "$TEST_TEMP_DIR/forge.git" main
	run_fabriek up acme
	assert_success
	run_fabriek down acme
	assert_success
	run git -C "$REPO" config --get-regexp '^credential\.'
	assert_output ""
}
