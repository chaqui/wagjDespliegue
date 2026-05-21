#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# watch_and_deploy.sh
#
# Flujo (se repite indefinidamente en modo loop):
#   1. Captura los digests actuales de TODAS las imágenes del stack en GHCR.
#   2. Espera (polling cada POLL_INTERVAL segundos) hasta que cualquier
#      imagen cambie de digest  ← GitHub Actions publicó una nueva versión.
#   3. Baja el stack Docker Swarm (STACK_NAME).
#   4. Ejecuta DEPLOY_SCRIPT.
#   5. Registra el resultado en STATUS_FILE (JSON) y emite notificación.
#   6. Vuelve al paso 1.
#
# EJECUCIÓN CONTINUA (como servicio):
#   • Primer plano  : ./watch_and_deploy.sh
#   • Background    : nohup ./watch_and_deploy.sh >> redeploy.log 2>&1 &
#   • systemd       : usar el archivo watch-deploy.service incluido abajo
#   • Una sola vez  : LOOP_MODE=false ./watch_and_deploy.sh
#
# VARIABLES configurables (env o editar sección CONFIGURACIÓN):
#   GITHUB_TOKEN     PAT de GitHub (scope: read:packages). Req. para imgs privadas.
#   STACK_NAME       Nombre del stack Swarm              (default: sistema)
#   COMPOSE_FILE     Ruta al docker-stack.yml            (default: ./docker-stack.yml)
#   IMAGE_REGISTRY   Prefijo de registro a vigilar       (default: ghcr.io)
#   POLL_INTERVAL    Segundos entre cada chequeo         (default: 60)
#   DEPLOY_SCRIPT    Ruta al script de despliegue        (default: ./deploy_sequential.sh)
#   LOOP_MODE        true = bucle continuo / false = solo un ciclo (default: true)
#   WEBHOOK_URL      URL Slack/Discord/genérica para notificación (opcional)
#   STATUS_FILE      Ruta del JSON de estado             (default: ./deploy-status.json)
#
# FUENTE DE IMÁGENES:
#   Las imágenes se leen automáticamente de COMPOSE_FILE en cada ciclo.
#   Solo se vigilan las que empiezan con IMAGE_REGISTRY (traefik queda excluido).
#   Basta con editar docker-stack.yml para añadir/quitar imágenes vigiladas.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURACIÓN
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
STACK_NAME="${STACK_NAME:-sistema}"
# Ruta al docker-stack.yml — ÚNICA fuente de verdad para las imágenes
COMPOSE_FILE="${COMPOSE_FILE:-${SCRIPT_DIR}/docker-stack.yml}"
# Solo se vigilan imágenes cuyo nombre empiece con este prefijo de registro
IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr.io}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-${SCRIPT_DIR}/deploy_sequential.sh}"
LOG="${LOG:-${SCRIPT_DIR}/redeploy.log}"
STATUS_FILE="${STATUS_FILE:-${SCRIPT_DIR}/deploy-status.json}"
LOOP_MODE="${LOOP_MODE:-true}"
WEBHOOK_URL="${WEBHOOK_URL:-}"

# Array que se rellena dinámicamente en load_images_from_compose()
IMAGES=()

# Directorio temporal para guardar los digests conocidos
DIGEST_DIR="${SCRIPT_DIR}/.digests"

# ─────────────────────────────────────────────────────────────────────────────
# UTILIDADES
# ─────────────────────────────────────────────────────────────────────────────
log() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] $*" | tee -a "$LOG"
}

die() {
  log "ERROR: $*"
  exit 1
}

# Detecta si hace falta sudo para Docker
_init_sudo() {
  if docker info >/dev/null 2>&1; then
    SUDO_PREFIX=""
  else
    SUDO_PREFIX="sudo -E"
  fi
}

