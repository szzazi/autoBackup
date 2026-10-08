#!/bin/bash
#########################################################
# autoBackup - automatic backup to a Samba/CIFS share
#
# Two modes:
#   - Zip backup (default): copies the paths from SOURCE_DIRS_LIST (and optionally
#     MySQL dumps) into a temp dir, zips them and copies the zip to the share.
#   - Sync-only (--sync-only, or SYNC_ONLY_DEFAULT="true" in the config): mirrors
#     the paths directly to the share with rsync, without creating a zip.
#
# Settings come from config.conf next to this script, or from --config <path>.
# Run with --help for all options.
#########################################################


# ======================================================
# Paths and defaults
# ======================================================

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
CONFIG_FILE="$SCRIPT_DIR/config.conf"
DESTINATION_DIR="$SCRIPT_DIR/temp"       # staging dir of the zip backup
LOCAL_MOUNT_POINT="$SCRIPT_DIR/remote"   # the Samba share is mounted here
ZIP_DIR="$SCRIPT_DIR/zip"                # the zip is created here before it is copied to the share
LOCK_FILE="$SCRIPT_DIR/.autoBackup.lock"
BACKUP_FILE=""                           # absolute path of the zip, set by generate_backup_filename
WARNINGS=false                           # set if something was skipped, but the backup still completed

# Command line options
CLI_USERNAME=""
CLI_PASSWORD=""
DRY_RUN=false
TEST_SAMBA=false
SYNC_ONLY=""   # empty = not given on the CLI, so SYNC_ONLY_DEFAULT from the config decides
SYNC_PATH=""   # optional single path given after --sync-only


# ======================================================
# Command line
# ======================================================

# Prints the usage and exits with the given code (default 0)
print_help() {
    cat <<EOF
Usage: $0 [--config <path>] [--user <username>] [--pass <password>] [--dry-run] [--test-samba] [--sync-only [<path>] | --no-sync-only] [--help]

Options:
  -c, --config <path>      Path to config file
      --user <username>    Samba username (overrides config)
      --pass <password>    Samba password (overrides config)
      --dry-run            Run full flow in simulation mode (no actual copy)
      --test-samba         Only test Samba/CIFS connection (mount & unmount)
      --sync-only [<path>] Sync the specified local folder to the remote share (no zip).
                           Without <path>, every path listed in SOURCE_DIRS_LIST is synced.
      --no-sync-only       Run the normal zip backup even if SYNC_ONLY_DEFAULT="true" in the config
  -h, --help               Show this help message
EOF
    exit "${1:-0}"
}

# Fails if an option that needs a value is the last argument.
# Without this check "shift 2" would fail and the parser would loop forever.
require_value() {
    if [[ $# -lt 2 ]]; then
        echo "Error: $1 requires a value"
        print_help 1
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
                # The path is optional: only take the next argument if it is not another option
                if [[ -n "$2" && "$2" != -* ]]; then
                    SYNC_PATH="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --no-sync-only)
                SYNC_ONLY=false
                SYNC_PATH=""
                shift
                ;;
            -h|--help)
                print_help
                ;;
            *)
                echo "Unknown option: $1"
                print_help 1
                ;;
        esac
    done
}


# ======================================================
# Configuration
# ======================================================

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Config file not found: $CONFIG_FILE"
        exit 1
    fi
    source "$CONFIG_FILE"

    # Defaults for optional settings
    MYSQL_BACKUP_ENABLED="${MYSQL_BACKUP_ENABLED:-false}"
    MYSQL_USERNAME="${MYSQL_USERNAME:-}" # must be set in config
    MYSQL_PASSWORD="${MYSQL_PASSWORD:-}" # must be set in config
    MYSQL_HOST="${MYSQL_HOST:-localhost}"
    MYSQL_PORT="${MYSQL_PORT:-3306}"
    MYSQL_EXCLUDE_DBS="${MYSQL_EXCLUDE_DBS:-mysql phpmyadmin}"
    SYNC_ONLY_DEFAULT="${SYNC_ONLY_DEFAULT:-false}"

    ZIP_KEEP_MAX="${ZIP_KEEP_MAX:-10}"
    if [[ ! "$ZIP_KEEP_MAX" =~ ^[0-9]+$ ]]; then
        echo "Warning: ZIP_KEEP_MAX=\"$ZIP_KEEP_MAX\" is not a number, using 10"
        ZIP_KEEP_MAX=10
    fi
}

