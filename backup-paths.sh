#!/usr/bin/env bash
# ==============================================================================
# DABR — Docker Automated Backup with Rsync
# Version: 1.0
# Platform: Debian / Ubuntu
# https://github.com/kayaman78/dabr
#
# Hardlinked snapshots of host paths: bind mounts, config trees, application
# data directories — everything that is neither a database nor a named volume.
# ==============================================================================

# --- GENERAL SETTINGS ---
DRY_RUN="off"                            # [on/off] — simulate without writing anything

# Paths to back up. Each one becomes a directory inside the snapshot, named
# after its basename. Two paths with the same basename would collide, and the
# script refuses to start if that happens.
BACKUP_PATHS=(
    "/srv/docker"
)

# --- DESTINATION ---
DEST_MODE="local"                        # [local/remote]
DEST_BASE="/mnt/backup/myserver"         # snapshot root (daily/ and weekly/ live here)

# Used only when DEST_MODE="remote"
REMOTE_USER="backup"
REMOTE_HOST="192.168.1.10"
REMOTE_SSH_PORT="22"
SSH_KEY=""                               # empty = default ssh key resolution

# --- RETENTION ---
DAILY_RETENTION=7                        # daily snapshots to keep
WEEKLY_RETENTION=4                       # weekly snapshots to keep
WEEKLY_DAY=1                             # 1=Monday … 7=Sunday; a weekly copy is
                                         # made on this day, hardlinked from the daily

# --- VERIFY ---
SIZE_DROP_WARN=20                        # % size drop vs previous snapshot that warns
FILE_DROP_WARN=20                        # % file count drop vs previous snapshot that warns

# Excluded patterns (rsync syntax).
#
# NOTE ON DATABASES: sockets, pids and locks are useless in a snapshot, but
# database files are NOT excluded here. Copying a live database with rsync
# gives an inconsistent copy — that is what KDD (MySQL/PostgreSQL/MongoDB) and
# DABS (SQLite) are for. DABR copies them only so the snapshot is a complete
# picture of the filesystem: never restore a database from here if a proper
# dump exists.
EXCLUDE_PATTERNS=(
    "*.sock" "*.pid" "*.lock"
    "*/tmp/*" "*/.tmp/*"
    "*/__pycache__" "*/__pycache__/*"
    "*.log" "*.log.*"
)

LOG_DIR="/var/log/dabr"

# --- SMTP SETTINGS ---
SMTP_SERVER="smtp.example.com"
SMTP_PORT="587"         # 25 = plain relay | 465 = SMTPS | 587 = STARTTLS
SMTP_USER=""            # Leave empty for unauthenticated relay
SMTP_PASS=""

# --- EMAIL SETTINGS ---
MAIL_ENABLED="true"
EMAIL_FROM="dabr@example.com"
EMAIL_TO="admin@example.com"
EMAIL_SUBJECT_PREFIX="Path Backup"

# Telegram (optional)
TELEGRAM_ENABLED="false"
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""

# ntfy (optional)
NTFY_ENABLED="false"
NTFY_URL=""             # e.g. https://ntfy.sh or your self-hosted instance
NTFY_TOPIC=""           # e.g. dabr-backups

# Attach log to push notifications
NOTIFY_ATTACH_LOG="false"

# ==============================================================================
# INITIAL CHECKS
# ==============================================================================
# No `set -e` on purpose. This script counts warnings and errors and reports
# them; with errexit a single `((VAR++))` returning 0 — which bash treats as
# exit status 1 — would kill the run silently, before any notification is sent.

command -v rsync &>/dev/null || { echo "FATAL: 'rsync' not found." >&2; exit 1; }
[ "$DEST_MODE" = "remote" ] && { command -v ssh &>/dev/null || { echo "FATAL: 'ssh' not found." >&2; exit 1; }; }

mkdir -p "$LOG_DIR" 2>/dev/null || { echo "FATAL: cannot create $LOG_DIR" >&2; exit 1; }
LOG_FILE="${LOG_DIR}/dabr_$(date +%Y%m%d_%H%M%S).log"
touch "$LOG_FILE" || { echo "FATAL: cannot write $LOG_FILE" >&2; exit 1; }

