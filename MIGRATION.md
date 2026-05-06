<!--
  MIGRATION.md — v4 to v5 user-facing migration guide.
  Ships via release-manifest.txt to the public mirror.
-->

# Migrating from v4 to v5

`n8n-manager` v5 is a **complete rewrite** — modular Bash + Gum, single compiled artifact, canonical backup layout, three-tier read/write fallback. v4 was a single-file monolith; v5 is structurally different but **forward-compatible on the read path**.

This guide walks you through the upgrade with zero surprises.

> **TL;DR:** run `n8n-manager update` on every host. Your config keeps working, your existing backup repos keep working, the v4 binary is preserved as a `.bak` next to the new one. Convert backup-repo layouts to canonical v5 lazily with `n8n-manager migrate` whenever you're ready.

---

## What changed

| Area | v4 | v5 |
|---|---|---|
| Implementation | Single 4 000-line `n8n-manager.sh` | Modular `src/` + Gum UI, compiled to one binary |
| Backup layout | Flat (`workflows.json`, `credentials.json`) | Canonical (`workflows/`, `credential_stubs/`, `.n8n-manager/` sidecars) |
| Restore | CLI-only | CLI → REST API → direct DB engine, picked per-entity by runtime probe |
| Postgres support | Best-effort | First-class — Postgres backend recognized on probe, native fallback engine |
| Credentials | Plaintext or encrypted | `stub` (default, enterprise-compatible), `encrypted`, `decrypted` modes |
| Pre-restore safety | Manual | Automatic snapshot + rollback on failure |
| Dry-run | Some commands | Every destructive command |
| Token logging | Best-effort | Hard-redacted, even under `--verbose`/`--trace` |
| Distribution | Raw `.sh` from main | Single compiled binary; `.sh` legacy mirror kept on the `legacy` branch |

---

## Step 1 — Upgrade the binary

On every host where you run v4:

```bash
curl -fsSL https://i.nskha.com/install.sh | sudo bash
```

The installer:

1. Detects v4 by running `--version` on whatever's at `/usr/local/bin/n8n-manager` (regex: `^[Vv]?4\.`).
2. **Preserves** the v4 binary as `/usr/local/bin/n8n-manager.v4.bak` — rollback is `sudo mv n8n-manager.v4.bak n8n-manager`.
3. Drops the v5 binary in place, with a SHA-256 cross-check against a pinned table embedded in `install.sh`.
4. Verifies `--version` on the new binary reports `5.x` before swapping atomically.

If anything fails the swap is rolled back; you stay on v4.

### Verify

```bash
n8n-manager --version            # should print 5.x.y
ls -la /usr/local/bin/n8n-manager*
```

---

## Step 2 — Verify your config is still picked up

v5 reads the same `~/.config/n8n-manager/config` as v4 with the same `CONF_*` keys. Any v5-only keys you don't set just take their defaults.

```bash
n8n-manager backup --dry-run -c <your-container>
```

If this lists what v5 would back up without touching anything, your config is good.

### Removed / renamed config keys

None. Every v4 `CONF_*` key still works.

### New v5-only config keys

| Key | Default | What it does |
|---|---|---|
| `CONF_BACKUP_LAYOUT` | `canonical` | `canonical` / `bundle` / `combined` / `workflow-bundles` |
| `CONF_CREDENTIAL_EXPORT_MODE` | `stub` | `stub` / `encrypted` / `decrypted` |
| `CONF_RECORD` | `false` | Capture session recordings |
| `CONF_RECORD_OUTPUT` | (unset) | Override recording artifact dir |

---

## Step 3 — Decide what to do about backup repos

You have two options:

### Option A — leave v4 backup repos as-is (read-compatible)

v5 **reads** v4 backup-repo shapes natively. Restore from a v4 backup with no changes:

```bash
n8n-manager restore -c n8n -t <pat> -r owner/old-v4-backups --dry-run
n8n-manager restore -c n8n -t <pat> -r owner/old-v4-backups
```

The probe + dispatcher figure out the layout (`bundle`, `full-db`, `legacy` flat) and route to the matching importer.

You can keep using these repos indefinitely. New backups you take **with v5** will write canonical layout into the same repo, gradually migrating it over time. Eventually a `migrate` pass cleans up the residual v4 files.

### Option B — convert backup repos to canonical now

Run the bundled migrate command:

```bash
n8n-manager migrate -r owner/old-v4-backups
```

This:

1. Clones the repo to a temp dir.
2. Reshapes flat files into the canonical tree (`workflows/`, `credential_stubs/`, etc.).
3. Builds the `.n8n-manager/{manifest,capabilities,checksums}.json` sidecars.
4. Commits with a clear migrate message and pushes.

Pre-flight: dry-run first.

```bash
n8n-manager migrate -r owner/old-v4-backups --dry-run
```

---

## Step 4 — Switch your CI / cron jobs to v5 flags

Every v4 flag still works. Most v5 capabilities are **additive** — you can adopt them incrementally.

| Want | v4 (still works) | v5 (recommended) |
|---|---|---|
| Bundle backup | n/a | `--backup-layout combined` (single file) |
| Bundle per-workflow | n/a | `--backup-layout workflow-bundles` |
| Enterprise data | n/a | `--backup-type enterprise` (canonical-only) |
| Full DB dump | n/a | `--backup-type full-db` (canonical-only) |
| Incremental | n/a | `--incremental` (canonical-only) |
| Postgres explicit | n/a | auto-detected via probe; no flag needed |

---

## Compatibility constraints (v5)

The CLI validates these before any write:

- `--backup-type enterprise` requires `--backup-layout canonical`.
- `--backup-type full-db` requires `--backup-layout canonical`.
- `--incremental` is canonical-only.

`--backup-layout combined` and `--backup-layout workflow-bundles` are **write-only** — every layout is read-compatible on restore.

---

## Rolling back to v4

If anything goes sideways, both binaries are on disk. To revert:

```bash
sudo mv /usr/local/bin/n8n-manager{,.v5.bak}
sudo mv /usr/local/bin/n8n-manager.v4.bak /usr/local/bin/n8n-manager
n8n-manager --version    # confirms 4.x
```

You can also pin to a specific binary by branch:

```bash
# v4 monolith from the legacy branch (frozen):
curl -fsSL 'https://i.nskha.com/n8n-manager?legacy' -o /usr/local/bin/n8n-manager
chmod +x /usr/local/bin/n8n-manager

# Latest v5 stable:
curl -fsSL 'https://i.nskha.com/n8n-manager' -o /usr/local/bin/n8n-manager
chmod +x /usr/local/bin/n8n-manager
```

---

## Source on each branch

| Branch | What's there | Cadence |
|---|---|---|
| `main` | v5 stable: source + compiled `n8n-manager` + `install.sh` | Tagged releases |
| `alpha` | v5 pre-release validation builds | Rolling, no tags |
| `legacy` | v4 monolith (`n8n-manager.sh`) frozen at the pre-v5-cutover snapshot | Frozen — no further commits |

The `pre-v5-cutover-archive` tag on the public mirror points at the last v4 commit, so you can always `git checkout pre-v5-cutover-archive` to reproduce the exact v4 source tree byte-for-byte.

---

## Reporting issues

Found something v4 did that v5 doesn't, or a backup repo v5 won't read? Open an issue on [the public mirror](https://github.com/Automations-Project/n8n-data-manager/issues). Attach:

1. `n8n-manager --version`
2. The command line that failed
3. Anonymized output (rerun with `--verbose`; tokens are auto-redacted)
4. Whether it's a fresh v5 install or post-`update` from v4
