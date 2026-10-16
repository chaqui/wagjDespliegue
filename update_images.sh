#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_VERSION="2026.10.16.3"
STACK_NAME="${STACK_NAME:-sistema}"
COMPOSE_FILE="${COMPOSE_FILE:-${SCRIPT_DIR}/docker-stack.yml}"
INITIAL_DEPLOY_SCRIPT="${INITIAL_DEPLOY_SCRIPT:-${SCRIPT_DIR}/deploy_sequential.sh}"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"
ENV_STATE_FILE="${ENV_STATE_FILE:-${SCRIPT_DIR}/.env.applied.sha256}"
COMPOSE_STATE_FILE="${COMPOSE_STATE_FILE:-${SCRIPT_DIR}/.compose.applied.sha256}"
ENV_HASH_KEY_FILE="${ENV_HASH_KEY_FILE:-${SCRIPT_DIR}/.env.hash.key}"
JWT_SECRET_FILE="${JWT_SECRET_FILE:-${SCRIPT_DIR}/.jwt-secret}"
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/update-images.log}"
STATUS_FILE="${STATUS_FILE:-${SCRIPT_DIR}/deploy-status.json}"
LOCK_FILE="${LOCK_FILE:-/tmp/${STACK_NAME}-update-images.lock}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-420}"
PRUNE_OLD_IMAGES="${PRUNE_OLD_IMAGES:-false}"
PRUNE_UNTIL="${PRUNE_UNTIL:-168h}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
WEBHOOK_URL="${WEBHOOK_URL:-}"

MODE=all DRY_RUN=false FORCE_SERVICE=""
UPDATED_SERVICES=() FAILED_SERVICES=() UNCHANGED_SERVICES=() TMP_FILES=()
ENV_OVERRIDE_NAMES=()

usage() {
  cat <<'EOF'
Uso: ./update_images.sh [opcion]
  --dry-run          Muestra cambios sin modificar servicios
  --env-only         Revisa y aplica solamente .env
  --images-only      Revisa y aplica solamente imagenes
  --force SERVICIO   Fuerza la actualizacion de un servicio
  --status           Muestra el ultimo resultado y el stack actual
  -h, --help         Muestra esta ayuda
EOF
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --env-only) MODE=env ;;
    --images-only) MODE=images ;;
    --force) [ "$#" -ge 2 ] || { echo "Falta el servicio" >&2; exit 2; }; FORCE_SERVICE="$2"; shift ;;
    --status) MODE=status ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Opcion desconocida: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
cleanup() { [ "${#TMP_FILES[@]}" -eq 0 ] || rm -f "${TMP_FILES[@]}"; }
trap cleanup EXIT
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/[[:cntrl:]]/ /g'; }
write_status() {
  local status="$1" message="$2" tmp
  tmp="$(mktemp "${STATUS_FILE}.XXXXXX")"; TMP_FILES+=("$tmp")
  printf '{"status":"%s","timestamp":"%s","stack":"%s","message":"%s"}\n' \
    "$status" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$STACK_NAME" "$(json_escape "$message")" > "$tmp"
  mv "$tmp" "$STATUS_FILE"
}
notify() {
  local status="$1" message="$2" emoji="❌"
  [ "$status" = success ] && emoji="✅"
  write_status "$status" "$message" 2>/dev/null || true
  if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] && command -v curl >/dev/null; then
    curl -fsSL -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" -d "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${emoji} [${STACK_NAME}] ${message}" >/dev/null 2>&1 || true
  fi
  if [ -n "$WEBHOOK_URL" ] && command -v curl >/dev/null; then
    curl -fsSL -X POST -H 'Content-Type: application/json' \
      -d "{\"text\":\"${emoji} [${STACK_NAME}] $(json_escape "$message")\"}" "$WEBHOOK_URL" >/dev/null 2>&1 || true
  fi
}
die() { log "ERROR: $*"; notify failure "$*"; exit 1; }