# Two paths with the same basename would write into the same snapshot directory
# and the second would overwrite the first. Caught here, not at 3am.
declare -A _SEEN_BASE
for p in "${BACKUP_PATHS[@]}"; do
    b=$(basename "$p")
    if [ -n "${_SEEN_BASE[$b]:-}" ]; then
        echo "FATAL: '$p' and '${_SEEN_BASE[$b]}' share the basename '$b'." >&2
        echo "They would overwrite each other inside the snapshot." >&2
        exit 1
    fi
    _SEEN_BASE[$b]="$p"
done

# ==============================================================================
# WORKING VARIABLES
# ==============================================================================
START_TIME=$(date +%s)
SNAP_NAME=$(date +%Y%m%d-%H%M%S)
DATE_LABEL=$(date "+%Y-%m-%d %H:%M")
HOSTNAME=$(hostname)

ERRORS=0
WARNINGS=0
TABLE_ROWS=""
GLOBAL_STATUS="OK"
COUNT_OK=0
COUNT_ERR=0
COUNT_WARN=0

# ==============================================================================
# LOGGING
# ==============================================================================
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a "$LOG_FILE"
}
log_info()    { log "INFO"    "$@"; }
log_warn()    { log "WARN"    "$@"; WARNINGS=$((WARNINGS + 1)); }
log_error()   { log "ERROR"   "$@"; ERRORS=$((ERRORS + 1)); }
log_success() { log "SUCCESS" "$@"; }

# ==============================================================================
# REMOTE / LOCAL ABSTRACTION
# One pair of helpers so the rest of the script never branches on DEST_MODE.
# ==============================================================================
ssh_opts() {
    local opts=(-p "$REMOTE_SSH_PORT" -o ConnectTimeout=10 -o BatchMode=yes)
    [ -n "$SSH_KEY" ] && opts+=(-i "$SSH_KEY")
    printf '%s\n' "${opts[@]}"
}

# Runs a command where the snapshots live.
dest_run() {
    if [ "$DEST_MODE" = "remote" ]; then
        mapfile -t OPTS < <(ssh_opts)
        ssh "${OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "$@"
    else
        bash -c "$*"
    fi
}

# The rsync target prefix for a given snapshot subpath.
dest_target() {
    if [ "$DEST_MODE" = "remote" ]; then
        echo "${REMOTE_USER}@${REMOTE_HOST}:$1"
    else
        echo "$1"
    fi
}

check_destination() {
    if [ "$DEST_MODE" = "remote" ]; then
        mapfile -t OPTS < <(ssh_opts)
        ssh "${OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "exit" 2>>"$LOG_FILE" || {
            log_error "SSH to ${REMOTE_HOST} failed — nothing was written."
            return 1
        }
    fi
    dest_run "mkdir -p '${DEST_BASE}/daily' '${DEST_BASE}/weekly'" >/dev/null 2>&1 || {
        log_error "Cannot create ${DEST_BASE}/{daily,weekly}"
        return 1
    }
    return 0
}

# ==============================================================================
# SNAPSHOT
# ==============================================================================
find_latest_snapshot() {
    dest_run "ls -1 '${DEST_BASE}/daily' 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort -r | head -n1" 2>/dev/null
}

# Size in bytes and file count of a snapshot's subdirectory, for the size trend.
snapshot_stats() {
    local dir="$1"
    dest_run "if [ -d '$dir' ]; then du -sb '$dir' 2>/dev/null | cut -f1; find '$dir' -type f 2>/dev/null | wc -l; else echo 0; echo 0; fi" 2>/dev/null
}

