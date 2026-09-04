## Shared container layer: the minimal userland profile and the
## nixcage-container script that owns all nspawn mechanics. Used by the
## VM module (macOS path) and the host module (Linux path) unchanged --
## the script only assumes a Linux system with /var/lib/nixcage,
## /etc/nixcage/{profile,secret-env}, and a nix daemon socket.
{ pkgs }:
let
  ## Minimal userland for project containers. Containers hold no system of
  ## their own -- this profile plus the read-only store bind is everything.
  containerProfile = pkgs.buildEnv {
    name = "nixcage-container-profile";
    paths = with pkgs; [
      bashInteractive
      coreutils
      nix
      git
      cacert
      ## A project that declares its environment in .envrc is entered through
      ## direnv rather than nix develop, so direnv is part of the userland
      ## every session gets.
      direnv
      ## ssh-keygen signs commits and ssh-add names the key to sign with;
      ## both talk to the forwarded agent rather than to any key on disk.
      openssh
    ];
  };

  ## Guest-side container manager. The host CLI only ever calls this over
  ## SSH; all nspawn mechanics stay inside the VM where they are testable
  ## as one Nix-built script.
  nixcageContainer = pkgs.writeShellApplication {
    name = "nixcage-container";
    ## The sourced helpers are store paths, which shellcheck cannot follow from
    ## inside the build. They are real shell files and the dev shell lints them
    ## directly, so following them here would add nothing and the unfollowable
    ## source is what fails the build.
    excludeShellChecks = [ "SC1091" ];
    runtimeInputs = with pkgs; [
      coreutils
      systemd
      gnugrep
      ## A role's worktree is created here and handed to its uid: git makes
      ## the worktree, setfacl grants the uid the parts of the repository it
      ## needs without a shared group, which a cage cannot have (ADR-010).
      git
      acl
      ## The ownership check on a session's home walks it, so find has to be on
      ## the script's own PATH rather than only on the system's.
      findutils
      ## The shared record. The supervisor is the only writer (ADR-013), so
      ## this is here rather than in the container profile.
      git-bug
    ];
    text = ''
      ## Sourced by store path: the file is a real shell file so shellcheck
      ## and the bats suite can read it, and the store is available here.
      . ${./git-worktree.sh}
      . ${./role-uid.sh}
      . ${./storage.sh}
      . ${./role-worktree.sh}
      . ${./factory-clone.sh}
      . ${./task-store.sh}
      . ${./workflow-config.sh}
      . ${./record.sh}
      . ${./caps.sh}
      . ${./signing.sh}
      . ${./integrate.sh}
      . ${./dev-shell.sh}
      . ${./factory-config.sh}
      . ${./role-guidance.sh}

      STATE_DIR=/var/lib/nixcage
      ## Rendered by the platform module from nixcage.supervisor.roleUidRange.
      ## Absent when no factory is declared, which is the ordinary case.
      FACTORY_CONFIG=/etc/nixcage/factory
      ## One directory per declared factory, rendered by the platform module.
      FACTORIES_ROOT=/etc/nixcage/factories
      ## Resolve the /etc symlink to its store path: the container has its
      ## own /etc, but the store bind makes store paths valid inside.
      PROFILE="$(readlink -f /etc/nixcage/profile)"
      SECRET_ENV=/etc/nixcage/secret-env

      die() { echo "nixcage-container: $*" >&2; exit 1; }

      [ "$(id -u)" = 0 ] || die "must run as root (use sudo)"

      ## Names reach root-level rm -rf and nspawn --machine; only the
      ## derived-name alphabet is allowed.
      check_name() {
        printf '%s' "$1" | grep -qE '^[a-zA-Z0-9-]+$' || die "invalid container name: $1"
      }

      ## Render nixcage.secretEnv (VAR=secretname lines) into an export
      ## file inside the session rootfs. Values must never appear in
      ## nspawn's argv, where any local user could read them from
      ## /proc/<pid>/cmdline; %q also keeps multiline secrets intact.
      write_secret_env() {
        local out="$1"
        : >"$out"
        chmod 600 "$out"
        [ -f "$SECRET_ENV" ] || return 0
        local var secret
        while IFS='=' read -r var secret; do
          [ -n "$var" ] || continue
          if [ -r "/run/secrets/$secret" ]; then
            printf 'export %s=%q\n' "$var" "$(cat "/run/secrets/$secret")" >>"$out"
          else
            echo "nixcage-container: secret '$secret' for $var not found; skipping" >&2
          fi
        done <"$SECRET_ENV"
      }

      ## A per-session rootfs skeleton is a few kilobytes; separate ones let
      ## concurrent sessions of the same project coexist because nspawn
      ## takes an exclusive lock on its directory tree.
      make_rootfs() {
        local root="$1" role="''${2:-}"
        ## nspawn refuses a rootfs without /usr ("doesn't look like it has
        ## an OS tree").
        mkdir -p "$root"/{etc,usr,tmp,root,workspace,nix,proc,sys,dev,run,var/empty}
        chmod 1777 "$root/tmp"
        echo 'NAME=nixcage' >"$root/etc/os-release"
        cp /etc/resolv.conf "$root/etc/resolv.conf" 2>/dev/null || true
        nixcage_role_passwd "$role" >"$root/etc/passwd" ||
          die "invalid role name: $role"
        cat >"$root/etc/group" <<'EOF'
      root:x:0:
      nogroup:x:65534:
      EOF
        cat >"$root/etc/nsswitch.conf" <<'EOF'
      passwd: files
      group: files
      hosts: files dns
      EOF
      }

      cmd_enter() {
        ## Options precede the positional arguments so a session command can
        ## still be anything at all.
        local auth_sock="" role="" task_dir="" signing_role="" shell_name=""
        while [ $# -gt 0 ]; do
          case "$1" in
          --auth-sock)
            auth_sock="''${2:-}"
            shift 2
            ;;
          --role)
            role="''${2:-}"
            shift 2
            ;;
          --task-dir)
            task_dir="''${2:-}"
            shift 2
            ;;
          --signing-key)
            signing_role="''${2:-}"
            shift 2
            ;;
          --shell)
            shell_name="''${2:-}"
            shift 2
            ;;
          *) break ;;
          esac
        done

        local name="$1" project="$2"
        shift 2
        check_name "$name"

        ## Refused rather than resolved: a silent preference would decide a
        ## security property by argument order (ADR-009).
        if [ -n "$auth_sock" ] && [ -n "$signing_role" ]; then
          die "--auth-sock and --signing-key are mutually exclusive"
        fi
        [ -d "$project" ] || die "project directory not found: $project"

        ## A specialist works in one named devShell of the project's own flake.
        ## The name is checked here as well as where it is declared, because
        ## this is the last point before it becomes part of a flake reference
        ## inside the session.
        local -a shell_env=()
        if [ -n "$shell_name" ]; then
          nixcage_shell_name_ok "$shell_name" ||
            die "not a usable devShell name: $shell_name"
          shell_env=("--setenv=NIXCAGE_SHELL=$shell_name")
        fi

        ## An ordinary session is mapped onto the project owner: nix's libgit2
        ## refuses a repository owned by a different uid, and every project
        ## directory belongs to the invoking user (ADR-004). A factory role
        ## instead gets a uid of its own, because roles must be isolated from
        ## each other and not merely from the host (ADR-010); the role owns its
        ## worktree, so the ownership check still passes.
        local owner_uid owner_gid
        if [ -n "$role" ]; then
          [ -f "$FACTORY_CONFIG" ] ||
            die "no factory declared: set nixcage.supervisor.roleUidRange"
          # shellcheck disable=SC1090
          . "$FACTORY_CONFIG"
          owner_uid="$(nixcage_role_uid "$STATE_DIR/role-uids" \
            "''${ROLE_UID_BASE:?}" "''${ROLE_UID_SIZE:?}" "$role")" || exit 1
          owner_gid="$owner_uid"
        else
          owner_uid="$(stat -c %u "$project")"
          owner_gid="$(stat -c %g "$project")"
        fi

        ## A linked git worktree keeps its git directory inside the primary
        ## repository, which the project bind does not cover; without these
        ## binds every git command in the session fails outright. The paths
        ## are bound at the spelling git itself recorded, so its own pointers
        ## resolve unchanged inside the container.
        local -a git_binds=()
        local git_dirs git_dir
        git_dirs="$(nixcage_git_binds "$project")" ||
          die "cannot resolve the git directory of $project"
        ## A linked worktree is also recorded by its own absolute path, inside
        ## the administrative directory git keeps for it. Tools that resolve a
        ## repository through libgit2 rather than through the .git file open
        ## that path directly -- nix's flake fetcher does, so without this bind
        ## every flake command in a role worktree fails on a directory that
        ## exists in the VM and not in the session. The project keeps its
        ## /workspace bind as well: that path is the one sessions are written
        ## against.
        if [ "$project" != /workspace ]; then
          git_binds+=("--bind=$project:$project")
        fi
        while IFS= read -r git_dir; do
          [ -n "$git_dir" ] || continue
          git_binds+=("--bind=$git_dir")
        done <<<"$git_dirs"

        local cdir="$STATE_DIR/containers/$name"
        local home="$STATE_DIR/homes/$name"
        mkdir -p "$cdir" "$home"
        ## The home is the container's /root and holds whatever the session
        ## writes there, so it is private to the mapped user. If its contents
        ## belong to someone else the whole tree is re-owned rather than left
        ## unusable: a role's uid can change when nixcage state is lost and
        ## reallocated, and a home the session cannot write fails far from that
        ## cause, as a read-only database deep inside a flake evaluation.
        if [ "$(stat -c %u "$home")" != "$owner_uid" ] ||
          [ -n "$(find "$home" ! -uid "$owner_uid" -print -quit 2>/dev/null)" ]; then
          chown -R "$owner_uid:$owner_gid" "$home"
        fi
        chmod 700 "$home"

        local rootfs="$cdir/session-$$"
        make_rootfs "$rootfs" "$role"
        ## Expand now: locals are out of scope when the EXIT trap fires.
        # shellcheck disable=SC2064
        trap "rm -rf '$rootfs'" EXIT

        ## The environment is chosen inside the container, where the project
        ## is actually bound; the library is referenced by store path because
        ## the store is bound read-only there. bash -c consumes the first
        ## argument as $0, so a placeholder always precedes the user command.
        local shell_cmd=". /etc/nixcage-env 2>/dev/null || true; \
          . ${./dev-shell.sh}; \
          nixcage_enter_shell \"\$@\""
        set -- placeholder "$@"

        ## Git identity, rendered by the platform module from nixcage.git.
        ## Absent when the user declared none, in which case git behaves as
        ## it does anywhere else without an identity.
        if [ -f /etc/nixcage/gitconfig ]; then
          cp /etc/nixcage/gitconfig "$rootfs/etc/gitconfig"
        fi

        ## Commits are signed through the invoking user's agent: the socket
        ## is forwarded in, no key material is. The container is mapped onto
        ## the project owner, so the socket has to be reachable by that uid
        ## rather than by whoever forwarded it.
        local -a agent_bind=()
        if [ -n "$auth_sock" ]; then
          if [ -S "$auth_sock" ]; then
            chown "$owner_uid:$owner_gid" "$auth_sock"
            : >"$rootfs/run/ssh-agent.sock"
            agent_bind=(
              "--bind=$auth_sock:/run/ssh-agent.sock"
              "--setenv=SSH_AUTH_SOCK=/run/ssh-agent.sock"
            )
          else
            echo "nixcage-container: no agent socket at $auth_sock; commits cannot be signed" >&2
          fi
        fi

        ## A role is told the rules it cannot infer from error messages: what
        ## it may write, and that the packed-refs permission error on every ref
        ## update is expected rather than a failed commit (ADR-010).
        local -a guidance_args=()
        local guidance_line
        while IFS= read -r guidance_line; do
          [ -n "$guidance_line" ] || continue
          guidance_args+=("$guidance_line")
        done < <(nixcage_role_guidance_args "${./role-guidance.md}" "$role")

        ## A task reaches the session as files rather than as arguments: the
        ## brief is read, the outcome is written, and neither ever passes
        ## through a command line or a keystroke stream.
        local -a task_bind=()
        if [ -n "$task_dir" ]; then
          task_bind=(
            "--bind=$task_dir:/run/nixcage/task"
            "--setenv=NIXCAGE_TASK=/run/nixcage/task"
          )
        fi

        ## A run nobody is watching signs with a key of its own and holds no
        ## forwarded agent, so it cannot push, pull a private repository, or
        ## authenticate anywhere (ADR-009).
        local -a signing_bind=()
        if [ -n "$signing_role" ]; then
          local key signers line
          key="$(nixcage_signing_ensure "$STATE_DIR" "$signing_role" "$owner_uid")" ||
            die "could not prepare a signing key for $signing_role"
          signers="$(nixcage_signing_signers "$STATE_DIR")"
          while IFS= read -r line; do
            [ -n "$line" ] || continue
            signing_bind+=("$line")
          done < <(nixcage_signing_args "$key" "$signers")
          ## Appended after the operator's identity so the role's own name,
          ## address and key win: a role signs as itself.
          nixcage_signing_gitconfig "$signing_role" >>"$rootfs/etc/gitconfig"
        fi

        write_secret_env "$rootfs/etc/nixcage-env"
        ## Everything the skeleton contains was created by root and would
        ## otherwise appear as an unmapped nobody inside the container.
        chown -R "$owner_uid:$owner_gid" "$rootfs"

        systemd-nspawn --quiet --register=no \
          --directory="$rootfs" \
          --machine="$name" \
          --private-users="$owner_uid:1" \
          --private-users-ownership=off \
          --bind-ro=/nix/store \
          --bind-ro=/nix/var/nix/db \
          --bind=/nix/var/nix/daemon-socket \
          --bind="$project:/workspace" \
          --bind="$home:/root" \
          ''${git_binds[@]+"''${git_binds[@]}"} \
          ''${agent_bind[@]+"''${agent_bind[@]}"} \
          ''${guidance_args[@]+"''${guidance_args[@]}"} \
          ''${task_bind[@]+"''${task_bind[@]}"} \
          ''${signing_bind[@]+"''${signing_bind[@]}"} \
          --chdir=/workspace \
          --setenv=HOME=/root \
          --setenv=PATH="$PROFILE/bin" \
          --setenv=NIX_REMOTE=daemon \
          --setenv=NIX_CONFIG='experimental-features = nix-command flakes' \
          --setenv=NIX_SSL_CERT_FILE="$PROFILE/etc/ssl/certs/ca-bundle.crt" \
          --setenv=NIXCAGE_DIRENVRC="${pkgs.nix-direnv}/share/nix-direnv/direnvrc" \
          ''${shell_env[@]+"''${shell_env[@]}"} \
          --setenv=TERM="''${TERM:-xterm}" \
          "$PROFILE/bin/bash" -c "$shell_cmd" "$@"
      }

      ## Create or repair a role's worktree and print its path. Separate from
      ## enter because the supervisor prepares a role before it runs anything
      ## in it, and because entering must not silently create state.
      ##
      ## The worktree is taken from the factory's own clone rather than from the
      ## operator's repository: role ownership needs a filesystem carrying
      ## ownership and ACLs, and the operator's may not have one (ADR-011).
      cmd_role_worktree() {
        local factory="$1" role="$2" repo="$3"
        [ -d "$repo" ] || die "repository not found: $repo"
        [ -f "$FACTORY_CONFIG" ] ||
          die "no factory declared: set nixcage.supervisor.roleUidRange"
        # shellcheck disable=SC1090
        . "$FACTORY_CONFIG"

        local clone
        clone="$(nixcage_factory_clone_ensure "$STATE_DIR" "$factory" "$repo")" ||
          die "could not prepare the factory clone for $factory"

        local uid
        uid="$(nixcage_role_uid "$STATE_DIR/role-uids" \
          "''${ROLE_UID_BASE:?}" "''${ROLE_UID_SIZE:?}" "$role")" || exit 1
        ## STORAGE_DATASET and ROLE_QUOTA come from the same declaration file
        ## as the uid range and are empty where nixcage's state is not on ZFS,
        ## in which case the worktree is an ordinary directory (ADR-017). zfs
        ## itself is taken from the system rather than pinned here: the tools
        ## have to match the kernel module of the machine running them, which
        ## on Linux is the admin's and not ours.
        nixcage_role_worktree_ensure "$STATE_DIR" "$factory" "$role" "$clone" "$uid" \
          "''${STORAGE_DATASET:-}" "''${ROLE_QUOTA:-}" ||
          die "could not prepare the worktree for role $role"
      }

      ## Enter a declared role: prepare its worktree, then enter it under the
      ## role's own uid. The repository comes from the declaration rather than
      ## from the caller, so a role can only ever be run against the factory it
      ## was declared in.
      cmd_role_enter() {
        ## Options precede the positionals exactly as in enter, so a session
        ## command can still be anything at all and no flag can be mistaken
        ## for part of it.
        local -a passthrough=()
        while [ $# -gt 0 ]; do
          case "$1" in
          --auth-sock | --task-dir | --signing-key)
            passthrough+=("$1" "''${2:-}")
            shift 2
            ;;
          *) break ;;
          esac
        done

        local factory="''${1:-}" role="''${2:-}"
        [ -n "$factory" ] && [ -n "$role" ] ||
          die "usage: nixcage-container role-enter [--auth-sock <path>|--signing-key <role>] [--task-dir <path>] <factory> <role> [cmd...]"
        shift 2

        local repo declared_cmd declared_shell
        repo="$(nixcage_factory_repository "$FACTORIES_ROOT" "$factory")" || exit 1
        declared_cmd="$(nixcage_factory_role_command "$FACTORIES_ROOT" "$factory" "$role")" || exit 1
        declared_shell="$(nixcage_factory_role_shell "$FACTORIES_ROOT" "$factory" "$role")" || exit 1

        ## A role's toolchain comes from its declaration for the same reason
        ## its command does: what a specialist has to hand is a property of the
        ## factory, not of whoever started the session.
        local -a shell_opt=()
        if [ -n "$declared_shell" ]; then
          shell_opt=(--shell "$declared_shell")
        fi

        local worktree
        worktree="$(cmd_role_worktree "$factory" "$role" "$repo")" || exit 1

        ## The declaration wins over anything the caller passes, because what a
        ## role runs is a property of the factory and not of whoever started it.
        ## It arrives as argv words, one per line, so nothing in it is re-split.
        if [ -n "$declared_cmd" ]; then
          local -a declared=()
          local word
          while IFS= read -r word; do
            [ -n "$word" ] || continue
            declared+=("$word")
          done <<<"$declared_cmd"
          set -- "''${declared[@]}"
        fi

        cmd_enter --role "$role" ''${shell_opt[@]+"''${shell_opt[@]}"} \
          ''${passthrough[@]+"''${passthrough[@]}"} \
          "$factory-$role" "$worktree" "$@"
      }

      ## The tasks of every declared factory, kept beside the clones they are
      ## worked in rather than in any repository.
      TASKS_ROOT="$STATE_DIR/tasks"
      ## How much of each item each role has been shown. The supervisor's
      ## bookkeeping, not part of the shared record.
      SEEN_ROOT="$STATE_DIR/seen"

      ## Every role that could take a task at this stage, in declaration order.
      ## A stage nothing can work is a declaration mistake and is refused where
      ## it is read rather than when a task reaches it (ADR-015).
      stage_roles() {
        local factory="$1" workflow="$2" stage="$3"
        local capability roles
        capability="$(nixcage_workflow_stage_needs \
          "$FACTORIES_ROOT" "$factory" "$workflow" "$stage")" ||
          die "$workflow stage $stage declares no capability"
        roles="$(nixcage_factory_roles_providing "$FACTORIES_ROOT" "$factory" "$capability")"
        [ -n "$roles" ] ||
          die "no role of $factory provides $capability, which $workflow stage $stage needs"
        printf '%s\n' "$roles"
      }

      ## A role is busy while it holds a task: one worktree, one branch, one
      ## task at a time. Blocked counts as busy because nothing switched
      ## branches when the task blocked.
      role_busy() {
        local factory="$1" role="$2" id state
        while IFS= read -r id; do
          [ -n "$id" ] || continue
          [ "$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" role)" = "$role" ] || continue
          state="$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" state)"
          case "$state" in
          running | blocked) return 0 ;;
          esac
        done < <(nixcage_task_list "$TASKS_ROOT" "$factory")
        return 1
      }

      ## Who works a task. A task already taken answers with its taker, however
      ## busy it is: the branch is in that role's namespace and no peer can
      ## write it. An untaken one resolves its stage's capability to the first
      ## idle role providing it, in declaration order, so a factory replays the
      ## same way twice (ADR-015).
      resolve_taker() {
        local factory="$1" id="$2"
        local taken workflow stage role
        taken="$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" role)"
        if [ -n "$taken" ]; then
          echo "$taken"
          return 0
        fi
        workflow="$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" workflow)"
        stage="$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" stage)"
        ## Resolved into a variable rather than read from a process
        ## substitution: an undeclared capability has to fail here with its own
        ## message, and inside a subshell it would look like every role being
        ## busy instead.
        local candidates
        candidates="$(stage_roles "$factory" "$workflow" "$stage")" || exit 1
        while IFS= read -r role; do
          [ -n "$role" ] || continue
          role_busy "$factory" "$role" && continue
          echo "$role"
          return 0
        done <<<"$candidates"
        return 1
      }

      ## The fields a stage requires before it will take a task, defaulting to
      ## the acceptance criteria: a task nobody stated a finish line for is not
      ## work anyone can judge.
      stage_ready_fields() {
        local factory="$1" workflow="$2" stage="$3" fields
        fields="$(nixcage_workflow_stage_ready \
          "$FACTORIES_ROOT" "$factory" "$workflow" "$stage")"
        [ -n "$fields" ] || fields=acceptance
        printf '%s\n' "$fields"
      }

      ## File a goal. It enters at the workflow's first stage, which says what
      ## capability the work needs rather than who has it, so the operator
      ## names what should happen and nobody names a role.
      cmd_task_file() {
        local factory="$1" workflow="$2" acceptance="''${3:-}"
        local entry stage field
        entry="$(nixcage_workflow_entry "$FACTORIES_ROOT" "$factory" "$workflow")" || exit 1
        stage="''${entry%% *}"
        stage_roles "$factory" "$workflow" "$stage" >/dev/null || exit 1

        local id
        id="$(nixcage_task_new "$TASKS_ROOT" "$factory" "$workflow" "$stage")" ||
          die "could not file a task for $workflow"
        if [ -n "$acceptance" ]; then
          nixcage_task_set "$TASKS_ROOT" "$factory" "$id" acceptance "$acceptance"
        fi

        ## Every task opens an item in the shared record, so there is one place
        ## the discussion of this work accumulates (ADR-013). The clone must
        ## exist first; filing is the operator's act, so it is made here rather
        ## than waiting for a role to run.
        local repo clone item
        repo="$(nixcage_factory_repository "$FACTORIES_ROOT" "$factory")" || exit 1
        clone="$(nixcage_factory_clone_ensure "$STATE_DIR" "$factory" "$repo")" || exit 1
        item="$(printf '%s\n\n%s\n' "$id" "$acceptance" |
          nixcage_record_new "$clone" supervisor)"
        [ -n "$item" ] && nixcage_task_set "$TASKS_ROOT" "$factory" "$id" item "$item"
        ## What a stage requires before it will take work is the stage's to
        ## state. A task missing one of those fields stays proposed and says
        ## which, rather than being taken and failing inside a cage.
        local -a required=()
        while IFS= read -r field; do
          [ -n "$field" ] || continue
          required+=("$field")
        done < <(stage_ready_fields "$factory" "$workflow" "$stage")
        nixcage_task_ready "$TASKS_ROOT" "$factory" "$id" "''${required[@]}" >/dev/null || true
        echo "$id"
      }

      cmd_task_list() {
        local factory="$1" want="''${2:-}"
        local id
        while IFS= read -r id; do
          [ -n "$id" ] || continue
          printf '%s\t%s\t%s\n' "$id" \
            "$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" state)" \
            "$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" role)"
        done < <(nixcage_task_list "$TASKS_ROOT" "$factory" "$want")
      }

      ## Move settled work to the next stage, or finish it. Used when a stage
      ## has no gate, and again when a gate is approved, so the two paths
      ## cannot drift apart.
      advance_work() {
        local factory="$1" id="$2" clone="$3" item="$4"
        local workflow stage next child child_item seed
        workflow="$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" workflow)"
        stage="$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" stage)"
        next="$(nixcage_workflow_next "$FACTORIES_ROOT" "$factory" "$workflow" "$stage")"

        if [ -n "$next" ]; then
          child="$(nixcage_task_advance "$TASKS_ROOT" "$factory" "$id" \
            "''${next%% *}")" || die "$id: could not advance the work"
          local -a required=()
          local field
          while IFS= read -r field; do
            [ -n "$field" ] || continue
            required+=("$field")
          done < <(stage_ready_fields "$factory" "$workflow" "''${next%% *}")
          nixcage_task_ready "$TASKS_ROOT" "$factory" "$child" "''${required[@]}" >/dev/null || true
          if [ -n "$item" ]; then
            seed="$STATE_DIR/runs/$factory/$id/seed"
            mkdir -p "$(dirname "$seed")"
            {
              printf '%s\n\n' "$child"
              printf 'inherited from %s:\n\n' "$id"
              nixcage_record_show "$clone" "$item"
            } >"$seed"
            child_item="$(nixcage_record_new "$clone" supervisor <"$seed")"
            [ -n "$child_item" ] &&
              nixcage_task_set "$TASKS_ROOT" "$factory" "$child" item "$child_item"
            printf 'settled; %s opened, needing %s\n' "$child" "''${next#* }" |
              nixcage_record_comment "$clone" "$item" supervisor
          fi
          echo "$id: settled, $child opened, needing ''${next#* }"
        else
          nixcage_task_advance "$TASKS_ROOT" "$factory" "$id" "" ||
            die "$id: could not finish the work"
          [ -n "$item" ] && printf 'settled; the pipeline ends here\n' |
            nixcage_record_comment "$clone" "$item" supervisor
          echo "$id: settled, the pipeline ends here"
        fi
      }

      ## Answer a gate. Approval lets the work move on by the same path a
      ## gateless stage takes; rejection sends it back with the reason kept.
      cmd_task_answer() {
        local factory="$1" id="$2" answer="$3" reason="''${4:-}"
        local clone item
        clone="$(nixcage_factory_clone_path "$STATE_DIR" "$factory")" || exit 1
        item="$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" item)"

        nixcage_task_answer "$TASKS_ROOT" "$factory" "$id" "$answer" "$reason" || exit 1
        if [ -n "$item" ]; then
          printf '%s: %s\n' "$answer" "''${reason:-no reason given}" |
            nixcage_record_comment "$clone" "$item" operator
        fi

        if [ "$answer" = "approve" ]; then
          advance_work "$factory" "$id" "$clone" "$item"
        else
          echo "$id: rejected, back to its role"
        fi
      }

      ## Bring the factory and the operator's repository back into agreement,
      ## in the only direction each is allowed to move. Divergence stops the
      ## factory rather than being resolved: rewriting a shared branch is rare
      ## and deliberate, and continuing on a history that no longer exists is
      ## worse than stopping.
      cmd_factory_sync() {
        local factory="$1"
        local repo clone shared
        repo="$(nixcage_factory_repository "$FACTORIES_ROOT" "$factory")" || exit 1
        clone="$(nixcage_factory_clone_path "$STATE_DIR" "$factory")" || exit 1
        shared="$(nixcage_factory_shared_branch)"
        [ -d "$clone" ] || die "$factory has no clone yet"

        if nixcage_integrate_diverged "$clone" "$repo" "$shared"; then
          nixcage_integrate_halt "$STATE_DIR" "$factory" \
            "the operator's $shared no longer contains what this factory was built on"
          die "$factory halted: $shared has diverged"
        fi

        nixcage_integrate_publish "$clone" "$repo" "$shared" ||
          die "$factory: could not hand $shared to the operator"
        echo "$factory: $shared published"
      }

      ## Advance the shared branch to a commit a role produced, then hand it on.
      ## Reading nothing: which commit is the reviewer's judgement, made in a
      ## cage; moving a ref to a named commit is this, made outside one.
      cmd_factory_integrate() {
        local factory="$1" commit="$2"
        local clone shared
        clone="$(nixcage_factory_clone_path "$STATE_DIR" "$factory")" || exit 1
        shared="$(nixcage_factory_shared_branch)"
        nixcage_integrate_advance "$clone" "$shared" "$commit" ||
          die "$factory: $commit does not fast-forward $shared"
        cmd_factory_sync "$factory"
      }

      cmd_factory_resume() {
        local factory="$1"
        nixcage_integrate_resume "$STATE_DIR" "$factory"
        echo "$factory: resumed"
      }

      ## What roles have raised for the operator. The same mechanism a role
      ## uses to ask another role, pointed at the one participant who is not a
      ## role, so there is one way to ask for attention rather than two.
      cmd_factory_reports() {
        local factory="$1"
        local clone item
        clone="$(nixcage_factory_clone_path "$STATE_DIR" "$factory")" || exit 1
        [ -d "$clone" ] || return 0
        while IFS= read -r item; do
          [ -n "$item" ] || continue
          printf '%s\t%s\n' "''${item:0:8}" \
            "$(nixcage_record_show "$clone" "$item" | head -1)"
        done < <(nixcage_record_needing "$clone" operator)
      }

      cmd_factory_status() {
        local factory="$1" halted
        if halted="$(nixcage_integrate_halted "$STATE_DIR" "$factory")"; then
          printf 'halted\t%s\n' "$halted"
        else
          printf 'running\t\n'
        fi
      }

      cmd_task_thread() {
        local factory="$1" id="$2"
        local clone item
        clone="$(nixcage_factory_clone_path "$STATE_DIR" "$factory")" || exit 1
        item="$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" item)"
        [ -n "$item" ] || die "$id has no item in the record"
        nixcage_record_show "$clone" "$item"
      }

      cmd_task_show() {
        local factory="$1" id="$2" field
        for field in state role workflow stage parent item gate attempts acceptance outcome answer; do
          printf '%s\t%s\n' "$field" \
            "$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" "$field")"
        done
      }

      ## Run one task in the cage of whoever takes it. The task is handed in as
      ## files and the outcome is read back out of one, so nothing about it is
      ## ever an argument. Every ending is recorded: settled when the role wrote
      ## what it did, failed when it wrote nothing, crashed, or outlived its
      ## limit.
      ##
      ## No role is named by the caller: the stage says what the work needs and
      ## the first idle role providing it takes the task, which is then its for
      ## every later attempt (ADR-015).
      cmd_task_run() {
        local factory="$1" id="$2" role
        [ -f "$FACTORY_CONFIG" ] ||
          die "no factory declared: set nixcage.supervisor.roleUidRange"
        # shellcheck disable=SC1090
        . "$FACTORY_CONFIG"
        local max="''${TASK_MAX_ATTEMPTS:-3}"
        local limit="''${TASK_TIMEOUT_SECONDS:-3600}"

        local halted
        if halted="$(nixcage_integrate_halted "$STATE_DIR" "$factory")"; then
          die "$factory is halted: $halted"
        fi

        role="$(resolve_taker "$factory" "$id")" ||
          die "$id: every role that could take this work is busy"
        nixcage_task_take "$TASKS_ROOT" "$factory" "$id" "$role" || exit 1

        local clone item workflow
        clone="$(nixcage_factory_clone_path "$STATE_DIR" "$factory")" || exit 1
        item="$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" item)"
        workflow="$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" workflow)"

        ## The caps are checked before anything is spent, and in this order:
        ## the machine before the workflow, because a slot refused costs
        ## nothing while a budget charged and then abandoned does not come
        ## back. Reaching either stops cleanly and says which one it was.
        local concurrency budget_runs
        concurrency="''${RUN_CONCURRENCY:-0}"
        budget_runs="$(nixcage_workflow_budget "$FACTORIES_ROOT" "$factory" "$workflow" runs)"

        nixcage_cap_claim "$STATE_DIR" "$factory" "$id" "$concurrency" || exit 1
        # shellcheck disable=SC2064
        trap "nixcage_cap_release '$STATE_DIR' '$factory' '$id'" EXIT

        if ! nixcage_cap_spend "$STATE_DIR" "$factory" "$workflow" runs 1 "$budget_runs"; then
          [ -n "$item" ] && printf 'stopped: %s has spent its run budget\n' "$workflow" |
            nixcage_record_comment "$clone" "$item" supervisor
          exit 1
        fi

        nixcage_task_attempt "$TASKS_ROOT" "$factory" "$id" "$max" || exit 1

        ## The supervisor writes what it did as it does it, so reading the item
        ## top to bottom is the story of the work rather than its ending.
        if [ -n "$item" ]; then
          printf 'attempt %s started for %s\n' \
            "$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" attempts)" "$role" |
            nixcage_record_comment "$clone" "$item" supervisor || true
        fi

        local uid run_dir
        uid="$(nixcage_role_uid "$STATE_DIR/role-uids" \
          "''${ROLE_UID_BASE:?}" "''${ROLE_UID_SIZE:?}" "$role")" || exit 1
        run_dir="$STATE_DIR/runs/$factory/$id"
        rm -rf "$run_dir"
        mkdir -p "$run_dir"
        {
          printf 'task: %s\n' "$id"
          printf 'role: %s\n' "$role"
          printf 'acceptance:\n%s\n' \
            "$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" acceptance)"
          ## What finishing means at this stage, as its declaration states it.
          ## Handed over rather than checked: judging whether work meets a bar
          ## is reading content, which is what a cage is for (ADR-015).
          local finish
          finish="$(nixcage_workflow_stage_done "$FACTORIES_ROOT" "$factory" \
            "$workflow" "$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" stage)")"
          if [ -n "$finish" ]; then
            printf '\ndone at this stage means:\n%s\n' "$finish"
          fi
          printf '\nbody:\n%s\n' \
            "$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" body)"
          ## The conventions of this factory, which the repository carries and
          ## the architect maintains. The baseline nixcage ships states
          ## properties of the cage; this states how this project works.
          local own_guidance
          own_guidance="$(nixcage_factory_guidance "$clone")"
          if [ -n "$own_guidance" ]; then
            printf '\nthis factory:\n%s\n' "$own_guidance"
          fi

          ## What has already been said about this work. A role opens its turn
          ## reading the discussion rather than only the goal, and is told
          ## which part of it is new since it last looked -- replaying
          ## everything as though it were new is how a record stops being read.
          if [ -n "$item" ]; then
            local seen fresh
            seen="$(nixcage_record_seen "$SEEN_ROOT" "$factory" "$role" "$item")"
            fresh="$(nixcage_record_since "$clone" "$item" "$seen")"
            printf '\nrecord:\n%s\n' "$(nixcage_record_show "$clone" "$item")"
            if [ -n "$fresh" ]; then
              printf '\nnew since you last looked:\n%s\n' "$fresh"
            else
              printf '\nnew since you last looked:\n  nothing\n'
            fi
            nixcage_record_mark_seen "$SEEN_ROOT" "$factory" "$role" "$item" \
              "$(nixcage_record_count "$clone" "$item")"
          fi
        } >"$run_dir/brief"
        : >"$run_dir/outcome"
        : >"$run_dir/mentions"
        mkdir -p "$run_dir/comments"
        chown "$uid:$uid" "$run_dir/outcome" "$run_dir/mentions" "$run_dir/comments"
        chmod 444 "$run_dir/brief"

        local status=0
        timeout "$limit" "$0" role-enter \
          --task-dir "$run_dir" --signing-key "$role" \
          "$factory" "$role" || status=$?

        ## Whatever the role wrote during its turn reaches the record now: it
        ## could not write there itself, and this is the boundary where its
        ## writing becomes visible to anyone else.
        if [ -n "$item" ]; then
          nixcage_record_ingest "$clone" "$run_dir" "$role" "$item" || true
        fi

        local outcome
        outcome="$(cat "$run_dir/outcome" 2>/dev/null)"
        if [ "$status" = 124 ]; then
          nixcage_task_failed "$TASKS_ROOT" "$factory" "$id" \
            "the run outlived its $limit second limit" "$max"
          [ -n "$item" ] && printf 'the run outlived its %s second limit\n' "$limit" |
            nixcage_record_comment "$clone" "$item" supervisor
          die "$id: run outlived its limit"
        elif [ -n "$outcome" ]; then
          nixcage_task_settle "$TASKS_ROOT" "$factory" "$id" "$outcome" ||
            die "$id: could not record the outcome"

          ## A gated stage stops here. The work is done and the hand-off waits
          ## on a person, so the task stays awaiting-review rather than moving
          ## on, and the slot it held was released when this run ended.
          local stage gate
          stage="$(nixcage_task_get "$TASKS_ROOT" "$factory" "$id" stage)"
          gate="$(nixcage_workflow_stage_gate "$FACTORIES_ROOT" "$factory" "$workflow" "$stage")"
          if [ -n "$gate" ]; then
            nixcage_task_gate "$TASKS_ROOT" "$factory" "$id" "$gate" || exit 1
            [ -n "$item" ] && printf 'waiting at the %s gate\n' "$gate" |
              nixcage_record_comment "$clone" "$item" supervisor
            echo "$id: settled, waiting at the $gate gate"
            return 0
          fi

          advance_work "$factory" "$id" "$clone" "$item"
        else
          nixcage_task_failed "$TASKS_ROOT" "$factory" "$id" \
            "the session ended having recorded no outcome" "$max"
          [ -n "$item" ] && printf 'the session ended having recorded no outcome\n' |
            nixcage_record_comment "$clone" "$item" supervisor
          die "$id: no outcome recorded"
        fi
      }

      cmd_list() {
        [ -d "$STATE_DIR/containers" ] || return 0
        ls -1 "$STATE_DIR/containers"
      }

      cmd_rm() {
        local name="$1"
        check_name "$name"
        rm -rf "$STATE_DIR/containers/''${name:?}" "$STATE_DIR/homes/''${name:?}"
      }

      cmd="''${1:-}"
      shift || true
      case "$cmd" in
      enter) cmd_enter "$@" ;;
      role-worktree) cmd_role_worktree "$@" ;;
      role-enter) cmd_role_enter "$@" ;;
      task-run) cmd_task_run "$@" ;;
      task-file) cmd_task_file "$@" ;;
      task-list) cmd_task_list "$@" ;;
      task-show) cmd_task_show "$@" ;;
      task-thread) cmd_task_thread "$@" ;;
      task-answer) cmd_task_answer "$@" ;;
      factory-sync) cmd_factory_sync "$@" ;;
      factory-integrate) cmd_factory_integrate "$@" ;;
      factory-resume) cmd_factory_resume "$@" ;;
      factory-status) cmd_factory_status "$@" ;;
      factory-reports) cmd_factory_reports "$@" ;;
      list) cmd_list ;;
      rm) cmd_rm "$@" ;;
      *) die "usage: nixcage-container enter [--role <role>] [--shell <name>] <name> <project> [cmd...] | role-enter [--auth-sock <path>] <factory> <role> [cmd...] | role-worktree <factory> <role> <repo> | task-run <factory> <id> | task-file <factory> <workflow> [acceptance] | task-list <factory> [state] | task-show <factory> <id> | task-thread <factory> <id> | task-answer <factory> <id> approve|reject [reason] | factory-sync <factory> | factory-integrate <factory> <commit> | factory-resume <factory> | factory-status <factory> | factory-reports <factory> | list | rm <name>" ;;
      esac
    '';
  };
  ## The git configuration a session sees, rendered from nixcage.git by
  ## whichever platform module is in use. Signing goes through the agent the
  ## CLI forwards, so no key is named here: with user.signingKey unset git
  ## calls gpg.ssh.defaultKeyCommand and signs with the first agent key.
  gitConfigText =
    git:
    ''
      [user]
        name = ${git.userName}
        email = ${git.userEmail}
    ''
    + pkgs.lib.optionalString git.signing.enable ''
      [gpg]
        format = ssh
      [gpg "ssh"]
        program = ${pkgs.openssh}/bin/ssh-keygen
        defaultKeyCommand = ssh-add -L
      [commit]
        gpgsign = true
      [tag]
        gpgsign = true
    '';
in
{
  profile = containerProfile;
  script = nixcageContainer;
  inherit gitConfigText;
}
