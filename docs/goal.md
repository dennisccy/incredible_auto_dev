# Project Goal

This repository IS the AI Multi-Agent Dev Chain framework itself. It is not a project that uses the framework -- it is the framework.

## Vision

Provide a reusable, quality-gated, multi-agent development pipeline that automates phased software development using Claude AI agents.

## Target Users

Developers and teams who want to automate their development lifecycle with AI agents while maintaining quality gates, security controls, and audit trails.

## Key Capabilities

1. 11-step verdict-gated pipeline (plan, test plan, dev+review, UI analysis, browser QA, QA validation, UX regression, audit, closure, finalize)
2. TDD-first development with automated review and QA loops
3. UI visibility system ensuring backend capabilities are surfaced to users
4. Supply-chain security gates for all package installations
5. Checkpoint/resume for interrupted pipeline runs
6. Artifact-based inter-agent communication (no free-form conversation)
7. Configurable model tiers (strong/standard/light) per agent

## Must-have user journeys

The framework's own acceptance journeys — operator-observable and evidence-backed. They
also make this file pass the same validation (`run-goal.sh validate_goal_file`) the
framework enforces on every adopter's goal.md.

- **J-01: Adopter ships phase 1**
  1. Fill `.claude/project-template.md` and author `docs/phases/phase-1.md` from `templates/phase-spec.md`.
  2. Run `./scripts/automation/run-phase.sh phase-1`.
  Acceptance: the run ends with CLOSURE-PASS; `runs/phase-1/status.json` reaches the
  final step; all 6 `reports/phase-1-*` UI-visibility artifacts exist.
- **J-02: Goal session achieves a demo goal**
  1. Author a small adopter-style `docs/goal.md` (journeys + anti-goals).
  2. Run `./scripts/automation/run-goal.sh --session-id demo`.
  Acceptance: the session halts GOAL_ACHIEVED only through the deterministic gates plus
  the two-key confirm — `telemetry.jsonl` halt event, `iter-<N>/gate-report.md`, and the
  CONFIRM_ACHIEVED verdict line all present.
- **J-03: Interrupted session resumes**
  1. Ctrl-C a running goal session mid-iteration.
  2. Relaunch `./scripts/automation/run-goal.sh --session-id <same-sid>`.
  Acceptance: the engine resumes from checkpoint without repeating completed steps —
  checkpoint markers present in the session dir; `engine.log` shows completed steps
  skipped on re-entry.
- **J-04: Offline evals protect edits**
  1. Run `./scripts/automation/run-evals.sh` with no API access.
  2. Seed a mirror edit (hand-edit one `.claude/agents/*.md`), run it again, then resync
     with `python3 scripts/automation/sync-cli-assets.py --cli claude` and run it a third time.
  Acceptance: exit 0 on the clean tree, exit 1 on the seeded drift, exit 0 again after
  the resync.

## Anti-goals

- No freeform-assistant mode: every change enters through a phase spec or a goal-mode iteration spec — work with no spec behind it is rejected in review
- No autonomous decisions on what the product IS: changes to `CLAUDE.md`, `docs/goal.md` journeys/anti-goals, model spend, or gate defaults require explicit human approval (maintenance-protocol §1) — an agent-made change there without a matching approved task is a violation
- No third AI provider: the backends are exactly Claude Code and OpenAI Codex CLI (`docs/cli-providers.md`) — a change adding another provider integration is out of scope

## Note for Projects Using This Framework

If you are using this framework in your project (as a subrepo or copy), replace this file with your own `docs/goal.md`. Use `templates/project-goal.md` as a starting point.

Your `docs/goal.md` should describe YOUR project's vision, target users, success criteria, and key capabilities. All agents read this file before starting any phase.