backup_one_path() {
    local src="$1" latest="$2"
    local name; name=$(basename "$src")
    local dest_dir="${DEST_BASE}/daily/${SNAP_NAME}/${name}"

    if [ ! -d "$src" ]; then
        log_error "Source does not exist: $src"
        add_row "$name" "—" "❌ MISSING" "—"
        COUNT_ERR=$((COUNT_ERR + 1))
        GLOBAL_STATUS="ERROR"
        return 1
    fi

    log_info "rsync: $src → ${dest_dir}"

    local opts=(-aHAXx --numeric-ids --delete --partial --timeout=600 --stats)
    [ "$DRY_RUN" = "on" ] && opts+=(--dry-run)

    # Hardlink unchanged files against the previous snapshot. The path is
    # relative to the destination directory: ../../<snapshot>/<name>
    if [ -n "$latest" ]; then
        opts+=(--link-dest="../../${latest}/${name}")
    fi
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        opts+=("--exclude=${pattern}")
    done
    if [ "$DEST_MODE" = "remote" ]; then
        mapfile -t OPTS < <(ssh_opts)
        opts+=(-e "ssh ${OPTS[*]}")
    fi

    # Only outside dry-run: rsync --dry-run writes nothing, but this mkdir
    # would, leaving an empty snapshot directory behind that retention then
    # counts as a real one.
    [ "$DRY_RUN" = "off" ] && dest_run "mkdir -p '$dest_dir'" >/dev/null 2>&1

    local rsync_out rc
    rsync_out=$(rsync "${opts[@]}" "${src}/" "$(dest_target "${dest_dir}/")" 2>&1)
    rc=$?
    echo "$rsync_out" >> "$LOG_FILE"

    # 23/24 = files vanished or changed while copying. Normal on a live system,
    # not a failure — but worth surfacing rather than hiding.
    case $rc in
        0)  log_success "$name copied cleanly" ;;
        23) log_warn "$name: some files could not be transferred (rsync 23)" ;;
        24) log_warn "$name: some files vanished during transfer (rsync 24)" ;;
        *)  log_error "$name: rsync failed with code $rc"
            add_row "$name" "—" "❌ ERROR ($rc)" "—"
            COUNT_ERR=$((COUNT_ERR + 1))
            GLOBAL_STATUS="ERROR"
            return 1 ;;
    esac

    verify_one_path "$name" "$dest_dir" "$latest" "$rc"
    return 0
}

# ==============================================================================
# VERIFY
# Three checks, same shape as the other tools in the ecosystem:
#   1. rsync exit code (already handled above — 0/23/24 reach here)
#   2. the snapshot directory exists and is not empty
#   3. size and file-count trend vs the previous snapshot
# ==============================================================================
verify_one_path() {
    local name="$1" dest_dir="$2" latest="$3" rc="$4"
    local status="✅ OK" verify="✅ OK"

    if [ "$DRY_RUN" = "on" ]; then
        add_row "$name" "—" "⚠️ DRY-RUN" "⚠️ DRY-RUN"
        return 0
    fi

    mapfile -t stats < <(snapshot_stats "$dest_dir")
    local size="${stats[0]:-0}" files="${stats[1]:-0}"

    if [ "$files" -eq 0 ]; then
        log_error "$name: snapshot is empty"
        add_row "$name" "0" "✅ OK" "❌ FAIL: empty"
        COUNT_ERR=$((COUNT_ERR + 1))
        GLOBAL_STATUS="ERROR"
        return 1
    fi

    [ "$rc" -ne 0 ] && status="⚠️ WARN (rsync $rc)"

    if [ -n "$latest" ]; then
        mapfile -t prev < <(snapshot_stats "${DEST_BASE}/daily/${latest}/${name}")
        local psize="${prev[0]:-0}" pfiles="${prev[1]:-0}"
        if [ "$psize" -gt 0 ] && [ "$size" -lt $(( psize * (100 - SIZE_DROP_WARN) / 100 )) ]; then
            log_warn "$name: size dropped $(human "$psize") → $(human "$size")"
            verify="⚠️ WARN: size $(human "$psize")→$(human "$size")"
        elif [ "$pfiles" -gt 0 ] && [ "$files" -lt $(( pfiles * (100 - FILE_DROP_WARN) / 100 )) ]; then
            log_warn "$name: file count dropped ${pfiles} → ${files}"
            verify="⚠️ WARN: files ${pfiles}→${files}"
        fi
    fi

    case "$verify$status" in
        *WARN*) COUNT_WARN=$((COUNT_WARN + 1)); [ "$GLOBAL_STATUS" = "OK" ] && GLOBAL_STATUS="WARN" ;;
        *)      COUNT_OK=$((COUNT_OK + 1)) ;;
    esac

    add_row "$name" "$(human "$size") / ${files} files" "$status" "$verify"
    return 0
}

