#!/bin/bash
#########################################################
# autoBackup installer and configurator
#
# 1. Installs the missing packages (rsync, zip, cifs-utils)
# 2. Asks for every setting; the current value is offered as the default,
#    so re-running it is an easy way to change the configuration
# 3. Writes the config from config.conf.example, keeping its comments and order
# 4. Tests the Samba connection
# 5. Creates sourceList.txt and excludeList.txt from their examples
# 6. Optionally schedules the backup in crontab
#########################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
CONFIG_EXAMPLE="$SCRIPT_DIR/config.conf.example"
CONFIG_FILE="$SCRIPT_DIR/config.conf"   # can be changed at the first prompt

# KEY -> value of every setting, filled from the existing config and the prompts
declare -A config_values


# ======================================================
# Existing config
# ======================================================

# Reads the settings of an existing config into config_values.
# The config is sourced (in a subshell, so nothing leaks into the installer), exactly as
# startBackup.sh does, so every value is what the backup really uses: quotes, escapes,
# comments and references like "$PROGRAM_DIR/sourceList.txt" are all resolved by the shell.
load_existing_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return
    fi

    # The names of the settings: every KEY= at the start of a line
    local keys
    keys=$(grep -oE '^[A-Za-z0-9_]+=' "$CONFIG_FILE" | tr -d '=' | sort -u)

    # The subshell prints KEY\0VALUE\0 pairs; \0 cannot occur in a value, so any value is safe
    local key value
    while IFS= read -r -d '' key && IFS= read -r -d '' value; do
        config_values[$key]="$value"
    done < <(
        source "$CONFIG_FILE" >/dev/null 2>&1
        for key in $keys; do
            if [ -n "${!key+set}" ]; then
                printf '%s\0%s\0' "$key" "${!key}"
            fi
        done
    )
}

# Prints a value in single quotes, so the shell takes it literally when the config is sourced:
# $, ", `, \ and spaces need no escaping there, only a ' itself, which is written as '\''
#   e.g.  pa$$w"rd  ->  'pa$$w"rd'     it's  ->  'it'\''s'
shell_quote() {
    local escaped="${1//\'/\'\\\'\'}"
    printf "'%s'" "$escaped"
}


# ======================================================
# Packages
# ======================================================

# Installs the packages whose command is missing.
# The command and the package name differ for cifs-utils, so both are listed.
check_dependencies() {
    echo "Checking required packages..."

    local -A package_of_command=(
        [rsync]=rsync
        [zip]=zip
        [mount.cifs]=cifs-utils
    )

    local missing=() cmd
    for cmd in "${!package_of_command[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("${package_of_command[$cmd]}")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        echo "Installing missing packages: ${missing[*]}"
        apt-get update
        apt-get install -y "${missing[@]}"
    else
        echo "All required packages are installed."
    fi
}


# ======================================================
# Prompts
# ======================================================

# Asks for one setting, offering the current value (or the fallback) as an editable default.
#   $1: config key   $2: prompt text   $3: fallback if the key has no value yet
ask() {
    local key="$1" prompt="$2" fallback="$3" val
    local default="${config_values[$key]:-$fallback}"
    read -e -i "$default" -p "$prompt: " val
    config_values[$key]="${val:-$default}"
}

# Asks for a secret without echoing it. An empty answer keeps the current value.
#   $1: config key   $2: prompt text
ask_secret() {
    local key="$1" prompt="$2" val
    read -rsp "$prompt (press enter to keep existing): " val
    echo ""
    config_values[$key]="${val:-${config_values[$key]:-}}"
}

