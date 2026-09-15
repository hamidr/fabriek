// The test-first guard in the loop (ADR-044): what the agent may do next
// given what the loop has seen. Constrains factory/src/extension/guard.ts.
//
// The agent moves freely; the guard's rules are the preconditions on the
// two moves it can refuse, editSource and reportDone. The invariants say
// what no reachable state may look like. Every rule is a guard on an
// action, so a run that finds nothing says the rules are enough; break
// one on purpose and the matching invariant goes red.
module tddGuard {
  var lastRun: str          // "none", "failed", "passed"
  var srcEditsSinceRun: int // source edits since the last run
  var testEditedSinceRun: bool
  var done: bool
  // History: a source edit that followed a test edit with no run between.
  // Never set when the rules hold; set as soon as one is dropped.
  var codeBeforeRedSeen: bool
  // History: any edit at all this session. A session that edited nothing
  // has nothing a run could prove green: a verdict (ADR-051).
  var everEdited: bool

  action init = all {
    lastRun' = "none",
    srcEditsSinceRun' = 0,
    testEditedSinceRun' = false,
    done' = false,
    codeBeforeRedSeen' = false,
    everEdited' = false,
  }

  // A test file changes: always allowed, remembered until the next run.
  action editTest = all {
    not(done),
    lastRun' = lastRun,
    srcEditsSinceRun' = srcEditsSinceRun,
    testEditedSinceRun' = true,
    done' = done,
    codeBeforeRedSeen' = codeBeforeRedSeen,
    everEdited' = true,
  }

  // The three rules on a source edit.
  action editSource = all {
    not(done),
    not(testEditedSinceRun),                                   // see the test fail first
    not(lastRun == "passed" and srcEditsSinceRun >= 1),        // run between steps
    lastRun != "none",                                         // run something first
    lastRun' = lastRun,
    srcEditsSinceRun' = srcEditsSinceRun + 1,
    testEditedSinceRun' = testEditedSinceRun,
    done' = done,
    codeBeforeRedSeen' = (codeBeforeRedSeen or testEditedSinceRun),
    everEdited' = true,
  }

  // A test run the loop saw, with either verdict.
  action runTests(verdict) = all {
    not(done),
    lastRun' = verdict,
    srcEditsSinceRun' = 0,
    testEditedSinceRun' = false,
    done' = done,
    codeBeforeRedSeen' = codeBeforeRedSeen,
    everEdited' = everEdited,
  }

  // The fourth rule: done only on a passing run after the last edit, or
  // with no edit at all this session, which is a verdict and not a change.
  action reportDone = all {
    not(done),
    (lastRun == "passed" and srcEditsSinceRun == 0 and not(testEditedSinceRun)) or not(everEdited),
    lastRun' = lastRun,
    srcEditsSinceRun' = srcEditsSinceRun,
    testEditedSinceRun' = testEditedSinceRun,
    done' = true,
    codeBeforeRedSeen' = codeBeforeRedSeen,
    everEdited' = everEdited,
  }

  action step = any {
    editTest,
    editSource,
    nondet v = Set("failed", "passed").oneOf()
    runTests(v),
    reportDone,
  }

  // No two source edits without a run between, once green.
  val runBetweenSteps = not(lastRun == "passed" and srcEditsSinceRun > 1)
  // No source edit after a test edit without a run between.
  val testSeenFailingFirst = not(codeBeforeRedSeen)
  // No source edit before any run.
  val runBeforeCode = srcEditsSinceRun > 0 implies lastRun != "none"
  // Done only when the last run passed and nothing changed after it, or
  // when nothing was ever changed.
  val doneIsGreen = done implies ((lastRun == "passed" and srcEditsSinceRun == 0 and not(testEditedSinceRun)) or not(everEdited))
  // A session that edited and reported done had a passing run after it.
  val editedDoneIsRun = (done and everEdited) implies lastRun == "passed"

  val allInvariants = runBetweenSteps and testSeenFailingFirst and runBeforeCode and doneIsGreen and editedDoneIsRun
}
