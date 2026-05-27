#!/bin/bash
# Script: monitor_logs_and_notify.sh
# Description: Monitors service logs for exceptions, notifies via Telegram, and avoids duplicate notifications for the same exception.

# === CONFIGURATION ===
LOG_FILE="/var/log/syslog"  # Cambia esto al archivo de log de tu servicio
SERVICE_NAME="watch-deploy" # Cambia esto si tu servicio tiene otro nombre
TELEGRAM_BOT_TOKEN="<TU_BOT_TOKEN>" # Reemplaza con tu token de bot
TELEGRAM_CHAT_ID="<TU_CHAT_ID>"     # Reemplaza con tu chat ID
STATE_FILE="/tmp/last_exception_time.txt"

# === FUNCIONES ===
notify_telegram() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="$message"
}

get_last_exception_time() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo ""
    fi
}

save_last_exception_time() {
    echo "$1" > "$STATE_FILE"
}

# === MONITOREO ===
tail -Fn0 "$LOG_FILE" | \
while read line; do
    if echo "$line" | grep -q -i "exception"; then
        # Extrae la hora del log (ajusta el regex según el formato de tu log)
        log_time=$(echo "$line" | grep -oE '^[A-Za-z]{3} [ 0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}')
        [[ -z "$log_time" ]] && log_time=$(date '+%Y-%m-%d %H:%M:%S')

        last_time=$(get_last_exception_time)
        if [[ "$log_time" != "$last_time" ]]; then
            notify_telegram "[$SERVICE_NAME] Nueva excepción detectada a las $log_time:\n$line"
            save_last_exception_time "$log_time"
        fi
    fi
done
