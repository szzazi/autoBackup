# autoBackup.sh

A lightweight, configurable Bash script to automatically back up system and user configuration data to a Samba (CIFS) network share.

---

## 🚀 Features

- 📁 Backup specific folders (e.g., `/etc`, `~/.config`)
- 🔒 Exclude sensitive or regenerable files
- 🛠 Configurable via interactive `install.sh`
- 🧪 Dry-run mode to safely simulate backups
- ⏱️ Scheduled execution via `cron`
- ✅ Samba mount and connection verification
- 🔧 Reconfigurable anytime

---

## 📁 Project Structure

```
autoBackup/
├── startBackup.sh         # Main script
├── install.sh            # Interactive installer
├── config.conf.example   # Editable config template
├── config.conf           # Auto-generated config (after install)
├── sourceList.txt        # List of source folders
├── excludeList.txt       # List of patterns/folders to exclude
├── README.md             # This file
```

---

## 🔧 Quick Setup (copy & paste)

To install everything into `/usr/local/bin/autoBackup`, run:

```bash
rm -rf /usr/local/bin/autoBackup
mkdir -p /usr/local/bin/autoBackup
git clone git@github.com:szzazi/autoBackup.git /usr/local/bin/autoBackup
cd /usr/local/bin/autoBackup
chmod +x configure.sh startBackup.sh
./configure.sh
```

> This will clone the full repository and launch the interactive installer.

---

## 📦 Configuration

Clone or copy the `autoBackup` folder somewhere or use the Quick Setup, then run:

```bash
chmod +x configure.sh
./configure.sh
```

The installer will:

1. Check for required packages: `rsync`, `zip`, `cifs-utils`
2. Prompt for settings (backup paths, Samba server, credentials, etc.)
3. Save them to `config.conf` with secure permissions
4. Test your Samba mount connection
5. Create sample `sourceList.txt` and `excludeList.txt`
6. Offer to set up a scheduled `cron` job

---

## ⚙️ Configuration

All settings are stored in `config.conf`. You can edit it manually or re-run:

```bash
./configure.sh
```

### Example config (simplified):

```bash
PROGRAM_DIR="/usr/local/bin/autoBackup"
SOURCE_DIRS_LIST="$PROGRAM_DIR/sourceList.txt"
EXCLUDE_LIST="$PROGRAM_DIR/excludeList.txt"
SAMBA_SERVER="192.168.1.10"
SAMBA_FOLDER="/backupTarget"
SAMBA_VERSION="1.0"
SAMBA_USERNAME="backupuser"
SAMBA_PASSWORD="mypassword"
```

---

## 🧪 Dry Run Mode

You can test the backup process without writing any files:

```bash
./startBackup.sh --dry-run
```

This will:
- Generate an empty zip file
- Simulate `rsync` to remote target
- Mount/unmount network share safely

---

## 🕑 Scheduled Backups with Cron

The installer can add a `cron` job like:

```
06 01 */3 * * /usr/local/bin/autoBackup/startBackup.sh >>/var/log/autoBackup.log 2>&1
```

You can view your current crontab with:

```bash
crontab -l
```

Or remove the line manually if needed.

---

## 🧹 What Gets Backed Up?

By default, these folders are included (`sourceList.txt`):

- `/etc`
- `/home/youruser/.config`
- `/var/spool/cron`

And these are excluded (`excludeList.txt`):

- `.cache/`, `*.tmp`, `*.lock`, `*.bak`
- Trash folders, SSH private keys, X11 cookies, etc.

---

## 🗄️ Optional MySQL Database Backup

- The script can optionally back up MySQL databases and include them in the zip archive.
- The configurator (`configure.sh`) will prompt you to enable/disable MySQL backup and set all required parameters.
- Each table's data is exported to a separate file; schema and meta info are exported to one file per database.
- You can exclude system or unwanted databases (default: `mysql phpmyadmin`).
- All MySQL backup settings are stored in `config.conf` and can be edited manually.

### Example MySQL config section:
```bash
MYSQL_BACKUP_ENABLED="true"          # Enable/disable MySQL backup
MYSQL_USERNAME="backupuser"          # MySQL user
MYSQL_PASSWORD="yourStrongPassword"  # MySQL password
MYSQL_HOST="localhost"               # MySQL host
MYSQL_PORT="3306"                    # MySQL port
MYSQL_EXCLUDE_DBS="mysql phpmyadmin" # Excluded databases
```

