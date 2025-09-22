#!/bin/bash
#########################################################
# autoBackup.sh installer and configurator
# Keeps the original comments and structure of config.conf.example
#########################################################

CONFIG_FILE="./config.conf"
CONFIG_EXAMPLE="./config.conf.example"

declare -A config_values

check_dependencies() {
    echo "Checking required packages..."

    missing=()
    for pkg in rsync zip cifs-utils; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
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

prompt_user_input() {
    echo ""
    echo "=== Configuration ==="

    read -rp "Backup script directory (default: $(pwd)): " val
    config_values[PROGRAM_DIR]="${val:-$(pwd)}"

    read -rp "Path to source list file (default: \$PROGRAM_DIR/sourceList.txt): " val
    config_values[SOURCE_DIRS_LIST]="${val:-${config_values[PROGRAM_DIR]}/sourceList.txt}"

    read -rp "Path to exclude list file (default: \$PROGRAM_DIR/excludeList.txt): " val
    config_values[EXCLUDE_LIST]="${val:-${config_values[PROGRAM_DIR]}/excludeList.txt}"

    read -rp "Samba server IP or hostname: " val
    config_values[SAMBA_SERVER]="$val"

    read -rp "Samba folder (e.g., /backupTarget): " val
    config_values[SAMBA_FOLDER]="$val"

    read -rp "Samba version (e.g., 1.0, 3.0): " val
    config_values[SAMBA_VERSION]="$val"

    read -rp "Samba username: " val
    config_values[SAMBA_USERNAME]="$val"

    read -rsp "Samba password: " val
    echo ""
    config_values[SAMBA_PASSWORD]="$val"
    
    read -rp "Do you want to sync the folders only instead of compressing and uploading the archive? (true/false) [false]: " val
    config_values[SYNC_ONLY_DEFAULT]="${val:-false}"
}

write_config() {
    if [ ! -f "$CONFIG_EXAMPLE" ]; then
        echo "Missing $CONFIG_EXAMPLE template!"
        exit 1
    fi

    echo "Creating $CONFIG_FILE from template..."
    rm -f "$CONFIG_FILE"

    while IFS= read -r line; do
        if [[ "$line" =~ ^([A-Za-z0-9_]+)= ]]; then
            key="${BASH_REMATCH[1]}"
            if [[ -n "${config_values[$key]}" ]]; then
                value="${config_values[$key]}"
                echo "$key=\"$value\"" >> "$CONFIG_FILE"
                continue
            fi
        fi
        echo "$line" >> "$CONFIG_FILE"
    done < "$CONFIG_EXAMPLE"

    chmod 600 "$CONFIG_FILE"
    echo "Config written to $CONFIG_FILE with permission 600 ✅"
}

test_samba_connection() {
    echo ""
    echo "Testing Samba mount..."

    TMP_MOUNT="./__smbtest__"
    mkdir -p "$TMP_MOUNT"

    mount -t cifs -o rw,vers="${config_values[SAMBA_VERSION]}",username="${config_values[SAMBA_USERNAME]}",password="${config_values[SAMBA_PASSWORD]}" \
        "//${config_values[SAMBA_SERVER]}${config_values[SAMBA_FOLDER]}" "$TMP_MOUNT" >/dev/null 2>&1

    if mountpoint -q "$TMP_MOUNT"; then
        echo "✅ Successfully connected to Samba share."
        umount "$TMP_MOUNT"
    else
        echo "❌ Failed to connect to Samba share. Check credentials or server access."
    fi

    rmdir "$TMP_MOUNT"
}

create_source_and_exclude_lists() {
    echo ""
    echo "Creating sourceList.txt and excludeList.txt from .example files..."

    local src_dir="${config_values[PROGRAM_DIR]}"
    [ -z "$src_dir" ] && src_dir="$(pwd)"

    local source_example="$src_dir/sourceList.txt.example"
    local exclude_example="$src_dir/excludeList.txt.example"
    local source_file="$src_dir/sourceList.txt"
    local exclude_file="$src_dir/excludeList.txt"

    # Detect available editor
    local editor=""
    for e in nano vim vi; do
        if command -v "$e" >/dev/null 2>&1; then
            editor="$e"
            break
        fi
    done
    [ -z "$editor" ] && editor="less"

    if [ -f "$source_example" ] && [ ! -f "$source_file" ]; then
        cp "$source_example" "$source_file"
        echo "✔ $source_file created from example"
        echo "📂 Contains default configuration folders to back up (e.g. /etc, ~/.config)"
        echo "✏️ Opening $source_file for editing..."
        "$editor" "$source_file"
    elif [ -f "$source_file" ]; then
        echo "ℹ $source_file already exists, not overwritten"
    else
        echo "⚠ $source_example not found"
    fi

    if [ -f "$exclude_example" ] && [ ! -f "$exclude_file" ]; then
        cp "$exclude_example" "$exclude_file"
        echo "✔ $exclude_file created from example"
        echo "📂 Contains exclude rules (e.g. *.tmp, .cache/)"
        echo "✏️ Opening $exclude_file for editing..."
        "$editor" "$exclude_file"
    elif [ -f "$exclude_file" ]; then
        echo "ℹ $exclude_file already exists, not overwritten"
    else
        echo "⚠ $exclude_example not found"
    fi
}

confirm() {
    read -rp "Do you want to continue (y/n)? " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

setup_cron_job() {
    echo ""
    echo "Would you like to schedule automatic backups via cron?"

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
        1) cron_expr="06 01 * * *" ;;
        2|"") cron_expr="06 01 */3 * *" ;;
        3) cron_expr="06 01 * * 0" ;;
        4) read -rp "Enter custom cron expression (5 fields): " cron_expr ;;
        *) echo "Invalid option. Skipping."; return ;;
    esac

    script_path="$SCRIPT_DIR/startBackup.sh"
    log_path="/var/log/autoBackup.log"
    cron_cmd="$cron_expr $script_path >>$log_path 2>&1"

    current_cron=$(crontab -l 2>/dev/null)

    if echo "$current_cron" | grep -qF "$script_path"; then
        echo "ℹ Cron job already exists for this script. Skipping."
    else
        (echo "$current_cron"; echo "$cron_cmd") | crontab -
        echo "✅ Cron job added:"
        echo "$cron_cmd"
    fi
}


# === MAIN ===

echo "Welcome to Auto Backup installer"

if [ -f "$CONFIG_FILE" ]; then
    echo "Config file already exists at $CONFIG_FILE."
    if confirm; then
            # === MySQL Backup Settings ===
            read -rp "Enable MySQL database backup? (true/false) [true]: " val
            config_values[MYSQL_BACKUP_ENABLED]="${val:-true}"

            if [[ "${config_values[MYSQL_BACKUP_ENABLED]}" == "true" ]]; then
                read -rp "MySQL username for backup: " val
                config_values[MYSQL_USERNAME]="$val"
                read -rsp "MySQL password for backup: " val
                echo ""
                config_values[MYSQL_PASSWORD]="$val"
                read -rp "MySQL host (default: localhost): " val
                config_values[MYSQL_HOST]="${val:-localhost}"
                read -rp "MySQL port (default: 3306): " val
                config_values[MYSQL_PORT]="${val:-3306}"
                read -rp "Excluded databases (space-separated, default: mysql phpmyadmin): " val
                config_values[MYSQL_EXCLUDE_DBS]="${val:-mysql phpmyadmin}"
            fi
        echo "Reconfiguring..."
    else
        echo "Installation cancelled."
        exit 0
    fi
fi

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
