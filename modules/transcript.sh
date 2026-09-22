# shellcheck shell=bash
## A role's transcript: the session pi keeps in the role's home (ADR-038
## point 2), listed, printed as it is, or read as the turns' text. Reading
## it is how one learns whether a skill loaded, a server started or the
## guard fired; nothing here reaches a cage.
##
## Sourced by store path into fabriek-container beside names.sh.

## Where pi writes a role's sessions: PI_CODING_AGENT_SESSION_DIR is
## ~/.pi/sessions in the cage, and the role's home is what ~ is there.
fabriek_transcript_dir() {
	local state="$1" factory="$2" role="$3"
	printf '%s/homes/%s-%s/.pi/sessions\n' "$state" "$factory" "$role"
}

## A session is one file pi named; a name that could be a path is refused.
fabriek_transcript_name_ok() {
	[[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*\.jsonl$ ]]
}

## Newest first, with size in bytes.
fabriek_transcript_list() {
	local dir="$1"
	if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
		echo "no sessions yet"
		return 0
	fi
	## Session names are pi's, timestamped and without spaces, so newest
	## first is the reverse of their sort.
	local path name
	for path in "$dir"/*.jsonl; do
		[ -e "$path" ] || continue
		printf '%s\n' "${path##*/}"
	done | sort -r | while IFS= read -r name; do
		printf '%s  %s\n' "$name" "$(stat -c %s "$dir/$name")"
	done
}

## The turns' text: who said what, the tools called, the results and
## whether each was an error. One jq program over the session's lines.
fabriek_transcript_text() {
	jq -r '
	  select(.type == "message") | .message as $m
	  | if $m.role == "user" then
	      "user: " + (if ($m.content | type) == "string" then $m.content
	                  else ([$m.content[]? | select(.type == "text") | .text] | join("\n")) end)
	    elif $m.role == "assistant" then
	      ([$m.content[]? | select(.type == "text") | "assistant: " + .text]
	       + [$m.content[]? | select(.type == "toolCall") | "assistant calls " + .name])
	      | join("\n")
	    elif $m.role == "toolResult" then
	      $m.toolName + (if $m.isError then " (error)" else "" end) + ": "
	      + ([$m.content[]? | select(.type == "text") | .text] | join("\n"))
	    else empty end'
}

## fabriek_transcript <state> <factory> <role> [--text] [<session>]
fabriek_transcript() {
	local state="$1" factory="$2" role="$3" text="" session=""
	shift 3
	while [ $# -gt 0 ]; do
		case "$1" in
		--text) text=1 ;;
		*) session="$1" ;;
		esac
		shift
	done
	local dir
	dir="$(fabriek_transcript_dir "$state" "$factory" "$role")"
	if [ -z "$session" ]; then
		fabriek_transcript_list "$dir"
		return 0
	fi
	if ! fabriek_transcript_name_ok "$session"; then
		echo "fabriek: not a session name: $session" >&2
		return 1
	fi
	[ -f "$dir/$session" ] || {
		echo "fabriek: $role has no session $session" >&2
		return 1
	}
	if [ -n "$text" ]; then
		fabriek_transcript_text <"$dir/$session"
	else
		cat "$dir/$session"
	fi
}
