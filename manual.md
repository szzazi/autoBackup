# autoBackup – Manual

This document describes how `autoBackup` works, what run modes it has, how they differ, and which parameters (command-line options and `config.conf` settings) control it.

---

## Contents

1. [Overview](#overview)
2. [Requirements](#requirements)
3. [Files and directories](#files-and-directories)
4. [The two modes](#the-two-modes)
   - [ZIP backup mode (default)](#1-zip-backup-mode-default)
   - [Sync-only mode (folder sync)](#2-sync-only-mode-folder-sync)
   - [Differences at a glance](#differences-at-a-glance)
   - [Which mode should I use?](#which-mode-should-i-use)
5. [Additional run options](#additional-run-options)
   - [Dry run (simulation)](#dry-run-simulation)
   - [Samba connection test](#samba-connection-test)
6. [Command-line parameters](#command-line-parameters)
7. [Configuration parameters (`config.conf`)](#configuration-parameters-configconf)
8. [Source list and exclude list](#source-list-and-exclude-list)
9. [Installation and configuration (`configure.sh`)](#installation-and-configuration-configuresh)
10. [Safety mechanisms](#safety-mechanisms)
11. [Exit codes](#exit-codes)
12. [Examples](#examples)
13. [Troubleshooting](#troubleshooting)

---

## Overview

`autoBackup` is a Bash backup script that saves local folders (and optionally MySQL databases) to a Samba/CIFS network share. On every run the script:

1. mounts the network share into the `remote/` folder next to the script,
2. performs the backup in the selected mode,
3. unmounts the share and cleans up after itself.

It has two main modes:

| Mode | What it does, in short |
|---|---|
| **ZIP backup** (default) | Creates a timestamped `.zip` archive from the source folders and copies it to the share. |
| **Sync-only** | Mirrors the source folders to the share without compression (`rsync --delete`). |

---

## Requirements

- Linux (Debian/Ubuntu/Raspberry Pi OS – the installer uses `apt-get`)
- `bash`, `rsync`, `zip`, `cifs-utils` (`mount -t cifs`), `flock`, `realpath`, `mountpoint`
- **root privileges** (needed for `mount`/`umount`)
- For MySQL backups: the `mysql` and `mysqldump` clients

---

## Files and directories

```
autoBackup/
├── startBackup.sh            # Main backup script
├── configure.sh              # Interactive installer / configurator
├── config.conf.example       # Configuration template
├── config.conf               # Actual configuration (created by configure.sh, permissions: 600)
├── sourceList.txt(.example)  # List of paths to back up
├── excludeList.txt(.example) # Exclude patterns (rsync)
├── remote/                   # Temporary mount point – exists only while the script runs
├── temp/                     # Temporary staging folder (ZIP mode only) – removed after the run
└── .autoBackup.lock          # Lock file, prevents concurrent runs
```

> The `remote/`, `temp/` and `.autoBackup.lock` paths are always relative to the directory of `startBackup.sh` and cannot be configured.

---

## The two modes

### 1. ZIP backup mode (default)

This is the classic "snapshot" backup. Every run creates a **new, self-contained ZIP file** on the share.

**Steps:**

1. Changes into `PROGRAM_DIR`.
2. Copies every path listed in the `SOURCE_DIRS_LIST` file into the `temp/` folder using
   `rsync -avr --relative`, so the full path is preserved (e.g. `/etc/nginx` → `temp/etc/nginx`).
   - Patterns from `EXCLUDE_LIST` are skipped.
   - The `remote/` and `temp/` folders are always excluded, so the share's content never ends up in the backup.
3. If `MYSQL_BACKUP_ENABLED="true"`, dumps the databases into `temp/mysql_dump/`:
   - one `schema.sql` per database (structure, routines, events, no data),
   - one `<table>.data.sql` per table (data only).
4. Packs the contents of `temp/` into a ZIP file named:
   `YYYYMMDD_HHMMSS-<hostname>.zip` (e.g. `20261007_010600-raspberrypi.zip`; dots in the hostname are replaced with `_`).
5. Mounts the share and copies the ZIP file to the share root with `rsync`.
6. Unmounts the share, deletes the local ZIP and the `temp/` folder.

**Result on the share:**

```
//server/backupTarget/
├── 20261001_010600-raspberrypi.zip
├── 20261004_010600-raspberrypi.zip
└── 20261007_010600-raspberrypi.zip
```

**Characteristics:**

- Versioned: every run is kept, older states can be restored.
- The script **does not delete** old ZIP files – cleaning up old backups on the share has to be handled separately.
- Needs temporary local disk space for the copy and the ZIP (roughly twice the size of the backed-up data).
- Supports MySQL backups.
- Paths containing spaces in the source list are **not** supported in this mode (the list is split on whitespace); glob patterns (`/usr/local/bin/*`) do work.

### 2. Sync-only mode (folder sync)

This is a **mirror**: the share always holds the current state of the sources, uncompressed, in a browsable folder structure.

**How to enable it:**

- from the command line: `--sync-only` (optionally followed by a path), or
- by default: `SYNC_ONLY_DEFAULT="true"` in `config.conf`.

**Which paths are synced?**

- `--sync-only /some/path` → only that single path.
- `--sync-only` without a path (or with `SYNC_ONLY_DEFAULT="true"`) → every line of the `SOURCE_DIRS_LIST` file. Empty lines and lines starting with `#` are skipped; leading/trailing whitespace is trimmed.

**Steps:**

1. Collects the paths (see above).
2. Mounts the share.
3. For each path:
   - expands glob patterns (e.g. `/usr/local/bin/*`); paths containing spaces work too,
   - normalizes it to an absolute path (resolving `.` and `..`),
   - places it **at the same path on the share** as on the machine:
     - folder: `/var/www` → `//server/backupTarget/var/www/`
     - file: `/etc/fstab` → `//server/backupTarget/etc/fstab`
   - runs: `rsync -avh --delete --exclude-from=EXCLUDE_LIST <source> <destination>`.
4. Unmounts the share.

**Result on the share:**

```
//server/backupTarget/
├── etc/
│   └── ...
├── home/
│   └── pi/...
└── var/
    └── www/...
```

**Characteristics:**

- **No versioning**: only the latest state is kept.
- Because of `--delete`, **files deleted from the source are also deleted from the share** (excluded files on the destination are left untouched). An accidental local deletion disappears from the backup on the next run!
- Incremental: only changed files are transferred, so it is fast for large amounts of data.
- No temporary local disk space needed.
- **No MySQL backup** (`MYSQL_BACKUP_ENABLED` has no effect in this mode).
- Error handling: if a path does not exist, cannot be resolved, or `rsync` fails, the script reports it, **continues with the remaining paths**, and exits with code `1` at the end ("completed with errors (sync-only)").
- Safety limits:
  - it refuses to sync a path inside the `remote/` mount point,
  - if a source contains the mount point (e.g. syncing `/` or `/usr/local/bin`), the mount point is excluded automatically, so the share is never copied into itself.

> **Warning – exclude patterns:** in sync-only mode rsync copies the *contents* of each source folder separately. Therefore exclude patterns starting with `/` (anchored patterns) are relative to **the synced folder**, not to the filesystem root. For example, the pattern `/etc/alternatives/*` will not match when syncing `/etc`; you would need `alternatives/*` or `/alternatives/*` instead. Unanchored patterns (`*.log`, `*.key`, `.cache/`) behave the same in both modes.

### Differences at a glance

| Aspect | ZIP backup | Sync-only |
|---|---|---|
| Result on the share | One new `.zip` file per run | Folder structure, a mirror of the sources |
| Versioning / history | Yes, every run is kept | No, only the latest state |
| Deleted files | Remain in older ZIPs | Also deleted from the share (`--delete`) |
| Data transferred | Always the full archive | Only the changes |
| Temporary local disk space | Required (`temp/` + ZIP) | Not required |
| MySQL backup | Supported | Not supported |
| Compression | Yes (zip) | None |
| Single path from the CLI | No | Yes: `--sync-only /path` |
| Spaces in paths (source list) | Not supported | Supported |
| Anchored (`/...`) excludes | Relative to the filesystem root | Relative to the synced folder |
| Missing source | rsync prints an error, backup continues | Error, exit code `1` at the end |
| Cleaning up old backups | Manually / with a separate script | Not needed |

### Which mode should I use?

- **ZIP mode** if you need to restore earlier states (e.g. configuration files, `/etc`), or if you also back up databases.
- **Sync-only** if you want to keep large, rarely changing data (e.g. websites, media, home folders) on the share quickly, space-efficiently and in a browsable form.
- The two can be combined: for example two separate `config.conf` files with two cron entries (`--config`), or one cron entry for the ZIP backup and another with `--sync-only`.

---

## Additional run options

### Dry run (simulation)

```bash
./startBackup.sh --dry-run
./startBackup.sh --sync-only --dry-run
```

- The share is mounted **read-only (`ro`)**, so nothing on it can change.
- **In ZIP mode:**
  - the local copy of the source folders into `temp/` does actually happen (it is removed at the end of the run),
  - an empty ZIP file is created,
  - with MySQL enabled, no dump is made; only the user's privileges are checked (`SELECT`, `SHOW VIEW`, `EVENT`, `LOCK TABLES`),
  - the upload runs as an `rsync -n` simulation.
- **In sync-only mode:** `rsync -n` lists what would be copied / deleted, but makes no changes and creates no destination folders.

### Samba connection test

```bash
./startBackup.sh --test-samba
```

Mounts and immediately unmounts the share, then prints the result. No backup is performed. It takes precedence over the `--sync-only` option and the `SYNC_ONLY_DEFAULT` setting.

---

## Command-line parameters

```
startBackup.sh [--config <path>] [--user <name>] [--pass <password>] [--dry-run]
               [--test-samba] [--sync-only [<path>] | --no-sync-only] [--help]
```

| Option | Description |
|---|---|
| `-c`, `--config <path>` | Use a different configuration file. Default: `config.conf` next to the script. |
| `--user <name>` | Samba username – overrides `SAMBA_USERNAME`. |
| `--pass <password>` | Samba password – overrides `SAMBA_PASSWORD`. (Note: a password given on the command line may be visible to other users in the process list.) |
| `--dry-run` | Simulation, see [Dry run](#dry-run-simulation). Can be combined with both modes. |
| `--test-samba` | Connection test only, see [Samba connection test](#samba-connection-test). |
| `--sync-only [<path>]` | Sync-only mode. Without a path, every line of `SOURCE_DIRS_LIST` is synced. The path is only taken if it does not start with `-`. |
| `--no-sync-only` | Force ZIP mode, even if `SYNC_ONLY_DEFAULT="true"`. |
| `-h`, `--help` | Print help. |

**How the mode is decided:**

1. `--test-samba` → connection test only.
2. `--sync-only` / `--no-sync-only` on the command line → decides (if both are given, the last one wins).
3. Otherwise the value of `SYNC_ONLY_DEFAULT` (`"true"` → sync-only, anything else → ZIP).

---

## Configuration parameters (`config.conf`)

The file is a Bash script that `startBackup.sh` sources. Values should be enclosed in quotes.

### Program settings

| Parameter | Default (template) | Description |
|---|---|---|
| `PROGRAM_DIR` | `/usr/local/bin/autoBackup` | Program directory. In ZIP mode the script changes into it; it should be the directory of `startBackup.sh`. |
| `SOURCE_DIRS_LIST` | `$PROGRAM_DIR/sourceList.txt` | File listing the paths to back up. Used by both modes. |
| `EXCLUDE_LIST` | `$PROGRAM_DIR/excludeList.txt` | File containing rsync exclude patterns. Used by both modes. |
| `SYNC_ONLY_DEFAULT` | `false` | If `"true"`, the script runs in sync-only mode when no CLI mode option is given. |

### Samba/CIFS settings

| Parameter | Default (template) | Description |
|---|---|---|
| `SAMBA_SERVER` | `192.168.1.10` | IP address or hostname of the Samba server. |
| `SAMBA_FOLDER` | `/backupTarget` | Share name starting with `/`, without a trailing `/`. The mounted path is `//SAMBA_SERVER` + `SAMBA_FOLDER`. |
| `SAMBA_VERSION` | `1.0` | SMB protocol version (`vers=`), e.g. `1.0`, `2.0`, `3.0`. `3.0` is recommended if the server supports it. |
| `SAMBA_USERNAME` | – | Username (override: `--user`). |
| `SAMBA_PASSWORD` | – | Password (override: `--pass`). |

Username and password are required (from the config or the command line); otherwise the script exits with an error.

### MySQL settings (ZIP mode only)

| Parameter | Default | Description |
|---|---|---|
| `MYSQL_BACKUP_ENABLED` | `false` | If `"true"`, the ZIP backup also contains a MySQL dump. |
| `MYSQL_USERNAME` | – | MySQL user. |
| `MYSQL_PASSWORD` | – | MySQL password. |
| `MYSQL_HOST` | `localhost` | MySQL server. |
| `MYSQL_PORT` | `3306` | MySQL port. |
| `MYSQL_EXCLUDE_DBS` | `mysql phpmyadmin` | Space-separated list of databases to skip. |

Required MySQL privileges: `SELECT`, `SHOW VIEW`, `EVENT`, `LOCK TABLES`.

---

## Source list and exclude list

### `sourceList.txt`

One absolute path per line (folder or file, glob patterns allowed):

```
/var/www
/etc
/home/pi
/usr/local/bin/*
```

- In sync-only mode empty lines and lines starting with `#` are skipped; in ZIP mode avoid comments and paths containing spaces.

### `excludeList.txt`

`rsync --exclude-from` format. One pattern per line; a `-` prefix followed by a space means exclude (optional):

```
- *.log
- *.pem
- *.key
- */.*
- etc/letsencrypt/*
- /etc/alternatives/*
```

- `*` – anything except `/`; `**` – anything, including `/`.
- A pattern ending in `/` matches directories only (e.g. `.cache/`).
- A pattern starting with `/` is anchored – in ZIP mode to the filesystem root, in sync-only mode to the synced folder (see the [warning](#2-sync-only-mode-folder-sync)).

---

## Installation and configuration (`configure.sh`)

```bash
git clone git@github.com:szzazi/autoBackup.git /usr/local/bin/autoBackup
cd /usr/local/bin/autoBackup
chmod +x configure.sh startBackup.sh
sudo ./configure.sh
```

The installer:

1. Asks for the config file path (default: `./config.conf`); if it exists, its current values are offered as defaults.
2. Checks for and, if needed, installs the `rsync`, `zip`, `cifs-utils` packages.
3. Prompts for the settings: program directory, list files, Samba details, MySQL (optional), `SYNC_ONLY_DEFAULT`. Pressing Enter at a password prompt keeps the existing one.
4. Writes `config.conf` from the `config.conf.example` template (comments are preserved), with `600` permissions.
5. Tests the Samba connection.
6. If they do not exist yet, creates `sourceList.txt` and `excludeList.txt` from the examples and opens them for editing.
7. Optionally adds a cron entry (daily / every 3rd day / weekly at 01:06, or a custom expression):

   ```
   06 01 */3 * * "/usr/local/bin/autoBackup/startBackup.sh" --config "/usr/local/bin/autoBackup/config.conf" >>/var/log/autoBackup.log 2>&1
   ```

   The installer does not ask about the mode – if the cron run should be sync-only, set `SYNC_ONLY_DEFAULT="true"`, or add `--sync-only` to the cron line manually (`crontab -e`).

The installer can be re-run at any time to change settings, or `config.conf` can be edited by hand.

---

## Safety mechanisms

- **One instance at a time:** an `flock` lock is held on `.autoBackup.lock`; if a backup is already running, the new instance exits ("Another backup is already running"). The kernel releases the lock, so an interrupted run never leaves a stale lock behind.
- **Cleanup on exit:** on errors, `Ctrl+C` (INT) or `kill` (TERM), the share is still unmounted and local temporary files are removed.
- **Leftovers from previous runs:** if `remote/` is still mounted from an earlier run, the script unmounts it at startup (up to 10 attempts); if `temp/` is not empty, it is cleared.
- **Read-only dry run:** during a simulation the share is mounted `ro`.
- **No self-copying:** the mount point never ends up in the backup.

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Successful run. |
| `1` | Error: missing config / credentials, failed mount or unmount, another instance running, invalid or missing source in sync-only mode. |
| `130` | Interrupted (`Ctrl+C`). |
| `143` | Terminated (`SIGTERM`). |

---

## Examples

```bash
# Normal ZIP backup using the config
sudo ./startBackup.sh

# Simulate a ZIP backup
sudo ./startBackup.sh --dry-run

# With a different config and user
sudo ./startBackup.sh --config /etc/autoBackup/web.conf --user backup --pass secret

# Connection test only
sudo ./startBackup.sh --test-samba

# Sync every path in the source list
sudo ./startBackup.sh --sync-only

# Sync a single folder
sudo ./startBackup.sh --sync-only /var/www

# Simulate a sync (shows what would be deleted)
sudo ./startBackup.sh --sync-only /var/www --dry-run

# ZIP backup even if SYNC_ONLY_DEFAULT="true"
sudo ./startBackup.sh --no-sync-only
```

---

## Troubleshooting

| Symptom | Possible cause / fix |
|---|---|
| `Mount failed` | Wrong server/share name, username or password; unsupported `SAMBA_VERSION` – try `2.0` or `3.0`. Run as root. Check with `--test-samba`. |
| `Config file not found` | `config.conf` is not next to the script – run `configure.sh`, or pass it with `--config`. |
| `Samba username and password must be provided` | `SAMBA_USERNAME` / `SAMBA_PASSWORD` is missing and not given on the command line either. |
| `Another backup is already running` | Another instance is running (e.g. from cron). Wait for it to finish. |
| `Error: source path not found` (sync-only) | A path in the source list does not exist – fix `sourceList.txt`. |
| `refusing to sync a path inside the mount point` | The given path is inside the `remote/` folder – the script blocks this on purpose. |
| An exclude does not work in sync-only mode | Probably a pattern starting with `/`; in sync-only mode it must be relative to the synced folder. |
| The share fills up (ZIP mode) | The script does not delete old ZIPs – clean them up regularly. |

Log of cron runs: `/var/log/autoBackup.log`.
