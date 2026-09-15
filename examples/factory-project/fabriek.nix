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

  ## Specialists and skills of this repository's own, beside the ones fabriek
  ## ships (ADR-042 point 3): a directory with the same layout as fabriek's
  ## catalogue. A name declared in both is refused, never shadowed.
  catalogue = "fabriek/catalogue";

  ## A role is what it provides and who it is. 'specialists' names entries of
  ## the catalogues; the role gets their tools, their prompts in that order,
  ## and their skills (ADR-042). Two specialists compose: 'backend' below is
  ## a Java developer who can read the Python beside it.
  ##
  ## 'shell' names one devShell of this same flake: the project's own build
  ## environment, resolved against the project's pin (ADR-016). A role that
  ## names none gets 'default'. A specialist's kit sits in front of it.
  ##
  ## 'provides' is what a role can be given to do. A stage names a capability
  ## rather than a role, so declaring a second backend adds capacity without
  ## touching the pipeline (ADR-015).
  ##
  ## No 'command': a role runs pi, the agent fabriek supports (ADR-029), in
  ## the mode its loop drives. Declaring one is allowed and wins word for
  ## word; it is argv, never a shell line.
  ##
  ## 'replicas = N' makes a role N roles, backend-1 to backend-N, each with
  ## this block and a cage, a worktree, a key and an account of its own; the
  ## base name is then no role (ADR-053). Capacity at a stage is how many
  ## roles provide what it needs.
  roles = {
    architect = {
      provides = [ "design" ];
      specialists = [ "architect" ];
    };
    ## Splits a goal from the architect's record and tends the policy, the
    ## guidance and this repository's own catalogue; assigns nothing, the
    ## decider does (ADR-050).
    manager = {
      provides = [
        "plan"
        "inspect"
      ];
      specialists = [ "manager" ];
    };
    backend = {
      provides = [ "build" ];
      specialists = [
        "springboot"
        "python"
      ];
      shell = "backend-jvm";
    };
    frontend = {
      provides = [ "build" ];
      specialists = [
        "frontend"
        "release-here"
      ];
      shell = "frontend";
    };
    reviewer = {
      provides = [ "review" ];
      specialists = [ "reviewer" ];
    };
  };

  workflows.ship = {
    ## A stage says what the work needs, what a task must carry before it is
    ## taken, and what finishing means there. The last is prose: the role
    ## reads it and fabriek never checks it.
    stages = [
      {
        needs = "design";
        done = "the approach is a record, with every decision a builder would need";
      }
      {
        needs = "plan";
        done = "the outcome lists the tasks, each with done and must-not-touch, in dependency order";
      }
      {
        needs = "build";
        ready = [ "acceptance" ];
        done = "tests pass and the change is reviewable";
      }
      ## A verdict stage: done is the role's judgement, not a change, so
      ## the executor asks no commit of it (ADR-051).
      {
        needs = "review";
        gate = "before-integration";
        verdict = true;
      }
      ## Every task ends under the manager's eye: the thread carries the
      ## trace of each attempt, and the manager's outcome names the lever it
      ## pulled or says nothing needed changing.
      {
        needs = "inspect";
        done = "the traces are read, and any lever pulled is named with its symptom";
        verdict = true;
      }
    ];

    ## What this workflow may spend before it stops. Runs are what can be
    ## counted from outside a cage whatever agent a role runs, which is why
    ## they always apply.
    budget.runs = 200;

    ## Who may ask whom. Unlike the pipeline this may point backwards, because
    ## the role that can answer a question is usually the one before.
    consults.backend = [ "architect" ];
    consults.manager = [ "architect" ];
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
    ## How many cages the machine's memory and cores are divided among.
    ## Every declared role runs, replicas included, so a count below the
    ## roles is refused rather than sizing each cage for fewer (ADR-053).
    concurrency = 5;
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
    egress = [
      "api.anthropic.com"
      "api.deepseek.com"
    ];
  };
}
