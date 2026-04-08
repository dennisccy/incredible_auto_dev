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

## Note for Projects Using This Framework

If you are using this framework in your project (as a subrepo or copy), replace this file with your own `docs/goal.md`. Use `templates/project-goal.md` as a starting point.

Your `docs/goal.md` should describe YOUR project's vision, target users, success criteria, and key capabilities. All agents read this file before starting any phase.