# CLI credentials win over the config ones
resolve_credentials() {
    SAMBA_USERNAME="${CLI_USERNAME:-$SAMBA_USERNAME}"
    SAMBA_PASSWORD="${CLI_PASSWORD:-$SAMBA_PASSWORD}"

    if [[ -z "$SAMBA_USERNAME" || -z "$SAMBA_PASSWORD" ]]; then
        echo "Error: Samba username and password must be provided via CLI or config."
        exit 1
    fi
}

# --sync-only / --no-sync-only on the CLI win, otherwise the config default decides
resolve_sync_mode() {
    if [[ -z "$SYNC_ONLY" ]]; then
        if [[ "$SYNC_ONLY_DEFAULT" == "true" ]]; then
            SYNC_ONLY=true
        else
            SYNC_ONLY=false
        fi
    fi
}


# ======================================================
# Source list helpers (shared by both modes)
# ======================================================

# Removes leading and trailing whitespace (including a Windows \r line ending)
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Reads SOURCE_DIRS_LIST into the SOURCE_PATHS array, one entry per line.
# Empty lines and "#" comments are skipped. Lines are not split on whitespace,
# so paths containing spaces stay in one piece.
read_source_list() {
    SOURCE_PATHS=()
    if [ ! -f "$SOURCE_DIRS_LIST" ]; then
        echo "Error: source list not found: $SOURCE_DIRS_LIST"
        exit 1
    fi

    local line
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        SOURCE_PATHS+=("$line")
    done < "$SOURCE_DIRS_LIST"
}

# Expands a glob pattern (e.g. /home/*/Documents) into the MATCHES array.
# A path without wildcards matches itself if it exists. MATCHES is empty if nothing exists.
expand_path() {
    mapfile -t MATCHES < <(compgen -G "$1")
}


# ======================================================
# Remote storage (Samba/CIFS)
# ======================================================

mount_remote_storage() {
    echo "Mounting network storage..."

    if [ ! -d "$LOCAL_MOUNT_POINT" ]; then
        mkdir -p "$LOCAL_MOUNT_POINT"
        echo "\"$LOCAL_MOUNT_POINT\" folder created."
    else
        echo "\"$LOCAL_MOUNT_POINT\" already exists."
    fi

    # A dry run is mounted read-only, so it cannot change anything on the share
    local mode=rw
    $DRY_RUN && mode=ro

    if ! mount -t cifs \
        -o "$mode",file_mode=0660,dir_mode=0660,vers="$SAMBA_VERSION",username="$SAMBA_USERNAME",password="$SAMBA_PASSWORD" \
        "//$SAMBA_SERVER$SAMBA_FOLDER" "$LOCAL_MOUNT_POINT"; then
        echo "Mount failed"
        exit 1
    fi
}

# Returns non-zero if the share could not be unmounted or the mount point not removed
unmount_remote_storage() {
    echo "Unmounting network storage..."
    if ! umount "$LOCAL_MOUNT_POINT"; then
        echo "Failed to unmount $LOCAL_MOUNT_POINT"
        return 1
    fi

    if ! rmdir "$LOCAL_MOUNT_POINT"; then
        echo "Unmounted, but failed to remove $LOCAL_MOUNT_POINT"
        return 1
    fi
}

