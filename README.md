# BMO tools

Utility scripts for BMO (Bugzilla) instance management.

## bmo_backup_restore.pl

Backup and restore data from a BMO/Bugzilla instance via the REST API,
with automatic web form fallbacks for endpoints where REST auth is broken.
Useful for preserving a dev/test instance across Docker image rebuilds.

### What is backed up

| Section | Content |
|---|---|
| **Groups** | Name, description, user regexp, active status |
| **Products** | Name, description, settings, plus components, versions, and milestones |
| **Users** | Email, full name, group memberships, login/email status, API keys (authenticated user only) |
| **Bugs** | All fields, comments, attachments, flags, custom fields |

### Installation

```bash
cpanm Getopt::Long JSON::MaybeXS LWP::UserAgent HTTP::Request URI::Escape
```

### Usage

#### Full instance backup

```bash
bmo_backup_restore.pl --mode=backup --apikey=KEY --full
```

#### Selective backup

```bash
# Structural data only (no bugs)
bmo_backup_restore.pl --mode=backup --apikey=KEY --groups --products --users

# Structural data + bugs from one product
bmo_backup_restore.pl --mode=backup --apikey=KEY --groups --products --users \
                      --product="TestProduct"

# Specific bugs only
bmo_backup_restore.pl --mode=backup --apikey=KEY --bug=1 --bug=2

# Exclude auto-created accounts from the user backup
bmo_backup_restore.pl --mode=backup --apikey=KEY --full \
                      --skip-user=admin@mozilla.bugs
```

#### Restore

```bash
bmo_backup_restore.pl --mode=restore --apikey=KEY --file=backup.json

# With a custom initial password for restored user accounts
bmo_backup_restore.pl --mode=restore --apikey=KEY --file=backup.json \
                      --restore-password="MyDevPass1"
```

Restore is automatic: all sections present in the backup file are applied in
the correct order (groups → products → users → bugs). Running restore a second
time on the same instance is safe — existing groups, products, and users are
detected via upfront queries and skipped. Bugs are detected via their
`bmo-backup-{id}` alias. Missing components, versions, and milestones are
created even when the parent product already exists.

Inactive products are temporarily enabled during restore so bugs can be filed
into them, then disabled again once all bugs are restored.

```bash
# Exclude a user from restore (e.g. the admin account)
bmo_backup_restore.pl --mode=restore --apikey=KEY --file=backup.json \
                      --skip-user=admin@mozilla.bugs
```

#### Remove duplicate bugs

If bugs were restored more than once before the alias-based deduplication was
introduced, duplicates can be cleaned up with:

```bash
bmo_backup_restore.pl --mode=deduplicate --apikey=KEY --file=backup.json
```

A bug is considered a duplicate when it shares the same summary, product,
component, and description as the canonical copy (the one carrying the
`bmo-backup-{id}` alias). Duplicates are deleted if `allowbugdeletion` is
enabled in the Bugzilla configuration, or marked `RESOLVED DUPLICATE` otherwise.

### Options

| Option | Default | Description |
|---|---|---|
| `--mode` | — | `backup`, `restore`, or `deduplicate` (required) |
| `--url` | `http://localhost:8000` | Bugzilla base URL |
| `--apikey` | — | API key for authentication |
| `--login` / `--password` | — | Alternative to `--apikey` |
| `--file` | `bugs_backup.json` | Backup file path |
| `--full` | — | Backup groups + products + users + all bugs |
| `--groups` | — | Include groups in backup |
| `--products` | — | Include products (components, versions, milestones) |
| `--users` | — | Include users and their API keys |
| `--skip-user` | — | Exclude a user from backup/restore by email (repeatable) |
| `--bug` | — | Specific bug ID (repeatable) |
| `--product` | — | Backup bugs in this product |
| `--limit` | `500` | Max bugs per product query |
| `--restore-password` | `password012!` | Initial password for restored users |
| `--usage` | — | Print a one-line usage summary and exit |
| `--help` | — | Print full help (man page) and exit |
| `--version` | — | Print the script version and exit |

### Versioning

Backup files include a `version` field matching the script version that created
them. On restore and deduplicate, the version is checked:

- **Missing version**: treated as 1.0.0, fully compatible.
- **Higher major version**: restore is aborted (incompatible format).
- **Higher minor version**: a warning is printed but restore proceeds.

### Authentication

Two methods are supported:

- **API key** (recommended): `--apikey=KEY` — sent via `X-BUGZILLA-API-KEY`
  header. Works uniformly across all REST endpoints.
- **Login/password**: `--login=EMAIL --password=PASS` — obtains a REST token
  via `/rest/login` and establishes a web session (via `index.cgi`) for
  endpoints where REST token auth is broken. Some BMO endpoints
  (`POST /rest/component`, `PUT /rest/product`) reject token-based auth;
  the script automatically falls back to web forms (`editcomponents.cgi`,
  `editproducts.cgi`) using the session cookie.

### Error diagnostics

When an API call fails, the error message includes both the full response body
and the request payload, making it easier to identify which field is causing
the issue.

### Known limitations

- **Bug IDs, reporter, and timestamps** cannot be preserved (REST API limitation).
  Each restored bug receives a `bmo-backup-{original_id}` alias so it can be
  identified on subsequent restores without an external mapping file.
- **Alias is set during bug creation**, not via PUT update, as some BMO instances
  reject alias modifications through the update endpoint.
- **Some fields have defaults during restore**: `type` defaults to `defect`,
  `filed_via` to `other`, when not present in the backup data. The read-only
  field `cf_last_resolved` is excluded from creation.
- **API key values** cannot be written back via the REST API. New keys are created
  and their values printed to stdout during restore so you can update your config.
- **Other users' API keys** are not accessible via the REST API; only the
  authenticated user's keys are backed up.
- **User passwords** are not stored. Restored accounts receive `--restore-password`
  as their initial password.
- `POST /rest/component`, `/rest/version`, and `/rest/milestone` require
  Bugzilla 5.0+. Failures on older instances produce warnings but do not abort.
- **Web form fallbacks** (`editcomponents.cgi`, `editproducts.cgi`) are used
  when REST endpoints reject token auth. These require BMO's `team_name` field
  for component creation. The fallbacks rely on session cookies, so
  `--login`/`--password` must be provided (not just `--apikey`).

## bmo_run_tests.pl

Runs BMO's docker-based test suites (sanity, unit, webservices, selenium ×4)
and prints a colored PASS/FAIL summary table with timing.

### Usage

```bash
# Run from a bmo checkout, or set BMO_DIR to point at one
cd /path/to/bmo
bmo_run_tests.pl                 # run all suites
bmo_run_tests.pl sanity bmo      # run only the named suites
bmo_run_tests.pl --build         # docker compose build first, then run all
bmo_run_tests.pl --list          # list suite names and exit
bmo_run_tests.pl --usage         # one-line usage and exit
bmo_run_tests.pl --help          # full help (man page) and exit
bmo_run_tests.pl --version       # print script version and exit
```

### Suites

| Suite | Runs |
|---|---|
| `sanity` | `test_sanity` over `t/*.t extensions/*/t/*.t` |
| `bmo` | `test_bmo -q -f` over `t/bmo/*.t extensions/*/t/bmo/*.t` (with `CI=1`) |
| `webservices` | `test_webservices` |
| `selenium1`..`selenium4` | `test_selenium` with `SELENIUM_GROUP=1..4` |

Each suite runs `docker compose down -v` before it starts, to reset state.
Exit code is non-zero if any suite failed.