command -v docker >/dev/null 2>&1 || die "Docker no esta instalado."
[ -f "$COMPOSE_FILE" ] || die "No existe $COMPOSE_FILE."
if command -v flock >/dev/null 2>&1; then exec 9>"$LOCK_FILE"; flock -n 9 || die "Ya hay otra actualizacion en curso."; fi
if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo -E docker)
else die "El usuario no tiene acceso a Docker y sudo requiere interaccion."; fi
docker_cmd() { "${DOCKER[@]}" "$@"; }
log "update_images.sh version $SCRIPT_VERSION"
print_service_logs() {
  local svc="$1"
  log "Ultimos logs de $svc:"
  docker_cmd service logs --timestamps --tail 200 "$svc" \
    2>&1 | tee -a "$LOG_FILE" || log "ADVERTENCIA: no fue posible obtener logs de $svc."
}
stack_exists() { docker_cmd stack ls --format '{{.Name}}' 2>/dev/null | grep -Fxq "$STACK_NAME"; }
is_manager() { [ "$(docker_cmd info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || true)" = true ]; }
prepare_bind_dirs() {
  local writable_dirs=(
    "$SCRIPT_DIR/keys"
    "$SCRIPT_DIR/logs/auth"
    "$SCRIPT_DIR/logs/losmolinos-store-backend"
    "$SCRIPT_DIR/logs/crecilandia-store-backend"
    "$SCRIPT_DIR/logs/losmolinos-restaurante-backend"
    "$SCRIPT_DIR/logs/crecilandia-restaurante-backend"
    "$SCRIPT_DIR/data/losmolinos-store"
    "$SCRIPT_DIR/data/crecilandia-store"
    "$SCRIPT_DIR/data/losmolinos-restaurante"
    "$SCRIPT_DIR/data/crecilandia-restaurante"
  )
  local dir
  mkdir -p "$SCRIPT_DIR/certs"
  chmod 755 "$SCRIPT_DIR/certs" || true
  for dir in "${writable_dirs[@]}"; do
    if [ ! -d "$dir" ]; then log "Creando directorio requerido por bind mount: $dir"; fi
    mkdir -p "$dir"
    chmod 777 "$dir" || true
  done
}
recover_bind_mount_failures() {
  local svc errors wanted active
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    wanted="$(desired_replicas "$svc")"
    active="$(running_replicas "$svc")"
    [ -n "$wanted" ] || continue
    [ "$active" -lt "$wanted" ] || continue
    errors="$(docker_cmd service ps --no-trunc --format '{{.Error}}' "$svc" 2>/dev/null || true)"
    if grep -q 'invalid mount config.*bind source path does not exist' <<< "$errors"; then
      if $DRY_RUN; then
        log "DRY-RUN: reiniciaria $svc despues de reparar sus bind mounts."
      else
        log "Reiniciando $svc despues de reparar sus bind mounts."
        docker_cmd service update --detach=true --force "$svc" 2>&1 | tee -a "$LOG_FILE"
        if wait_healthy "$svc"; then
          UPDATED_SERVICES+=("$svc")
        else
          log "ERROR: $svc no se recupero despues de reparar sus bind mounts."
          FAILED_SERVICES+=("$svc")
        fi
      fi
    fi
  done < <(docker_cmd service ls --filter "label=com.docker.stack.namespace=${STACK_NAME}" --format '{{.Name}}')
}

