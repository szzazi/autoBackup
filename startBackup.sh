#!/bin/bash
    #########################################################
    # Automatic backup script with optional dry-run support
    # - Uses external config (with override)
    # - Accepts CLI username/password or from config
    # - Supports dry-run mode with --dry-run switch
    #########################################################

    SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
    CONFIG_FILE="$SCRIPT_DIR/config.conf"
    DESTINATION_DIR="$SCRIPT_DIR/temp"
    LOCAL_MOUNT_POINT="$SCRIPT_DIR/remote"

    # Optional CLI overrides
    CLI_USERNAME=""
    CLI_PASSWORD=""
    DRY_RUN=false
    TEST_SAMBA=false

    print_help() {
        echo "Usage: $0 [--config <path>] [--user <username>] [--pass <password>] [--dry-run] [--help]"
        echo ""
        echo "Options:"
        echo "  -c, --config <path>     Path to config file"
        echo "      --user <username>   Samba username (overrides config)"
        echo "      --pass <password>   Samba password (overrides config)"
        echo "      --dry-run           Run full flow in simulation mode (no actual copy)"
        echo "      --test-samba        Only test Samba/CIFS connection (mount & unmount)"
        echo "  -h, --help              Show this help message"
        exit 0
    }

    parse_arguments() {
        while [[ $# -gt 0 ]]; do
            case $1 in
                -c|--config)
                    CONFIG_FILE="$2"
                    shift 2
                    ;;
                --user)
                    CLI_USERNAME="$2"
                    shift 2
                    ;;
                --pass)
                    CLI_PASSWORD="$2"
                    shift 2
                    ;;
                --dry-run)
                    DRY_RUN=true
                    shift
                    ;;
                --test-samba)
                    TEST_SAMBA=true
                    shift
                    ;;
                -h|--help)
                    print_help
                    ;;
                *)
                    echo "Unknown option: $1"
                    print_help
                    ;;
            esac
        done
    }

    load_config() {
        if [ ! -f "$CONFIG_FILE" ]; then
            echo "Config file not found: $CONFIG_FILE"
            exit 1
        fi
        source "$CONFIG_FILE"

        # Set MySQL defaults if not present
        MYSQL_BACKUP_ENABLED="${MYSQL_BACKUP_ENABLED:-false}"
        MYSQL_USERNAME="${MYSQL_USERNAME:-}" # must be set in config
        MYSQL_PASSWORD="${MYSQL_PASSWORD:-}" # must be set in config
        MYSQL_HOST="${MYSQL_HOST:-localhost}"
        MYSQL_PORT="${MYSQL_PORT:-3306}"
        MYSQL_EXCLUDE_DBS="${MYSQL_EXCLUDE_DBS:-mysql phpmyadmin}"

        # Set MySQL defaults if not present
        MYSQL_USERNAME="${MYSQL_USERNAME:-}" # must be set in config
        MYSQL_PASSWORD="${MYSQL_PASSWORD:-}" # must be set in config
        MYSQL_HOST="${MYSQL_HOST:-localhost}"
        MYSQL_PORT="${MYSQL_PORT:-3306}"
        MYSQL_EXCLUDE_DBS="${MYSQL_EXCLUDE_DBS:-mysql phpmyadmin}"
    }
    check_mysql_privileges() {
        echo "Checking MySQL user privileges for export..."
        PRIVS=$(mysql -u"$MYSQL_USERNAME" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" -e "SHOW GRANTS FOR CURRENT_USER();" 2>/dev/null)
        for priv in SELECT "SHOW VIEW" EVENT "LOCK TABLES"; do
            if echo "$PRIVS" | grep -iq "$priv"; then
                echo "  ✅ $priv privilege: OK"
            else
                echo "  ❌ $priv privilege: MISSING"
            fi
        done
    }

    dump_mysql_databases() {
        if $DRY_RUN; then
            check_mysql_privileges
            return
        fi
        echo "Dumping MySQL databases..."
        MYSQL_DUMP_DIR="$DESTINATION_DIR/mysql_dump"
        mkdir -p "$MYSQL_DUMP_DIR"

        # Get database list, excluding system DBs
        DBS=$(mysql -u"$MYSQL_USERNAME" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" -e "SHOW DATABASES;" | grep -vE "Database|$(echo $MYSQL_EXCLUDE_DBS | sed 's/ /|/g')")

        for db in $DBS; do
            echo "  Exporting database: $db"
            DB_DIR="$MYSQL_DUMP_DIR/$db"
            mkdir -p "$DB_DIR"
            # Dump schema and meta
            mysqldump -u"$MYSQL_USERNAME" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" --no-data --routines --events "$db" > "$DB_DIR/schema.sql"
            # Dump each table's data separately
            TABLES=$(mysql -u"$MYSQL_USERNAME" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" -D "$db" -e "SHOW TABLES;" | awk 'NR>1')
            for tbl in $TABLES; do
                echo "    Table: $tbl"
                mysqldump -u"$MYSQL_USERNAME" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" --no-create-info "$db" "$tbl" > "$DB_DIR/${tbl}.data.sql"
            done
        done
    }

    resolve_credentials() {
        SAMBA_USERNAME="${CLI_USERNAME:-$SAMBA_USERNAME}"
        SAMBA_PASSWORD="${CLI_PASSWORD:-$SAMBA_PASSWORD}"

        if [[ -z "$SAMBA_USERNAME" || -z "$SAMBA_PASSWORD" ]]; then
            echo "Error: Samba username and password must be provided via CLI or config."
            exit 1
        fi
    }

    print_start_info() {
        local timestamp
        timestamp=$(date +"%Y-%m-%d %H:%M:%S")
        echo "=============================================="
        echo "Start auto backup script at ${timestamp}"
        echo "Simulation mode: $DRY_RUN"
        echo "Working directory: \"$SCRIPT_DIR\""
        echo "=============================================="
        echo "Directory files:"
        ls -la
        echo "=============================================="
    }

    change_to_program_dir() {
        cd "$PROGRAM_DIR" || { echo "Cannot change directory to $PROGRAM_DIR"; exit 1; }
    }

    copy_source_dirs() {
        echo "Copying source directories..."
        mkdir -p "$DESTINATION_DIR"
        for path in $(cat "$SOURCE_DIRS_LIST"); do
            rsync -avr --exclude-from="$EXCLUDE_LIST" --relative "$path" "$DESTINATION_DIR"
        done
    }

    generate_backup_filename() {
        host=$(hostname | tr '.' '_')
        timestamp=$(date +"%Y%m%d_%H%M%S")
        BACKUP_FILENAME="${timestamp}-${host}.zip"
    }

    compress_backup() {
        if $DRY_RUN; then
            echo "Creating empty ZIP file for simulation: $BACKUP_FILENAME"
            zip -r "$BACKUP_FILENAME" --filesync -q /dev/null
        else
            echo "Compressing backup to: $BACKUP_FILENAME"
            (cd "$DESTINATION_DIR" && zip -r "../$BACKUP_FILENAME" .)
        fi
    }

    mount_remote_storage() {
        echo "Mounting network storage..."

        if [ ! -d "$LOCAL_MOUNT_POINT" ]; then
            mkdir -p "$LOCAL_MOUNT_POINT"
            echo "\"$LOCAL_MOUNT_POINT\" folder created."
        else
            echo "\"$LOCAL_MOUNT_POINT\" already exists."
        fi

        mount -t cifs -o rw,file_mode=0660,dir_mode=0660,vers="$SAMBA_VERSION",username="$SAMBA_USERNAME",password="$SAMBA_PASSWORD" \
            "//$SAMBA_SERVER$SAMBA_FOLDER" "$LOCAL_MOUNT_POINT"

        if [ $? -ne 0 ]; then
            echo "Mount failed"
            exit 1
        fi
    }

    copy_backup_to_remote() {
        echo "Preparing to sync backup file to remote..."

        archivedFile="./$BACKUP_FILENAME"
        mountPoint="$LOCAL_MOUNT_POINT"

        if $DRY_RUN; then
            echo -e "\n[Dry-run mode enabled] Simulating rsync:"
            rsync -avhzn --delete "$archivedFile" "$mountPoint"
        else
            echo -e "\nPerforming actual sync:"
            rsync -avhz --delete "$archivedFile" "$mountPoint"
        fi
    }

    unmount_remote_storage() {
        echo "Unmounting network storage..."
        umount "$LOCAL_MOUNT_POINT"

        if [ $? -eq 0 ]; then
            rmdir "$LOCAL_MOUNT_POINT"
        else
            echo "Failed to unmount $LOCAL_MOUNT_POINT"
        fi
    }

    cleanup_local_backup() {
        echo "Cleaning up local files..."
        rm -f "$BACKUP_FILENAME"
        rm -rf "$DESTINATION_DIR"
    }

    print_done() {
        local timestamp
        timestamp=$(date +"%Y-%m-%d %H:%M:%S")
        echo "=============================================="
        echo "Backup process completed at ${timestamp}"
        echo "=============================================="
    }

    # === Main sequence ===

    parse_arguments "$@"
    print_start_info
    load_config
    resolve_credentials

    if $TEST_SAMBA; then
        echo "Testing Samba/CIFS connection..."
        mount_remote_storage
        unmount_remote_storage
        echo "Samba/CIFS connection test completed."
        exit 0
    fi

    change_to_program_dir
    copy_source_dirs
    if [ "$MYSQL_BACKUP_ENABLED" = "true" ]; then
        dump_mysql_databases
    fi
    generate_backup_filename
    compress_backup
    mount_remote_storage
    copy_backup_to_remote
    unmount_remote_storage
    cleanup_local_backup
    print_done


    # Exit with success