human() {
    local b="${1:-0}"
    if   [ "$b" -ge 1073741824 ]; then echo "$(( b / 1073741824 ))G"
    elif [ "$b" -ge 1048576 ];    then echo "$(( b / 1048576 ))M"
    elif [ "$b" -ge 1024 ];       then echo "$(( b / 1024 ))K"
    else echo "${b}B"; fi
}

add_row() {
    local bg="#d4edda"
    [[ "$3$4" == *WARN* ]] && bg="#fff3cd"
    [[ "$3$4" == *FAIL* || "$3$4" == *ERROR* || "$3$4" == *MISSING* ]] && bg="#f8d7da"
    TABLE_ROWS+="
        <tr>
            <td style='padding:8px;border:1px solid #ddd;'>$1</td>
            <td style='padding:8px;border:1px solid #ddd;'>$2</td>
            <td style='padding:8px;border:1px solid #ddd;text-align:center;background:${bg};'>$3</td>
            <td style='padding:8px;border:1px solid #ddd;text-align:center;background:${bg};'>$4</td>
        </tr>"
}

# ==============================================================================
# WEEKLY + RETENTION
# ==============================================================================
create_weekly() {
    [ "$DRY_RUN" = "on" ] && { log_info "Weekly copy skipped (dry-run)"; return 0; }
    [ "$(date +%u)" != "$WEEKLY_DAY" ] && return 0

    log_info "Weekly day: hardlinking snapshot into weekly/"
    # cp -al: hardlinks, so a weekly copy costs almost nothing.
    dest_run "cp -al '${DEST_BASE}/daily/${SNAP_NAME}' '${DEST_BASE}/weekly/${SNAP_NAME}'" \
        >/dev/null 2>>"$LOG_FILE" || log_warn "Weekly copy failed"
}

# Keeps the N most recent snapshots. Calendar-independent: if the job has been
# paused longer than the retention, existing snapshots survive until newer ones
# replace them, instead of all being deleted at once.
rotate() {
    local kind="$1" keep="$2"
    local n=$((keep + 1))
    local victims
    victims=$(dest_run "ls -1 '${DEST_BASE}/${kind}' 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort -r | tail -n +${n}" 2>/dev/null)
    [ -z "$victims" ] && { log_info "Retention ${kind}: nothing to remove"; return 0; }

    while IFS= read -r v; do
        [ -z "$v" ] && continue
        # Guard: only ever delete a name matching the snapshot pattern, and
        # never the one just written.
        [[ "$v" =~ ^[0-9]{8}-[0-9]{6}$ ]] || { log_warn "Retention: refusing to remove '$v'"; continue; }
        [ "$v" = "$SNAP_NAME" ] && continue
        if [ "$DRY_RUN" = "on" ]; then
            log_info "[DRY-RUN] would remove ${kind}/${v}"
        else
            log_info "Removing ${kind}/${v}"
            dest_run "rm -rf '${DEST_BASE}/${kind}/${v}'" >/dev/null 2>>"$LOG_FILE" \
                || log_warn "Could not remove ${kind}/${v}"
        fi
    done <<< "$victims"
}

rotate_logs() {
    [ "$DRY_RUN" = "on" ] && return 0
    find "$LOG_DIR" -maxdepth 1 -type f -name 'dabr_*.log' -printf '%T@\t%p\n' 2>/dev/null \
        | sort -rn | tail -n +$((DAILY_RETENTION + 1)) | cut -f2- \
        | while IFS= read -r old; do rm -f -- "$old"; done
}

# ==============================================================================
# NOTIFICATIONS
# ==============================================================================
build_text_summary() {
    if [ "$DRY_RUN" = "on" ]; then
        printf "🔍 DABR DRY-RUN — %s | %s\n%d path(s) scanned. Nothing written." \
            "$HOSTNAME" "$DATE_LABEL" "${#BACKUP_PATHS[@]}"
        return
    fi
    local icon="✅"
    [ $COUNT_WARN -gt 0 ] && icon="⚠️"
    [ $COUNT_ERR  -gt 0 ] && icon="❌"
    printf "%s DABR Backup — %s | %s\nPaths %s✅ %s⚠️ %s❌ (total: %s)\nSnapshot: %s" \
        "$icon" "$HOSTNAME" "$DATE_LABEL" \
        "$COUNT_OK" "$COUNT_WARN" "$COUNT_ERR" "${#BACKUP_PATHS[@]}" "$SNAP_NAME"
}