load_env() {
  local line key value
  [ -f "$ENV_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    line="${line#export }"
    key="${line%%=*}"
    value="${line#*=}"
    key="$(printf '%s' "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Variable invalida en .env: $key"
    if [[ "$value" == \"*\" ]] || [[ "$value" == \'*\' ]]; then value="${value:1:${#value}-2}"; fi
    # Las variables ya exportadas por systemd o por el shell tienen prioridad.
    # Solo se registra el nombre, nunca el valor.
    if printenv "$key" >/dev/null 2>&1; then
      [ "${!key-}" = "$value" ] || ENV_OVERRIDE_NAMES+=("$key")
    else
      export "$key=$value"
    fi
  done < "$ENV_FILE"
  if [ "${#ENV_OVERRIDE_NAMES[@]}" -gt 0 ]; then
    log "Variables del servidor que tienen prioridad sobre .env: $(printf '%s\n' "${ENV_OVERRIDE_NAMES[@]}" | sort -u | tr '\n' ' ')"
  fi
}
generate_traefik_auth() {
  local raw_hash
  case "${TRAEFIK_DASHBOARD_AUTH:-}" in
    ""|*REEMPLAZAR*|*CHANGE_ME*|*change_me*) ;;
    *) return 0 ;;
  esac
  [ -n "${TRAEFIK_USER:-}" ] || die "Falta TRAEFIK_USER para generar TRAEFIK_DASHBOARD_AUTH."
  [ -n "${TRAEFIK_PASSWORD:-}" ] || die "Falta TRAEFIK_PASSWORD para generar TRAEFIK_DASHBOARD_AUTH."
  case "$TRAEFIK_PASSWORD" in
    *REEMPLAZAR*|*CHANGE_ME*|*change_me*)
      die "TRAEFIK_PASSWORD conserva un valor de ejemplo. Configure una contraseña real." ;;
  esac
  if command -v htpasswd >/dev/null 2>&1; then
    raw_hash="$(htpasswd -nb "$TRAEFIK_USER" "$TRAEFIK_PASSWORD")"
  elif command -v openssl >/dev/null 2>&1; then
    raw_hash="${TRAEFIK_USER}:$(openssl passwd -apr1 "$TRAEFIK_PASSWORD")"
  else
    die "Se necesita htpasswd u openssl para generar TRAEFIK_DASHBOARD_AUTH."
  fi
  export TRAEFIK_DASHBOARD_AUTH="$(printf '%s' "$raw_hash" | sed 's/\$/$$/g')"
  log "TRAEFIK_DASHBOARD_AUTH generado automaticamente para TRAEFIK_USER=$TRAEFIK_USER."
}
generate_database_url() {
  case "${DB_URL:-}" in
    ""|*example.internal*|*REEMPLAZAR*|*CHANGE_ME*|*change_me*) ;;
    *) return 0 ;;
  esac
  [ -n "${DB_HOST:-}" ] || return 0
  [ -n "${DB_NAME:-}" ] || return 0
  case "$DB_HOST:$DB_NAME" in
    *example.internal*|*REEMPLAZAR*|*CHANGE_ME*|*change_me*) return 0 ;;
  esac
  export DB_PORT="${DB_PORT:-5432}"
  export DB_URL="jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}"
  log "DB_URL generado automaticamente desde DB_HOST, DB_PORT y DB_NAME."
}
generate_jwt_secret() {
  case "${JWT_SECRET:-}" in
    ""|*REEMPLAZAR*|*CHANGE_ME*|*change_me*) ;;
    *) return 0 ;;
  esac
  if [ -s "$JWT_SECRET_FILE" ]; then
    export JWT_SECRET="$(<"$JWT_SECRET_FILE")"
    log "JWT_SECRET cargado desde el archivo seguro local."
    return 0
  fi
  umask 077
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 64 > "$JWT_SECRET_FILE"
  elif command -v sha256sum >/dev/null 2>&1; then
    head -c 128 /dev/urandom | sha256sum | awk '{print $1}' > "$JWT_SECRET_FILE"
  else
    die "Se necesita openssl o sha256sum para generar JWT_SECRET."
  fi
  chmod 600 "$JWT_SECRET_FILE"
  export JWT_SECRET="$(<"$JWT_SECRET_FILE")"
  log "JWT_SECRET generado automaticamente y guardado en un archivo seguro local."
}
normalize_runtime_config() {
  if ! [[ "$HEALTH_TIMEOUT" =~ ^[0-9]+$ ]]; then
    die "HEALTH_TIMEOUT debe ser un numero entero de segundos."
  fi
  if [ "$HEALTH_TIMEOUT" -lt 420 ]; then
    log "HEALTH_TIMEOUT=$HEALTH_TIMEOUT es insuficiente para auth-service; se ajusta a 420s."
    HEALTH_TIMEOUT=420
    export HEALTH_TIMEOUT
  fi
}
validate_env() {
  local required=(ACME_EMAIL DB_URL DB_USERNAME DB_PASSWORD JWT_SECRET) missing=() placeholders=() key value
  for key in "${required[@]}"; do [ -n "${!key:-}" ] || missing+=("$key"); done
  [ "${#missing[@]}" -eq 0 ] || die "Variables obligatorias vacias o ausentes: ${missing[*]}"
  [[ "$DB_URL" == jdbc:postgresql://* ]] || die "DB_URL debe iniciar con jdbc:postgresql://"
  case "$DB_URL" in
    *example.internal*|*REEMPLAZAR*|*CHANGE_ME*|*change_me*)
      die "DB_URL conserva un valor de ejemplo ($DB_URL). Configure el host PostgreSQL real antes de desplegar." ;;
  esac
  for key in DB_USERNAME DB_PASSWORD JWT_SECRET; do
    value="${!key-}"
    case "$value" in *REEMPLAZAR*|*CHANGE_ME*|*change_me*) placeholders+=("$key");; esac
  done
  [ "${#placeholders[@]}" -eq 0 ] || die "Variables que conservan valores de ejemplo: ${placeholders[*]}. Configure valores reales antes de desplegar."
  [ "${#JWT_SECRET}" -ge 32 ] || die "JWT_SECRET debe tener al menos 32 caracteres."
  if [ -z "${TRAEFIK_DASHBOARD_AUTH:-}" ] && { [ -z "${TRAEFIK_USER:-}" ] || [ -z "${TRAEFIK_PASSWORD:-}" ]; }; then
    die "Defina TRAEFIK_DASHBOARD_AUTH o TRAEFIK_USER y TRAEFIK_PASSWORD."
  fi
  docker_cmd stack config -c "$COMPOSE_FILE" >/dev/null || die "docker-stack.yml o .env no son validos."
}
ensure_hash_key() {
  [ -s "$ENV_HASH_KEY_FILE" ] && return
  command -v openssl >/dev/null || return
  umask 077; openssl rand -hex 32 > "$ENV_HASH_KEY_FILE"
}
hash_value() {
  if command -v openssl >/dev/null 2>&1 && [ -s "$ENV_HASH_KEY_FILE" ]; then
    printf '%s' "$1" | openssl dgst -sha256 -hmac "$(<"$ENV_HASH_KEY_FILE")" | awk '{print $NF}'
  elif command -v sha256sum >/dev/null; then printf '%s' "$1" | sha256sum | awk '{print $1}'
  else printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; fi
}
file_checksum() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
build_env_state() {
  local output="$1" key; : > "$output"
  while read -r key; do printf '%s=%s\n' "$key" "$(hash_value "${!key-}")"; done < <(
    {
      sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$ENV_FILE" | grep -v '^TRAEFIK_DASHBOARD_AUTH$'
      # Se rastrean las entradas del hash de Traefik, no el hash generado:
      # APR1 usa sal aleatoria y cambiaría en cada ejecución.
      printf '%s\n' DB_URL DB_HOST DB_PORT DB_NAME DB_USERNAME DB_PASSWORD JWT_SECRET TRAEFIK_USER TRAEFIK_PASSWORD
    } | sort -u
  ) >> "$output"; chmod 600 "$output"
}
env_changes() {
  local current="$1" key hash previous
  while IFS='=' read -r key hash; do
    previous="$(awk -F= -v k="$key" '$1==k {print $2; exit}' "$ENV_STATE_FILE" 2>/dev/null || true)"
    if [ -z "$previous" ]; then printf 'NUEVA|%s\n' "$key"; elif [ "$previous" != "$hash" ]; then printf 'MODIFICADA|%s\n' "$key"; fi
  done < "$current"
  if [ -f "$ENV_STATE_FILE" ]; then
    while IFS='=' read -r key _; do grep -q "^${key}=" "$current" || printf 'ELIMINADA|%s\n' "$key"; done < "$ENV_STATE_FILE"
  fi
}
services_for_variable() {
  local key="$1" marker='${'"$key"'}'
  awk -v marker="$marker" '/^services:/ {inside=1; next} inside && /^[^ ]/ {inside=0} inside && /^  [[:alnum:]_.-]+:$/ {s=$1; sub(/:$/, "",s)} inside && index($0,marker) {print s}' "$COMPOSE_FILE"
  case "$key" in DB_URL|DB_HOST|DB_PORT|DB_NAME|DB_USERNAME|DB_PASSWORD|JWT_SECRET)
    awk '/^  [[:alnum:]_.-]+:$/ {s=$1; sub(/:$/, "",s)} /\*backend-environment/ {print s}' "$COMPOSE_FILE";; esac
  case "$key" in TRAEFIK_USER|TRAEFIK_PASSWORD|TRAEFIK_DASHBOARD_AUTH) echo traefik;; esac
}
capture_versions() {
  local svc; while read -r svc; do printf '%s|%s\n' "$svc" "$(docker_cmd service inspect --format '{{.Version.Index}}' "$svc")"; done < <(
    docker_cmd service ls --filter "label=com.docker.stack.namespace=${STACK_NAME}" --format '{{.Name}}'
  )
}
changed_services_since() {
  local svc old new; while IFS='|' read -r svc old; do new="$(docker_cmd service inspect --format '{{.Version.Index}}' "$svc" 2>/dev/null || true)"; [ -n "$new" ] && [ "$new" != "$old" ] && echo "$svc"; done < "$1"
}
desired_replicas() { docker_cmd service inspect --format '{{if .Spec.Mode.Replicated}}{{.Spec.Mode.Replicated.Replicas}}{{end}}' "$1" 2>/dev/null; }
running_replicas() { docker_cmd service ps --filter desired-state=running --format '{{.CurrentState}}' "$1" 2>/dev/null | grep -c '^Running' || true; }
wait_healthy() {
  local svc="$1" desired elapsed=0 running state
  desired="$(desired_replicas "$svc")"; [ -n "$desired" ] || return 0
  while [ "$elapsed" -lt "$HEALTH_TIMEOUT" ]; do
    running="$(running_replicas "$svc")"; state="$(docker_cmd service inspect --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' "$svc" 2>/dev/null || true)"
    case "$state" in paused|rollback_paused|rollback_completed) return 1;; esac
    if [ "$running" -eq "$desired" ] && { [ -z "$state" ] || [ "$state" = completed ]; }; then return 0; fi
    sleep 5; elapsed=$((elapsed+5))
  done; return 1
}
verify_or_rollback() {
  local svc failed=()
  for svc in "$@"; do log "Verificando $svc (timeout ${HEALTH_TIMEOUT}s)..."; wait_healthy "$svc" || failed+=("$svc"); done
  [ "${#failed[@]}" -eq 0 ] && return 0
  for svc in "${failed[@]}"; do
    local update_state
    update_state="$(docker_cmd service inspect --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' "$svc" 2>/dev/null || true)"
    log "ERROR: $svc no quedo saludable. Estado de actualizacion:"
    docker_cmd service inspect --format '  {{if .UpdateStatus}}{{.UpdateStatus.State}}: {{.UpdateStatus.Message}}{{else}}sin UpdateStatus{{end}}' "$svc" 2>&1 | tee -a "$LOG_FILE" || true
    log "Ultimas tareas de $svc:"
    docker_cmd service ps --no-trunc --format '  {{.Name}} | {{.CurrentState}} | {{.Error}}' "$svc" 2>&1 | head -n 8 | tee -a "$LOG_FILE" || true
    print_service_logs "$svc"
    case "$update_state" in
      rollback_*|rollback-paused)
        log "Docker ya intento el rollback de $svc; no se solicitara otro." ;;
      *)
        log "Solicitando rollback de $svc."
        docker_cmd service rollback --detach=true "$svc" 2>&1 | tee -a "$LOG_FILE" || true ;;
    esac
    FAILED_SERVICES+=("$svc")
  done
  return 1
}
save_replicas() {
  local svc replicas; : > "$1"
  while read -r svc; do replicas="$(desired_replicas "$svc")"; [ -n "$replicas" ] && printf '%s|%s\n' "$svc" "$replicas" >> "$1"; done < <(
    docker_cmd service ls --filter "label=com.docker.stack.namespace=${STACK_NAME}" --format '{{.Name}}'
  )
}
restore_replicas() {
  local svc wanted current
  while IFS='|' read -r svc wanted; do
    current="$(desired_replicas "$svc")"
    if [ "$current" != "$wanted" ]; then
      log "Restaurando replicas de $svc: $current -> $wanted"
      docker_cmd service scale --detach=true "${svc}=${wanted}" 2>&1 | tee -a "$LOG_FILE"
      if [ "$wanted" -gt 0 ]; then
        log "Esperando que $svc quede estable antes de continuar..."
        if ! wait_healthy "$svc"; then
          log "ERROR: $svc no quedo estable durante la restauracion secuencial."
          docker_cmd service ps --no-trunc "$svc" 2>&1 | tee -a "$LOG_FILE" || true
          print_service_logs "$svc"
          return 1
        fi
      fi
    fi
  done < "$1"
}
sync_env() {
  [ -f "$ENV_FILE" ] || { log "ADVERTENCIA: no existe $ENV_FILE; se omite .env."; return; }
  load_env; normalize_runtime_config; generate_traefik_auth; generate_database_url; generate_jwt_secret; validate_env; ensure_hash_key
  local current changes replicas versions services type key svc state_tmp compose_hash previous_compose_hash compose_changed=false
  current="$(mktemp /tmp/env-current.XXXXXX)"; changes="$(mktemp /tmp/env-changes.XXXXXX)"; replicas="$(mktemp /tmp/replicas.XXXXXX)"
  versions="$(mktemp /tmp/versions.XXXXXX)"; services="$(mktemp /tmp/env-services.XXXXXX)"; TMP_FILES+=("$current" "$changes" "$replicas" "$versions" "$services")
  build_env_state "$current"; env_changes "$current" > "$changes"
  compose_hash="$(file_checksum "$COMPOSE_FILE")"
  previous_compose_hash="$(cat "$COMPOSE_STATE_FILE" 2>/dev/null || true)"
  [ "$compose_hash" = "$previous_compose_hash" ] || compose_changed=true
  if [ ! -s "$changes" ] && ! $compose_changed; then log "Variables y docker-stack.yml sin cambios."; return; fi
  if [ -s "$changes" ]; then
    log "Cambios detectados en .env:"
    while IFS='|' read -r type key; do log "  - $key ($type)"; while read -r svc; do [ -n "$svc" ] && log "      afecta: ${STACK_NAME}_$svc"; done < <(services_for_variable "$key" | sort -u); done < "$changes"
  else
    log "Variables de .env sin cambios."
  fi
  $compose_changed && log "Cambio detectado en docker-stack.yml; se reconciliara el stack."
  $DRY_RUN && { log "DRY-RUN: los cambios no se aplicaron."; return; }
  save_replicas "$replicas"; capture_versions > "$versions"
  docker_cmd stack deploy --detach=true --prune --with-registry-auth \
    -c "$COMPOSE_FILE" "$STACK_NAME" 2>&1 | tee -a "$LOG_FILE"
  restore_replicas "$replicas" || die "No se pudieron restaurar secuencialmente las replicas previas."
  changed_services_since "$versions" > "$services"
  local env_updated=(); mapfile -t env_updated < "$services"
  verify_or_rollback "${env_updated[@]}" || die "La actualizacion de .env fallo; se solicitaron rollbacks."
  state_tmp="${ENV_STATE_FILE}.tmp.$$"; cp "$current" "$state_tmp"; chmod 600 "$state_tmp"; mv "$state_tmp" "$ENV_STATE_FILE"
  state_tmp="${COMPOSE_STATE_FILE}.tmp.$$"; printf '%s\n' "$compose_hash" > "$state_tmp"; chmod 600 "$state_tmp"; mv "$state_tmp" "$COMPOSE_STATE_FILE"
  UPDATED_SERVICES+=("${env_updated[@]}"); log "Variables aplicadas y verificadas."
}
read_service_images() {
  awk '/^services:/ {inside=1; next} inside && /^[^ ]/ {inside=0} inside && /^  [[:alnum:]_.-]+:$/ {s=$1; sub(/:$/, "",s)} inside && /^    image:/ {i=$0; sub(/^ *image: */,"",i); sub(/ *#.*/,"",i); gsub(/["\047]/,"",i); print s "|" i}' "$COMPOSE_FILE"
}
remove_orphan_services() {
  local deployed compose_name desired_names orphaned=()
  desired_names="$(read_service_images | cut -d'|' -f1)"
  while IFS= read -r deployed; do
    [ -n "$deployed" ] || continue
    compose_name="${deployed#${STACK_NAME}_}"
    if ! grep -Fxq "$compose_name" <<< "$desired_names"; then
      orphaned+=("$deployed")
      if $DRY_RUN; then
        log "DRY-RUN: eliminaria el servicio ausente del YAML: $deployed"
      else
        log "Eliminando servicio ausente del YAML: $deployed"
        docker_cmd service rm "$deployed" 2>&1 | tee -a "$LOG_FILE"
      fi
    fi
  done < <(docker_cmd service ls --filter "label=com.docker.stack.namespace=${STACK_NAME}" --format '{{.Name}}')
  [ "${#orphaned[@]}" -eq 0 ] || log "Servicios huerfanos detectados: ${orphaned[*]}"
}
image_digest() {
  local image="$1" repo candidate; repo="${image%%@*}"; [[ "${repo##*/}" == *:* ]] && repo="${repo%:*}"
  while read -r candidate; do case "$candidate" in "${repo}@"*) echo "${candidate##*@}"; return;; esac; done < <(docker_cmd image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image" 2>/dev/null || true); return 1
}
current_digest() { local ref; ref="$(docker_cmd service inspect --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' "$1" 2>/dev/null || true)"; [[ "$ref" == *@* ]] && echo "${ref##*@}"; }
remote_digest() {
  local image="$1" digest=""
  if docker_cmd buildx version >/dev/null 2>&1; then
    digest="$(docker_cmd buildx imagetools inspect "$image" 2>/dev/null | awk '/^Name:/ && /@sha256:/ {sub(/^.*@/, ""); print; exit}')"
  fi
  if [ -z "$digest" ]; then
    digest="$(docker_cmd manifest inspect --verbose "$image" 2>/dev/null | sed -n 's/.*"digest"[[:space:]]*:[[:space:]]*"\(sha256:[a-f0-9]*\)".*/\1/p' | head -n1)"
  fi
  [ -n "$digest" ] && echo "$digest"
}
sync_images() {
  local mappings=() mapping image digest compose_service swarm_service old force_match; declare -A digests=() pull_failed=()
  mapfile -t mappings < <(read_service_images)
  for mapping in "${mappings[@]}"; do image="${mapping#*|}"; [ -n "${digests[$image]+x}" ] && continue
    if $DRY_RUN; then
      log "DRY-RUN: consultando $image sin descargarla"
      digests["$image"]="$(remote_digest "$image" || true)"
      [ -n "${digests[$image]}" ] || pull_failed["$image"]=1
    else
      log "Descargando $image"
      if docker_cmd pull "$image" 2>&1 | tee -a "$LOG_FILE"; then digests["$image"]="$(image_digest "$image" || true)"; else pull_failed["$image"]=1; fi
    fi
  done
  for mapping in "${mappings[@]}"; do compose_service="${mapping%%|*}"; image="${mapping#*|}"; swarm_service="${STACK_NAME}_${compose_service}"
    if [ -n "${pull_failed[$image]+x}" ] || [ -z "${digests[$image]:-}" ]; then FAILED_SERVICES+=("$swarm_service"); continue; fi
    digest="${digests[$image]}"; old="$(current_digest "$swarm_service")"
    force_match=false
    if [ "$FORCE_SERVICE" = "$compose_service" ] || [ "$FORCE_SERVICE" = "$swarm_service" ]; then force_match=true; fi
    if [ "$old" = "$digest" ] && ! $force_match; then UNCHANGED_SERVICES+=("$swarm_service"); continue; fi
    if $DRY_RUN; then log "DRY-RUN: actualizaria $swarm_service: ${old:-sin-digest} -> $digest"; continue; fi
    log "Actualizando $swarm_service: ${old:-sin-digest} -> $digest"
    if $force_match; then
      docker_cmd service update --detach=true --force --with-registry-auth --image "${image%%@*}@${digest}" "$swarm_service" 2>&1 | tee -a "$LOG_FILE"
    else
      docker_cmd service update --detach=true --with-registry-auth --image "${image%%@*}@${digest}" "$swarm_service" 2>&1 | tee -a "$LOG_FILE"
    fi
    verify_or_rollback "$swarm_service" && UPDATED_SERVICES+=("$swarm_service")
  done
}
show_status() { [ -f "$STATUS_FILE" ] && { echo "Ultima ejecucion:"; cat "$STATUS_FILE"; echo; }; stack_exists && docker_cmd stack services "$STACK_NAME" || echo "El stack $STACK_NAME no existe."; }
prune_images() { [ "$PRUNE_OLD_IMAGES" = true ] || return; log "Limpiando imagenes no referenciadas anteriores a $PRUNE_UNTIL."; docker_cmd image prune -f --filter "until=${PRUNE_UNTIL}" 2>&1 | tee -a "$LOG_FILE"; }

