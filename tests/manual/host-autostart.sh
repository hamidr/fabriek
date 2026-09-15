#!/usr/bin/env bash
## ADR-048's one claim that needs a NixOS host and so cannot be a bats test:
## a factory declared with autoStart is running after boot, the CLI by hand
## and the unit are the same program on the same state, and the CLI reads
## the file the module rendered when the person has none of their own.
##
## Runs on a NixOS host whose configuration carries, for a factory named
## by F (default acme):
##
##   services.fabriek.factories.<F> = { path = ...; autoStart = true; };
##
## after a rebuild and a boot. Wants no scratch directory: the host's own
## /etc/fabriek/config.toml and /var/lib/fabriek are what is proved, so a
## personal config that would win over them is refused rather than unset.
##
##   F=acme tests/manual/host-autostart.sh
set -uo pipefail
cd "${FABRIEK_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}" || exit 1
F="${F:-acme}"
if [ -n "${FABRIEK_CONFIG:-}" ] || [ -e "$HOME/.config/fabriek/config.toml" ]; then
	echo "a personal config would win over /etc/fabriek/config.toml; this proof is about the host's" >&2
	exit 2
fi

fail=0
check() {
	local what="$1" want="$2" got="$3"
	got="$(printf '%s' "$got" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
	if [ "$got" = "$want" ]; then
		echo "  ok   $what"
	else
		echo "  FAIL $what: wanted '$want', got '$got'"
		fail=1
	fi
}
scenario() { printf '\n%s\n' "$1"; }
when() { printf '  When  %s\n' "$1"; }
ps_state() { fabriek ps --json | jq -r --arg f "$F" '.[] | select(.factory == $f) | .state'; }

scenario "The CLI reads the file the module rendered (ADR-048 point 2)"
when "fabriek help says which configuration it read"
check "it is the host's" "/etc/fabriek/config.toml" \
	"$(fabriek help | grep -m1 -o '/etc/fabriek/config.toml')"
check "the factory is registered there by the module, not by a hand" "$F" \
	"$(grep -o "^\[factories\.$F\]" /etc/fabriek/config.toml | sed 's/\[factories\.//; s/\]//')"

scenario "A factory with autoStart is running after boot (ADR-048 point 3)"
when "the host has booted and nobody has run fabriek up"
check "the unit is active" "active" "$(systemctl is-active "fabriek-$F")"
check "its machines live under /var/lib/fabriek" "/var/lib/fabriek/machines" \
	"$(systemctl show "fabriek-$F" -p Environment --value | tr ' ' '\n' | sed -n 's/^FABRIEK_MACHINES=//p')"
check "fabriek ps by hand sees the machine the unit started" "running" "$(ps_state)"

scenario "The unit and a hand are the same program on the same state"
when "the unit is stopped"
systemctl stop "fabriek-$F"
check "fabriek ps sees it down" "stopped" "$(ps_state)"
when "the unit is started again"
systemctl start "fabriek-$F"
check "fabriek ps sees it up" "running" "$(ps_state)"
check "and the unit agrees" "active" "$(systemctl is-active "fabriek-$F")"

echo
[ "$fail" = 0 ] && echo "host-autostart: every check passed" || echo "host-autostart: a check failed"
exit "$fail"
