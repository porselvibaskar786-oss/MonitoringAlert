#!/bin/bash
###############################################################################
# Agentic AI DB Temp Cleanup
# Auto Port Discovery | Multi-MySQL | Disk-aware | DB-aware | Alerts
###############################################################################

set -euo pipefail

############################################
# CONFIG
############################################

DISK_THRESHOLD=80
RETENTION_DAYS=3

LOG_FILE="/var/tmp/db_temp_cleanup.log"
LOCK_FILE="/tmp/db_temp_cleanup.lock"
AGENT_MEMORY="/var/tmp/db_cleanup_agent_state.json"

############################################
# ALERTING
############################################

SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
ALERT_EMAIL="ops@example.com"

############################################
# DB CREDS (READ-ONLY)
############################################

MYSQL_USER="readonly"
MYSQL_PASS="${MYSQL_PASS:-}"
PG_USER="readonly"
ORACLE_CONN="user/pass@ORCL"

############################################
# AGENTIC AI
############################################

AI_ENABLED=true
LLM_API_URL="https://api.openai.com/v1/chat/completions"
LLM_MODEL="gpt-4.1-mini"
LLM_API_KEY="${LLM_API_KEY:-}"

############################################
# TEMP DIRS
############################################

TEMP_DIRS=(
  "/tmp"
  "/var/tmp"
  "/var/lib/mysql/tmp"
  "/var/tmp/mysql"
  "/tmp/pg_tmp"
  "/u01/app/oracle/temp"
)

############################################
# UTILS
############################################

log() {
  echo "$(date '+%F %T') - $1" | tee -a "$LOG_FILE"
}

alert() {
  local msg="$1"
  [[ -n "$SLACK_WEBHOOK_URL" ]] && \
    curl -s -X POST -H 'Content-type: application/json' \
      --data "{\"text\":\"$msg\"}" "$SLACK_WEBHOOK_URL" >/dev/null
  [[ -n "$ALERT_EMAIL" ]] && \
    echo "$msg" | mail -s "DB Temp Cleanup Alert" "$ALERT_EMAIL" || true
}

############################################
# LOCK
############################################

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

############################################
# DISK
############################################

disk_usage() {
  df / | awk 'NR==2 {gsub("%",""); print $5}'
}

############################################
# AUTO PORT DISCOVERY
############################################

discover_ports() {
  ss -lnt 2>/dev/null | awk '{print $4}' | awk -F: '{print $NF}' | sort -u \
  || netstat -lnt 2>/dev/null | awk '{print $4}' | awk -F: '{print $NF}' | sort -u
}

MYSQL_PORTS=()
POSTGRES_PORTS=()
ORACLE_PORTS=()

for p in $(discover_ports); do
  case "$p" in
    3306|33*) MYSQL_PORTS+=("$p") ;;
    5432|54*) POSTGRES_PORTS+=("$p") ;;
    1521|15*) ORACLE_PORTS+=("$p") ;;
  esac
done

############################################
# DB SIGNALS
############################################

mysql_temp_active() {
  local total=0
  for port in "${MYSQL_PORTS[@]}"; do
    val=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -P "$port" -sN \
      -e "SHOW GLOBAL STATUS LIKE 'Created_tmp_disk_tables';" 2>/dev/null | awk '{print $2}' || echo 0)
    total=$((total + val))
  done
  echo "$total"
}

postgres_temp_active() {
  [[ ${#POSTGRES_PORTS[@]} -eq 0 ]] && echo 0 && return
  psql -U "$PG_USER" -t \
    -c "SELECT COALESCE(SUM(temp_bytes),0) FROM pg_stat_database;" 2>/dev/null | tr -d ' '
}

oracle_temp_active() {
  [[ ${#ORACLE_PORTS[@]} -eq 0 ]] && echo 0 && return
  sqlplus -s "$ORACLE_CONN" <<EOF
SET HEADING OFF FEEDBACK OFF
SELECT COALESCE(SUM(blocks),0) FROM v\\$sort_usage;
EXIT;
EOF
}

############################################
# AGENT MEMORY
############################################

init_memory() {
  [[ -f "$AGENT_MEMORY" ]] || echo '{}' > "$AGENT_MEMORY"
}

############################################
# OBSERVATION
############################################

collect_signals() {
  cat <<EOF
{
  "disk_usage": $(disk_usage),
  "mysql_instances": ${#MYSQL_PORTS[@]},
  "mysql_ports": "${MYSQL_PORTS[*]}",
  "postgres_ports": "${POSTGRES_PORTS[*]}",
  "oracle_ports": "${ORACLE_PORTS[*]}",
  "mysql_temp": "$(mysql_temp_active)",
  "postgres_temp": "$(postgres_temp_active)",
  "oracle_temp": "$(oracle_temp_active)",
  "hour": $(date +%H),
  "environment": "production"
}
EOF
}

############################################
# AGENT DECISION
############################################

agent_decide() {
  local signals
  signals=$(collect_signals)

  curl -s "$LLM_API_URL" \
    -H "Authorization: Bearer $LLM_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"$LLM_MODEL\",
      \"messages\": [
        {\"role\": \"system\", \"content\": \"You are a cautious SRE agent.\"},
        {\"role\": \"user\", \"content\": \"Signals: $signals.
Choose one:
CLEAN_NOW | PARTIAL_CLEAN | DEFER | ESCALATE_ONLY
Format:
ACTION: <value>
REASON: <short reason>\"}
      ]
    }" | jq -r '.choices[0].message.content'
}

############################################
# CLEANUP
############################################

cleanup_dirs() {
  for dir in "${TEMP_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    log "Cleaning $dir"
    find "$dir" -type f \
      \( -name "*.tmp" -o -name "*.temp" -o -name "*.swap" -o -name "ibtmp*" \) \
      -mtime +"$RETENTION_DAYS" \
      -print -delete 2>/dev/null || true
  done
}

############################################
# MAIN
############################################

init_memory
log "===== AUTO-DISCOVERY AGENTIC CLEANUP STARTED ====="

CURRENT_DISK=$(disk_usage)
[[ "$CURRENT_DISK" -lt "$DISK_THRESHOLD" ]] && {
  log "Disk ${CURRENT_DISK}% below threshold. Exit."
  exit 0
}

#CURRENT_DISK=$(disk_usage)
#log "Disk ${CURRENT_DISK}% (threshold $DISK_THRESHOLD) — Agentic flow will always run for testing."
## No exit here → always trigger agent


if [[ "$AI_ENABLED" == "true" ]]; then
  RESPONSE=$(agent_decide)
  ACTION=$(echo "$RESPONSE" | awk '/ACTION:/ {print $2}')
  REASON=$(echo "$RESPONSE" | sed -n 's/REASON: //p')
else
  ACTION="CLEAN_NOW"
  REASON="AI disabled"
fi

log "Decision: $ACTION | $REASON"

case "$ACTION" in
  CLEAN_NOW)
    cleanup_dirs
    alert "Cleanup executed: $REASON"
    ;;
  PARTIAL_CLEAN)
    RETENTION_DAYS=7
    cleanup_dirs
    alert "Partial cleanup executed: $REASON"
    ;;
  DEFER)
    alert "Cleanup deferred: $REASON"
    ;;
  ESCALATE_ONLY)
    alert "Cleanup escalated: $REASON"
    ;;
  *)
    cleanup_dirs
    ;;
esac

log "===== AUTO-DISCOVERY AGENTIC CLEANUP COMPLETED ====="
