## The factory that works this repository (ADR-020).
##
## A repository declares who works it, and it declares it here rather than in
## the configuration of whichever machine happens to be running it. That is
## what lets a second person clone this and get the same team, and what makes
## a role and the devShell it names change together instead of drifting apart.
##
## It is a separate file only so that reading it costs nothing: the flake
## imports it as its 'fabriek' output, and anything that wants to check the
## declaration can evaluate this file on its own.
##
## Nothing here can reach the machine the factory is given. The schema is
## closed: a key fabriek does not recognise is refused with its own name.
{
  name = "example";

  ## A command is argv, one word per element, never a shell line, so nothing
  ## in it is re-split on the way through. Which coding agent a role runs is
  ## this repository's business and not fabriek', and nothing validates it.
  ## pi is the one fabriek supports (ADR-029): the console and the ledger are
  ## built on records the agent defines, so the factory needs an agent whose
  ## protocol it can pin and change rather than wait on.
  ##
  ## 'shell' names one devShell of this same flake, so each specialist has its
  ## own tools to hand (ADR-016). A role that names none gets 'default'.
  ##
  ## 'provides' is what a role can be given to do. A stage names a capability
  ## rather than a role, so declaring a second backend adds capacity without
  ## touching the pipeline (ADR-015).
  roles = {
    architect = {
      command = [ "pi" "--mode" "rpc" ];
      provides = [ "design" ];
    };
    backend = {
      command = [ "pi" "--mode" "rpc" ];
      provides = [ "build" ];
      shell = "backend-jvm";
    };
    frontend = {
      command = [ "pi" "--mode" "rpc" ];
      provides = [ "build" ];
      shell = "frontend";
    };
    reviewer = {
      command = [ "pi" "--mode" "rpc" ];
      provides = [ "review" ];
    };
  };

  workflows.ship = {
    ## A stage says what the work needs, what a task must carry before it is
    ## taken, and what finishing means there. The last is prose: the role
    ## reads it and fabriek never checks it.
    stages = [
      {
        needs = "design";
        done = "the approach is written down and the work is split";
      }
      {
        needs = "build";
        ready = [ "acceptance" ];
        done = "tests pass and the change is reviewable";
      }
      {
        needs = "review";
        gate = "before-integration";
      }
    ];

    ## What this workflow may spend before it stops. Runs are what can be
    ## counted from outside a cage whatever agent a role runs, which is why
    ## they always apply.
    budget.runs = 200;

    ## Who may ask whom. Unlike the pipeline this may point backwards, because
    ## the role that can answer a question is usually the one before.
    consults.backend = [ "architect" ];
  };

  ## What this factory asks of the machine it is given. Every one of these is
  ## clamped to the ceiling the operator set in their own config, and fabriek
  ## says which field it clamped rather than sizing down quietly.
  resources = {
    memory = "8G";
    cores = 4;
    roleQuota = "20G";
    ## What this factory's record may cost (ADR-036). Unbounded it would
    ## fill the pool and take every worktree above with it.
    recordQuota = "4G";
    ## Tokens, input and output, the factory may spend before the proxy
    ## refuses (ADR-037). The operator's ceiling caps it like the rest.
    tokens = 2000000;
    concurrency = 3;
    taskAttempts = 3;
    runTimeoutSeconds = 3600;

    ## Where this factory's agents may reach, and the only thing here that is
    ## a permission rather than an amount (ADR-025). A cage holds no
    ## credential and no route: it reaches the proxy on its own machine, and
    ## the proxy reaches these and nothing else.
    ##
    ## This one meets its ceiling by intersection, and an operator who has
    ## named no endpoints allows none. Declaring more here cannot widen what
    ## this factory reaches on somebody else's machine.
    egress = [ "api.anthropic.com" ];
  };
}