prompt_user_input() {
    echo ""
    echo "=== Configuration ==="

    # Program and list files
    ask PROGRAM_DIR      "Backup script directory"    "$SCRIPT_DIR"
    ask SOURCE_DIRS_LIST "Path to source list file"   "${config_values[PROGRAM_DIR]}/sourceList.txt"
    ask EXCLUDE_LIST     "Path to exclude list file"  "${config_values[PROGRAM_DIR]}/excludeList.txt"

    # Samba share
    ask SAMBA_SERVER   "Samba server IP or hostname"          ""
    ask SAMBA_FOLDER   "Samba folder (e.g., /backupTarget)"   ""
    ask SAMBA_VERSION  "Samba version (e.g., 1.0, 3.0)"       "1.0"
    ask SAMBA_USERNAME "Samba username"                       ""
    ask_secret SAMBA_PASSWORD "Samba password"

    # MySQL (the details are only asked if it is enabled)
    ask MYSQL_BACKUP_ENABLED "Enable MySQL database backup? (true/false)" "false"
    if [[ "${config_values[MYSQL_BACKUP_ENABLED]}" == "true" ]]; then
        ask MYSQL_USERNAME "MySQL username for backup" ""
        ask_secret MYSQL_PASSWORD "MySQL password for backup"
        ask MYSQL_HOST "MySQL host" "localhost"
        ask MYSQL_PORT "MySQL port" "3306"
        ask MYSQL_EXCLUDE_DBS "Excluded databases (space-separated)" "mysql phpmyadmin"
    fi

    # Mode
    ask SYNC_ONLY_DEFAULT "Set sync-only by default? (true/false)" "false"
}


# ======================================================
# Writing the config
# ======================================================

# Rebuilds the config from the example: comments and other lines are copied as they are,
# KEY=value lines get the collected value (or keep the example value if there is none).
# The collected values are written with shell_quote, so a password containing $, " or `
# is read back unchanged by startBackup.sh.
write_config() {
    if [ ! -f "$CONFIG_EXAMPLE" ]; then
        echo "Missing $CONFIG_EXAMPLE template!"
        exit 1
    fi

    echo "Creating $CONFIG_FILE from template..."
    rm -f "$CONFIG_FILE"

    local line key
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^([A-Za-z0-9_]+)= ]]; then
            key="${BASH_REMATCH[1]}"
            if [[ -n "${config_values[$key]}" ]]; then
                echo "$key=$(shell_quote "${config_values[$key]}")" >> "$CONFIG_FILE"
                continue
            fi
        fi
        echo "$line" >> "$CONFIG_FILE"
    done < "$CONFIG_EXAMPLE"

    # The file contains passwords
    chmod 600 "$CONFIG_FILE"
    echo "Config written to $CONFIG_FILE with permission 600 ✅"
}


# ======================================================
# Samba test
# ======================================================

# Mounts the share to a temporary folder and unmounts it again
test_samba_connection() {
    echo ""
    echo "Testing Samba mount..."

    local tmp_mount="$SCRIPT_DIR/__smbtest__"
    mkdir -p "$tmp_mount"

    mount -t cifs \
        -o rw,vers="${config_values[SAMBA_VERSION]}",username="${config_values[SAMBA_USERNAME]}",password="${config_values[SAMBA_PASSWORD]}" \
        "//${config_values[SAMBA_SERVER]}${config_values[SAMBA_FOLDER]}" "$tmp_mount" >/dev/null 2>&1

    if mountpoint -q "$tmp_mount"; then
        echo "✅ Successfully connected to Samba share."
        umount "$tmp_mount"
    else
        echo "❌ Failed to connect to Samba share. Check credentials or server access."
    fi

    rmdir "$tmp_mount"
}


# ======================================================
# Source and exclude lists
# ======================================================

# Returns the first available text editor (falls back to less, which can only view)
find_editor() {
    local e
    for e in nano vim vi; do
        if command -v "$e" >/dev/null 2>&1; then
            echo "$e"
            return
        fi
    done
    echo "less"
}

# Creates a list file from its .example and opens it for editing.
# An existing list is never overwritten.
#   $1: list file   $2: description shown to the user   $3: editor
create_list_file() {
    local file="$1" description="$2" editor="$3"
    local example="$file.example"

    if [ -f "$file" ]; then
        echo "ℹ $file already exists, not overwritten"
    elif [ -f "$example" ]; then
        cp "$example" "$file"
        echo "✔ $file created from example"
        echo "📂 $description"
        echo "✏️ Opening $file for editing..."
        "$editor" "$file"
    else
        echo "⚠ $example not found"
    fi
}

