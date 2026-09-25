#!/usr/bin/env bats
# A NixOS host declares its factories (ADR-048): services.fabriek renders the
# operator's config.toml and a unit per auto-started factory. The module is
# evaluated for real in a minimal NixOS configuration; nothing is built.

load ../test_helper/common

setup() {
	setup_temp_dir
	HOST="$(nix eval --impure --raw --expr 'builtins.currentSystem')"
	MACHINE="${HOST%%-*}-linux"
}

teardown() {
	teardown_temp_dir
}

## A NixOS configuration with the module and the options given, and one
## attribute of its config as JSON. nixcage's host module is beside it, as
## it is on a host (ADR-067 point 1): the floor adds to its packages.
host_eval() {
	nix eval --json --impure --expr "
	  let flake = builtins.getFlake \"path:$FABRIEK_ROOT\";
	      c = (flake.inputs.nixpkgs.lib.nixosSystem {
	        system = \"$MACHINE\";
	        modules = [
	          flake.inputs.nixcage.nixosModules.host
	          flake.nixosModules.host
	          { boot.loader.grub.enable = false; fileSystems.\"/\" = { device = \"none\"; fsType = \"tmpfs\"; }; system.stateVersion = \"25.05\"; nixpkgs.overlays = [ flake.overlays.default ]; }
	          { services.fabriek = { enable = true; $1 }; }
	        ];
	      }).config;
	  in $2" 2> >(grep -v -e 'Nix search path entry' -e 'evaluation warning' >&2)
}

@test "the module renders the operator's config as the TOML the CLI reads, at /etc/fabriek/config.toml" {
	run host_eval 'caps = { memory = "16G"; cores = 8; egress = [ "api.anthropic.com" ]; };
	               credentials."api.anthropic.com" = { header = "x-api-key"; file = "/run/secrets/anthropic"; };
	               models."api.anthropic.com" = "claude-opus-5";
	               factories.acme.path = "/srv/acme";' \
		'c.environment.etc."fabriek/config.toml".text'
	assert_success
	local text
	text="$(jq -r . <<<"$output")"
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/schema.sh
	source "$FABRIEK_ROOT/modules/schema.sh"
	# shellcheck source=../../modules/resources.sh
	source "$FABRIEK_ROOT/modules/resources.sh"
	# shellcheck source=../../modules/repo-declaration.sh
	source "$FABRIEK_ROOT/modules/repo-declaration.sh"
	# shellcheck source=../../modules/operator-config.sh
	source "$FABRIEK_ROOT/modules/operator-config.sh"
	printf '%s\n' "$text" >"$TEST_TEMP_DIR/config.toml"
	run fabriek_operator_config "$TEST_TEMP_DIR/config.toml"
	assert_success
	run jq -c '[.caps.cores, .factories.acme.path, .credentials["api.anthropic.com"].header, .models["api.anthropic.com"]]' <<<"$output"
	assert_output '[8,"/srv/acme","x-api-key","claude-opus-5"]'
}

@test "a factory with autoStart gets a unit that brings it up at boot and down at stop, in its slice, from its facts" {
	run host_eval 'factories.acme = { path = "/srv/acme"; autoStart = true; }; factories.widgets.path = "/srv/widgets";' \
		'{ start = c.systemd.services.fabriek-acme.serviceConfig.ExecStart; stop = c.systemd.services.fabriek-acme.serviceConfig.ExecStop;
		   type = c.systemd.services.fabriek-acme.serviceConfig.Type; env = c.systemd.services.fabriek-acme.environment;
		   facts = c.systemd.services.fabriek-acme.serviceConfig.EnvironmentFile; slice = c.systemd.services.fabriek-acme.serviceConfig.Slice;
		   wanted = c.systemd.services.fabriek-acme.wantedBy; widgets = c.systemd.services ? fabriek-widgets; }'
	assert_success
	local unit="$output"
	run jq -c '[(.start | test("/bin/fabriek-container factory-up acme$")), (.stop | test("/bin/fabriek-container factory-down acme$")), .type, .env.FABRIEK_CONFIG, .facts, .slice, .wanted, .widgets]' <<<"$unit"
	assert_output '[true,true,"oneshot","/etc/fabriek/config.toml","/etc/fabriek/factories/acme.env","fabriek-acme.slice",["multi-user.target"],false]'
	# The unit reads the operator's checkout as root, which git refuses as
	# dubious unless that one directory is declared safe to it (measured
	# 2026-09-16: "has no origin" on the first boot of the pc).
	run jq -c '[.env.GIT_CONFIG_COUNT, .env.GIT_CONFIG_KEY_0, .env.GIT_CONFIG_VALUE_0]' <<<"$unit"
	assert_output '["1","safe.directory","/srv/acme"]'
}