# A mount left over from an interrupted run would be read by copy_source_dirs
# (backing up the share into itself), so it is removed before anything else runs
ensure_remote_unmounted() {
    local attempt
    for attempt in {1..10}; do
        mountpoint -q "$LOCAL_MOUNT_POINT" || return 0
        echo "\"$LOCAL_MOUNT_POINT\" is still mounted from a previous run, unmounting (attempt $attempt/10)..."
        umount "$LOCAL_MOUNT_POINT" || sleep 1
    done

    if mountpoint -q "$LOCAL_MOUNT_POINT"; then
        echo "Cannot unmount $LOCAL_MOUNT_POINT, aborting."
        exit 1
    fi
}

# --test-samba: only checks that the share can be mounted and unmounted
run_samba_test() {
    echo "Testing Samba/CIFS connection..."
    mount_remote_storage
    unmount_remote_storage || return 1
    echo "Samba/CIFS connection test completed."
}


# ======================================================
# Sync-only mode
# ======================================================

# Syncs SYNC_PATH, or every path of SOURCE_DIRS_LIST, to the share.
# Returns non-zero if any source was missing or failed to sync, so a broken source
# (and the stale copy it leaves on the share) is never reported as a successful backup.
sync_specified_folder() {
    local patterns=()
    if [[ -n "$SYNC_PATH" ]]; then
        patterns=("$SYNC_PATH")
    else
        read_source_list
        patterns=("${SOURCE_PATHS[@]}")
    fi

    if [ ${#patterns[@]} -eq 0 ]; then
        echo "No paths to sync."
        return 0
    fi

    mount_remote_storage

    local failed=0 pattern path
    for pattern in "${patterns[@]}"; do
        expand_path "$pattern"
        if [ ${#MATCHES[@]} -eq 0 ]; then
            echo "Error: source path not found: $pattern"
            failed=1
            continue
        fi

        for path in "${MATCHES[@]}"; do
            sync_path_to_remote "$path" || failed=1
        done
        remove_vanished_matches "$pattern" || failed=1
    done

    unmount_remote_storage || failed=1
    return $failed
}

# The matches of a glob pattern are synced one by one, so a match deleted locally
# (e.g. /data/b of /data/*) would stay on the share forever. This expands the pattern
# on the share too, and deletes every match that no longer exists locally.
#   - Only absolute patterns without "." / ".." parts: for them a match on the share
#     maps back to exactly one local path.
#   - Matches at the top level of the share are never deleted: the zips of the ZIP mode live there.
#   - A pattern with no local match at all is reported as an error by the caller and
#     not cleaned up, so e.g. an unmounted disk does not wipe its copy on the share.
remove_vanished_matches() {
    local pattern="$1"
    [[ "$pattern" == *[\*\?\[]* ]] || return 0
    [ ${#MATCHES[@]} -eq 0 ] && return 0
    if [[ "$pattern" != /* || "$pattern/" == */./* || "$pattern/" == */../* ]]; then
        echo "Warning: not an absolute path, stale matches of $pattern are not removed from the share"
        return 0
    fi

    # Leading slashes removed, the pattern is expanded relative to the mount point
    local rel_pattern="${pattern#"${pattern%%[!/]*}"}"
    local remote_matches=()
    mapfile -t remote_matches < <(cd "$LOCAL_MOUNT_POINT" && compgen -G "$rel_pattern")

    local failed=0 rel
    for rel in "${remote_matches[@]}"; do
        [[ "$rel" == */* ]] || continue
        [ -e "/$rel" ] || [ -L "/$rel" ] && continue

        if $DRY_RUN; then
            echo "[Dry-run] Would delete from the share (no longer exists locally): $rel"
        else
            echo "Deleting from the share (no longer exists locally): $rel"
            rm -rf -- "${LOCAL_MOUNT_POINT:?}/$rel" || { echo "Error: cannot delete $rel"; failed=1; }
        fi
    done
    return $failed
}

# Mirrors one local file or folder to the same absolute path under the share,
# e.g. /var/www -> <share>/var/www/. Files deleted locally are deleted on the share too.
#
# Two forms of the path are used:
#   abspath   - "." and ".." resolved, symlinks kept: the destination is built from this,
#               so it is always the path as written in the source list
#   real_path - symlinks resolved too: this is what rsync actually reads, so the checks
#               against the mount point use it (a symlink like /data/app -> /opt/autoBackup
#               would otherwise smuggle the mounted share into the source)
# Symlinks deeper inside a source are copied as links (rsync -a without -L), not followed,
# so only the source path itself needs these checks.
sync_path_to_remote() {
    local abspath real_path real_prefix mount_real relpath src dest
    local rsync_opts=(-avh --delete)
    $DRY_RUN && rsync_opts+=(-n)

    if ! abspath=$(realpath -s -e -- "$1") || ! real_path=$(realpath -e -- "$1"); then
        echo "Error: cannot resolve path: $1"
        return 1
    fi
    real_prefix="${real_path%/}/"
    mount_real=$(realpath -m -- "$LOCAL_MOUNT_POINT")

    # The source is (or points into) the share itself
    if [[ "$real_prefix" == "$mount_real/"* ]]; then
        echo "Error: refusing to sync a path inside the mount point: $abspath -> $real_path"
        return 1
    fi

    relpath="${abspath#/}"
    if [ -d "$abspath" ]; then
        # The trailing slash makes rsync copy the folder's content into dest
        # (and follow the source itself if it is a symlink to a folder)
        src="${abspath%/}/"
        dest="$LOCAL_MOUNT_POINT/$relpath/"
        # A source that contains the mount point (e.g. "/") would copy the share into itself.
        # The exclude is relative to the folder rsync really reads, hence real_prefix.
        if [[ "$mount_real" == "$real_prefix"* ]]; then
            rsync_opts+=(--exclude="/${mount_real#"$real_prefix"}/")
        fi
        # Syncing "/" targets the share root, where the ZIP mode keeps its archives.
        # They do not exist locally, so --delete would remove them: the P (protect) rule
        # keeps them on the share. Like the mount exclude, it must precede the user's rules.
        if [[ -z "$relpath" ]]; then
            rsync_opts+=(--filter="P /*.zip")
        fi
    else
        src="$abspath"
        dest="$(dirname "$LOCAL_MOUNT_POINT/$relpath")/"
    fi
    # rsync uses the first matching rule, so the user's list comes after the mount exclude:
    # an include ("+ ...") rule in it can never pull the mounted share back in
    rsync_opts+=(--exclude-from="$EXCLUDE_LIST")

    echo "Syncing $src -> $dest"

    # rsync only creates the last folder of dest, so the parents are created first.
    # Skipped in dry-run: the share is read-only there, and rsync -n reports missing folders by itself.
    if ! $DRY_RUN && ! mkdir -p "$dest"; then
        echo "Error: cannot create $dest"
        return 1
    fi

    if ! rsync "${rsync_opts[@]}" "$src" "$dest"; then
        echo "Error: rsync failed for $src"
        return 1
    fi
}


# ======================================================
# Zip backup mode
# ======================================================

change_to_program_dir() {
    cd "$PROGRAM_DIR" || { echo "Cannot change directory to $PROGRAM_DIR"; exit 1; }
}

# Copies every path of SOURCE_DIRS_LIST into DESTINATION_DIR, keeping the full path (--relative).
# A path that cannot be copied (e.g. a read or permission error) is reported and skipped,
# the other paths are still copied. Returns non-zero if that happened, so the run can end
# "with warnings". A missing source and rsync code 24 (files vanished while copying,
# normal on a live system) only print a warning.
copy_source_dirs() {
    echo "Copying source directories..."
    mkdir -p "$DESTINATION_DIR" || return 1
    read_source_list

    local failed=0 pattern path rc
    for pattern in "${SOURCE_PATHS[@]}"; do
        expand_path "$pattern"
        if [ ${#MATCHES[@]} -eq 0 ]; then
            echo "Warning: source path not found, skipped: $pattern"
            continue
        fi

        for path in "${MATCHES[@]}"; do
            # The mount point, the temp dir and the zip dir are always excluded, regardless of the
            # exclude list, so neither the share nor earlier backups end up in this backup.
            # They come before --exclude-from: rsync uses the first matching rule.
            rsync -avr --exclude="$LOCAL_MOUNT_POINT" --exclude="$DESTINATION_DIR" --exclude="$ZIP_DIR" \
                --exclude-from="$EXCLUDE_LIST" --relative "$path" "$DESTINATION_DIR"
            rc=$?
            if [ $rc -eq 24 ]; then
                echo "Warning: some files of $path vanished while copying"
            elif [ $rc -ne 0 ]; then
                echo "Warning: copying $path failed (rsync exit code $rc), continuing with the rest"
                failed=1
            fi
        done
    done
    return $failed
}

# Common connection arguments of the mysql and mysqldump commands
set_mysql_args() {
    MYSQL_ARGS=(-u"$MYSQL_USERNAME" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT")
}

# Dry-run only: shows whether the MySQL user has every privilege the dump needs
check_mysql_privileges() {
    echo "Checking MySQL user privileges for export..."
    local privs priv
    privs=$(mysql "${MYSQL_ARGS[@]}" -e "SHOW GRANTS FOR CURRENT_USER();" 2>/dev/null)
    for priv in SELECT "SHOW VIEW" EVENT "LOCK TABLES"; do
        if echo "$privs" | grep -iq "$priv"; then
            echo "  ✅ $priv privilege: OK"
        else
            echo "  ❌ $priv privilege: MISSING"
        fi
    done
}

# Dumps every database (except MYSQL_EXCLUDE_DBS) into DESTINATION_DIR/mysql_dump/<db>/:
# schema.sql with the structure, routines and events, and one <table>.data.sql per table
dump_mysql_databases() {
    set_mysql_args

    if $DRY_RUN; then
        check_mysql_privileges
        return
    fi

    echo "Dumping MySQL databases..."
    local dump_dir="$DESTINATION_DIR/mysql_dump"
    mkdir -p "$dump_dir"

    # Excluded names as an exact-match regex, e.g. "mysql phpmyadmin" -> "mysql|phpmyadmin"
    local exclude_regex
    exclude_regex=$(echo $MYSQL_EXCLUDE_DBS | sed 's/ /|/g')

    local dbs tables db tbl db_dir
    # -N leaves out the column header
    mapfile -t dbs < <(mysql "${MYSQL_ARGS[@]}" -N -e "SHOW DATABASES;" | grep -vxE "$exclude_regex")

    for db in "${dbs[@]}"; do
        echo "  Exporting database: $db"
        db_dir="$dump_dir/$db"
        mkdir -p "$db_dir"

        mysqldump "${MYSQL_ARGS[@]}" --no-data --routines --events "$db" > "$db_dir/schema.sql"

        mapfile -t tables < <(mysql "${MYSQL_ARGS[@]}" -N -D "$db" -e "SHOW TABLES;")
        for tbl in "${tables[@]}"; do
            echo "    Table: $tbl"
            mysqldump "${MYSQL_ARGS[@]}" --no-create-info "$db" "$tbl" > "$db_dir/${tbl}.data.sql"
        done
    done
}

# The zip is named <timestamp>-<host>.zip.
# A real backup goes to ZIP_DIR, where it waits until it reaches the share.
# The empty zip of a dry run goes to the temp dir, so it can never be uploaded by a later real run.
generate_backup_filename() {
    local host timestamp dir="$ZIP_DIR"
    host=$(hostname | tr '.' '_')
    timestamp=$(date +"%Y%m%d_%H%M%S")
    $DRY_RUN && dir="$DESTINATION_DIR"
    BACKUP_FILE="$dir/${timestamp}-${host}.zip"
}

# Returns non-zero if the zip could not be created.
# The zip is written as <name>.zip.part and only renamed to .zip when it is complete,
# so a run killed while zipping never leaves a broken .zip behind to be uploaded later.
compress_backup() {
    if $DRY_RUN; then
        echo "Creating empty ZIP file for simulation: $BACKUP_FILE"
        mkdir -p "$(dirname "$BACKUP_FILE")"
        zip -r "$BACKUP_FILE" --filesync -q /dev/null
        return
    fi

    echo "Compressing backup to: $BACKUP_FILE"
    mkdir -p "$ZIP_DIR"
    if ! (cd "$DESTINATION_DIR" && zip -r "$BACKUP_FILE.part" .) \
        || ! mv -- "$BACKUP_FILE.part" "$BACKUP_FILE"; then
        echo "Error: creating $BACKUP_FILE failed"
        rm -f -- "$BACKUP_FILE.part"
        return 1
    fi
}

# Keeps at most ZIP_KEEP_MAX zips in ZIP_DIR (0 = no limit), so zips piling up while
# the share is offline cannot fill the disk. The oldest ones are deleted, they never reach the share.
# The names start with a timestamp, so sorting them by name sorts them by age.
prune_old_zips() {
    [ "$ZIP_KEEP_MAX" -eq 0 ] && return 0

    local zips=()
    mapfile -t zips < <(compgen -G "$ZIP_DIR/*.zip" | sort)

    local excess=$(( ${#zips[@]} - ZIP_KEEP_MAX ))
    [ $excess -le 0 ] && return 0

    local zip_file
    for zip_file in "${zips[@]:0:excess}"; do
        if $DRY_RUN; then
            echo "[Dry-run] Would delete old zip (ZIP_KEEP_MAX=$ZIP_KEEP_MAX): $zip_file"
        else
            echo "Warning: deleting old zip that never reached the share (ZIP_KEEP_MAX=$ZIP_KEEP_MAX): $zip_file"
            rm -f -- "$zip_file"
        fi
    done
}

# Uploads every zip waiting in ZIP_DIR, oldest first: the one of this run, and the ones
# of earlier runs whose upload failed or was interrupted. Each zip is deleted locally
# only after it reached the share, the others stay for the next run.
# Returns non-zero if any zip could not be uploaded.
copy_backup_to_remote() {
    echo "Preparing to sync backup files to remote..."

    local zips=()
    mapfile -t zips < <(compgen -G "$ZIP_DIR/*.zip" | sort)
    # The dry-run zip is not in ZIP_DIR, see generate_backup_filename
    $DRY_RUN && zips+=("$BACKUP_FILE")

    if [ ${#zips[@]} -eq 0 ]; then
        echo "No zip files to upload."
        return 0
    fi

    local rsync_opts=(-avhz)
    if $DRY_RUN; then
        echo -e "\n[Dry-run mode enabled] Simulating rsync:"
        rsync_opts+=(-n)
    else
        echo -e "\nPerforming actual sync:"
    fi

    local failed=0 zip_file
    for zip_file in "${zips[@]}"; do
        if [[ "$zip_file" != "$BACKUP_FILE" ]]; then
            echo "Uploading zip left over from an earlier run: $zip_file"
        fi

        if ! rsync "${rsync_opts[@]}" "$zip_file" "$LOCAL_MOUNT_POINT"; then
            echo "Error: copying $zip_file to the share failed, it is kept for the next run"
            failed=1
            continue
        fi

        $DRY_RUN || rm -f -- "$zip_file"
    done
    return $failed
}

# The full zip backup flow. Returns non-zero if the zip could not be created,
# any zip did not reach the share, or the share could not be unmounted.
# Zips that did not reach the share stay in ZIP_DIR, everything else is cleaned up.
run_zip_backup() {
    local failed=0

    change_to_program_dir
    # The backup runs unattended from cron, so a path that cannot be copied does not stop it:
    # everything else is still zipped and uploaded, and the run ends "with warnings"
    if ! copy_source_dirs; then
        echo "Warning: some sources could not be copied, the zip of this run is incomplete"
        WARNINGS=true
    fi
    if [ "$MYSQL_BACKUP_ENABLED" = "true" ]; then
        dump_mysql_databases
    fi
    generate_backup_filename
    # Even if this zip fails, the leftovers of earlier runs are still uploaded
    compress_backup || failed=1
    prune_old_zips

    mount_remote_storage
    copy_backup_to_remote || failed=1
    unmount_remote_storage || failed=1
    cleanup_local_backup
    return $failed
}


# ======================================================
# Locking and cleanup
# ======================================================

# Only one instance may run at a time. The kernel releases the lock when the process ends,
# so an interrupted run cannot leave a stale lock behind.
acquire_lock() {
    exec 9>"$LOCK_FILE" || { echo "Cannot open lock file: $LOCK_FILE"; exit 1; }
    flock -n 9 || { echo "Another backup is already running, exiting."; exit 1; }
}

# A run killed without the trap firing (SIGKILL, power loss) can leave a populated temp dir,
# and rsync without --delete would carry its stale files into this backup
clear_stale_destination_dir() {
    if [ -d "$DESTINATION_DIR" ] && [ -n "$(ls -A "$DESTINATION_DIR")" ]; then
        echo "\"$DESTINATION_DIR\" contains leftovers from a previous run, clearing it..."
        rm -rf -- "${DESTINATION_DIR:?}"/* "${DESTINATION_DIR:?}"/.[!.]* "${DESTINATION_DIR:?}"/..?*
    fi
}

# A zip that was still being written when a run was killed is incomplete, it is never uploaded
clear_partial_zips() {
    local part
    for part in "$ZIP_DIR"/*.zip.part; do
        [ -e "$part" ] || continue
        echo "Removing incomplete zip from a previous run: $part"
        rm -f -- "$part"
    done
}

# Removes the temp dir (with the dry-run zip) and an unfinished zip.
# Complete zips in ZIP_DIR are kept: they are uploaded by copy_backup_to_remote.
cleanup_local_backup() {
    echo "Cleaning up local files..."
    rm -rf "$DESTINATION_DIR"
    [ -n "$BACKUP_FILE" ] && rm -f -- "$BACKUP_FILE.part"
}

# EXIT trap: never leave the share mounted or local leftovers behind,
# even if the script fails or is interrupted
cleanup_on_exit() {
    if mountpoint -q "$LOCAL_MOUNT_POINT"; then
        unmount_remote_storage
    elif [ -d "$LOCAL_MOUNT_POINT" ]; then
        # Left behind by a failed mount; rmdir only removes it if it is empty
        rmdir "$LOCAL_MOUNT_POINT" 2>/dev/null
    fi

    if [ -d "$DESTINATION_DIR" ] || { [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE.part" ]; }; then
        cleanup_local_backup
    fi
}


# ======================================================
# Output
# ======================================================

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

# $1: optional status text, e.g. " with errors"
print_done() {
    local status="$1"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "=============================================="
    echo "Backup process completed${status} at ${timestamp}"
    echo "=============================================="
}


# ======================================================
# Main
# ======================================================

parse_arguments "$@"

# The lock must be held before the trap is set, so an instance that did not get it touches nothing
acquire_lock
clear_stale_destination_dir
clear_partial_zips

trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

print_start_info
load_config
resolve_credentials
ensure_remote_unmounted

# An explicit --test-samba is checked first, so SYNC_ONLY_DEFAULT cannot turn it into a sync
if $TEST_SAMBA; then
    run_samba_test
    exit $?
fi

resolve_sync_mode

status=0
if $SYNC_ONLY; then
    echo "Running in sync-only mode..."
    sync_specified_folder || status=1
else
    run_zip_backup || status=1
fi

if [ $status -ne 0 ]; then
    print_done " with errors"
    exit 1
fi

# Warnings do not fail the run: the backup was made, only some sources are missing from it
if $WARNINGS; then
    print_done " with warnings"
else
    print_done
fi
exit 0
