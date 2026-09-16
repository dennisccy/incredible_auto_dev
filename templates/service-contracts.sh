#!/usr/bin/env bash
# service-contracts.sh — copy to <project>/.claude/service-contracts.sh
#
# The framework sources this file (from ensure_phase_ports) before it probes,
# reuses or tears down any application service. It is the supported way to
# configure the service contracts at RUNTIME — `.claude/project-template.md`
# documents them for agents but is never sourced, so declaring them only there
# has no effect on the shell.
#
# Anything already set in the environment wins, so an operator or CI can
# override a single invocation without editing this file.

# ── Reuse verification ───────────────────────────────────────────────────────
# When a service is ALREADY listening on this project's port and this run did
# not start it, the framework will not assume it is yours. Declare how to
# recognise it, or the run stops with a named blocker rather than testing an
# unknown service (it will not kill it, and will not silently change port).
#
# The command receives the response body on STDIN and "<url> <port>" as
# arguments. Exit 0 means "this is the expected service".
# Pin the build where you can, so a stale external instance is rejected too.
#
# export CHAIN_SERVICE_VERIFY_BACKEND='jq -e ".service == \"myapp-api\""'
# export CHAIN_SERVICE_VERIFY_FRONTEND='grep -q "<title>MyApp"'

# ── Health contract ──────────────────────────────────────────────────────────
# Which HTTP statuses mean "the application is actually serving". Default is
# 2xx/3xx. This is deliberately NOT the boot-readiness regex: that one is
# permissive (any status proves the server is routing) and using it for health
# would let a service returning 500 be preserved and reused as a dependency.
# Set this only if your valid readiness response is not 2xx/3xx.
#
# export CHAIN_SERVICE_HEALTHY_BACKEND='^(2|3|404)'
# export CHAIN_SERVICE_HEALTHY_FRONTEND='^[23]'
