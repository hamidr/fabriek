#!/usr/bin/env bats
# fabriek up on the host (ADR-067): the machine program, as root, brings
# one declared factory up. Under a lock on the factory's directory it pins
# the checkout's HEAD (or keeps the pin, or moves it on --update), writes
# the credential the operator's config projects for this factory, starts
# the factory's units, clones the checkout by path, renders, files the
# model credentials for the proxy, prepares the forge and the bus, and
# marks the factory prepared for the executor. down stops the units and
# removes the mark, and is refused while a role's cage runs.
#
# systemctl, nixcage-container, chown, the forge and nix build are stubbed;
# git and nix eval are real.

load ../test_helper/common
load ../test_helper/stubs

setup() {
	setup_temp_dir
	STATE="$TEST_TEMP_DIR/state"
	STUB_DIR="$TEST_TEMP_DIR/bin"
	ETC="$TEST_TEMP_DIR/etc"
	RUN="$TEST_TEMP_DIR/run"
	CALLS="$TEST_TEMP_DIR/calls"
	FORGE="$TEST_TEMP_DIR/forge"
	FACTS="$TEST_TEMP_DIR/facts"
	mkdir -p "$STATE" "$STUB_DIR" "$RUN" "$CALLS" "$FORGE" "$FACTS"
	REAL_NIX="$(command -v nix)"
	PATH="$STUB_DIR:$PATH"
	export PATH STATE
	git init -q --bare -b main "$TEST_TEMP_DIR/forge.git"
	export FABRIEK_FORGE_GIT_URL="$TEST_TEMP_DIR/forge.git"

	# The factory's facts, as the host module writes them, and the one
	# factory named in the environment, as the CLI and the units name it.
	FLOOR="$TEST_TEMP_DIR/floor"
	mkdir -p "$FLOOR/extensions/fabriek" "$FLOOR/decider/extensions/fabriek" "$TEST_TEMP_DIR/self"
	echo loop >"$FLOOR/extensions/fabriek/index.ts"
	echo decider >"$FLOOR/decider/extensions/fabriek/index.ts"
	echo '# Working as a factory role' >"$FLOOR/guidance.md"
	cat >"$FACTS/acme.env" <<EOF
FABRIEK_FACTORY=acme
FABRIEK_BRIDGE=fb-0
FABRIEK_BRIDGE_HOST=10.77.0.1
FABRIEK_PROXY_PORT=8118
FABRIEK_FORGEJO_PORT=3000
FABRIEK_VALKEY_PORT=6379
FABRIEK_STATE=$STATE
FABRIEK_ETC=$ETC
FABRIEK_RUN=$RUN
FABRIEK_FLOOR=$FLOOR
FABRIEK_SELF=$TEST_TEMP_DIR/self
FABRIEK_NIXPKGS=$TEST_TEMP_DIR/nixpkgs
FABRIEK_SYSTEM=aarch64-linux
EOF
	export FABRIEK_FACTORIES="$FACTS" FABRIEK_FACTORY=acme

	# The operator's checkout, with its declaration committed.
	REPO="$TEST_TEMP_DIR/src/acme"
	mkdir -p "$REPO/docs"
	git init -q -b main "$REPO"
	git -C "$REPO" config user.name operator
	git -C "$REPO" config user.email operator@invalid
	cat >"$REPO/fabriek.toml" <<'TOML'
name = "acme"

[roles.builder]
provides = ["build"]

[roles.reviewer]
provides = ["review"]

[[workflows.ship.stages]]
needs = "build"

[[workflows.ship.stages]]
needs = "review"

[resources]
memory = "4G"
cores = 2
egress = ["api.anthropic.com", "api.openai.com"]
TOML
	printf '{ outputs = { self }: { }; }\n' >"$REPO/flake.nix"
	git -C "$REPO" add -A
	git -C "$REPO" -c commit.gpgsign=false commit -qm declare
	REV="$(git -C "$REPO" rev-parse HEAD)"

	# The operator's config on the host, and the one credential it names.
	echo "sk-ant-secret" >"$TEST_TEMP_DIR/anthropic.key"
	cat >"$FABRIEK_CONFIG" <<TOML
[caps]
memory = "16G"
cores = 8
egress = ["api.anthropic.com"]

[factories.acme]
path = "$REPO"

[credentials."api.anthropic.com"]
header = "x-api-key"
file = "$TEST_TEMP_DIR/anthropic.key"
TOML

	stub_forge "$FORGE"
	stub_nix_build "$CALLS" "$REAL_NIX" "$TEST_TEMP_DIR/store"
	stub_record systemctl "$CALLS/systemctl"
	stub_record chown "$CALLS/chown"
	cat >"$STUB_DIR/nixcage-container" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS/nixcage-container"
case "\$1" in
uid) case "\${2#acme-}" in builder) echo 60000 ;; reviewer) echo 60064 ;; decider) echo 60192 ;; *) exit 1 ;; esac ;;
storage) echo "\$2" ;;
status) [ -e "$CALLS/running-\$2" ] && echo "running 4242 machine.slice/\$2.scope" || echo stopped ;;
esac
EOF
	cat >"$STUB_DIR/id" <<'EOF'
