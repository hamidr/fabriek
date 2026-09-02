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
    ];
    text = ''
      ## Sourced by store path: the file is a real shell file so shellcheck
      ## and the bats suite can read it, and the store is available here.
      . ${./git-worktree.sh}
      . ${./role-uid.sh}
      . ${./role-worktree.sh}
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
        local auth_sock="" role=""
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
          *) break ;;
          esac
        done

        local name="$1" project="$2"
        shift 2
        check_name "$name"
        [ -d "$project" ] || die "project directory not found: $project"

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
        while IFS= read -r git_dir; do
          [ -n "$git_dir" ] || continue
          git_binds+=("--bind=$git_dir")
        done <<<"$git_dirs"

        local cdir="$STATE_DIR/containers/$name"
        local home="$STATE_DIR/homes/$name"
        mkdir -p "$cdir" "$home"
        ## The home is the container's /root and holds whatever the session
        ## writes there, so it is private to the mapped user.
        chown "$owner_uid:$owner_gid" "$home"
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
          --chdir=/workspace \
          --setenv=HOME=/root \
          --setenv=PATH="$PROFILE/bin" \
          --setenv=NIX_REMOTE=daemon \
          --setenv=NIX_CONFIG='experimental-features = nix-command flakes' \
          --setenv=NIX_SSL_CERT_FILE="$PROFILE/etc/ssl/certs/ca-bundle.crt" \
          --setenv=NIXCAGE_DIRENVRC="${pkgs.nix-direnv}/share/nix-direnv/direnvrc" \
          --setenv=TERM="''${TERM:-xterm}" \
          "$PROFILE/bin/bash" -c "$shell_cmd" "$@"
      }

      ## Create or repair a role's worktree and print its path. Separate from
      ## enter because the supervisor prepares a role before it runs anything
      ## in it, and because entering must not silently create state.
      cmd_role_worktree() {
        local factory="$1" role="$2" repo="$3"
        [ -d "$repo" ] || die "repository not found: $repo"
        [ -f "$FACTORY_CONFIG" ] ||
          die "no factory declared: set nixcage.supervisor.roleUidRange"
        # shellcheck disable=SC1090
        . "$FACTORY_CONFIG"
        local uid
        uid="$(nixcage_role_uid "$STATE_DIR/role-uids" \
          "''${ROLE_UID_BASE:?}" "''${ROLE_UID_SIZE:?}" "$role")" || exit 1
        nixcage_role_worktree_ensure "$STATE_DIR" "$factory" "$role" "$repo" "$uid" ||
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
          --auth-sock)
            passthrough+=(--auth-sock "''${2:-}")
            shift 2
            ;;
          *) break ;;
          esac
        done

        local factory="''${1:-}" role="''${2:-}"
        [ -n "$factory" ] && [ -n "$role" ] ||
          die "usage: nixcage-container role-enter [--auth-sock <path>] <factory> <role> [cmd...]"
        shift 2

        local repo declared_cmd
        repo="$(nixcage_factory_repository "$FACTORIES_ROOT" "$factory")" || exit 1
        declared_cmd="$(nixcage_factory_role_command "$FACTORIES_ROOT" "$factory" "$role")" || exit 1

        local worktree
        worktree="$(cmd_role_worktree "$factory" "$role" "$repo")" || exit 1

        ## The declaration wins over anything the caller passes, because what a
        ## role runs is a property of the factory and not of whoever started it.
        if [ -n "$declared_cmd" ]; then
          set -- "$declared_cmd"
        fi

        cmd_enter --role "$role" ''${passthrough[@]+"''${passthrough[@]}"} \
          "$factory-$role" "$worktree" "$@"
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
      list) cmd_list ;;
      rm) cmd_rm "$@" ;;
      *) die "usage: nixcage-container enter [--role <role>] <name> <project> [cmd...] | role-enter [--auth-sock <path>] <factory> <role> [cmd...] | role-worktree <factory> <role> <repo> | list | rm <name>" ;;
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