# Convierte "ghcr.io/chaqui/inventario:main" en un nombre de fichero seguro
# → "ghcr.io_chaqui_inventario_main"
image_to_key() {
  echo "$1" | tr '/: ' '_'
}

# ─────────────────────────────────────────────────────────────────────────────
# Leer imágenes vigiladas directamente desde COMPOSE_FILE
# Solo se incluyen las que comiencen con IMAGE_REGISTRY (ej: ghcr.io).
# Traefik y cualquier imagen de otro registro quedan excluidos automáticamente.
# Se llama al inicio de cada ciclo: si cambias docker-stack.yml no hay que
# editar este script.
# ─────────────────────────────────────────────────────────────────────────────
load_images_from_compose() {
  [ -f "$COMPOSE_FILE" ] || die "COMPOSE_FILE '$COMPOSE_FILE' no encontrado."

  # Extraer todas las líneas  "image: <valor>"  del yml,
  # quedarse solo con las del registro configurado.
  mapfile -t IMAGES < <(
    grep -E '^[[:space:]]+image:[[:space:]]+' "$COMPOSE_FILE" \
      | awk '{print $NF}' \
      | grep "^${IMAGE_REGISTRY}/" \
      | sort -u
  )

  if [ "${#IMAGES[@]}" -eq 0 ]; then
    die "No se encontraron imágenes con prefijo '${IMAGE_REGISTRY}' en ${COMPOSE_FILE}."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Extraer credenciales almacenadas por "docker login ghcr.io"
# Devuelve el password/token en texto plano guardado en ~/.docker/config.json
# ─────────────────────────────────────────────────────────────────────────────
_docker_stored_password() {
  local registry="$1"
  local cfg="${DOCKER_CONFIG:-${HOME}/.docker}/config.json"
  [ -f "$cfg" ] || return 0

  # Si hay un credHelper configurado para este registro, usarlo
  local helper
  helper="$(grep -A1 "\"${registry}\"" "$cfg" 2>/dev/null \
    | grep -o '"[^"]*"$' | tr -d '"')" || helper=""

  if [ -n "$helper" ] && command -v "docker-credential-${helper}" >/dev/null 2>&1; then
    printf '%s' "$registry" \
      | "docker-credential-${helper}" get 2>/dev/null \
      | grep -o '"Secret":"[^"]*"' | cut -d'"' -f4 || true
    return 0
  fi

  # Credenciales embebidas en base64 (auth field)
  local b64auth
  b64auth="$(grep -A2 "\"${registry}\"" "$cfg" 2>/dev/null \
    | grep '"auth"' | grep -o '"[A-Za-z0-9+/=]*"$' | tr -d '"')" || b64auth=""

  if [ -n "$b64auth" ]; then
    # "usuario:password" → devolver solo el password
    printf '%s' "$b64auth" | base64 -d 2>/dev/null | cut -d':' -f2- || true
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# GHCR: obtener token Bearer para una imagen dada.
# Orden de preferencia:
#   1. Variable de entorno GITHUB_TOKEN
#   2. Credenciales guardadas por "docker login ghcr.io"
#   3. Intento anónimo (imágenes públicas)
# ─────────────────────────────────────────────────────────────────────────────
_get_ghcr_token() {
  local registry="$1" repo="$2" token="" credential=""

  # ── 1. GITHUB_TOKEN explícito ──────────────────────────────────────────
  if [ -n "$GITHUB_TOKEN" ]; then
    credential="$GITHUB_TOKEN"
  else
    # ── 2. Credenciales de "docker login" ───────────────────────────────
    credential="$(_docker_stored_password "$registry")" || credential=""
  fi

  if [ -n "$credential" ]; then
    local b64
    b64="$(printf 'token:%s' "$credential" | base64 | tr -d '\n')"
    token="$(curl -fsSL \
      -H "Authorization: Basic ${b64}" \
      "https://${registry}/token?service=${registry}&scope=repository:${repo}:pull" \
      2>/dev/null | grep -o '"token":"[^"]*"' | cut -d'"' -f4)" || token=""
    # Si el endpoint de token falla, GHCR acepta el PAT directamente como Bearer
    [ -z "$token" ] && token="$credential"
  else
    # ── 3. Intento anónimo (solo imágenes públicas) ──────────────────────
    token="$(curl -fsSL \
      "https://${registry}/token?service=${registry}&scope=repository:${repo}:pull" \
      2>/dev/null | grep -o '"token":"[^"]*"' | cut -d'"' -f4)" || token=""
  fi

  echo "$token"
}

