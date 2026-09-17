# Changelog

## 0.2.2-demo — source-only prerelease (2026-09-18)

- Added checksummed forward migrations for padded dispatch suggestions and
  protected invoice line-detail compatibility without changing stored document
  identifiers.
- Added numeric ordering, rollover/exhaustion, authorization, fresh/upgrade,
  mobile-validator, and isolated API regression coverage.
- Added ownership-aware clean onboarding, loopback isolation, configuration and
  data-preservation checks, and exact mobile companion pinning in both workflow
  copies.
- Verified the complete source-demo API matrix and paired Android onboarding;
  production and physical-device release gates remain separate.
- Reconciled public onboarding, acceptance scope, maintainer redistribution
  attestation, Supabase-derived configuration provenance, and included license text.
- Restricted the release workflow to the exact `v0.2.2-demo` tag with positive
  and negative regression coverage; publication contains source archives only.

## Unreleased — second-pass review

- Corrected readiness claims: fresh migrations and mobile API coverage fail;
  setup/start and future releases are gated pending a complete sanitized export.
- Added isolated migration/contract tests, credential-preservation and JWT/profile
  regression tests, Compose ownership checks, and explicit readiness documentation.
- Hardened custom-auth function checks and corrected public configuration URLs.

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-03-10

### Added
- Initial release of the Supabase Warehouse Template
- Custom phone OTP authentication (no GoTrue dependency)
- Docker Compose setup with 10+ containers
- Edge Functions: router, config, PDF generation, printing
- CUPS printing integration via IPP
- Gotenberg HTML-to-PDF conversion
- Prometheus + Grafana monitoring stack (optional profile)
- Connection pooler via Supavisor (optional profile)
- One-command setup script with automatic secret generation
- Health check script
- Comprehensive .env.example with all variables documented
- CI/CD workflows for GitHub Actions
- Consolidated database migration with warehouse schema