@test "the CLI is on the host's PATH, since the unit and a hand run the same program" {
	run host_eval 'factories.acme.path = "/srv/acme";' 'map (p: p.pname or p.name) c.environment.systemPackages'
	assert_success
	assert_output --partial '"fabriek"'
}

# ADR-061: everything the operator's file may say, roles and workflows,
# specialists and skills and catalogue directories, is an option here and
# comes out as the TOML the CLI reads: the same value, read back.
@test "the module renders a whole factory, specialists, skills and catalogues, and the CLI reads back what was given" {
	mkdir -p "$TEST_TEMP_DIR/cat/specialists"
	printf '# Strict\n' >"$TEST_TEMP_DIR/strict.md"
	run host_eval "factories.knot = {
	                 path = \"/srv/knot\";
	                 roles.backend = { provides = [ \"build\" ]; specialists = [ \"rust\" ]; shell = \"default\"; replicas = 2; };
	                 roles.reviewer = { provides = [ \"review\" ]; specialists = [ \"strict\" ]; };
	                 workflows.ship = {
	                   stages = [ { needs = \"build\"; done = \"tests pass\"; ready = [ \"acceptance\" ]; } { needs = \"review\"; verdict = true; gate = \"before-integration\"; } ];
	                   budget.runs = 200;
	                   consults.backend = [ \"reviewer\" ];
	                 };
	                 resources = { memory = \"8G\"; cores = 4; egress = [ \"api.anthropic.com\" ]; };
	                 decider.policy = \"docs/policy.md\";
	               };
	               specialists.rust = { extends = [ \"developer\" ]; tools = [ \"cargo\" ]; skills = [ \"cargo-profile\" ]; prompt = \"You write Rust.\"; };
	               specialists.strict = { extends = [ \"reviewer\" ]; prompt = $TEST_TEMP_DIR/strict.md; };
	               skills.cargo-profile = { tools = [ \"cargo\" ]; skill = \"# Profile\"; };
	               catalogues = [ $TEST_TEMP_DIR/cat ];" \
		'c.environment.etc."fabriek/config.toml".text'
	assert_success
	local text
	text="$(jq -r . <<<"$output")"
	source "$FABRIEK_ROOT/modules/names.sh"
	source "$FABRIEK_ROOT/modules/schema.sh"
	source "$FABRIEK_ROOT/modules/resources.sh"
	source "$FABRIEK_ROOT/modules/repo-declaration.sh"
	source "$FABRIEK_ROOT/modules/operator-config.sh"
	printf '%s\n' "$text" >"$TEST_TEMP_DIR/config.toml"
	run fabriek_operator_config "$TEST_TEMP_DIR/config.toml"
	assert_success
	run jq -cS '{ knot: (.factories.knot | del(.path)), rust: .specialists.rust, profile: .skills."cargo-profile" }' <<<"$output"
	assert_output '{"knot":{"decider":{"policy":"docs/policy.md"},"resources":{"cores":4,"egress":["api.anthropic.com"],"memory":"8G"},"roles":{"backend":{"provides":["build"],"replicas":2,"shell":"default","specialists":["rust"]},"reviewer":{"provides":["review"],"specialists":["strict"]}},"workflows":{"ship":{"budget":{"runs":200},"consults":{"backend":["reviewer"]},"stages":[{"done":"tests pass","needs":"build","ready":["acceptance"]},{"gate":"before-integration","needs":"review","verdict":true}]}}},"profile":{"skill":"# Profile","tools":["cargo"]},"rust":{"extends":["developer"],"prompt":"You write Rust.","skills":["cargo-profile"],"tools":["cargo"]}}'
	# A path given for a prompt or a catalogue is a store path in the file.
	run fabriek_operator_config "$TEST_TEMP_DIR/config.toml"
	run jq -r '.specialists.strict.prompt, .catalogues[0]' <<<"$output"
	assert_line --index 0 --regexp '^/nix/store/[a-z0-9]{32}-strict.md$'
	assert_line --index 1 --regexp '^/nix/store/[a-z0-9]{32}-cat$'
	# And the declaration the CLI would send is the one given.
	run fabriek_operator_declaration "$TEST_TEMP_DIR/config.toml" knot
	assert_success
	run jq -r '.roles | keys | join(",")' <<<"$output"
	assert_output "backend-1,backend-2,reviewer"
}


# ADR-067: a factory is declared on the host and its services are NixOS
# configuration. Every name the machine had as a constant is a function of
# the factory's name here, and the bridge's index is the factory's position
# among the declared names, so two factories never share a subnet.
@test "each declared factory gets a bridge of its own at .1, indexed in name order, usable before its first cage" {
	run host_eval 'factories.widgets.path = "/srv/widgets"; factories.acme.path = "/srv/acme";' \
		'{ acme = c.networking.interfaces.fb-0.ipv4.addresses; widgets = c.networking.interfaces.fb-1.ipv4.addresses;
		   carrier = c.systemd.network.networks."40-fb-0".networkConfig.ConfigureWithoutCarrier;
		   nonlocal = c.boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind";
		   ports = c.networking.firewall.interfaces.fb-1.allowedTCPPorts; }'
	assert_success
	run jq -c '[.acme, .widgets, .carrier, .nonlocal, .ports]' <<<"$output"
	assert_output '[[{"address":"10.77.0.1","prefixLength":24}],[{"address":"10.77.1.1","prefixLength":24}],true,1,[3000,4222,8118]]'
}

# What the machine program is told through the environment, per factory
# now: one file under /etc the units load and the CLI hands to
# fabriek-container for the factory named.
@test "each factory has a facts file under /etc naming its bridge, its state, its rendered directory and the floor" {
	run host_eval 'factories.widgets.path = "/srv/widgets"; factories.acme.path = "/srv/acme";' \
		'c.environment.etc."fabriek/factories/widgets.env".text'
	assert_success
	local text
	text="$(jq -r . <<<"$output")"
	run grep -c '^FABRIEK_[A-Z_]*=' <<<"$text"
	assert_output "$(grep -c . <<<"$text")"
	run bash -c "set -a; . <(printf '%s\n' \"\$1\"); printf '%s\n' \"\$FABRIEK_FACTORY\" \"\$FABRIEK_BRIDGE\" \"\$FABRIEK_BRIDGE_HOST\" \"\$FABRIEK_PROXY_PORT\" \"\$FABRIEK_FORGEJO_PORT\" \"\$FABRIEK_BUS_PORT\" \"\$FABRIEK_STATE\" \"\$FABRIEK_FORGE_STATE\" \"\$FABRIEK_ETC\" \"\$FABRIEK_RUN\" \"\${FABRIEK_FLOOR:+set}\"" _ "$text"
	assert_output "widgets
fb-1
10.77.1.1
8118
3000
4222
/var/lib/nixcage/fabriek/widgets
/var/lib/nixcage/fabriek-forge
/var/lib/fabriek/widgets
/run/fabriek/widgets
set"
}

# The factory's own state is a dataset under nixcage's pool, asked for
# through the primitive, before anything of the factory writes there. The
# record is no longer one of them: it is the host's forge (ADR-068).
@test "each factory's state is a dataset asked for through the storage primitive, in its slice" {
	run host_eval 'factories.acme.path = "/srv/acme";' \
		'{ state = c.systemd.services.fabriek-acme-state.script;
		   slice = c.systemd.services.fabriek-acme-state.serviceConfig.Slice;
		   sliceUnit = c.systemd.slices ? fabriek-acme; }'
	assert_success
	local units="$output"
	run jq -r .state <<<"$units"
	assert_output --partial 'nixcage-container storage ensure'
	assert_output --partial '/var/lib/nixcage/fabriek/acme 0'
	run jq -c '[.slice, .sliceUnit]' <<<"$units"
	assert_output '["fabriek-acme.slice",true]'
}

# The bus is one nats-server for the host (ADR-069 point 1), outside every
# factory's slice, with JetStream in memory and no file store at all. A
# factory is an account in it (point 2), bounded on memory, connections and
# subscriptions, with no import and no export, and its users come from a
# file this configuration includes (point 3).
@test "the bus is one nats-server for the host, and a factory is an account in it" {
	run host_eval 'factories.widgets.path = "/srv/widgets"; factories.acme.path = "/srv/acme";' \
		'{ start = c.systemd.services.nats.serviceConfig.ExecStart;
		   reload = c.systemd.services.nats.serviceConfig.ExecReload;
		   slice = c.systemd.services.nats.serviceConfig.Slice or "none";
		   conf = c.services.fabriek.bus.text;
		   files = builtins.filter (r: builtins.match ".*nats.*" r != null) c.systemd.tmpfiles.rules;
		   perFactory = builtins.filter (n: builtins.match "fabriek-(acme|widgets)-bus.*" n != null) (builtins.attrNames c.systemd.services); }'
	assert_success
	local out="$output"
	run jq -c '[.start, .reload, .slice, .perFactory]' <<<"$out"
	assert_output --partial 'nats-server -c /var/lib/fabriek/nats.conf'
	assert_output --partial '--signal reload=/run/nats/nats.pid'
	assert_output --partial '"none"'
	assert_output --partial '[]'
	run jq -r .conf <<<"$out"
	assert_output --partial 'port: 4222'
	assert_output --partial 'max_file_store: 0'
	assert_output --partial 'acme {'
	assert_output --partial 'widgets {'
	assert_output --partial 'include "acme/nats-users.conf"'
	assert_output --partial 'include "widgets/nats-users.conf"'
	assert_output --partial 'max_connections: 64'
	refute_output --partial 'imports'
	run jq -r '.files | join("\n")' <<<"$out"
	assert_output --partial 'L+ /var/lib/fabriek/nats.conf'
	assert_output --partial 'f /var/lib/fabriek/acme/nats-users.conf'
	assert_output --partial 'f /var/lib/fabriek/widgets/nats-users.conf'
}

# Forgejo's NixOS module is one instance, and so is the board: one unit
# for the host (ADR-068 point 1), outside every factory's slice, on one
# dataset of the host's, its secrets generated there on first start and
# read back by name. No factory has a board or a record of its own.
@test "the board is one Forgejo on the host, in no factory's slice, on one dataset" {
	run host_eval 'factories.widgets.path = "/srv/widgets"; factories.acme.path = "/srv/acme";' \
		'{ ini = c.services.fabriek.board.settings;
		   unit = { inherit (c.systemd.services.fabriek-forge) serviceConfig environment requires preStart; };
		   storage = c.systemd.services.fabriek-forge-storage.script;
		   perFactory = builtins.filter (n: builtins.match ".*-(board|record)" n != null) (builtins.attrNames c.systemd.services);
		   wrapper = map (p: p.name) (builtins.filter (p: p.name == "forgejo") c.environment.systemPackages); }'
	assert_success
	local out="$output"
	run jq -c '[.ini.server.HTTP_PORT, .ini.server.DISABLE_SSH, .ini.service.DISABLE_REGISTRATION, .ini.security.INSTALL_LOCK, .ini.federation.ENABLED, .ini.mailer.ENABLED, .ini.DEFAULT.WORK_PATH, .ini.database.DB_TYPE]' <<<"$out"
	assert_output '[3000,true,true,true,false,false,"/var/lib/nixcage/fabriek-forge","sqlite3"]'
	run jq -c '[.unit.serviceConfig.User, (.unit.serviceConfig.Slice // "none"), .unit.environment.FORGEJO_WORK_DIR, (.unit.serviceConfig.ExecStart | test("forgejo.* web")), .unit.requires, .wrapper, .perFactory]' <<<"$out"
	assert_output '["forgejo","none","/var/lib/nixcage/fabriek-forge",true,["fabriek-forge-storage.service"],["forgejo"],[]]'
	run jq -r .storage <<<"$out"
	assert_output --partial 'nixcage-container storage ensure'
	assert_output --partial '/var/lib/nixcage/fabriek-forge "$(id -u forgejo)" 4096M'
	assert_output --partial 'systemd-tmpfiles --create --prefix=/var/lib/nixcage/fabriek-forge'
	run jq -r .unit.preStart <<<"$out"
	assert_output --partial 'generate secret SECRET_KEY'
	assert_output --partial 'generate secret INTERNAL_TOKEN'
	assert_output --partial 'environment-to-ini'
}

# ADR-068 point 6: one instance answers on every factory's bridge, so it
# binds every address and the firewall is what bounds it, the same rule a
# cage's proxy and bus are under. Loopback is open to the host itself and
# no external interface is, because NixOS opens none by default. The URL
# the forge builds is loopback's: nothing in factory/src reads it.
@test "the board answers on every bridge and loopback, and on no external interface" {
	run host_eval 'factories.widgets.path = "/srv/widgets"; factories.acme.path = "/srv/acme";' \
		'{ addr = c.services.fabriek.board.settings.server.HTTP_ADDR;
		   root = c.services.fabriek.board.settings.server.ROOT_URL;
		   domain = c.services.fabriek.board.settings.server.DOMAIN;
		   bridges = { fb0 = c.networking.firewall.interfaces.fb-0.allowedTCPPorts;
		               fb1 = c.networking.firewall.interfaces.fb-1.allowedTCPPorts; };
		   open = c.networking.firewall.allowedTCPPorts; }'
	assert_success
	run jq -c '[.addr, .root, .domain, (.bridges.fb0 | index(3000) != null), (.bridges.fb1 | index(3000) != null), (.open | index(3000))]' <<<"$output"
	assert_output '["0.0.0.0","http://127.0.0.1:3000/","127.0.0.1",true,true,null]'
}

# ADR-068 point 1: one work directory, named here and not taken from the
# caller's environment, so the CLI cannot be pointed at a factory's state
# that no longer holds a forge.
@test "the forgejo wrapper runs against the one work directory and reads no factory's state" {
	run host_eval 'factories.acme.path = "/srv/acme";' \
		'(builtins.head (builtins.filter (p: p.name == "forgejo") c.environment.systemPackages)).text'
	assert_success
	local text
	text="$(jq -r . <<<"$output")"
	run printf '%s\n' "$text"
	assert_output --partial 'FORGEJO_WORK_DIR=/var/lib/nixcage/fabriek-forge'
	assert_output --partial '--config /var/lib/nixcage/fabriek-forge/custom/conf/app.ini'
	refute_output --partial 'FABRIEK_STATE'
}

# Found on the host: a second factory's up was refused with "start of the
# service was attempted too often", because every up reloads the proxy and
# a reload after a failed start is a restart, which systemd counts.
@test "the proxy has no start limit, so two factories may come up one after the other" {
	run host_eval 'factories.widgets.path = "/srv/widgets"; factories.acme.path = "/srv/acme";' \
		'c.systemd.services.nginx.startLimitIntervalSec'
	assert_success
	assert_output 0
}

# One nginx on the host, a server per factory on its bridge, a dictionary
# and a ceiling per factory (ADR-067 point 2). The locations are render's
# to write under the factory's directory; before render there are none.
@test "the proxy is one nginx with a server, a spend dictionary and an include per factory" {
	run host_eval 'factories.widgets.path = "/srv/widgets"; factories.acme.path = "/srv/acme";' \
		'{ enable = c.services.nginx.enable; user = c.services.nginx.user;
		   modules = map (m: m.name) c.services.nginx.additionalModules;
		   common = c.services.nginx.commonHttpConfig;
		   listen = (builtins.head c.services.nginx.virtualHosts.fabriek-widgets.listen);
		   extra = c.services.nginx.virtualHosts.fabriek-widgets.extraConfig;
		   js = c.environment.etc."fabriek/spend.js".text; }'
	assert_success
	local out="$output"
	run jq -c '[.enable, .user, (.modules | any(test("njs"))), .listen.addr, .listen.port]' <<<"$out"
	assert_output '[true,"fabriek-egress",true,"10.77.1.1",8118]'
	run jq -r .common <<<"$out"
	assert_output --partial 'js_shared_dict_zone zone=spend_acme:256k type=number;'
	assert_output --partial 'js_shared_dict_zone zone=spend_widgets:256k type=number;'
	assert_output --partial 'js_set $spend_over'
	run jq -r .extra <<<"$out"
	assert_output --partial 'set $spend_zone spend_widgets;'
	assert_output --partial 'set $spend_ceiling 0;'
	assert_output --partial 'location = /status'
	assert_output --partial 'include /var/lib/fabriek/widgets/proxy/*.conf;'
	refute_output --partial 'proxy_pass'
	run jq -r .js <<<"$out"
	assert_output --partial 'r.variables.spend_zone'
}

@test "each factory's credential headers are composed from the endpoints render wrote for it, under a run directory of its own" {
	run host_eval 'factories.acme.path = "/srv/acme";' \
		'{ script = c.systemd.services.fabriek-acme-egress-credentials.script;
		   before = c.systemd.services.fabriek-acme-egress-credentials.before;
		   uid = c.users.users.fabriek-egress.uid; }'
	assert_success
	local out="$output"
	run jq -r .script <<<"$out"
	assert_output --partial 'endpoints=/var/lib/fabriek/acme/endpoints.json'
	assert_output --partial '[ -f "$endpoints" ] || exit 0'
	assert_output --partial '/run/fabriek-egress/acme'
	assert_output --partial '/var/lib/nixcage/fabriek/acme/egress/$host'
	refute_output --partial 'api.anthropic.com'
	run jq -c '[.before, .uid]' <<<"$out"
	assert_output '[["nginx.service"],500]'
}

# ADR-037 on a host: a cage's only interface is its factory's bridge, and
# the host forwards nothing from or to one, whatever docker or a VPN has
# set ip_forward to. A drop in this chain holds beside any other table's
# accept, which is nftables' rule for base chains.
@test "the host forwards nothing from or to a factory's bridge" {
	run host_eval 'factories.acme.path = "/srv/acme";' \
		'{ on = c.networking.nftables.enable; content = c.networking.nftables.tables.fabriek.content; }'
	assert_success
	local out="$output"
	run jq -r .on <<<"$out"
	assert_output true
	run jq -r .content <<<"$out"
	assert_output --partial 'hook forward'
	assert_output --partial 'iifname "fb-*" drop'
	assert_output --partial 'oifname "fb-*" drop'
}

# The host is .1 on every factory's bridge, and nixos-fw's global accepts
# (sshd, NFS, whatever else the host serves) apply on that interface too:
# a cage reached 10.77.1.1:22 (found 2026-09-24). A cage may reach the
# host's forge, bus and proxy there and nothing else of the host.
@test "a cage reaches the host's three factory ports and nothing else of the host" {
	run host_eval 'factories.acme.path = "/srv/acme";' \
		'{ content = c.networking.nftables.tables.fabriek.content;
		   ports = [ c.services.fabriek.ports.forgejo c.services.fabriek.ports.bus c.services.fabriek.ports.egress ]; }'
	assert_success
	local out ports
	out="$output"
	ports="$(jq -r '.ports | map(tostring) | join(", ")' <<<"$out")"
	run jq -r .content <<<"$out"
	assert_output --partial 'hook input'
	assert_output --partial 'iifname "fb-*" ct state established,related accept'
	assert_output --partial "iifname \"fb-*\" tcp dport { $ports } accept"
	assert_output --partial 'iifname "fb-*" drop'
	# The input chain's drop comes after its accepts.
	run bash -c "jq -r .content <<<'$out' | sed -n '/hook input/,/^[[:space:]]*}[[:space:]]*$/p' | grep -n 'fb-' | tail -1"
	assert_output --partial 'iifname "fb-*" drop'
}

@test "each factory's executor waits for a mark up writes per start, under /run, and reads the factory's facts" {
	run host_eval 'factories.widgets.path = "/srv/widgets"; factories.acme.path = "/srv/acme";' \
		'{ cond = c.systemd.services.fabriek-widgets-executor.unitConfig.ConditionPathExists;
		   env = c.systemd.services.fabriek-widgets-executor.serviceConfig.EnvironmentFile;
		   slice = c.systemd.services.fabriek-widgets-executor.serviceConfig.Slice;
		   after = c.systemd.services.fabriek-widgets-executor.after;
		   start = c.systemd.services.fabriek-widgets-executor.serviceConfig.ExecStart; }'
	assert_success
	local out="$output"
	run jq -c '[.cond, .env, .slice, (.after | contains(["fabriek-widgets-bus-acl.service","fabriek-forge.service"])), (.start | test("executor/main.js$"))]' <<<"$out"
	assert_output '["/run/fabriek/widgets/prepared","/etc/fabriek/factories/widgets.env","fabriek-widgets.slice",true,true]'
}

# One reader for the host: the kernel is one, so the probes are one, and
# the machine program names the factory and the role each cgroup belongs
# to from every factory's facts.
@test "the probes run in each factory's machine, over its facts there, and none on the host (ADR-070 point 7)" {
	run host_eval 'factories.widgets.path = "/srv/widgets"; factories.acme.path = "/srv/acme";' \
		'let g = c.nixcage.machines.acme.guest.config; in
		 { host = c.systemd.services ? fabriek-probes;
		   script = g.systemd.services.fabriek-probes.script;
		   env = g.systemd.services.fabriek-probes.environment.FABRIEK_FACTORIES;
		   wanted = g.systemd.services.fabriek-probes.wantedBy;
		   facts = g.environment.etc ? "fabriek/factories/acme.env"; }'
	assert_success
	local out="$output"
	run jq -r .script <<<"$out"
	assert_output --partial 'bpftrace'
	assert_output --regexp '/nix/store/[^ ]*-probes.bt \| fabriek-container probes-publish'
	grep -q 'exec cgroup=%d uid=%d' "$FABRIEK_ROOT/modules/host/probes.bt"
	run jq -c '[.host, .env, .wanted, .facts]' <<<"$out"
	assert_output '[false,"/etc/fabriek/factories",["multi-user.target"],true]'
}

# ADR-067 point 1: the CLI reaches the machine program through sudo, for
# one program and one group, never wheel-wide.
@test "a member of the fabriek group runs the machine program as root without a password, and nothing else" {
	run host_eval 'factories.acme.path = "/srv/acme";' \
		'{ rules = c.security.sudo.extraRules; group = c.users.groups ? fabriek; }'
	assert_success
	local out="$output"
	run jq -c '[.group, (.rules | map(select(.groups == ["fabriek"])) | .[0].commands | map([.command, .options]))]' <<<"$out"
	assert_output '[true,[["/run/current-system/sw/bin/fabriek-container",["NOPASSWD","SETENV"]]]]'
}

# The boundary between render and the host: the path the unit writes a
# credential to is the path the location render wrote includes. Each side
# is asserted alone above; this is the two agreeing.
@test "the credential the unit writes lands where the rendered location includes it" {
	run host_eval 'factories.acme = { path = "/srv/acme"; resources.egress = [ "api.anthropic.com" ]; };' \
		'c.systemd.services.fabriek-acme-egress-credentials.script'
	assert_success
	local script="$output"
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/factory-render.sh
	source "$FABRIEK_ROOT/modules/factory-render.sh"
	local decl="$TEST_TEMP_DIR/declaration.json"
	echo '{ "name": "acme", "roles": {}, "resources": { "egress": [ "api.anthropic.com" ] } }' >"$decl"
	local included
	included="$(fabriek_render_proxy "$decl" | sed -n 's/^ *include \(.*\);$/\1/p')"
	[ -n "$included" ]
	local written
	written="$(jq -r . <<<"$script" | sed -n 's/^ *conf=\(.*\)$/\1/p' | sed 's/\$host/api.anthropic.com/')"
	[ "$included" = "$written" ]
}

# A factory in a nixcage machine of its own (ADR-070): what the host module
# declares to nixcage for each factory, and what the machine's guest carries.

@test "each factory is a nixcage machine with a slice of its own, sized by the host" {
	run host_eval 'factories.acme.path = "/srv/acme"; factories.widgets = { path = "/srv/widgets"; machine = { memory = "4G"; cpus = 2; disk = "20G"; }; };' \
		'{ acme = { inherit (c.nixcage.machines.acme) memory cpus diskSize uidSlice; };
		   widgets = { inherit (c.nixcage.machines.widgets) memory cpus diskSize uidSlice; }; }'
	assert_success
	run jq -c '[.acme.memory, .acme.cpus, .acme.diskSize, .acme.uidSlice.base, .acme.uidSlice.size]' <<<"$output"
	assert_output '["8G",4,"40G",3000000,65536]'
	run host_eval 'factories.acme.path = "/srv/acme"; factories.widgets = { path = "/srv/widgets"; machine = { memory = "4G"; cpus = 2; disk = "20G"; }; };' \
		'{ inherit (c.nixcage.machines.widgets) memory cpus diskSize uidSlice; }'
	run jq -c '[.memory, .cpus, .diskSize, .uidSlice.base]' <<<"$output"
	assert_output '["4G",2,"20G",3065536]'
}

@test "a factory's machine is placed on its bridge as every address of its subnet but the host's" {
	run host_eval 'factories.acme.path = "/srv/acme";' 'c.nixcage.machines.acme.placement'
	assert_success
	run jq -c '[.bridge, (.addresses | length), .addresses[0], .addresses[-1], (.addresses | index("10.77.0.1"))]' <<<"$output"
	assert_output '["fb-0",253,"10.77.0.2","10.77.0.254",null]'
}

@test "a factory's machine sees the checkout, the rendered directory and its credentials, read-only" {
	run host_eval 'factories.acme.path = "/srv/acme";' 'c.nixcage.machines.acme.shares'
	assert_success
	assert_output '[{"path":"/srv/acme","writable":false},{"path":"/var/lib/fabriek/acme","writable":false},{"path":"/var/lib/nixcage/fabriek/acme/bus","writable":false},{"path":"/var/lib/nixcage/fabriek/acme/forge","writable":false}]'
}

@test "the egress credentials are shared with no machine" {
	run host_eval 'factories.acme.path = "/srv/acme";' 'map (s: s.path) c.nixcage.machines.acme.shares'
	refute_output --partial egress
}

@test "the host's facts name the machine and the guest's do not" {
	run host_eval 'factories.acme.path = "/srv/acme";' \
		'{ host = c.environment.etc."fabriek/factories/acme.env".text;
		   guest = c.nixcage.machines.acme.guest.config.environment.etc."fabriek/factories/acme.env".text; }'
	assert_success
	local both="$output"
	jq -r .host <<<"$both" | grep -qx 'FABRIEK_MACHINE=acme'
	run jq -r .guest <<<"$both"
	refute_output --partial FABRIEK_MACHINE
	assert_line FABRIEK_STATE=/var/lib/nixcage/fabriek/acme
	assert_line GIT_CONFIG_VALUE_0=/srv/acme
}

@test "the guest puts its cages on the factory's bridge through its NIC, at the address kept for it" {
	run host_eval 'factories.acme.path = "/srv/acme";' \
		'let g = c.nixcage.machines.acme.guest.config; in
		 { bridge = g.nixcage.bridges.fb-0;
		   packages = map (p: p.pname or p.name) g.nixcage.containerPackages;
		   path = map (p: p.pname or p.name) g.environment.systemPackages;
		   range = g.nixcage.principalUidRange; }'
	assert_success
	run jq -c '[.bridge.address, .bridge.prefix, .bridge.uplink, (.packages | index("pi-coding-agent") != null), (.path | index("fabriek-machine") != null), .range.base]' <<<"$output"
	assert_output '["10.77.0.254",24,"eth0",true,true,700000]'
}

@test "the machine table is the host's and never reaches the operator's config" {
	run host_eval 'factories.acme = { path = "/srv/acme"; machine.memory = "4G"; };' 'c.environment.etc."fabriek/config.toml".text'
	assert_success
	refute_output --partial machine
	refute_output --partial 4G
}

@test "the state unit makes the credential directories a machine shares, before the machine is up" {
	run host_eval 'factories.acme.path = "/srv/acme";' 'c.systemd.services.fabriek-acme-state.script'
	assert_success
	assert_output --partial 'install -d -m 0700 /var/lib/nixcage/fabriek/acme/bus /var/lib/nixcage/fabriek/acme/forge'
}

@test "a factory's machine's guest evaluates whole, with fabriek in it" {
	run host_eval 'factories.acme.path = "/srv/acme";' 'c.nixcage.machines.acme.guest.config.system.build.toplevel.drvPath'
	assert_success
	assert_output --partial '-nixos-system-acme-'
}

@test "a switch leaves a running factory alone: up and down move it, as they move its machine" {
	run host_eval 'factories.acme = { path = "/srv/acme"; autoStart = true; };' \
		'{ restart = c.systemd.services.fabriek-acme.restartIfChanged; stop = c.systemd.services.fabriek-acme.stopIfChanged; }'
	assert_success
	assert_output '{"restart":false,"stop":false}'
}