# ─────────────────────────────────────────────────────────────────────────────
# Obtener Docker-Content-Digest de una imagen remota
# Uso: get_remote_digest "ghcr.io/chaqui/inventario:main"
# ─────────────────────────────────────────────────────────────────────────────
get_remote_digest() {
  local full_image="$1"
  local registry repo tag repo_tag token digest

  registry="$(echo "$full_image" | cut -d'/' -f1)"
  repo_tag="$(echo "$full_image"  | cut -d'/' -f2-)"
  tag="${repo_tag##*:}"
  repo="${repo_tag%:*}"

  token="$(_get_ghcr_token "$registry" "$repo")"

  if [ -z "$token" ]; then
    echo ""
    return 0
  fi

  digest="$(curl -fsSL -I \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    "https://${registry}/v2/${repo}/manifests/${tag}" \
    2>/dev/null \
    | grep -i '^docker-content-digest:' \
    | awk '{print $2}' \
    | tr -d '\r\n')" || digest=""

  echo "$digest"
}

# ─────────────────────────────────────────────────────────────────────────────
# Guardar el digest actual de cada imagen en DIGEST_DIR
# ─────────────────────────────────────────────────────────────────────────────
save_digests() {
  mkdir -p "$DIGEST_DIR"
  for img in "${IMAGES[@]}"; do
    local key digest
    key="$(image_to_key "$img")"
    digest="$(get_remote_digest "$img")" || digest=""
    echo "$digest" > "${DIGEST_DIR}/${key}"
    if [ -z "$digest" ]; then
      log "  [digest] ${img} → (no disponible)"
    else
      log "  [digest] ${img} → ${digest:0:19}…"
    fi
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# Esperar que el stack desaparezca completamente de Swarm
# ─────────────────────────────────────────────────────────────────────────────
wait_stack_removed() {
  log "Esperando que el stack '${STACK_NAME}' se elimine completamente…"
  local count=0
  while $SUDO_PREFIX docker stack ls 2>/dev/null | grep -q "^${STACK_NAME}[[:space:]]"; do
    count=$((count + 1))
    if [ "$count" -ge 72 ]; then
      log "ADVERTENCIA: el stack tarda demasiado en bajar; continuando igualmente."
      return 0
    fi
    sleep 5
  done
  log "Stack '${STACK_NAME}' eliminado."
}

# ─────────────────────────────────────────────────────────────────────────────
# Registrar resultado en deploy-status.json
# ─────────────────────────────────────────────────────────────────────────────
write_status() {
  local status="$1"   # "success" | "failure"
  local message="$2"
  local triggered_by="${3:-}"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  cat > "$STATUS_FILE" <<EOF
{
  "status": "${status}",
  "timestamp": "${ts}",
  "stack": "${STACK_NAME}",
  "triggered_by_image": "${triggered_by}",
  "message": "${message}",
  "deploy_script": "${DEPLOY_SCRIPT}"
}
EOF
  log "Estado guardado en ${STATUS_FILE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Notificación de escritorio (macOS / Linux con notify-send)
# ─────────────────────────────────────────────────────────────────────────────
notify_desktop() {
  local title="$1" body="$2"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${body}\" with title \"${title}\"" 2>/dev/null || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$body" 2>/dev/null || true
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Notificación vía Webhook (Slack / Discord / genérico)
# ─────────────────────────────────────────────────────────────────────────────
notify_webhook() {
  local status="$1" message="$2"
  [ -z "$WEBHOOK_URL" ] && return 0

  local emoji
  [ "$status" = "success" ] && emoji="✅" || emoji="❌"

  local payload
  payload="{\"text\":\"${emoji} *[${STACK_NAME}]* ${message}\"}"

  curl -fsSL -X POST -H "Content-Type: application/json" \
    -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 || \
    log "ADVERTENCIA: no se pudo enviar notificación al webhook."
}

# ─────────────────────────────────────────────────────────────────────────────
# Emitir todas las notificaciones de éxito / fallo
# ─────────────────────────────────────────────────────────────────────────────
notify_all() {
  local status="$1" message="$2" triggered_by="${3:-}"
  write_status "$status" "$message" "$triggered_by"
  notify_desktop "[${STACK_NAME}] Despliegue ${status}" "$message"
  notify_webhook "$status" "$message"
}

# ─────────────────────────────────────────────────────────────────────────────
# UN CICLO COMPLETO: esperar cambio → bajar stack → deploy → notificar
# ─────────────────────────────────────────────────────────────────────────────
run_cycle() {
  local cycle="$1"

  log ""
  log "══════════════════════════════════════════════════════"
  log " CICLO #${cycle} — $(date +"%Y-%m-%d %H:%M:%S")"
  log "══════════════════════════════════════════════════════"
  # ── Leer imágenes actualizadas del yml (las recarga en cada ciclo) ────────
  load_images_from_compose
  log "        Imágenes leídas de ${COMPOSE_FILE} (${#IMAGES[@]}):"
  for _img in "${IMAGES[@]}"; do log "          • ${_img}"; done
  # ── PASO 1: Capturar digests de referencia ──────────────────────────────
  log "[ 1/4 ] Capturando digests actuales de ${#IMAGES[@]} imágenes…"
  save_digests

  # ── PASO 2: Polling hasta detectar cambio ───────────────────────────────
  log "[ 2/4 ] Vigilando cambios (cada ${POLL_INTERVAL}s). Ctrl+C para detener."
  local attempt=0 changed_image="" new_digest="" old_digest=""
  local start_time=$SECONDS

  while true; do
    attempt=$((attempt + 1))
    local elapsed=$(( SECONDS - start_time ))

    for img in "${IMAGES[@]}"; do
      local key current_digest known_digest
      key="$(image_to_key "$img")"
      known_digest="$(cat "${DIGEST_DIR}/${key}" 2>/dev/null)" || known_digest=""
      current_digest="$(get_remote_digest "$img" 2>/dev/null)" || current_digest=""

      if [ -z "$current_digest" ]; then
        continue   # no se pudo contactar el registro, ignorar en este intento
      fi

      if [ -z "$known_digest" ] || [ "$current_digest" != "$known_digest" ]; then
        changed_image="$img"
        old_digest="$known_digest"
        new_digest="$current_digest"
        break 2   # salir del for y del while
      fi
    done

    log "[#${attempt} | ${elapsed}s] Sin cambios detectados. Próxima revisión en ${POLL_INTERVAL}s…"
    sleep "$POLL_INTERVAL"
  done

  log "[ 2/4 ] ¡Cambio detectado!"
  log "        Imagen   : ${changed_image}"
  log "        Anterior : ${old_digest:-desconocido}"
  log "        Nuevo    : ${new_digest}"

  # Actualizar el digest guardado para esta imagen de inmediato
  echo "$new_digest" > "${DIGEST_DIR}/$(image_to_key "$changed_image")"

  # ── PASO 3: Bajar el stack ──────────────────────────────────────────────
  log "[ 3/4 ] Bajando stack '${STACK_NAME}'…"
  if $SUDO_PREFIX docker stack ls 2>/dev/null | grep -q "^${STACK_NAME}[[:space:]]"; then
    $SUDO_PREFIX docker stack rm "${STACK_NAME}"
    wait_stack_removed
  else
    log "        Stack '${STACK_NAME}' no estaba activo; se omite la eliminación."
  fi

  # ── PASO 4: Desplegar y notificar ───────────────────────────────────────
  log "[ 4/4 ] Ejecutando ${DEPLOY_SCRIPT}…"

  local deploy_ok=true
  bash "$DEPLOY_SCRIPT" || deploy_ok=false

  if $deploy_ok; then
    local msg="Despliegue completado correctamente — ${changed_image} (${new_digest:0:19}…)"
    log ""
    log "  ┌──────────────────────────────────────────────────┐"
    log "  │  ✔  DESPLIEGUE EXITOSO                           │"
    log "  │     Stack  : ${STACK_NAME}"
    log "  │     Imagen : ${changed_image}"
    log "  │     Digest : ${new_digest:0:19}…"
    log "  │     Hora   : $(date +"%Y-%m-%d %H:%M:%S")"
    log "  └──────────────────────────────────────────────────┘"
    notify_all "success" "$msg" "$changed_image"
  else
    local msg="El despliegue FALLÓ — revisar ${LOG}"
    log ""
    log "  ┌──────────────────────────────────────────────────┐"
    log "  │  ✘  DESPLIEGUE FALLIDO                           │"
    log "  │     Revisar: ${LOG}"
    log "  └──────────────────────────────────────────────────┘"
    notify_all "failure" "$msg" "$changed_image"
    # No abortar el loop; la próxima imagen nueva provocará un nuevo intento
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Manejo de señales para apagado limpio
# ─────────────────────────────────────────────────────────────────────────────
_on_exit() {
  log ""
  log "watch_and_deploy.sh detenido ($(date +"%Y-%m-%d %H:%M:%S"))."
}
trap '_on_exit' EXIT INT TERM

# ─────────────────────────────────────────────────────────────────────────────
# ARRANQUE
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "$DIGEST_DIR"

# Verificar dependencias mínimas
for cmd in curl docker; do
  command -v "$cmd" >/dev/null 2>&1 || die "comando requerido '$cmd' no encontrado."
done

[ -f "$DEPLOY_SCRIPT" ] || die "deploy script '$DEPLOY_SCRIPT' no encontrado."
[ -x "$DEPLOY_SCRIPT" ] || chmod +x "$DEPLOY_SCRIPT"

_init_sudo

# Carga inicial de imágenes (validación temprana antes del primer ciclo)
load_images_from_compose

log "══════════════════════════════════════════════════════"
log " watch_and_deploy.sh — iniciado $(date +"%Y-%m-%d %H:%M:%S")"
log "══════════════════════════════════════════════════════"
log " Stack         : ${STACK_NAME}"
log " Compose file  : ${COMPOSE_FILE}"
log " Registro      : ${IMAGE_REGISTRY}"
log " Imágenes      : ${#IMAGES[@]} (leídas del yml)"
for img in "${IMAGES[@]}"; do log "   • ${img}"; done
log " Intervalo     : ${POLL_INTERVAL}s (1 minuto)"
log " Modo loop     : ${LOOP_MODE}"
log " Script deploy : ${DEPLOY_SCRIPT}"
log " Status file   : ${STATUS_FILE}"
log " Webhook       : ${WEBHOOK_URL:-no configurado}"
log "══════════════════════════════════════════════════════"

# ─────────────────────────────────────────────────────────────────────────────
# BUCLE PRINCIPAL
# ─────────────────────────────────────────────────────────────────────────────
cycle=0
while true; do
  cycle=$((cycle + 1))
  run_cycle "$cycle"

  if [ "$LOOP_MODE" != "true" ]; then
    log "LOOP_MODE=false — terminando tras el primer ciclo."
    break
  fi

  log "Reiniciando ciclo en 5s…"
  sleep 5
done
