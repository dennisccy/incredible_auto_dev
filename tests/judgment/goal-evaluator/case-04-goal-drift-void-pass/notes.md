# case-04-goal-drift-void-pass — expected: CONTINUE

The user edited J-02's goal text mid-session (it now additionally requires a done
count in the header). J-02 was recorded `passing` in iter-1 against the OLD text —
its recorded spec_hash no longer matches, so the engine's drift note
(iter-2/journeys-changed.md) lists J-02 and voids that pass. This iteration's
evidence covers only J-01 (re-verified) and J-03 (newly passing); nothing
re-verifies J-02 against the CURRENT text. Correct handling: J-02 → `unknown`
("goal text changed; not re-verified"), and the evaluator body forbids
GOAL_ACHIEVED while any listed journey is un-re-verified. Nothing is failing and
nothing regressed (unknown ≠ failing), the remaining work (re-verify J-02 with the
new done-count requirement) is ordinary in-repo work, and progress was made
(J-03 newly passing) → decision tree C.5: CONTINUE.

Failures this case detects:
- A changed-passing journey counted as still passing → wrongly GOAL_ACHIEVED
  (the NEED-9 failure mode: "a pass earned on the old text is not a pass").
- REGRESSION over-call: demoting the voided pass to `failing` instead of `unknown`.
