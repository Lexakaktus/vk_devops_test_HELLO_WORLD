#!/usr/bin/env bash

set -u
CONFIG_FILE="$(dirname "$0")/monitor_app.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Ошибка: файл конфигурации $CONFIG_FILE не найден" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

log() {
    local msg="$1"
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
    echo "[$(timestamp)] $msg" >> "$LOGFILE"
}

# Проверяем, что curl установлен
if [[ -z "$CURL_BIN" ]]; then
    echo "curl не найден. Установи curl." >&2
    exit 2
fi

# Защита от параллельного запуска (используем flock)
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    log "INFO: другой экземпляр скрипта уже запущен — выходим"
    exit 0
fi

# Проверка лимита рестартов за час
record_restart() {
    local now_epoch=$(date +%s)
    echo "$now_epoch" >> "$RESTART_COUNTER_FILE"
    # очищаем старые записи (старше 3600 сек)
    awk -v now="$now_epoch" '($1+0) > (now-3600){ print $1 }' "$RESTART_COUNTER_FILE" > "${RESTART_COUNTER_FILE}.tmp" 2>/dev/null || true
    mv -f "${RESTART_COUNTER_FILE}.tmp" "$RESTART_COUNTER_FILE" 2>/dev/null || true
}

count_restarts_last_hour() {
    if [[ ! -f "$RESTART_COUNTER_FILE" ]]; then
        echo 0
        return
    fi
    local now_epoch=$(date +%s)
    awk -v now="$now_epoch" '($1+0) > (now-3600){ count++ } END{ print (count+0) }' "$RESTART_COUNTER_FILE"
}

# Выполнить перезапуск приложения
perform_restart() {
    log "ACTION: Начинаю перезапуск приложения"
    if [[ -n "$SERVICE_NAME" && "$(command -v systemctl || true)" ]]; then
        # systemctl restart
        if systemctl list-units --full -all | grep -q "^${SERVICE_NAME}\.service"; then
            log "ACTION: Перезапуск через systemctl: ${SERVICE_NAME}"
            if systemctl restart "${SERVICE_NAME}"; then
                log "OK: systemctl_restart выполнился успешно"
                record_restart
                return 0
            else
                log "ERROR: systemctl restart вернул ошибку"
                return 1
            fi
        else
            log "WARN: Сервис ${SERVICE_NAME} не найден в systemd — попробую RESTART_CMD"
        fi
    fi

    
    if [[ -n "$RESTART_CMD" && -x "$(command -v bash)" ]]; then
        log "ACTION: Перезапуск через команду: ${RESTART_CMD}"
        # Запускаем команду в фоне, перенаправляем вывод в лог
        nohup bash -c "${RESTART_CMD}" >> "$LOGFILE" 2>&1 &
        sleep 1
        record_restart
        return 0
    fi

    log "ERROR: Нет способа перезапустить приложение (SERVICE_NAME и RESTART_CMD оба не настроены)"
    return 2
}

# Функция проверки доступности
check_url() {
    # Возвращает http code 
    "$CURL_BIN" -sS -o /dev/null -w '%{http_code}' --max-time 5 "$URL" || echo "000"
}

# Основной рабочий цикл (выполняется один раз)
http_code=$(check_url)
if [[ "$http_code" == "$EXPECTED_STATUS" ]]; then
    log "OK: Проверка $URL вернула $http_code"
    exit 0
else
    log "FAIL: Проверка $URL вернула $http_code (ожидалось $EXPECTED_STATUS)"
fi

# Проверяем лимит рестартов
current_restarts=$(count_restarts_last_hour)
if (( current_restarts >= MAX_RESTARTS_PER_HOUR )); then
    log "ERROR: Достигнут лимит рестартов за последний час ($current_restarts). Перезапуск запрещён."
    exit 1
fi

# Пытаемся перезапустить
if ! perform_restart; then
    log "ERROR: Попытка перезапуска не удалась"
    exit 1
fi

# После рестарта — несколько попыток проверить 
success_after=0
for ((i=1;i<=RESTART_RETRIES;i++)); do
    sleep "$RESTART_WAIT"
    new_code=$(check_url)
    log "INFO: Повторная проверка #$i вернула $new_code"
    if [[ "$new_code" == "$EXPECTED_STATUS" ]]; then
        success_after=1
        log "OK: Приложение восстановлено, ответ $new_code"
        break
    fi
done

if (( success_after == 0 )); then
    log "ERROR: После рестарта приложение недоступно (последний код: ${new_code})."
    exit 2
fi

exit 0