#!/usr/bin/env bash
case "$*" in *forgejo*) echo 993 ;; *fabriek-egress*) echo 500 ;; *) echo 0 ;; esac
EOF
	chmod +x "$STUB_DIR"/*
}

teardown() {
	teardown_temp_dir
}

perms() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

@test "up pins the checkout's HEAD, writes the credential under the factory's directory, and starts the state unit first" {
	run_fabriek_container factory-up acme
	assert_success
	run sed -n 's/^rev = "\(.*\)"$/\1/p' "$ETC/fabriek.toml"
	assert_output "$REV"
	run grep -c "^remote = \"$REPO\"$" "$ETC/fabriek.toml"
	assert_output 1
	run head -1 "$CALLS/systemctl"
	assert_output "start fabriek-acme-state.service"
}

@test "a second up keeps the pin; --update moves it to the checkout's HEAD" {
	run_fabriek_container factory-up acme
	assert_success
	echo more >>"$REPO/docs/notes.md"
	git -C "$REPO" add -A && git -C "$REPO" -c commit.gpgsign=false commit -qm more
	local head
	head="$(git -C "$REPO" rev-parse HEAD)"
	run_fabriek_container factory-up acme
	assert_success
	run cat "$ETC/rev"
	assert_output "$REV"
	run_fabriek_container factory-up --update acme
	assert_success
	run cat "$ETC/rev"
	assert_output "$head"
}

@test "the clone's origin is the checkout's path, and its objects are the checkout's by hardlink" {
	run_fabriek_container factory-up acme
	assert_success
	local clone="$STATE/factories/acme"
	run git -C "$clone" remote get-url origin
	assert_output "$REPO"
	# One object at least is the same inode on both sides: nothing was
	# copied and nothing borrows through alternates.
	[ ! -e "$clone/.git/objects/info/alternates" ]
	run find "$clone/.git/objects" -type f -links +1
	refute_output ""
}

@test "up renders, files the credential for each endpoint the rendered factory reaches under the factory's state for the proxy's user, and prepares" {
	run_fabriek_container factory-up acme
	assert_success
	run jq -c '[.name, (.roles | keys), .resources.egress]' "$ETC/declaration.json"
	assert_output '["acme",["builder","reviewer"],["api.anthropic.com"]]'
	run cat "$STATE/egress/api.anthropic.com"
	assert_output "sk-ant-secret"
	[ ! -e "$STATE/egress/api.openai.com" ]
	run perms "$STATE/egress/api.anthropic.com"
	assert_output 400
	run grep -c "fabriek-egress:fabriek-egress $STATE/egress/api.anthropic.com" "$CALLS/chown"
	assert_output 1
	run cat "$CALLS/systemctl"
	assert_line --partial 'restart fabriek-acme-egress-credentials.service'
	assert_line --partial 'reload-or-restart nginx.service'
	assert_line --partial 'restart fabriek-acme-bus-acl.service'
	run cat "$FORGE/users"
	assert_line operator
	assert_line builder
}

@test "up marks the factory prepared under its own run directory, last, and starts the executor on it" {
	run_fabriek_container factory-up acme
	assert_success
	[ -f "$RUN/prepared" ]
	run tail -2 "$CALLS/systemctl"
	assert_line --index 0 'restart fabriek-acme-executor.service'
	assert_line --index 1 'restart fabriek-probes.service'
	assert_output --partial 'restart fabriek-acme-executor.service'
}

@test "a factory not declared on this host is refused before anything is written" {
	run_fabriek_container factory-up widgets
	assert_failure
	assert_output --partial "widgets is not declared on this host"
	[ ! -e "$CALLS/systemctl" ]
}

@test "a declaration the schema refuses stops up naming the key, before a unit is started" {
	sed -i.bak 's/cores = 2/cores = "two"/' "$REPO/fabriek.toml" && rm "$REPO/fabriek.toml.bak"
	git -C "$REPO" add -A && git -C "$REPO" -c commit.gpgsign=false commit -qm bad
	run_fabriek_container factory-up acme
	assert_failure
	assert_output --partial "cores"
	[ ! -e "$CALLS/systemctl" ]
}

# models/factory-lifecycle.qnt: the unit at boot and a hand can both call
# up, and the second waits for the first. The lock is a flock on the
# factory's directory, held for the whole run.
@test "a second up waits on the first's lock, and says so when it cannot have it" {
	mkdir -p "$ETC"
	exec 9>"$ETC/up.lock"
	flock 9
	FABRIEK_UP_LOCK_WAIT=1 run_fabriek_container factory-up acme
	assert_failure
	assert_output --partial "another up holds acme"
	flock -u 9
	exec 9>&-
	[ ! -e "$CALLS/systemctl" ]
}

@test "down stops the factory's units in reverse, removes the mark, and keeps the datasets" {
	run_fabriek_container factory-up acme
	assert_success
	: >"$CALLS/systemctl"
	run_fabriek_container factory-down acme
	assert_success
	assert_output --partial "acme has stopped"
	[ ! -e "$RUN/prepared" ]
	run cat "$CALLS/systemctl"
	assert_line --index 0 "stop fabriek-acme-executor.service"
	assert_line --index 1 "stop fabriek-acme-bus-acl.service fabriek-acme-bus.service"
	[ -d "$STATE/factories/acme" ]
}

# The executor starts a session for every role and its sessions end with
# it, so the cages down finds while the executor is up are the executor's
# own and no reason to refuse; the stub takes them down as the unit does.
# A cage still there after that is one a hand entered outside the executor,
# and that is reported rather than forced (PRD-004).
executor_owns_cages() {
	cat >"$STUB_DIR/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS/systemctl"
case "\$*" in "stop fabriek-acme-executor.service") rm -f "$CALLS"/running-acme-* ;; esac
EOF
	chmod +x "$STUB_DIR/systemctl"
}

@test "down stops the executor first, and its sessions go with it" {
	run_fabriek_container factory-up acme
	assert_success
	: >"$CALLS/systemctl"
	executor_owns_cages
	touch "$CALLS/running-acme-builder"
	run_fabriek_container factory-down acme
	assert_success
	assert_output --partial "acme has stopped"
	[ ! -e "$RUN/prepared" ]
	run head -1 "$CALLS/systemctl"
	assert_output "stop fabriek-acme-executor.service"
}

@test "down is refused while a cage the executor did not own still runs, and stops nothing more" {
	run_fabriek_container factory-up acme
	assert_success
	: >"$CALLS/systemctl"
	touch "$CALLS/running-acme-builder"
	run_fabriek_container factory-down acme
	assert_failure
	assert_output --partial "builder is still running"
	[ -f "$RUN/prepared" ]
	run cat "$CALLS/systemctl"
	assert_output "stop fabriek-acme-executor.service"
}

@test "status answers running once prepared, stopped after down, and never started before either" {
	run_fabriek_container factory-status acme
	assert_output "acme: stopped"
	run_fabriek_container factory-up acme
	assert_success
	run_fabriek_container factory-status acme
	assert_output "acme: running at $REV"
	run_fabriek_container factory-down acme
	run_fabriek_container factory-status acme
	assert_output "acme: stopped"
}

@test "the clone's path and the declaring file are answered for the CLI" {
	run_fabriek_container factory-clone acme
	assert_output "$STATE/factories/acme"
	run_fabriek_container factory-declared acme
	assert_failure
	run_fabriek_container factory-up acme
	assert_success
	run_fabriek_container factory-declared acme
	assert_output "$REPO/fabriek.toml"
}

# ADR-067 point 4: nixcage fixes a cage's substrate at its first enter, so
# a role whose declared substrate changed is removed from nixcage's record
# and entered anew. rm clears nixcage's record only: the role's dataset,
# home, key and forge account are the factory's and stay.
@test "up --update removes the cage of a role whose substrate changed, and no other" {
	run_fabriek_container factory-up acme
	assert_success
	sed -i.bak 's/^\[roles.builder\]$/[roles.builder]\nsubstrate = "microvm"/' "$REPO/fabriek.toml" && rm "$REPO/fabriek.toml.bak"
	git -C "$REPO" add -A && git -C "$REPO" -c commit.gpgsign=false commit -qm kernel
	: >"$CALLS/nixcage-container"
	run_fabriek_container factory-up --update acme
	assert_success
	assert_output --partial "builder now runs on microvm; its cage is made anew"
	run grep "^rm " "$CALLS/nixcage-container"
	assert_output "rm acme-builder"
	[ -d "$STATE/factories/acme" ]
}

@test "up --update on an unchanged substrate removes no cage" {
	run_fabriek_container factory-up acme
	assert_success
	: >"$CALLS/nixcage-container"
	run_fabriek_container factory-up --update acme
	assert_success
	run grep -c "^rm " "$CALLS/nixcage-container"
	assert_output 0
}

@test "the operator's substrate floor raises every role at up, and says so" {
	cat >"$FABRIEK_CONFIG" <<TOML
[caps]
memory = "16G"
cores = 8
egress = ["api.anthropic.com"]
substrate = "microvm"

[factories.acme]
path = "$REPO"

[credentials."api.anthropic.com"]
header = "x-api-key"
file = "$TEST_TEMP_DIR/anthropic.key"
TOML
	run_fabriek_container factory-up acme
	assert_success
	assert_output --partial "substrate: role builder asked for nspawn and this host's floor is microvm; raised to microvm"
	run jq -c '[.roles.builder.substrate, .roles.reviewer.substrate]' "$ETC/declaration.json"
	assert_output '["microvm","microvm"]'
}

# The bus's ACL unit reads the plan render wrote, so it starts after render
# and not before: found on pc 2026-09-22, where a plan that had moved to
# the factory's own bridge was applied from the old plan on another
# factory's bus and up died there, never reaching render. The state unit
# alone goes first, since render writes into what it makes.
@test "up renders before it starts the units that read the render, and only the state unit goes before" {
	run_fabriek_container factory-up acme
	assert_success
	cat >"$STUB_DIR/systemctl" <<EOF2
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS/systemctl"
case "\$*" in *bus-acl*) cp "$ETC/bridge.json" "$CALLS/plan-at-acl-start" ;; esac
EOF2
	chmod +x "$STUB_DIR/systemctl"
	: >"$CALLS/systemctl"
	sed -i.bak "s/^FABRIEK_BRIDGE=.*/FABRIEK_BRIDGE=fb-1/; s/^FABRIEK_BRIDGE_HOST=.*/FABRIEK_BRIDGE_HOST=10.77.1.1/" "$FACTS/acme.env" && rm "$FACTS/acme.env.bak"
	run_fabriek_container factory-up acme
	assert_success
	run jq -r .host "$CALLS/plan-at-acl-start"
	assert_output 10.77.1.1
	run grep "^start " "$CALLS/systemctl"
	assert_line --index 0 "start fabriek-acme-state.service"
	assert_line --index 1 "start fabriek-acme-bus.service fabriek-acme-bus-acl.service"
}
