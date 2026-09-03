## 28. Markdown-styled verdict cells vanish from the machine parser and launder FAIL into PASS

**Applies to:** any parser that extracts machine verdicts (PASS/FAIL/SKIP) from agent-written markdown, and any gate that consumes the parsed result.

**Pattern:** `merge_ui_test_results.py` matched verdict cells with `cell.strip().upper() in ("PASS","FAIL",...)`. Agents legitimately write `**FAIL**`, `` `SKIPPED` ``, or `PASS (with caveat)` — none of which match, so the cell parsed as NO verdict and silently dropped out of `compute_overall()`. With the FAIL rows invisible, the surviving PASS rows made the merged headline PASS while the raw lane file said FAIL — observed live twice (ops-hardening iter-9: 2 bold FAILs → merged PASS handed to the achievement gate; iter-12: header undercount). Auditors caught it both times only by re-reading the raw files.

**Why it fails:** The parser treated "doesn't match my exact format" as "carries no information" at exactly the layer where a dropped FAIL flips a gate outcome. Absence-of-verdict and PASS must never be conflated by a downstream `any(FAIL)` reduction; and agent output formats drift (bold, backticks, annotations) faster than parsers pin them.

**Prevention:** Normalize markdown emphasis (`c.strip().strip("*_`~")`) before matching; accept annotated verdicts via a word-boundary prefix match (`^(PASS|FAIL|SKIPPED|SKIP)\b`) scanned in REVERSE cell order so the verdict column outranks free-prose columns; keep bare-word prose non-matching. Every such parser carries a self-test case with bold/backtick/annotated verdicts wired into `run-evals.sh` (`merge_ui_test_results.py self-test`, cases `bold_verdicts` / `annotated_verdicts`). Rule: a verdict parser change ships with a fixture of REAL agent output that previously mis-parsed.

**Detection:** merged headline disagrees with a raw lane file's headline; `compute_overall` counter shows empty-string verdicts (`Counter({'PASS': n, '': k})`) for rows that visibly carry verdicts.
