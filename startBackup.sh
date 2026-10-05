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
    LOCK_FILE="$SCRIPT_DIR/.autoBackup.lock"

    # Optional CLI overrides
    CLI_USERNAME=""
    CLI_PASSWORD=""
    DRY_RUN=false
    TEST_SAMBA=false
    SYNC_ONLY=false
    SYNC_PATH=""
    CLI_WOL=""
    CLI_WOL_MAC=""
    CLI_WOL_PING_IP=""
    CLI_WOL_TIMEOUT=""
    SENTRY_DSN=""
    SENTRY_REPORTED=false

    print_help() {
        echo "Usage: $0 [--config <path>] [--user <username>] [--pass <password>] [--dry-run] [--test-samba]"
        echo "          [--sync-only [<path>]] [--wol] [--wol-mac <mac>] [--wol-ping-ip <ip>] [--wol-timeout <sec>] [--help]"
        echo ""
        echo "Options:"
        echo "  -c, --config <path>     Path to config file"
        echo "      --user <username>   Samba username (overrides config)"
        echo "      --pass <password>   Samba password (overrides config)"
        echo "      --dry-run           Run full flow in simulation mode (no actual copy)"
        echo "      --test-samba        Only test Samba/CIFS connection (mount & unmount)"
    echo "      --sync-only <path>   Sync the specified local folder to the remote share (no zip)."
    echo "                           If no <path> is provided, the script will read paths from SOURCE_DIRS_LIST in the config and sync each listed path."
        echo "      --wol               Enable Wake-on-LAN before mounting (ping first, send WOL if unreachable)"
        echo "      --wol-mac <mac>     Target MAC address (overrides WOL_MAC)"
        echo "      --wol-ping-ip <ip>  IP to ping for availability (overrides WOL_PING_IP)"
        echo "      --wol-timeout <sec> Max seconds to wait after WOL packet (overrides WOL_WAKEUP_TIMEOUT_SEC, default 120)"
        echo "  -h, --help              Show this help message"
        exit 0
    }

    # Exits if an option that needs a value has none (otherwise "shift 2" would loop forever)
    require_value() {
        if [[ $# -lt 2 ]]; then
            echo "Error: option $1 requires a value."
            exit 1
        fi
    }

    parse_arguments() {
        while [[ $# -gt 0 ]]; do
            case $1 in
                -c|--config)
                    require_value "$@"
                    CONFIG_FILE="$2"
                    shift 2
                    ;;
                --user)
                    require_value "$@"
                    CLI_USERNAME="$2"
                    shift 2
                    ;;
                --pass)
                    require_value "$@"
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
                --sync-only)
                    SYNC_ONLY=true
                    # optional path argument: only consume next token if it's not another flag
                    if [[ -n "$2" && "$2" != -* ]]; then
                        SYNC_PATH="$2"
                        shift 2
                    else
                        shift
                    fi
                    ;;
                --wol)
                    CLI_WOL=true
                    shift
                    ;;
                --wol-mac)
                    require_value "$@"
                    CLI_WOL_MAC="$2"
                    shift 2
                    ;;
                --wol-ping-ip)
                    require_value "$@"
                    CLI_WOL_PING_IP="$2"
                    shift 2
                    ;;
                --wol-timeout)
                    require_value "$@"
                    CLI_WOL_TIMEOUT="$2"
                    shift 2
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

        # Sync-only default from config
        SYNC_ONLY_DEFAULT="${SYNC_ONLY_DEFAULT:-false}"

        # Wake-on-LAN settings (CLI overrides config)
        [[ "$CLI_WOL" == "true" ]] && WOL_ENABLED=true
        WOL_ENABLED="${WOL_ENABLED:-false}"
        WOL_MAC="${CLI_WOL_MAC:-$WOL_MAC}"
        WOL_PING_IP="${CLI_WOL_PING_IP:-${WOL_PING_IP:-$SAMBA_SERVER}}"
        WOL_WAKEUP_TIMEOUT_SEC="${CLI_WOL_TIMEOUT:-${WOL_WAKEUP_TIMEOUT_SEC:-120}}"
        WOL_INTERFACE="${WOL_INTERFACE:-}"
        SENTRY_DSN="${SENTRY_DSN:-}"
        SENTRY_ENVIRONMENT="${SENTRY_ENVIRONMENT:-production}"
        [[ "$WOL_ENABLED" == "true" ]] && WOL_ENABLED=true || WOL_ENABLED=false

        # Mount retries (the share may come up a bit later than the host answers ping)
        MOUNT_RETRIES="${MOUNT_RETRIES:-5}"
        MOUNT_RETRY_DELAY_SEC="${MOUNT_RETRY_DELAY_SEC:-10}"
        [[ "$MOUNT_RETRIES" =~ ^[1-9][0-9]*$ ]] || MOUNT_RETRIES=1
        [[ "$MOUNT_RETRY_DELAY_SEC" =~ ^[0-9]+$ ]] || MOUNT_RETRY_DELAY_SEC=10
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
        local all_dbs
        if ! all_dbs=$(mysql -u"$MYSQL_USERNAME" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" -e "SHOW DATABASES;"); then
            report_error "autoBackup: MySQL backup failed" \
                "Cannot list MySQL databases on $MYSQL_HOST:$MYSQL_PORT, database backup skipped."
            return
        fi
        DBS=$(echo "$all_dbs" | grep -vE "Database|$(echo $MYSQL_EXCLUDE_DBS | sed 's/ /|/g')")

        local failed=()
        for db in $DBS; do
            echo "  Exporting database: $db"
            DB_DIR="$MYSQL_DUMP_DIR/$db"
            mkdir -p "$DB_DIR"
            # Dump schema and meta
            mysqldump -u"$MYSQL_USERNAME" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" --no-data --routines --events "$db" > "$DB_DIR/schema.sql" \
                || failed+=("$db (schema)")
            # Dump each table's data separately
            if ! TABLES=$(mysql -u"$MYSQL_USERNAME" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" -D "$db" -e "SHOW TABLES;"); then
                failed+=("$db (table list)")
                continue
            fi
            TABLES=$(echo "$TABLES" | awk 'NR>1')
            for tbl in $TABLES; do
                echo "    Table: $tbl"
                mysqldump -u"$MYSQL_USERNAME" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" --no-create-info "$db" "$tbl" > "$DB_DIR/${tbl}.data.sql" \
                    || failed+=("$db.$tbl")
            done
        done

        if [ ${#failed[@]} -gt 0 ]; then
            report_error "autoBackup: MySQL backup failed" \
                "MySQL backup is incomplete, failed: $(join_list "${failed[@]}")"
        fi
    }

    resolve_credentials() {
        SAMBA_USERNAME="${CLI_USERNAME:-$SAMBA_USERNAME}"
        SAMBA_PASSWORD="${CLI_PASSWORD:-$SAMBA_PASSWORD}"

        if [[ -z "$SAMBA_USERNAME" || -z "$SAMBA_PASSWORD" ]]; then
            fail_and_report "autoBackup: misconfigured" \
                "Error: Samba username and password must be provided via CLI or config."
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
        cd "$PROGRAM_DIR" || fail_and_report "autoBackup: misconfigured" "Cannot change directory to $PROGRAM_DIR"
    }

    copy_source_dirs() {
        echo "Copying source directories..."
        if [ ! -f "$SOURCE_DIRS_LIST" ]; then
            fail_and_report "autoBackup: misconfigured" "Source list not found: $SOURCE_DIRS_LIST"
        fi
        mkdir -p "$DESTINATION_DIR"
        # The mount point and the temp dir are always excluded, regardless of the exclude list,
        # so the remote content can never be copied back to this machine.
        local failed=() rc
        for path in $(cat "$SOURCE_DIRS_LIST"); do
            rsync -avr --exclude="$LOCAL_MOUNT_POINT" --exclude="$DESTINATION_DIR" \
                --exclude-from="$EXCLUDE_LIST" --relative "$path" "$DESTINATION_DIR"
            rc=$?
            # 24 = some source files vanished during the transfer, harmless for a backup
            if [ $rc -ne 0 ] && [ $rc -ne 24 ]; then
                failed+=("$path (rsync exit $rc)")
            fi
        done

        # Continue with what could be copied: a partial backup is better than none
        if [ ${#failed[@]} -gt 0 ]; then
            report_error "autoBackup: copy of source directories failed" \
                "Backup is incomplete, could not copy: $(join_list "${failed[@]}")"
        fi
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
            if ! (cd "$DESTINATION_DIR" && zip -r "../$BACKUP_FILENAME" .); then
                fail_and_report "autoBackup: compression failed" "Cannot create backup archive $BACKUP_FILENAME. Backup aborted."
            fi
        fi
    }

    log_msg() {
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] $*"
    }

    json_escape() {
        local s="$1"
        s="${s//\\/\\\\}"
        s="${s//\"/\\\"}"
        s="${s//$'\n'/\\n}"
        s="${s//$'\r'/}"
        s="${s//$'\t'/\\t}"
        printf '%s' "$s"
    }

    # Sends an event to Sentry (SENTRY_DSN). Uses sentry-cli if installed, otherwise curl.
    # Level: fatal, error (default), warning, info
    send_to_sentry() {
        local subject="$1" body="$2" level="${3:-error}"

        if [[ -z "$SENTRY_DSN" ]]; then
            log_msg "Sentry: SENTRY_DSN not set, event not sent."
            return 1
        fi

        if command -v sentry-cli >/dev/null 2>&1; then
            # --no-environ: do not upload environment variables with the event
            if SENTRY_DSN="$SENTRY_DSN" sentry-cli send-event --no-environ -l "$level" -m "$subject: $body" \
                -E "$SENTRY_ENVIRONMENT" -t "subject:$subject" -f "$subject" >/dev/null 2>&1; then
                log_msg "Sentry: event sent (sentry-cli)."
                return 0
            fi
            log_msg "Sentry: sentry-cli failed, falling back to curl."
        fi

        if ! command -v curl >/dev/null 2>&1; then
            log_msg "Sentry: neither sentry-cli nor curl is available, event not sent."
            return 1
        fi

        # DSN format: <scheme>://<public_key>[:<secret>]@<host>[/<path>]/<project_id>
        if ! [[ "$SENTRY_DSN" =~ ^(https?)://([^:@/]+)(:[^@]*)?@([^/]+)(/.*)?/([0-9]+)/?$ ]]; then
            log_msg "Sentry: invalid SENTRY_DSN."
            return 1
        fi
        local scheme="${BASH_REMATCH[1]}" key="${BASH_REMATCH[2]}" host="${BASH_REMATCH[4]}"
        local path="${BASH_REMATCH[5]}" project="${BASH_REMATCH[6]}"
        local url="$scheme://$host$path/api/$project/envelope/"

        local event_id
        event_id="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
        local ts sent_at
        ts="$(date +%s)"
        sent_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

        local event
        event=$(printf '{"event_id":"%s","timestamp":%s,"level":"%s","platform":"other","logger":"autoBackup","server_name":"%s","environment":"%s","message":{"formatted":"%s"},"fingerprint":["%s"],"tags":{"subject":"%s"}}' \
            "$event_id" "$ts" "$(json_escape "$level")" "$(json_escape "$(hostname)")" "$(json_escape "$SENTRY_ENVIRONMENT")" \
            "$(json_escape "$subject: $body")" "$(json_escape "$subject")" "$(json_escape "$subject")")

        local envelope
        envelope=$(printf '{"event_id":"%s","sent_at":"%s"}\n{"type":"event"}\n%s\n' \
            "$event_id" "$sent_at" "$event")

        if curl -sS -f -m 15 -X POST "$url" \
            -H "Content-Type: application/x-sentry-envelope" \
            -H "X-Sentry-Auth: Sentry sentry_version=7, sentry_key=$key, sentry_client=autoBackup/1.0" \
            --data-binary "$envelope" >/dev/null; then
            log_msg "Sentry: event sent ($event_id)."
        else
            log_msg "Sentry: failed to send event."
            return 1
        fi
    }

    ping_host() {
        ping -c 1 -W 2 "$WOL_PING_IP" >/dev/null 2>&1
    }

    # Logs the error and reports it to Sentry, but lets the script continue
    report_error() {
        local subject="$1" body="$2" level="${3:-error}"
        log_msg "$body"
        send_to_sentry "$subject" "$body" "$level"
    }

    # Logs the error, reports it to Sentry and exits
    fail_and_report() {
        report_error "$1" "$2" "${3:-error}"
        # Tells cleanup_on_exit that this exit is already reported
        SENTRY_REPORTED=true
        exit 1
    }

    # Joins the arguments with "; "
    join_list() {
        local out
        out="$(printf '%s; ' "$@")"
        printf '%s' "${out%; }"
    }

    send_wol_packet() {
        # etherwake only when an interface is given: without -i it uses eth0 and silently fails elsewhere
        if [[ -n "$WOL_INTERFACE" ]] && command -v etherwake >/dev/null 2>&1; then
            etherwake -i "$WOL_INTERFACE" "$WOL_MAC"
        elif command -v wakeonlan >/dev/null 2>&1; then
            wakeonlan "${WOL_MAC//-/:}" >/dev/null
        elif command -v python3 >/dev/null 2>&1; then
            python3 - "$WOL_MAC" <<'PY'
import socket, sys
mac = bytes.fromhex(sys.argv[1].replace(':', '').replace('-', ''))
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.sendto(b'\xff' * 6 + mac * 16, ('255.255.255.255', 9))
PY
        else
            log_msg "No WOL tool found (wakeonlan, etherwake, python3)."
            return 1
        fi
    }

    wake_remote_if_needed() {
        $WOL_ENABLED || return 0

        if [[ -z "$WOL_MAC" || -z "$WOL_PING_IP" ]]; then
            fail_and_report "autoBackup: WOL misconfigured" "WOL: MAC address and ping IP are required."
        fi
        if ! [[ "$WOL_MAC" =~ ^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$ ]]; then
            fail_and_report "autoBackup: WOL misconfigured" "WOL: invalid MAC address: $WOL_MAC"
        fi
        if ! [[ "$WOL_WAKEUP_TIMEOUT_SEC" =~ ^[0-9]+$ ]]; then
            fail_and_report "autoBackup: WOL misconfigured" "WOL: invalid timeout: $WOL_WAKEUP_TIMEOUT_SEC"
        fi

        if ping_host; then
            log_msg "WOL: $WOL_PING_IP is already reachable."
            return 0
        fi

        log_msg "WOL: $WOL_PING_IP unreachable, sending magic packet to $WOL_MAC"
        if ! send_wol_packet; then
            fail_and_report "autoBackup: WOL send failed" "WOL: could not send WOL packet to $WOL_MAC."
        fi

        # Measure real elapsed time: each failed ping itself takes up to 2s
        local start=$SECONDS
        while (( SECONDS - start < WOL_WAKEUP_TIMEOUT_SEC )); do
            if ping_host; then
                log_msg "WOL: $WOL_PING_IP is up after $((SECONDS - start))s."
                return 0
            fi
            sleep 1
        done

        fail_and_report "autoBackup: remote host did not wake up" \
            "WOL: target $WOL_PING_IP (MAC $WOL_MAC) did not respond to ping within ${WOL_WAKEUP_TIMEOUT_SEC}s after the WOL packet. Backup aborted."
    }

    mount_remote_storage() {
        wake_remote_if_needed
        echo "Mounting network storage..."

        if [ ! -d "$LOCAL_MOUNT_POINT" ]; then
            mkdir -p "$LOCAL_MOUNT_POINT"
            echo "\"$LOCAL_MOUNT_POINT\" folder created."
        else
            echo "\"$LOCAL_MOUNT_POINT\" already exists."
        fi

        local attempt=1
        while true; do
            if mount -t cifs -o rw,file_mode=0660,dir_mode=0660,vers="$SAMBA_VERSION",username="$SAMBA_USERNAME",password="$SAMBA_PASSWORD" \
                "//$SAMBA_SERVER$SAMBA_FOLDER" "$LOCAL_MOUNT_POINT"; then
                return 0
            fi
            if (( attempt >= MOUNT_RETRIES )); then
                break
            fi
            echo "Mount failed (attempt $attempt/$MOUNT_RETRIES), retrying in ${MOUNT_RETRY_DELAY_SEC}s..."
            sleep "$MOUNT_RETRY_DELAY_SEC"
            attempt=$((attempt + 1))
        done

        fail_and_report "autoBackup: mount failed" \
            "Mount of //$SAMBA_SERVER$SAMBA_FOLDER failed after $MOUNT_RETRIES attempt(s). Backup aborted."
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
            if ! rsync -avhz --delete "$archivedFile" "$mountPoint"; then
                fail_and_report "autoBackup: upload failed" \
                    "Cannot copy $BACKUP_FILENAME to //$SAMBA_SERVER$SAMBA_FOLDER. Backup aborted."
            fi
        fi
    }

    unmount_remote_storage() {
        echo "Unmounting network storage..."
        umount "$LOCAL_MOUNT_POINT"

        if [ $? -eq 0 ]; then
            rmdir "$LOCAL_MOUNT_POINT"
        else
            report_error "autoBackup: unmount failed" "Failed to unmount $LOCAL_MOUNT_POINT" warning
        fi
    }

    # A mount left over from an interrupted run would be readable by copy_source_dirs
    ensure_remote_unmounted() {
        local attempt
        for attempt in {1..10}; do
            mountpoint -q "$LOCAL_MOUNT_POINT" || return 0
            echo "\"$LOCAL_MOUNT_POINT\" is still mounted from a previous run, unmounting (attempt $attempt/10)..."
            umount "$LOCAL_MOUNT_POINT" || sleep 1
        done

        if mountpoint -q "$LOCAL_MOUNT_POINT"; then
            fail_and_report "autoBackup: stale mount" \
                "Cannot unmount $LOCAL_MOUNT_POINT left over from a previous run, aborting."
        fi
    }

    # Only one instance may run at a time. The kernel releases the lock when the process ends,
    # so an interrupted run cannot leave a stale lock behind.
    acquire_lock() {
        exec 9>"$LOCK_FILE" || fail_and_report "autoBackup: lock failed" "Cannot open lock file: $LOCK_FILE"
        # A still running previous backup usually means it hangs, so this is worth a warning
        flock -n 9 || fail_and_report "autoBackup: already running" \
            "Another backup is already running, exiting." warning
    }

    cleanup_on_exit() {
        local rc=$?

        # Catch-all: any failure that was not reported explicitly (e.g. an unexpected exit or a signal)
        if [ $rc -ne 0 ] && ! $SENTRY_REPORTED; then
            case $rc in
                130|143) report_error "autoBackup: interrupted" "Backup was interrupted by a signal (exit $rc)." warning ;;
                *) report_error "autoBackup: failed" "Backup script exited with code $rc." ;;
            esac
        fi

        if mountpoint -q "$LOCAL_MOUNT_POINT"; then
            unmount_remote_storage
        fi
        if [ -d "$DESTINATION_DIR" ] || { [ -n "$BACKUP_FILENAME" ] && [ -f "$BACKUP_FILENAME" ]; }; then
            cleanup_local_backup
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

    # Config is loaded first (it only reads values) so that lock errors can be reported to Sentry
    load_config

    # The lock must be held before the trap is set, so an instance that did not get it touches nothing
    acquire_lock

    # Never leave the share mounted or local leftovers behind, even if the script fails or is interrupted
    trap cleanup_on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    print_start_info
    resolve_credentials
    ensure_remote_unmounted

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