send_telegram() {
    [ "$TELEGRAM_ENABLED" != "true" ] && return 0
    if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        log_warn "Telegram enabled but TOKEN or CHAT_ID missing — skipping"; return 1
    fi
    local text api; text=$(build_text_summary); api="https://api.telegram.org/bot${TELEGRAM_TOKEN}"
    if [ "$NOTIFY_ATTACH_LOG" = "true" ] && [ -f "$LOG_FILE" ]; then
        curl -sf -X POST "${api}/sendDocument" -F "chat_id=${TELEGRAM_CHAT_ID}" \
            -F "caption=${text}" -F "document=@${LOG_FILE}" >/dev/null 2>&1 \
            && log_info "Telegram: sent with log" || log_warn "Telegram delivery failed"
    else
        curl -sf -X POST "${api}/sendMessage" -H "Content-Type: application/json" \
            -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"${text}\"}" >/dev/null 2>&1 \
            && log_info "Telegram: sent" || log_warn "Telegram delivery failed"
    fi
}

send_ntfy() {
    [ "$NTFY_ENABLED" != "true" ] && return 0
    if [ -z "$NTFY_URL" ] || [ -z "$NTFY_TOPIC" ]; then
        log_warn "ntfy enabled but URL or TOPIC missing — skipping"; return 1
    fi
    local text priority=3; text=$(build_text_summary)
    [ $COUNT_ERR -gt 0 ] && priority=5
    if [ "$NOTIFY_ATTACH_LOG" = "true" ] && [ -f "$LOG_FILE" ]; then
        curl -sf -X PUT "${NTFY_URL}/${NTFY_TOPIC}" -H "Title: DABR Backup — ${HOSTNAME}" \
            -H "Priority: ${priority}" -H "Filename: $(basename "$LOG_FILE")" \
            --data-binary "@${LOG_FILE}" >/dev/null 2>&1 \
            && log_info "ntfy: sent with log" || log_warn "ntfy delivery failed"
    else
        curl -sf -X POST "${NTFY_URL}/${NTFY_TOPIC}" -H "Title: DABR Backup — ${HOSTNAME}" \
            -H "Priority: ${priority}" -d "$text" >/dev/null 2>&1 \
            && log_info "ntfy: sent" || log_warn "ntfy delivery failed"
    fi
}

