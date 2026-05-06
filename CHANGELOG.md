# Changelog

All notable changes to n8n-manager are documented in this file.

## [Unreleased]

## [5.0.0] — TBD

### Major: v5 Takeover — complete architectural rewrite

This release completes the v5-takeover milestone, retiring the v4 monolith and establishing
n8n-manager v5 as the only implementation. Key capabilities:

- **Modular architecture**: Bashly + Gum CLI (single compiled `n8n-manager` binary)
- **Canonical layout**: versioned backup repos with `.n8n-manager/` metadata
- **Migration tooling**: `n8n-manager migrate` converts v4 backup repos to canonical layout
- **v4 config compatibility**: existing `~/.config/n8n-manager/config` files auto-translated
- **Install path takeover**: `curl -sSf https://i.nskha.com | bash` installs v5; v4 binary preserved as `.v4.bak`
- **Quality hardening**: schema-drift refusal, PAT redaction, SHA-pinned auto-installs, shellcheck-clean
- **Test harness**: bats-core 1.13.0 full path matrix (SQLite/Postgres x Debian/Alpine)
- **CI/CD pipeline**: private dev repo with 16-parallel-job matrix CI; public release mirror

### Upgrade from v4

Run `n8n-manager update` on any host with v4 installed. Your existing config and backup repos
are forward-compatible. To migrate v4 backup repos to canonical layout, run `n8n-manager migrate`.

[Full migration guide in README.md]

---
<!-- v3.x history below (preserved for reference) -->

## [](https://github.com/Automations-Project/n8n-data-manager/compare/v3.0.16...v) (2025-06-19)

### Features

* add automated readme badge generation script and update badge section ([dcc987a](https://github.com/Automations-Project/n8n-data-manager/commit/dcc987a17f91e0d69be66f0c1ad91b3bb575f428))
* add GitHub Actions workflow for auto-updating README badges ([a6944bb](https://github.com/Automations-Project/n8n-data-manager/commit/a6944bb619d8480377eb8346d094825636e8c5fc))
## [3.0.15](https://github.com/Automations-Project/n8n-data-manager/compare/02f689ce9f6dc97eae0263b0ee74e6a3d8a932ea...v3.0.15) (2025-06-19)

### Features

* add CI/CD workflows with shellcheck, integration tests, and release automation ([eb2d451](https://github.com/Automations-Project/n8n-data-manager/commit/eb2d451ecb9031bf3c0433125de9614eb989f19e))
* add GitHub Actions workflow for release management and badge updates ([a42bd0e](https://github.com/Automations-Project/n8n-data-manager/commit/a42bd0efb3ed71de2fd69cded2e3b2cf1e1a3813))
* add script to automatically update README badges with dynamic repository info ([ad9543a](https://github.com/Automations-Project/n8n-data-manager/commit/ad9543a6cc586450bac51f1bed9295759f9f077c))
* add script to automatically update README badges with dynamic version and repo info ([92861d5](https://github.com/Automations-Project/n8n-data-manager/commit/92861d5ba8f7399cfac38943f47e06275e5b3134))
* add script to dynamically update README badges with version and repo info ([59e3a10](https://github.com/Automations-Project/n8n-data-manager/commit/59e3a10014e74adbb817771663e4bacbd566321f))
* add version bump script with major/minor/patch support ([a8b55a6](https://github.com/Automations-Project/n8n-data-manager/commit/a8b55a65e8de332743a57b5cb599a7584467c755))
* improve backup/restore handling for empty n8n instances and duplicate items ([31e32e3](https://github.com/Automations-Project/n8n-data-manager/commit/31e32e34c758d185b64135cbbe867be074b17bbb))

### Bug Fixes

* improve backup handling for clean n8n installations with empty data files ([0b4a7d3](https://github.com/Automations-Project/n8n-data-manager/commit/0b4a7d35e6cdd3ca4da73a4c5524472f948803c1))

### Reverts

* Revert "Add non-interactive mode and bump version to 3.0.6" ([02f689c](https://github.com/Automations-Project/n8n-data-manager/commit/02f689ce9f6dc97eae0263b0ee74e6a3d8a932ea))
