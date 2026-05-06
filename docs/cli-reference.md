<!--
  cli-reference.md — single-file deep reference for the n8n-manager CLI.
  Source of truth: src/bashly.yml + each src/*_command.sh. The publish
  workflow auto-bumps the version banner between AUTOVER markers on
  every release; everything else is hand-written.
-->

# n8n-manager — Command Reference

**Version:** <!-- AUTOVER:start -->5.0.0<!-- AUTOVER:end --> &nbsp;·&nbsp; **Audience:** operators, CI authors, automation engineers &nbsp;·&nbsp; **Mode focus:** non-interactive, scriptable.

This document is the deep reference for every command, every flag, every argument, and every documented exit path. If you can't find a behavior here, it isn't there.

---

## Table of contents

- [Conventions](#conventions)
- [Global flags](#global-flags)
- [Configuration file (`~/.config/n8n-manager/config`)](#configuration-file)
- [Environment & runtime](#environment--runtime)
- [Authentication — three PAT input methods](#authentication--three-pat-input-methods)
- [Commands](#commands)
  - [`welcome`](#welcome)
  - [Data — `backup`](#backup)
  - [Data — `restore`](#restore)
  - [Data — `import-url` (alias `import`)](#import-url)
  - [System — `install`](#install)
  - [System — `update`](#update)
  - [System — `uninstall`](#uninstall)
  - [Workflow — `workflow graph`](#workflow-graph)
  - [Workflow — `workflow report`](#workflow-report)
  - [Workflow — `workflow clean-pins`](#workflow-clean-pins)
  - [Workflow — `workflow validate`](#workflow-validate)
  - [Workflow — `workflow settings`](#workflow-settings)
  - [Workflow — `workflow publish`](#workflow-publish)
  - [Workflow — `workflow unpublish`](#workflow-unpublish)
  - [Workflow — `workflow compare`](#workflow-compare)
  - [Migration — `migrate`](#migrate)
  - [Migration — `migrate-config`](#migrate-config)
- [Compatibility constraints](#compatibility-constraints)
- [Common non-interactive recipes](#common-non-interactive-recipes)
- [Exit codes](#exit-codes)

---

## Conventions

- Code in `monospace` is meant to be typed verbatim.
- Angle brackets `<value>` are placeholders.
- `[optional]` square brackets mark optional arguments.
- Boolean flags (no `arg:`) take **no value** — presence enables them.
- Enum flags are listed with `allowed: [a, b, c]` and an explicit default.
- Non-interactive readiness: every command in this document has at least one example that runs cleanly with **no TTY input** (suitable for CI, cron, docker `RUN`).
- "Probe-driven dispatch" means n8n-manager auto-detects CLI version, REST API auth, DB backend (sqlite vs postgres) per run and chooses the safest read/write path. You don't pass flags for this.

---

## Global flags

Every command accepts these — they are repeated in the per-command sections only when their behavior is command-specific.

| Flag | Type | Default | Effect |
|------|------|---------|--------|
| `--verbose` | bool | off | Detailed debug logging. Tokens stay redacted. |
| `--trace` | bool | off | `set -x` execution trace (developer-grade). Tokens stay redacted. |
| `--dry-run` | bool | off | No side effects — every destructive action becomes a log line. |
| `--log-file <path>` | string | — | Append plain-text timestamped logs to `<path>`. |
| `--config <path>` | string | `~/.config/n8n-manager/config` | Read config from a non-default path. CLI flags still override config values. |
| `--record` | bool | off | Capture session typescript + replay tape. For `backup --record`, artifacts are pushed to `Backups/records/<session-id>/` in the backup repo. |
| `--record-output <path>` | string | auto | Override the recording artifact directory. |

Recording behavior:

- In **interactive mode**, if `--record` is omitted the CLI may prompt whether to record.
- In **non-interactive mode** the flag is the sole source of truth — no prompt fires.
- Recording artifacts: `session.typescript`, `session.timing`, `replay.tape`, plus a JSON metadata file. Local GIF generation is intentionally disabled — GIFs render via a GitHub Actions workflow injected into the backup repo on first push.

---

## Configuration file

Path resolution (first match wins):

1. `--config <path>` flag
2. `${XDG_CONFIG_HOME}/n8n-manager/config`
3. `~/.config/n8n-manager/config`

Format: shell-style `KEY="value"` lines. Comments (`#`) and blank lines ignored. Unknown keys are silently dropped (forward-compatible). Quotes are stripped from values.

| Key | Maps to flag | Default | Notes |
|-----|--------------|---------|-------|
| `CONF_GITHUB_TOKEN` | `--token` | — | Required for backup/restore. **Keep the file `chmod 600`.** |
| `CONF_GITHUB_REPO` | `--repo` | — | `owner/repo` form |
| `CONF_GITHUB_BRANCH` | `--branch` | `main` | Git branch on the backup repo |
| `CONF_CONTAINER` | `--container` | — | n8n container name or ID |
| `CONF_BACKUP_TYPE` | `--backup-type` | `all` | `all` / `workflows` / `credentials` / `enterprise` / `full-db` |
| `CONF_BACKUP_LAYOUT` | `--backup-layout` | `canonical` | `canonical` / `combined` / `workflow-bundles` |
| `CONF_CREDENTIAL_EXPORT_MODE` | `--credential-export-mode` | `stubs` | `stubs` / `encrypted` / `decrypted` |
| `CONF_RESTORE_TYPE` | `--restore-type` | `all` | Mirror of `CONF_BACKUP_TYPE` for the restore path |
| `CONF_SEPARATE_FILES` | `--separate-files` | `false` | Legacy; canonical layout already separates files |
| `CONF_N8N_API_KEY` | `--n8n-api-key` | auto-detect | Override n8n REST API key |
| `CONF_N8N_API_URL` | `--n8n-api-url` | auto-detect | Override n8n REST API base URL |
| `CONF_VERBOSE` | `--verbose` | `false` | Boolean (`"true"`/`"false"`) |
| `CONF_LOG_FILE` | `--log-file` | — | File-append log path |
| `CONF_RECORD` | `--record` | `false` | Boolean |
| `CONF_RECORD_OUTPUT` | `--record-output` | auto | Recording artifact dir |
| `CONF_WORKFLOWS_DIR` | `--workflows-dir` | — | Default for the `workflow` subcommand group |

**Override precedence:** CLI flag → environment-supplied `ARG_*` → config file → built-in default.

Config-file shape changed in v5; v4 files are auto-translated on first read (the original is preserved as `<config>.v4.bak`). Run `n8n-manager migrate-config` explicitly if the auto-translate falls back.

---

## Environment & runtime

| Variable | Source | Effect |
|----------|--------|--------|
| `XDG_CONFIG_HOME` | env | Default: `~/.config`. Used for config file location. |
| `XDG_DATA_HOME` | env | Default: `~/.local/share`. Used for `n8n-manager/bin/{gum,vhs}`. |
| `HAS_GUM` | auto-set | `true` when `gum` is on PATH or in `${XDG_DATA_HOME}/n8n-manager/bin`. UI helpers degrade silently when `false`. |
| `SKIP_DOCKER_CHECK` | auto-set per command | `workflow`, `welcome`, `install`, `update`, `uninstall`, `migrate`, `migrate-config` skip the docker daemon pre-flight. Data commands (`backup`, `restore`, `import-url`) require docker. |
| `VERSION`, `BUILD_STAMP`, `GUM_VERSION`, `VHS_VERSION` | constants in `src/initialize.sh` | Read-only; surfaced in `--version`. |

Required host CLIs:

- `bash 4+` (`set -Eeuo pipefail` requires it)
- `docker` (running daemon) — for data commands only
- `git`, `curl` — always
- `python3` — only when the SQLite fallback path runs
- `psql` — optional; if absent, postgres fallback runs `postgres:16-alpine` as a sidecar on the same docker network
- `scriptreplay` (`util-linux`) — only if you use `--record`

Auto-installed on first run to `${XDG_DATA_HOME:-~/.local/share}/n8n-manager/bin/`:

- `gum` v0.17.0 (SHA-pinned per platform; see `src/initialize.sh`)
- `vhs` v0.11.0 (only when `make vhs` is invoked)

---

## Authentication — three PAT input methods

For every data command (`backup`, `restore`, `import-url`), the GitHub Personal Access Token can be supplied three ways. Listed in **descending preference**:

### `--token-file <path>` (recommended for shared hosts)

```bash
n8n-manager backup -c n8n -r user/backups --token-file ~/.secrets/gh.pat
```

- File **must** be `chmod 600` — otherwise the command refuses with an error.
- Token never appears in `/proc/<pid>/cmdline`.
- Empty file is rejected.

### `--token-stdin` (recommended for CI)

```bash
op read "op://Vault/n8n-manager/pat" | n8n-manager backup --token-stdin -c n8n -r user/backups
echo "$GITHUB_PAT" | n8n-manager backup --token-stdin -c n8n -r user/backups
```

- Refused if stdin is `/dev/null` (prevents silent empty-PAT runs).
- Empty input is rejected (stdin is consumed once, then closed).
- Cannot be combined with `--token` or `--token-file`.

### `--token <pat>` / `-t <pat>` (legacy / quick local use)

```bash
n8n-manager backup -c n8n -t ghp_xxx -r user/backups
```

- The token appears in `ps -ef` listings on the host. Avoid in shared environments.
- Acceptable for personal workstations and ephemeral containers.

### Token from the config file

Set `CONF_GITHUB_TOKEN="ghp_..."` in `~/.config/n8n-manager/config` (file mode `600`). With this set, every data command can drop the `--token*` flag entirely.

---

## Commands

### `welcome`

Default command — runs when `n8n-manager` is invoked with no subcommand. Prints a static command summary in every context (works fine over `curl | sudo bash`); when stdin is a TTY and `gum` is installed, also offers a one-shot menu that `exec`s into the chosen subcommand.

```bash
n8n-manager                    # routes here
n8n-manager welcome
```

Flags accepted (no behavioral effect): `--verbose`, `--trace`.

---

### `backup`

Export n8n data and push to a GitHub repo.

**Required:**

| Flag | Short | Purpose |
|------|-------|---------|
| `--container <name>` | `-c` | Docker container ID or name |
| `--token <pat>` *(or `--token-file` / `--token-stdin` / config)* | `-t` | GitHub PAT with `Contents: Read+Write` |
| `--repo <owner/repo>` | `-r` | Backup repository |

**Optional:**

| Flag | Short | Default | Effect |
|------|-------|---------|--------|
| `--branch <name>` | `-b` | `main` | Auto-created if missing |
| `--n8n-api-key <key>` | — | auto-detect | Override probe result |
| `--n8n-api-url <url>` | — | auto-detect | Override probe result |
| `--force` | — | off | Force-push when remote conflicts are detected |
| `--backup-type <t>` | — | `all` | `all` / `workflows` / `credentials` / `enterprise` / `full-db` |
| `--backup-layout <m>` | — | `canonical` | `canonical` / `combined` / `workflow-bundles` |
| `--credential-export-mode <m>` | — | `stubs` | `stubs` / `encrypted` / `decrypted` |
| `--separate-files` | — | off | Legacy; canonical is already split |
| `--incremental` | — | off | Only items changed since last backup. **Canonical-only.** |
| `--workflow-id <ids>` | — | — | Comma-separated workflow IDs |
| `--credential-id <ids>` | — | — | Comma-separated credential IDs |
| `--include-linked-creds` | — | off | When backing up a single workflow, also pull its credential dependencies |
| `--only-new` | — | off | Skip items already present in the backup repo |
| `--import-as-new` | — | off | Strip IDs from exported data so future restore creates new entities |
| `--select` | — | off | Interactive picker — TTY required, ignored otherwise |
| `--token-file <path>` | — | — | See [Authentication](#authentication--three-pat-input-methods) |
| `--token-stdin` | — | — | See [Authentication](#authentication--three-pat-input-methods) |

**Backup type semantics:**

- `all` — workflows + credentials + tags + folders + projects + datatables + variables (no full-DB dump)
- `workflows` — workflows + their tag/folder edges only
- `credentials` — credentials per `--credential-export-mode`
- `enterprise` — adds owners, project-membership, audit metadata. Requires `--backup-layout canonical`
- `full-db` — entire SQLite/Postgres database dump. Requires `--backup-layout canonical`

**Credential modes:**

- `stubs` *(default, enterprise-compatible)* — placeholder credentials with redacted secrets. Re-link on restore.
- `encrypted` — n8n's native encrypted payload. Restore requires the same encryption key.
- `decrypted` — full plaintext. Use only with private repos and explicit understanding.

**Layout semantics:**

- `canonical` — repository tree: `workflows/`, `credential_stubs/` or `credentials/`, `projects/`, `datatables/`, `tags.json`, `variable_stubs.json`, `folders.json`, `workflow_owners.json`, `.n8n-manager/{manifest,capabilities,checksums}.json`.
- `combined` — single bundle file `data.n8n.backups`.
- `workflow-bundles` — per-workflow `<workflow-id>.n8n.backup` files with linked dependencies.

**Non-interactive examples:**

```bash
# Stable nightly cron
n8n-manager backup -c n8n --token-file /etc/n8n-manager/pat -r ops/n8n-backups

# Just workflows, combined bundle
n8n-manager backup -c n8n -t ghp_xxx -r user/backups \
  --backup-type workflows --backup-layout combined

# Per-workflow bundles for portability
n8n-manager backup -c n8n -t ghp_xxx -r user/backups \
  --backup-layout workflow-bundles

# Enterprise canonical with full-DB snapshot
n8n-manager backup -c n8n -t ghp_xxx -r ops/backups \
  --backup-type full-db --backup-layout canonical

# Incremental (canonical only)
n8n-manager backup -c n8n -t ghp_xxx -r user/backups --incremental

# Single workflow + linked credentials
n8n-manager backup -c n8n -t ghp_xxx -r user/backups \
  --workflow-id "wf_abc123" --include-linked-creds
```

**Pre-flight checks** (run before any side effect): host deps, GitHub access (token + scopes + repo + branch), container running, docker daemon up.

---

### `restore`

Pull data from a backup repo and import into a running n8n container.

**Required:** same triple as `backup` (`--container`, `--token`/file/stdin, `--repo`).

**Optional:**

| Flag | Short | Default | Effect |
|------|-------|---------|--------|
| `--branch <name>` | `-b` | `main` | Source branch |
| `--n8n-api-key <key>` / `--n8n-api-url <url>` | — | auto-detect | Probe override |
| `--force` | — | off | Required for destructive ops on canonical layout |
| `--delete-missing` | — | off | Delete entities absent from the backup. **Requires `--force`.** |
| `--restore-type <t>` | — | `all` | `all` / `workflows` / `credentials` / `enterprise` / `full-db` |
| `--restore-mode <m>` | — | `overwrite` | `overwrite` / `new-only` / `merge` |
| `--separate-files` | — | off | Force per-file mode for legacy v4 inputs |
| `--import-as-new` | — | off | Strip IDs from inputs before import (creates new entities) |
| `--only-new` | — | off | Skip entities that already exist in the target n8n |
| `--workflow-id <ids>` | — | — | Restore specific workflow IDs only |
| `--credential-id <ids>` | — | — | Restore specific credential IDs only |
| `--user-id <id>` | — | — | Assign imported items to user |
| `--project-id <id>` | — | — | Assign imported items to project |
| `--select` | — | off | Interactive picker (TTY required) |
| `--legacy-fallback` | — | off | Skip the v4-shape adapter; use the raw pre-v5 import path. **Reduced validation — emergency restore.** |
| `--accept-legacy-partial` | — | off | Allow restore from a mixed v4/v5 source by treating v4 markers as authoritative |
| `--allow-schema-drift` | — | off | Allow DB-fallback writes when the n8n migrations-table hash doesn't match the pinned-tested set. **Risk of data corruption.** |
| `--unsafe-decrypted-credentials` | — | off | Allow plaintext credential export during pre-restore snapshot. Files written with `umask 077` and shredded on cleanup. |
| `--token-file <path>` / `--token-stdin` | — | — | See [Authentication](#authentication--three-pat-input-methods) |

**Restore mode semantics:**

- `overwrite` — replace target entity if it exists, by ID match.
- `new-only` — never modify existing entities; only create missing ones.
- `merge` — overwrite mutable fields, preserve target-side ID and ownership.

**Safety:**

- Pre-restore snapshot taken automatically before any write.
- Failure rolls back to the snapshot. No partial state.
- `--dry-run` works on every code path.

**Non-interactive examples:**

```bash
# Standard full restore
n8n-manager restore -c n8n -t ghp_xxx -r user/backups

# Workflows only, never overwrite existing
n8n-manager restore -c n8n -t ghp_xxx -r user/backups \
  --restore-type workflows --restore-mode new-only

# Force destructive cleanup of dropped entities
n8n-manager restore -c n8n -t ghp_xxx -r user/backups \
  --force --delete-missing

# Migration: import a v4 backup with the legacy fallback
n8n-manager restore -c n8n -t ghp_xxx -r user/old-v4-backups --legacy-fallback

# Re-create everything as new entities
n8n-manager restore -c n8n -t ghp_xxx -r user/backups --import-as-new

# Schema-drift acknowledgement (postgres upgrade scenario)
n8n-manager restore -c n8n -t ghp_xxx -r user/backups --allow-schema-drift
```

---

### `import-url`

Import a single backup payload from a direct URL (`.json`, `.zip`, `.n8n.backup`, `data.n8n.backups`). Aliased as `import`.

**Required:** `--url <url>`, `--container <name>`.

**Optional:** `--n8n-api-key`, `--n8n-api-url`, `--force`, `--delete-missing`, `--restore-type`, `--restore-mode`, `--separate-files`, `--import-as-new`, `--only-new`, `--user-id`, `--project-id`, `--legacy-fallback`, `--accept-legacy-partial`, `--allow-schema-drift`, `--unsafe-decrypted-credentials`, `--token-file`, `--token-stdin` (see [`restore`](#restore) for semantics — they share `perform_import()`).

```bash
n8n-manager import-url --url https://example.com/backup.json --container n8n
n8n-manager import     --url https://example.com/backup.zip  -c n8n --restore-type workflows
```

The `import` alias is identical to `import-url` — provided for ergonomics.

---

### `install`

Install n8n-manager onto the system PATH from the running script's location. (Distinct from the `install.sh` shipped with releases — `install` is post-binary-on-disk.)

| Flag | Short | Default | Effect |
|------|-------|---------|--------|
| `--path <dir>` | `-p` | `/usr/local/bin` | Custom install dir |
| `--user` | — | off | Install to `~/.local/bin` (no sudo) |
| `--yes` | — | off | Required when stdin is non-TTY |

```bash
n8n-manager install                      # /usr/local/bin (sudo)
n8n-manager install --user               # ~/.local/bin
n8n-manager install --path /opt/bin
n8n-manager install --yes                # CI / Dockerfile RUN
```

---

### `update`

Self-update the running binary in-place. Atomic swap with rollback.

| Flag | Short | Default | Effect |
|------|-------|---------|--------|
| `--check` | — | off | Don't install — just check for newer version |
| `--force` | — | off | Reinstall even if already on latest |
| `--channel <c>` | `-c` | `stable` | `stable` (releases) / `dev` (main branch) |
| `--rollback` | — | off | Restore the prior v4 binary from `.v4.bak` |
| `--yes` | — | off | Required when stdin is non-TTY for update or rollback |

Update procedure (atomic):

1. Detect current binary version
2. Download new binary to a temp location
3. Verify `bash -n` + `--version` smoke + SHA-256 (when pinned)
4. If a `.v4.bak` already exists, timestamp it (`.v4.bak.YYYYMMDD-HHMMSS`)
5. Move existing binary to `.v4.bak`
6. Move new binary into place atomically
7. On any failure between steps 4–6, restore from `.v4.bak`

```bash
n8n-manager update                # stable, latest
n8n-manager update --check        # report only
n8n-manager update --channel dev  # main-branch HEAD
n8n-manager update --rollback     # revert to .v4.bak
n8n-manager update --yes          # CI
```

---

### `uninstall`

Remove the binary and the auto-installed `gum`/`vhs`. The user config at `~/.config/n8n-manager/` is preserved.

| Flag | Short | Default | Effect |
|------|-------|---------|--------|
| `--path <dir>` | `-p` | autodetect | Override the install dir to remove |

```bash
n8n-manager uninstall
```

---

### `workflow graph`

Generate a dependency visualization of `.n8n` files (workflows pointing at sub-workflows / Execute Workflow nodes).

| Flag | Short | Default | Effect |
|------|-------|---------|--------|
| `--workflows-dir <path>` | `-d` | — | Directory holding `.n8n` files |
| `--format <f>` | `-f` | `excalidraw` | `excalidraw` / `mermaid` |
| `--output <path>` | `-o` | auto-generated | File path |
| `--filter <name>` | — | — | Restrict graph to a workflow + its dependencies |
| `--no-upload` | — | off | Skip Excalidraw upload; save locally only |
| `--open` | — | off | Open the shareable link in a browser |

```bash
n8n-manager workflow graph -d ./workflows
n8n-manager workflow graph -d ./workflows --format mermaid -o deps.md
n8n-manager workflow graph -d ./workflows --filter "Sales Pipeline"
n8n-manager workflow graph -d ./workflows --no-upload -o deps.excalidraw
```

---

### `workflow report`

Emit a dependency analysis report.

| Flag | Short | Default | Effect |
|------|-------|---------|--------|
| `--workflows-dir <path>` | `-d` | — | Directory holding `.n8n` files |
| `--format <f>` | `-f` | `console` | `console` / `md` / `html` |
| `--output <path>` | `-o` | required for `md`/`html` | File path |
| `--impact <name>` | — | — | Show impact analysis for a specific workflow |
| `--orphans` | — | off | Show only orphan workflows |
| `--cycles` | — | off | Show only circular dependency chains |
| `--missing` | — | off | Show only missing dependency references |
| `--summary` | — | off | Show summary statistics only |

```bash
n8n-manager workflow report -d ./workflows
n8n-manager workflow report -d ./workflows -f md -o report.md
n8n-manager workflow report -d ./workflows --impact "Sales Pipeline"
n8n-manager workflow report -d ./workflows --orphans
n8n-manager workflow report -d ./workflows --cycles --missing
```

---

### `workflow clean-pins`

Strip pinned (cached) execution data from `.n8n` files to shrink their size and remove sample-data leaks.

| Flag | Short | Default | Effect |
|------|-------|---------|--------|
| `--file <path>` | — | — | Single file mode |
| `--all` | — | off | Operate on every `.n8n` in `--workflows-dir` |
| `--workflows-dir <path>` | `-d` | — | Used with `--all` and `--select` |
| `--select` | — | off | Interactive picker (TTY) |
| `--check-only` | — | off | Report which files have pinned data; do not modify |

```bash
n8n-manager workflow clean-pins --file ./my.n8n
n8n-manager workflow clean-pins --all -d ./workflows
n8n-manager workflow clean-pins --all -d ./workflows --check-only
n8n-manager workflow clean-pins --all -d ./workflows --dry-run
```

---

### `workflow validate`

Structural validation for `.n8n` files (schema, required fields, node-version sanity).

| Flag | Short | Default | Effect |
|------|-------|---------|--------|
| `--file <path>` | — | — | Single file mode |
| `--all` | — | off | Validate all `.n8n` in `--workflows-dir` |
| `--workflows-dir <path>` | `-d` | — | Used with `--all` and `--select` |
| `--select` | — | off | Interactive picker (TTY) |
| `--strict` | — | off | Treat warnings as errors |
| `--json` | — | off | Emit results as JSON (machine-readable) |

```bash
n8n-manager workflow validate --file ./my.n8n
n8n-manager workflow validate --all -d ./workflows
n8n-manager workflow validate --all -d ./workflows --strict --json
```

---

### `workflow settings`

Read or update settings inside a `.n8n` file (e.g. `mcpEnabled`, `executionOrder`).

| Flag | Short | Default | Effect |
|------|-------|---------|--------|
| `--file <path>` | — | — | Single file mode |
| `--all` | — | off | All `.n8n` in `--workflows-dir` |
| `--workflows-dir <path>` | `-d` | — | Used with `--all` and `--select` |
| `--select` | — | off | Interactive picker (TTY) |
| `--setting <key=value>` | `-s` | — | Set a setting; omit to read |

```bash
n8n-manager workflow settings --file ./my.n8n                              # read
n8n-manager workflow settings --file ./my.n8n -s mcpEnabled=true           # write one key
n8n-manager workflow settings --all -d ./workflows -s executionOrder=v1
```

---

### `workflow publish`

Activate workflows: set `active=true` in the `.n8n` JSON, optionally also activate live in a running container via the n8n API.

| Flag | Short | Default | Effect |
|------|-------|---------|--------|
| `--file <path>` | — | — | Single file |
| `--all` | — | off | All `.n8n` in `--workflows-dir` |
| `--workflows-dir <path>` | `-d` | — | Used with `--all` / `--select` |
| `--select` | — | off | Interactive picker (TTY) |
| `--container <name>` | `-c` | — | Required by `--live` |
| `--live` | — | off | Also activate via the n8n API in the running container |

```bash
n8n-manager workflow publish --file ./my.n8n
n8n-manager workflow publish --all -d ./workflows
n8n-manager workflow publish --file ./my.n8n --live -c n8n
```

---

### `workflow unpublish`

Mirror of `publish` — sets `active=false`.

```bash
n8n-manager workflow unpublish --file ./my.n8n
n8n-manager workflow unpublish --all -d ./workflows
n8n-manager workflow unpublish --file ./my.n8n --live -c n8n
```

---

### `workflow compare`

Diff two local `.n8n` files (structural diff aware of node ordering and connection edges).

| Flag | Short | Default | Effect |
|------|-------|---------|--------|
| `--file-a <path>` | `-a` | — | Base file |
| `--file-b <path>` | `-b` | — | Target file |
| `--select` | — | off | Interactive picker (TTY); pair with `--workflows-dir` |
| `--workflows-dir <path>` | `-d` | — | Source dir for the picker |

```bash
n8n-manager workflow compare --file-a ./v1.n8n --file-b ./v2.n8n
n8n-manager workflow compare --select -d ./workflows
```

---

### `migrate`

Convert a v4-shape backup repo to v5 canonical layout.

**Required:** `--source <path>` (must be a git repo).

| Flag | Default | Effect |
|------|---------|--------|
| `--source <path>` | — | **Required.** v4 repo to migrate |
| `--target <dir>` | sibling-branch | Write canonical layout to a **new** dir / repo (mutually exclusive with the default sibling-branch behavior) |
| `--branch <name>` | `migrated-canonical-YYYY-MM-DD-HHMMSS` | Override the auto-generated sibling branch name |
| `--report-only` | off | Print audit summary, write nothing |
| `--format <fmt>` | `text` | Audit output: `text` / `markdown` |
| `--allow-dirty` | off | Skip git-tree-clean pre-flight |
| `--resume` | off | Continue an interrupted run from its staging dir |
| `--restart` | off | Discard staging dir and start fresh (mutually exclusive with `--resume`) |
| `--dry-run` | off | Implies `--report-only` |

```bash
# Standard sibling-branch migrate
n8n-manager migrate --source /srv/n8n-backups

# Output to a separate directory (clean v5 repo)
n8n-manager migrate --source /srv/n8n-backups --target /srv/n8n-backups-v5

# Audit only — no writes
n8n-manager migrate --source /srv/n8n-backups --report-only --format markdown

# Resume after interruption
n8n-manager migrate --source /srv/n8n-backups --resume
```

The migrated branch contains the canonical tree (`workflows/`, `credential_stubs/`, …, `.n8n-manager/`) plus a `MIGRATION-AUDIT.md` summary at root. The original v4 branch is untouched.

---

### `migrate-config`

Translate a v4 `~/.config/n8n-manager/config` file to the v5 schema in place. Atomic and idempotent.

| Flag | Default | Effect |
|------|---------|--------|
| `--dry-run` | off | Print proposed rewrite to stdout; touch nothing |
| `--restore-from-bak` | off | Atomically swap `.v4.bak` back into the original config path. Refuses when `.v4.bak` is absent. |
| `--config <path>` | XDG default | Operate on a non-default path |

```bash
n8n-manager migrate-config                                  # in-place v4→v5
n8n-manager migrate-config --dry-run                        # preview
n8n-manager migrate-config --config /etc/n8n-manager.cfg
n8n-manager migrate-config --restore-from-bak               # roll back
```

---

## Compatibility constraints

These are validated before any write — failing combinations exit non-zero with a clear message.

| Combination | Constraint |
|-------------|-----------|
| `--backup-type enterprise` | Requires `--backup-layout canonical` |
| `--backup-type full-db` | Requires `--backup-layout canonical` |
| `--incremental` | Requires `--backup-layout canonical` |
| `--delete-missing` (restore) | Requires `--force` |
| `--restart` (migrate) | Mutually exclusive with `--resume` |
| `--target` (migrate) | Mutually exclusive with the default sibling-branch flow |
| `--unsafe-decrypted-credentials` (restore) | Implies the credentials are written under `umask 077` and shredded on cleanup |
| `--allow-schema-drift` (restore) | Risk of data corruption — requires explicit opt-in |

---

## Common non-interactive recipes

### Cron-driven nightly backup

```cron
0 2 * * *  /usr/local/bin/n8n-manager backup -c n8n --token-file /etc/n8n-manager/pat -r ops/backups --log-file /var/log/n8n-manager.log
```

`pat` file is `chmod 600`, owned by the user running cron.

### GitHub Actions backup of an n8n container

```yaml
- name: Backup n8n
  run: |
    echo "$N8N_PAT" | n8n-manager backup --token-stdin \
      -c n8n -r ${{ github.repository_owner }}/n8n-backups \
      --backup-layout canonical --backup-type all \
      --log-file backup.log
  env:
    N8N_PAT: ${{ secrets.N8N_BACKUP_PAT }}
```

### Idempotent "restore on first run" in a Docker entrypoint

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
if ! n8n-manager restore -c n8n --token-stdin -r ops/backups --restore-mode new-only --dry-run >/dev/null 2>&1; then
  echo "Restore pre-flight failed — aborting"; exit 1
fi
echo "$N8N_PAT" | n8n-manager restore --token-stdin -c n8n -r ops/backups --restore-mode new-only
```

### Migration in CI before promotion

```bash
n8n-manager migrate --source ./old-backups --report-only --format markdown > migration-audit.md
n8n-manager migrate --source ./old-backups --target ./new-backups
```

### Workflow validation gate in pre-commit

```bash
n8n-manager workflow validate --all -d ./workflows --strict --json > validate.json || exit 1
```

### Bulk activation after a config change

```bash
n8n-manager workflow settings --all -d ./workflows -s executionOrder=v1
n8n-manager workflow publish  --all -d ./workflows --live -c n8n
```

---

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Generic failure — pre-flight failed, dependency missing, command rejected by validation, runtime error |
| `2` | Misuse — invalid flag combination, missing required argument |

Specific failure surfaces:

- Empty `--token-file` / empty `--token-stdin` → exit `1`
- Non-TTY without `--yes` on `install` (when needed) or `update --rollback` → exit `1`
- Container not running → exit `1` after pre-flight (data commands)
- GitHub repo unreachable / wrong scope → exit `1`
- Schema-drift rejection without `--allow-schema-drift` → exit `1`
- `--delete-missing` without `--force` → exit `2`
- `--resume` and `--restart` together → exit `2`

Every failure path that can roll back **does** roll back before exiting; a non-zero exit means the system is in the same state it was before the command started, except for log output and any explicitly listed mutations.

---

## See also

- [README.md](README.md) — onboarding, install matrix, branches
- [MIGRATION.md](MIGRATION.md) — v4 → v5 user guide
- [CHANGELOG.md](CHANGELOG.md) — release notes per version