send_email() {
    [ "$MAIL_ENABLED" != "true" ] && return 0
    command -v swaks &>/dev/null || { log_warn "swaks not found — email skipped"; return 1; }

    local icon="✅"
    [ "$GLOBAL_STATUS" = "WARN" ]  && icon="⚠️"
    [ "$GLOBAL_STATUS" = "ERROR" ] && icon="❌"

    local subject summary
    if [ "$DRY_RUN" = "on" ]; then
        subject="[DRY-RUN ⚠️] ${EMAIL_SUBJECT_PREFIX} | ${HOSTNAME} | ${DATE_LABEL}"
        summary="Mode: <b>DRY-RUN</b> — nothing written."
    else
        subject="[${icon} ${GLOBAL_STATUS}] ${EMAIL_SUBJECT_PREFIX} | ${HOSTNAME} | ${DATE_LABEL}"
        summary="Paths: <b>${#BACKUP_PATHS[@]}</b> &nbsp;|&nbsp; ✅ <b>${COUNT_OK}</b> ⚠️ <b>${COUNT_WARN}</b> ❌ <b>${COUNT_ERR}</b>"
        summary+="<br>Snapshot: <b>${SNAP_NAME}</b> &nbsp;|&nbsp; Destination: ${DEST_MODE} — ${DEST_BASE}"
    fi

    # The last log lines, as plain text. Reading them into a shell variable and
    # escaping the HTML keeps the report readable — printing a language's list
    # repr into the body produces ['line\n', 'line\n'] and helps nobody.
    local tail_log
    tail_log=$(tail -n 20 "$LOG_FILE" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

    [ -z "$TABLE_ROWS" ] && TABLE_ROWS="<tr><td colspan='4' style='padding:12px;text-align:center;color:#888;'>No paths processed.</td></tr>"

    local body="<html><body style='font-family:Arial,sans-serif;color:#333;max-width:750px;margin:0 auto;'>
<h2 style='border-bottom:2px solid #eee;padding-bottom:8px;'>${EMAIL_SUBJECT_PREFIX}</h2>
<p style='font-size:14px;'><strong>Server:</strong> ${HOSTNAME}<br>
<strong>Date:</strong> ${DATE_LABEL}<br>
<strong>Global status:</strong> ${icon} <b>${GLOBAL_STATUS}</b><br>
<strong>Duration:</strong> $(( $(date +%s) - START_TIME ))s</p>
<p style='background:#f9f9f9;border-left:4px solid #ccc;padding:10px 14px;font-size:13px;'>${summary}</p>
<table style='width:100%;border-collapse:collapse;margin-top:16px;font-size:13px;'>
<thead><tr style='background:#f2f2f2;'>
<th style='padding:9px 8px;border:1px solid #ddd;text-align:left;'>Path</th>
<th style='padding:9px 8px;border:1px solid #ddd;text-align:left;'>Size / Files</th>
<th style='padding:9px 8px;border:1px solid #ddd;text-align:center;'>Backup</th>
<th style='padding:9px 8px;border:1px solid #ddd;text-align:center;'>Verify</th>
</tr></thead><tbody>${TABLE_ROWS}</tbody></table>
<p style='font-size:12px;color:#666;margin-top:20px;'><b>Last log lines:</b></p>
<pre style='background:#f5f5f5;padding:10px;font-size:11px;overflow-x:auto;'>${tail_log}</pre>
<p style='font-size:11px;color:#aaa;margin-top:24px;'>
Log: ${LOG_FILE}<br>
Retention: ${DAILY_RETENTION} daily, ${WEEKLY_RETENTION} weekly &nbsp;|&nbsp; Snapshots: ${DEST_BASE}<br>
Verify: rsync exit code + non-empty snapshot + size/file-count trend (warn if drop &gt; ${SIZE_DROP_WARN}%/${FILE_DROP_WARN}%)
</p></body></html>"

    local tls=""
    case "$SMTP_PORT" in 465) tls="--tls-on-connect" ;; 587) tls="--tls" ;; esac
    local auth=()
    [ -n "$SMTP_USER" ] && auth=(--auth-user "$SMTP_USER" --auth-password "$SMTP_PASS")

    swaks --to "$EMAIL_TO" --from "$EMAIL_FROM" --server "$SMTP_SERVER" --port "$SMTP_PORT" \
        $tls "${auth[@]}" --header "Subject: $subject" \
        --header "Content-Type: text/html; charset=UTF-8" --body "$body" >/dev/null 2>&1 \
        && log_info "Report sent to $EMAIL_TO" || log_warn "Email delivery failed"
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
    echo "============================================================" | tee -a "$LOG_FILE"
    log_info "DABR start — host: $HOSTNAME — snapshot: $SNAP_NAME"
    log_info "Mode: $([ "$DRY_RUN" = "on" ] && echo "DRY-RUN" || echo "PRODUCTION") — destination: $DEST_MODE $DEST_BASE"
    echo "============================================================" | tee -a "$LOG_FILE"

    if ! check_destination; then
        GLOBAL_STATUS="ERROR"
        send_email; send_telegram; send_ntfy
        exit 1
    fi

    local latest; latest=$(find_latest_snapshot)
    if [ -n "$latest" ]; then
        log_info "Hardlinking against previous snapshot: $latest"
    else
        log_info "No previous snapshot — this run copies everything"
    fi

    for src in "${BACKUP_PATHS[@]}"; do
        backup_one_path "$src" "$latest"
    done

    create_weekly
    rotate "daily"  "$DAILY_RETENTION"
    rotate "weekly" "$WEEKLY_RETENTION"
    rotate_logs

    log_info "Done in $(( $(date +%s) - START_TIME ))s — ${ERRORS} error(s), ${WARNINGS} warning(s)"

    send_email
    send_telegram
    send_ntfy

    [ $COUNT_ERR -gt 0 ] && exit 1
    exit 0
}

main "$@"