**Required MySQL privileges for export:**

- `SELECT` (read table data)
- `SHOW VIEW` (read views)
- `EVENT` (read events)
- `LOCK TABLES` (for consistent dumps)

In dry-run mode, the script will check if the configured MySQL user has these privileges and report any missing rights before attempting a real backup.

If you set `MYSQL_BACKUP_ENABLED="false"`, no database backup will be performed.

---

## ⏰ Optional Wake-on-LAN

If the backup target is not always on, the script can wake it before mounting:

1. Pings `WOL_PING_IP` (defaults to `SAMBA_SERVER`).
2. If there is no answer, sends a WOL magic packet to `WOL_MAC`.
3. Keeps pinging until the host answers or `WOL_WAKEUP_TIMEOUT_SEC` (real seconds) expires.
4. On timeout, reports an error to Sentry and exits.

The packet is sent with `etherwake` (only if `WOL_INTERFACE` is set, needs root), otherwise `wakeonlan`, otherwise a `python3` broadcast.

Since a freshly woken host may answer ping before the Samba share is ready, the mount is retried `MOUNT_RETRIES` times with `MOUNT_RETRY_DELAY_SEC` seconds between attempts. If every attempt fails, an error is reported to Sentry as well.

```bash
WOL_ENABLED="true"
WOL_MAC="AA:BB:CC:DD:EE:FF"
WOL_PING_IP=""              # empty = SAMBA_SERVER
WOL_WAKEUP_TIMEOUT_SEC="120"
WOL_INTERFACE=""            # e.g. enp3s0 to use etherwake
MOUNT_RETRIES="5"
MOUNT_RETRY_DELAY_SEC="10"
```

CLI overrides: `--wol --wol-mac <mac> --wol-ping-ip <ip> --wol-timeout <sec>`.

---

## 🚨 Optional Sentry Error Reporting

Failures are sent to [Sentry](https://sentry.io) as events, grouped by type:

| Event | Level | Script |
| --- | --- | --- |
| Missing credentials / program dir / source list, WOL misconfigured | error | aborts |
| Remote host did not wake up, WOL send failed | error | aborts |
| Mount failed (after retries) | error | aborts |
| Compression failed, upload to the share failed | error | aborts |
| Some source directories could not be copied | error | continues (partial backup) |
| Some MySQL databases/tables could not be dumped | error | continues (partial backup) |
| Unmount failed | warning | continues |
| Interrupted (Ctrl+C / SIGTERM) | warning | aborts |
| Any other non-zero exit | error | — |

When the script aborts, the share is unmounted and the local temporary files are removed.
A missing config file cannot be reported, since the DSN is read from it.

Set the DSN from *Project Settings → Client Keys (DSN)*:

```bash
SENTRY_DSN="https://<public_key>@o000000.ingest.sentry.io/0000000"
SENTRY_ENVIRONMENT="production"
```

If `sentry-cli` is installed it is used, otherwise the event is posted with `curl`. Leave `SENTRY_DSN` empty to disable reporting (errors are still logged).

---

## 🆘 Troubleshooting

- ✅ Make sure `rsync`, `zip`, and `cifs-utils` are installed.
- 🧪 Test the Samba connection with `install.sh`.
- 🔐 Ensure the Samba credentials are correct (config or CLI).
- 🔧 Log output is stored in `/var/log/autoBackup.log`.
- 🛑 Mount failures may be due to unsupported `vers=` on the server.

---

## ✅ Example Commands

Run a real backup:

```bash
./startBackup.sh
```

Run with custom credentials:

```bash
./startBackup.sh --user yourUser --pass yourSecretPass
```

Run in test mode:

```bash
./startBackup.sh --dry-run
```

Run only a Samba/CIFS connection test:

```bash
./startBackup.sh --test-samba
```

This will:
- Mount the configured Samba/CIFS network share
- Immediately unmount it
- Print connection test results
- Exit without performing any backup or file operations

---

## 📜 License

MIT License. Use at your own risk. Contributions welcome!

## TODO
- Add automatic mail sending with the backup result.