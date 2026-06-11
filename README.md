# bmo_backup_restore.pl

Backup and restore data from a BMO/Bugzilla instance via the REST API.
Useful for preserving a dev/test instance across Docker image rebuilds.

## What is backed up

| Section | Content |
|---|---|
| **Groups** | Name, description, user regexp, active status |
| **Products** | Name, description, settings, plus components, versions, and milestones |
| **Users** | Email, full name, group memberships, login status, API keys (authenticated user only) |
| **Bugs** | All fields, comments, attachments, flags, custom fields |

## Installation

```bash
cpanm Getopt::Long JSON::MaybeXS LWP::UserAgent HTTP::Request URI::Escape
```

## Usage

### Full instance backup

```bash
bmo_backup_restore.pl --mode=backup --apikey=KEY --full
```

### Selective backup

```bash
# Structural data only (no bugs)
bmo_backup_restore.pl --mode=backup --apikey=KEY --groups --products --users

# Structural data + bugs from one product
bmo_backup_restore.pl --mode=backup --apikey=KEY --groups --products --users \
                      --product="TestProduct"

# Specific bugs only
bmo_backup_restore.pl --mode=backup --apikey=KEY --bug=1 --bug=2
```

### Restore

```bash
bmo_backup_restore.pl --mode=restore --apikey=KEY --file=backup.json

# With a custom initial password for restored user accounts
bmo_backup_restore.pl --mode=restore --apikey=KEY --file=backup.json \
                      --restore-password="MyDevPass1"
```

Restore is automatic: all sections present in the backup file are applied in
the correct order (groups → products → users → bugs).

## Options

| Option | Default | Description |
|---|---|---|
| `--mode` | — | `backup` or `restore` (required) |
| `--url` | `http://localhost:8000` | Bugzilla base URL |
| `--apikey` | — | API key for authentication |
| `--login` / `--password` | — | Alternative to `--apikey` |
| `--file` | `bugs_backup.json` | Backup file path |
| `--full` | — | Backup groups + products + users + all bugs |
| `--groups` | — | Include groups in backup |
| `--products` | — | Include products (components, versions, milestones) |
| `--users` | — | Include users and their API keys |
| `--bug` | — | Specific bug ID (repeatable) |
| `--product` | — | Backup bugs in this product |
| `--limit` | `500` | Max bugs per product query |
| `--restore-password` | `BugRestore123!` | Initial password for restored users |

## Known limitations

- **Bug IDs, reporter, and timestamps** cannot be preserved (REST API limitation).
  A `*_id_map.json` file mapping old IDs to new IDs is written alongside the backup.
- **API key values** cannot be written back via the REST API. New keys are created
  and their values printed to stdout during restore so you can update your config.
- **Other users' API keys** are not accessible via the REST API; only the
  authenticated user's keys are backed up.
- **User passwords** are not stored. Restored accounts receive `--restore-password`
  as their initial password.
- `POST /rest/component`, `/rest/version`, and `/rest/milestone` require
  Bugzilla 5.0+. Failures on older instances produce warnings but do not abort.
