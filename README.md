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

---

## 📜 License

MIT License. Use at your own risk. Contributions welcome!
