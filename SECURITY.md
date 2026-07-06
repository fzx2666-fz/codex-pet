# Security Policy

## Reporting a Vulnerability

Please report security issues privately before opening a public issue.

If this repository is hosted on GitHub, use GitHub's private vulnerability
reporting feature when available. Otherwise, contact the maintainer directly.

## Scope

Relevant issues include:

- unintended disclosure of local Codex prompt or log content
- unsafe modification of `~/.codex/hooks.json`
- privilege escalation or arbitrary command execution
- unexpected network access

## Local-Only Design

Codex Status Bar is intended to run locally and does not require a server. Avoid
adding telemetry, remote logging, or automatic update behavior without explicit
user consent and documentation.
