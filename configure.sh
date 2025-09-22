#!/bin/bash
#########################################################
# autoBackup.sh installer and configurator
# Keeps the original comments and structure of config.conf.example
#########################################################

CONFIG_FILE="./config.conf"
CONFIG_EXAMPLE="./config.conf.example"

declare -A config_values

load_existing_config() {
    if [ -f "$CONFIG_FILE" ]; then
        while IFS= read -r line; do
    # Use readline editable input with prefilled default when available
    default_program_dir="${config_values[PROGRAM_DIR]:-$(pwd)}"
    read -e -i "$default_program_dir" -p "Backup script directory: " val
    config_values[PROGRAM_DIR]="${val:-$default_program_dir}"
                value="${BASH_REMATCH[2]}"
    default_source_list="${config_values[SOURCE_DIRS_LIST]:-${config_values[PROGRAM_DIR]}/sourceList.txt}"
    read -e -i "$default_source_list" -p "Path to source list file: " val
    config_values[SOURCE_DIRS_LIST]="${val:-$default_source_list}"
        done < "$CONFIG_FILE"
    default_exclude_list="${config_values[EXCLUDE_LIST]:-${config_values[PROGRAM_DIR]}/excludeList.txt}"
    read -e -i "$default_exclude_list" -p "Path to exclude list file: " val
    config_values[EXCLUDE_LIST]="${val:-$default_exclude_list}"

    default_samba_server="${config_values[SAMBA_SERVER]:-}"
    read -e -i "$default_samba_server" -p "Samba server IP or hostname: " val
    config_values[SAMBA_SERVER]="${val:-$default_samba_server}"

    default_samba_folder="${config_values[SAMBA_FOLDER]:-}"
    read -e -i "$default_samba_folder" -p "Samba folder (e.g., /backupTarget): " val
    config_values[SAMBA_FOLDER]="${val:-$default_samba_folder}"

    default_samba_version="${config_values[SAMBA_VERSION]:-1.0}"
    read -e -i "$default_samba_version" -p "Samba version (e.g., 1.0, 3.0): " val
    config_values[SAMBA_VERSION]="${val:-$default_samba_version}"

    default_samba_user="${config_values[SAMBA_USERNAME]:-}"
    read -e -i "$default_samba_user" -p "Samba username: " val
    config_values[SAMBA_USERNAME]="${val:-$default_samba_user}"

    # Passwords are read silently; pressing Enter keeps existing value
    read -rsp "Samba password (press enter to keep existing): " val
    echo ""
    config_values[SAMBA_PASSWORD]="${val:-${config_values[SAMBA_PASSWORD]:-}}"
        echo "All required packages are installed."
    fi
    default_mysql_enabled="${config_values[MYSQL_BACKUP_ENABLED]:-false}"
    read -e -i "$default_mysql_enabled" -p "Enable MySQL database backup? (true/false): " val
    config_values[MYSQL_BACKUP_ENABLED]="${val:-$default_mysql_enabled}"

    if [[ "${config_values[MYSQL_BACKUP_ENABLED]}" == "true" ]]; then
        default_mysql_user="${config_values[MYSQL_USERNAME]:-}"
        read -e -i "$default_mysql_user" -p "MySQL username for backup: " val
        config_values[MYSQL_USERNAME]="${val:-$default_mysql_user}"

        read -rsp "MySQL password for backup (press enter to keep existing): " val
        echo ""
        config_values[MYSQL_PASSWORD]="${val:-${config_values[MYSQL_PASSWORD]:-}}"

        default_mysql_host="${config_values[MYSQL_HOST]:-localhost}"
        read -e -i "$default_mysql_host" -p "MySQL host: " val
        config_values[MYSQL_HOST]="${val:-$default_mysql_host}"

        default_mysql_port="${config_values[MYSQL_PORT]:-3306}"
        read -e -i "$default_mysql_port" -p "MySQL port: " val
        config_values[MYSQL_PORT]="${val:-$default_mysql_port}"

        default_mysql_exclude="${config_values[MYSQL_EXCLUDE_DBS]:-mysql phpmyadmin}"
        read -e -i "$default_mysql_exclude" -p "Excluded databases (space-separated): " val
        config_values[MYSQL_EXCLUDE_DBS]="${val:-$default_mysql_exclude}"
    fi

    default_sync_only="${config_values[SYNC_ONLY_DEFAULT]:-false}"
    read -e -i "$default_sync_only" -p "Set sync-only by default? (true/false): " val
    config_values[SYNC_ONLY_DEFAULT]="${val:-$default_sync_only}"

    read -rp "Samba username (default: ${config_values[SAMBA_USERNAME]:-}): " val
    config_values[SAMBA_USERNAME]="${val:-${config_values[SAMBA_USERNAME]:-}}"

    read -rsp "Samba password (press enter to keep existing): " val
    echo ""
    config_values[SAMBA_PASSWORD]="${val:-${config_values[SAMBA_PASSWORD]:-}}"

    # === MySQL Backup Settings ===
    read -rp "Enable MySQL database backup? (true/false) [${config_values[MYSQL_BACKUP_ENABLED]:-false}]: " val
    config_values[MYSQL_BACKUP_ENABLED]="${val:-${config_values[MYSQL_BACKUP_ENABLED]:-false}}"

    if [[ "${config_values[MYSQL_BACKUP_ENABLED]}" == "true" ]]; then
        read -rp "MySQL username for backup (default: ${config_values[MYSQL_USERNAME]:-}): " val
        config_values[MYSQL_USERNAME]="${val:-${config_values[MYSQL_USERNAME]:-}}"
        read -rsp "MySQL password for backup (press enter to keep existing): " val
        echo ""
        config_values[MYSQL_PASSWORD]="${val:-${config_values[MYSQL_PASSWORD]:-}}"
        read -rp "MySQL host (default: ${config_values[MYSQL_HOST]:-localhost}): " val
        config_values[MYSQL_HOST]="${val:-${config_values[MYSQL_HOST]:-localhost}}"
        read -rp "MySQL port (default: ${config_values[MYSQL_PORT]:-3306}): " val
        config_values[MYSQL_PORT]="${val:-${config_values[MYSQL_PORT]:-3306}}"
        read -rp "Excluded databases (space-separated, default: ${config_values[MYSQL_EXCLUDE_DBS]:-mysql phpmyadmin}): " val
        config_values[MYSQL_EXCLUDE_DBS]="${val:-${config_values[MYSQL_EXCLUDE_DBS]:-mysql phpmyadmin}}"
    fi

    read -rp "Set sync-only by default? (true/false) [${config_values[SYNC_ONLY_DEFAULT]:-false}]: " val
    config_values[SYNC_ONLY_DEFAULT]="${val:-${config_values[SYNC_ONLY_DEFAULT]:-false}}"
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
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    script_path="$SCRIPT_DIR/startBackup.sh"
    log_path="/var/log/autoBackup.log"
    cron_cmd="$cron_expr $script_path >>$log_path 2>&1"
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

read -rp "Path to config file to use (default: ./config.conf): " input_cfg
CONFIG_FILE="${input_cfg:-./config.conf}"

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
