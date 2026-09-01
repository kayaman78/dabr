# DABR — Docker Automated Backup with Rsync

**Project Status**: Active | **Version**: 1.0 | **Maintained**: Yes

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-Debian%20%2F%20Ubuntu-informational.svg)](https://www.debian.org/)
[![Type](https://img.shields.io/badge/type-bash%20script-lightgrey)](https://www.gnu.org/software/bash/)

Hardlinked snapshots of host paths. Backs up bind mounts, config trees and
application data directories — everything in a Docker setup that is neither a
database nor a named volume, and that the other tools in the ecosystem
therefore never touch.

> Part of the **KDD ecosystem** — see also [KDD](https://github.com/kayaman78/kdd) for MySQL/PostgreSQL/MongoDB, [DABS](https://github.com/kayaman78/dabs) for SQLite, [DABV](https://github.com/kayaman78/dabv) for Docker volumes, and [KCR](https://github.com/kayaman78/kcr) to run it from Komodo.

---

## Why this exists

A typical Docker host keeps its data in three different shapes, and the first
two already have a tool:

| Shape | Tool |
|---|---|
| Databases (MySQL, PostgreSQL, MongoDB) | KDD |
| Databases (SQLite) | DABS |
| Named Docker volumes | DABV |
| **Plain host paths — bind mounts, config, uploads, generated data** | **DABR** |

That fourth row is usually the largest one, and it is the one people discover
is missing on the day they need it. Compose files, `.env` files, an
application's uploads directory, a data tree built up over months: none of it
is a database, none of it is in a volume, and a git repository does not have it
because it is generated or deliberately ignored.

---

## How It Works

1. Reads `BACKUP_PATHS` — each path becomes a directory inside the snapshot
2. Finds the most recent existing snapshot
3. `rsync -aHAXx --link-dest` against it: changed files are copied, unchanged
   files become **hardlinks** and cost no disk space
4. Verifies each path: rsync exit code, non-empty result, size and file-count
   trend versus the previous snapshot
5. On the configured weekday, hardlinks the snapshot into `weekly/`
6. Applies retention to `daily/`, `weekly/` and its own logs
7. Sends an HTML email report, plus optional Telegram and ntfy notifications

The result is a **browsable** backup: every snapshot is a normal directory tree
you can `cd` into and read, not an archive to extract first.

```
DEST_BASE/
├── daily/
│   ├── 20260901-030001/
│   │   ├── docker/          ← from /srv/docker
│   │   └── data/            ← from /opt/myapp/data
│   └── 20260902-030001/     ← costs only what changed
└── weekly/
    └── 20260901-030001/
```

---

## Quick Start

```bash
mkdir -p /srv/docker/dabr
cp backup-paths.sh /srv/docker/dabr/
```

Edit the settings at the top — at minimum `BACKUP_PATHS` and `DEST_BASE` —
then try it without writing anything:

```bash
DRY_RUN=on bash /srv/docker/dabr/backup-paths.sh
```

Then schedule it, either from cron or through [KCR](https://github.com/kayaman78/kcr):

```json
{
  "server_name": "prod",
  "commands": ["bash /srv/docker/dabr/backup-paths.sh"],
  "timeout_seconds": 3600
}
```

---

## Local or remote

`DEST_MODE="local"` writes to a mounted disk. `DEST_MODE="remote"` sends the
snapshots over SSH to another machine. Nothing else in the configuration
changes — hardlinks, verification and retention behave identically, because
every operation on the destination goes through the same two helpers.

```bash
DEST_MODE="remote"
REMOTE_USER="backup"
REMOTE_HOST="192.168.1.10"
SSH_KEY="/root/.ssh/backup_key"      # empty = default ssh resolution
```

---

## ⚠️ Databases are not excluded, and are not reliable here

DABR copies whatever is under `BACKUP_PATHS`, database files included. Copying
a live database with rsync gives you an **inconsistent** file: the engine may
be mid-write, and for SQLite in WAL mode the recent transactions live in a
separate `-wal` file that may be copied at a different instant.

They are included so the snapshot is a complete picture of the filesystem — but
**never restore a database from a DABR snapshot when a proper dump exists**.
That is what KDD and DABS are for, and they run alongside DABR in the same
Komodo Procedure.

If you would rather leave them out entirely, add them to `EXCLUDE_PATTERNS`.

---

## Verification

| Check | What it catches |
|---|---|
| rsync exit code | transfer failures. Codes **23** and **24** (files vanished or changed mid-copy) are reported as WARN, not ERROR — they are normal on a live system |
| Non-empty snapshot | a path that resolved to nothing, or a destination that silently rejected the write |
| Size trend | a source that shrank by more than `SIZE_DROP_WARN`% — a wiped directory, a failed mount |
| File count trend | a drop of more than `FILE_DROP_WARN`% — catches many small files disappearing, which a size check alone can miss |

A WARN keeps the snapshot and continues. An ERROR sets the global status,
marks the email subject, and makes the script exit non-zero so KCR sees it.

---

## Configuration Reference

| Parameter | Description | Default |
|-----------|-------------|---------|
| `DRY_RUN` | `on` = simulate, writing and deleting nothing | `off` |
| `BACKUP_PATHS` | Array of host paths to snapshot | `("/srv/docker")` |
| `DEST_MODE` | `local` or `remote` | `local` |
| `DEST_BASE` | Snapshot root; `daily/` and `weekly/` live here | — |
| `REMOTE_USER` / `REMOTE_HOST` / `REMOTE_SSH_PORT` / `SSH_KEY` | Remote destination (ignored when local) | — |
| `DAILY_RETENTION` | Daily snapshots to keep | `7` |
| `WEEKLY_RETENTION` | Weekly snapshots to keep | `4` |
| `WEEKLY_DAY` | Day a weekly copy is made (1=Mon … 7=Sun) | `1` |
| `SIZE_DROP_WARN` | % size drop that warns | `20` |
| `FILE_DROP_WARN` | % file-count drop that warns | `20` |
| `EXCLUDE_PATTERNS` | rsync exclude patterns | sockets, pids, locks, tmp, caches, logs |
| `LOG_DIR` | Where logs are written and rotated | `/var/log/dabr` |
| `MAIL_ENABLED`, `SMTP_*`, `EMAIL_*` | HTML email report | — |
| `TELEGRAM_*`, `NTFY_*`, `NOTIFY_ATTACH_LOG` | Push notifications, each independent | disabled |

### Two paths with the same basename

Each path is stored inside the snapshot under its **basename**, so
`/opt/a/data` and `/opt/b/data` would both land in `data/` and the second would
overwrite the first. The script refuses to start when that happens, and says
which two paths collide — checked before anything is written, not at 3am.

---

## Retention is calendar-independent

Retention keeps the **N most recent** snapshots, it does not delete by age. If
the job has been paused for a month, the existing snapshots are still there:
they are removed only as newer ones replace them. A tool that deletes by
calendar date turns a paused backup into no backup at all.

Deletion only ever touches directory names matching the snapshot pattern
(`YYYYMMDD-HHMMSS`), and never the snapshot just written.

---

## Notes on robustness

**No `set -e`.** The script counts errors and warnings and reports them, and
`set -e` works badly with that: `((VAR++))` returns exit status 1 when the
variable was 0, which would kill the run at the first warning — before any
notification goes out. Errors are handled where they happen instead.

**Failures are logged, not hidden.** rsync's output goes to the log file
including stderr, and the last 20 lines are HTML-escaped into the email report
so you can see what happened without opening an SSH session.

---

## Requirements

- Debian / Ubuntu host (any Linux with bash 4+ works)
- **Run it as root.** Any directory the running user cannot read is skipped —
  rsync returns 23, DABR reports a WARN, and the run still ends green. That is
  enough to lose a service's data without noticing: Portainer, for one, keeps
  its state in `root:root` directories with mode 700. Unless every path you
  back up is owned by one unprivileged user, run as root.
- `rsync`, and `ssh` only when `DEST_MODE="remote"`
- `swaks` for email, `curl` for push notifications — both optional
- The destination filesystem must support **hardlinks**: ext4, xfs, btrfs are
  fine; exFAT, FAT32 and most SMB shares are not, and every snapshot would cost
  full size

---

## Changelog

### v1.0
- Initial release
- Hardlinked daily and weekly snapshots via `rsync --link-dest`
- Local and remote (SSH) destinations behind one abstraction
- Verification: rsync exit code, non-empty snapshot, size and file-count trend
- Calendar-independent retention for snapshots and logs
- HTML email report, Telegram and ntfy notifications, each independent
- Dry-run mode that writes and deletes nothing, verified
- Basename collision detected before the first write

---

## Related Projects

| Tool | Purpose |
|------|---------|
| [KDD](https://github.com/kayaman78/kdd) | MySQL / MariaDB / PostgreSQL / MongoDB dumps via Komodo Action |
| [DABS](https://github.com/kayaman78/dabs) | SQLite backup, bind mounts and named volumes |
| [DABV](https://github.com/kayaman78/dabv) | Named Docker volume archives |
| [KCR](https://github.com/kayaman78/kcr) | Komodo Action to run shell commands on remote servers |

Recommended: chain all of them in a **Komodo Procedure** for complete coverage
in one scheduled job.

---

## License

MIT
