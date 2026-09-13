# shellcheck shell=bash
## A declared size, as a number of bytes.
##
## Memory and a role's worktree quota are both written the way a person writes
## them, and both are compared against a ceiling the operator set (ADR-020),
## so reading one is a single thing rather than two. Comparing the strings
## instead would put 8G above 16G and hand a factory twice what was allowed.

## The suffixes a size may carry, and what each multiplies by. Powers of 1024,
## which is what every other tool in the path means by G.
fabriek_size_bytes() {
	local size="${1:-}" number suffix
	if [[ ! "$size" =~ ^([0-9]+)([KkMmGgTt]?)$ ]]; then
		echo "fabriek: not a size: $size" >&2
		return 1
	fi
	number="${BASH_REMATCH[1]}"
	suffix="${BASH_REMATCH[2]}"
	case "$suffix" in
	K | k) echo $((number * 1024)) ;;
	M | m) echo $((number * 1024 ** 2)) ;;
	G | g) echo $((number * 1024 ** 3)) ;;
	T | t) echo $((number * 1024 ** 4)) ;;
	*) echo "$number" ;;
	esac
}

## A declared size in MiB, which is what a hypervisor counts memory and disks
## in. Rounded down, because handing a machine more than the operator allowed
## is the direction that matters.
fabriek_size_mib() {
	local bytes
	bytes="$(fabriek_size_bytes "$1")" || return 1
	echo $((bytes / 1024 / 1024))
}