create_source_and_exclude_lists() {
    echo ""
    echo "Creating sourceList.txt and excludeList.txt from .example files..."

    local dir="${config_values[PROGRAM_DIR]:-$SCRIPT_DIR}"
    local editor
    editor="$(find_editor)"

    create_list_file "$dir/sourceList.txt" \
        "Contains default configuration folders to back up (e.g. /etc, ~/.config)" "$editor"
    create_list_file "$dir/excludeList.txt" \
        "Contains exclude rules (e.g. *.tmp, .cache/)" "$editor"
}


# ======================================================
# Cron
# ======================================================

# Adds a crontab entry that runs startBackup.sh with this config.
#   - An entry for the same script and config is left as it is.
#   - An old entry for this script without --config is replaced, because it would
#     silently use the config next to the script instead of this one.
#   - Entries of the script with other configs are kept.
setup_cron_job() {
    echo ""
    echo "Would you like to schedule automatic backups via cron?"

    local answer choice cron_expr
    read -rp "Schedule auto-backup in crontab? (y/n): " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "⏩ Skipping cron setup."
        return
    fi

    echo ""
    echo "Choose schedule:"
    echo "1) Every day at 01:06"
    echo "2) Every 3rd day at 01:06 (default)"
    echo "3) Every week (Sunday) at 01:06"
    echo "4) Custom cron expression"

    read -rp "Select option [1-4]: " choice
    case $choice in
        1)    cron_expr="06 01 * * *" ;;
        2|"") cron_expr="06 01 */3 * *" ;;
        3)    cron_expr="06 01 * * 0" ;;
        4)    read -rp "Enter custom cron expression (5 fields): " cron_expr ;;
        *)    echo "Invalid option. Skipping."; return ;;
    esac

    local script_path="$SCRIPT_DIR/startBackup.sh"
    local log_path="/var/log/autoBackup.log"
    local config_path
    config_path="$(realpath -- "$CONFIG_FILE")"
    local cron_cmd="$cron_expr \"$script_path\" --config \"$config_path\" >>$log_path 2>&1"

    local current_cron
    current_cron=$(crontab -l 2>/dev/null || true)

    # Same script with the same config: nothing to do
    if echo "$current_cron" | grep -F "$script_path" | grep -qF -- "--config \"$config_path\""; then
        echo "ℹ Cron job already exists for this script and config. Skipping."
        return
    fi

    # Drop the entries of this script that have no --config (from an older installer),
    # keep every other line in its original order
    local kept_cron
    kept_cron=$(printf '%s\n' "$current_cron" \
        | awk -v s="$script_path" '!(index($0, s) && !index($0, "--config"))')
    if [[ "$kept_cron" != "$current_cron" ]]; then
        echo "ℹ Replacing the old cron job that runs the script without --config."
    fi

    (echo "$kept_cron"; echo "$cron_cmd") | grep -v '^$' | crontab -
    echo "✅ Cron job added:"
    echo "$cron_cmd"
}


# ======================================================
# Main
# ======================================================

echo "Welcome to Auto Backup installer"

read -rp "Path to config file to use (default: $CONFIG_FILE): " input_cfg
CONFIG_FILE="${input_cfg:-$CONFIG_FILE}"

load_existing_config
check_dependencies
prompt_user_input
write_config
test_samba_connection
create_source_and_exclude_lists
setup_cron_job

echo ""
echo "✅ Installation complete. You can now run: ./startBackup.sh"
echo "To configure the script, edit $CONFIG_FILE or run the installer again."
echo ""
echo "Notes:"
echo " - You can sync folders directly to the remote (no zip) with the --sync-only option."
echo "   If you call: ./startBackup.sh --sync-only (without a path), the script will read the paths from SOURCE_DIRS_LIST in your config and sync each listed path."
echo ""
echo "Examples:"
echo "  ./startBackup.sh --sync-only /var/www        # sync a single folder"
echo "  ./startBackup.sh --sync-only                # sync all paths listed in SOURCE_DIRS_LIST"