[ "$MODE" = status ] && { show_status; exit; }
if ! stack_exists; then
  $DRY_RUN && { log "DRY-RUN: se ejecutaria el primer despliegue."; exit; }
  log "El stack no existe; ejecutando despliegue inicial."; (cd "$SCRIPT_DIR" && bash "$INITIAL_DEPLOY_SCRIPT") 2>&1 | tee -a "$LOG_FILE"
  if load_env; then
    generate_database_url
    generate_jwt_secret
    ensure_hash_key
    tmp="$(mktemp /tmp/env-initial.XXXXXX)"
    build_env_state "$tmp"
    mv "$tmp" "$ENV_STATE_FILE"
    printf '%s\n' "$(file_checksum "$COMPOSE_FILE")" > "$COMPOSE_STATE_FILE"
    chmod 600 "$COMPOSE_STATE_FILE"
  fi
  notify success "Primer despliegue completado."; exit
fi
is_manager || die "Este nodo no es manager del Swarm."
prepare_bind_dirs
recover_bind_mount_failures
remove_orphan_services
[ "$MODE" = images ] || sync_env
[ "$MODE" = env ] || sync_images
prune_images
[ "${#FAILED_SERVICES[@]}" -eq 0 ] || die "Servicios con error: ${FAILED_SERVICES[*]}"
summary="${#UPDATED_SERVICES[@]} servicio(s) actualizado(s), ${#UNCHANGED_SERVICES[@]} sin cambios."
log "$summary"; [ "${#UPDATED_SERVICES[@]}" -eq 0 ] || notify success "$summary Servicios: ${UPDATED_SERVICES[*]}"
