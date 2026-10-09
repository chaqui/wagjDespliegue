#!/usr/bin/env bash
set -Eeuo pipefail

# Descarga las imagenes declaradas en docker-stack.yml y actualiza solamente
# los servicios Docker Swarm cuyo digest haya cambiado. Si el stack no existe,
# ejecuta el script de despliegue inicial del proyecto.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_NAME="${STACK_NAME:-sistema}"
COMPOSE_FILE="${COMPOSE_FILE:-${SCRIPT_DIR}/docker-stack.yml}"
INITIAL_DEPLOY_SCRIPT="${INITIAL_DEPLOY_SCRIPT:-${SCRIPT_DIR}/deploy_sequential.sh}"
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/update-images.log}"
LOCK_FILE="${LOCK_FILE:-/tmp/${STACK_NAME}-update-images.lock}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  exit 1
}

command -v docker >/dev/null 2>&1 || die "Docker no esta instalado."
[ -f "$COMPOSE_FILE" ] || die "No existe $COMPOSE_FILE."

# Evita que cron o systemd ejecuten dos actualizaciones simultaneas.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Ya hay otra actualizacion en curso."
fi

if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
  DOCKER=(sudo -E docker)
else
  die "El usuario no tiene acceso a Docker y sudo requiere interaccion."
fi

docker_cmd() {
  "${DOCKER[@]}" "$@"
}

is_manager() {
  [ "$(docker_cmd info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)" = "active" ] &&
    [ "$(docker_cmd info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || true)" = "true" ]
}

stack_exists() {
  docker_cmd stack ls --format '{{.Name}}' 2>/dev/null | grep -Fxq "$STACK_NAME"
}

# Emite: <servicio-compose>|<imagen>
read_service_images() {
  awk '
    /^services:[[:space:]]*$/ { in_services=1; next }
    in_services && /^[^[:space:]]/ { in_services=0 }
    in_services && /^  [[:alnum:]_.-]+:[[:space:]]*$/ {
      service=$1
      sub(/:$/, "", service)
    }
    in_services && /^[[:space:]]{4}image:[[:space:]]*/ {
      image=$0
      sub(/^[[:space:]]*image:[[:space:]]*/, "", image)
      sub(/[[:space:]]*(#.*)?$/, "", image)
      gsub(/^['\''"]|['\''"]$/, "", image)
      print service "|" image
    }
  ' "$COMPOSE_FILE"
}

image_digest() {
  local image="$1" repository candidate
  repository="${image%%@*}"
  if [[ "$repository" == *:* ]] && [[ "${repository##*/}" == *:* ]]; then
    repository="${repository%:*}"
  fi

  while IFS= read -r candidate; do
    case "$candidate" in
      "${repository}@"*) printf '%s\n' "${candidate##*@}"; return 0 ;;
    esac
  done < <(docker_cmd image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image" 2>/dev/null || true)

  return 1
}

current_service_digest() {
  local swarm_service="$1" current
  current="$(docker_cmd service inspect --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' "$swarm_service" 2>/dev/null || true)"
  case "$current" in
    *@*) printf '%s\n' "${current##*@}" ;;
    *) printf '\n' ;;
  esac
}

if ! stack_exists; then
  log "El stack '$STACK_NAME' no existe; iniciando el primer despliegue."
  [ -f "$INITIAL_DEPLOY_SCRIPT" ] || die "No existe $INITIAL_DEPLOY_SCRIPT."
  (
    cd "$SCRIPT_DIR"
    bash "$INITIAL_DEPLOY_SCRIPT"
  ) 2>&1 | tee -a "$LOG_FILE"
  log "Primer despliegue finalizado."
  exit 0
fi

is_manager || die "El stack existe, pero este nodo no es manager del Swarm."

declare -a SERVICE_IMAGES=()
while IFS= read -r mapping; do
  [ -n "$mapping" ] && SERVICE_IMAGES+=("$mapping")
done < <(read_service_images)
[ "${#SERVICE_IMAGES[@]}" -gt 0 ] || die "No se encontraron servicios con image: en $COMPOSE_FILE."

declare -A PULLED_DIGESTS=()
declare -A PULL_FAILED=()
declare -a UPDATED_SERVICES=()
declare -a UNCHANGED_SERVICES=()
declare -a FAILED_SERVICES=()

log "Descargando las imagenes declaradas en $COMPOSE_FILE..."
for mapping in "${SERVICE_IMAGES[@]}"; do
  image="${mapping#*|}"
  [ -n "${PULLED_DIGESTS[$image]+x}" ] && continue
  [ -n "${PULL_FAILED[$image]+x}" ] && continue

  log "Descargando $image"
  if ! docker_cmd pull "$image" 2>&1 | tee -a "$LOG_FILE"; then
    log "ERROR: no se pudo descargar $image; sus servicios no se actualizaran."
    PULL_FAILED["$image"]=1
    continue
  fi

  digest="$(image_digest "$image" || true)"
  if [ -z "$digest" ]; then
    log "ERROR: no se pudo obtener el digest local de $image."
    PULL_FAILED["$image"]=1
    continue
  fi
  PULLED_DIGESTS["$image"]="$digest"
done

log "Comparando las imagenes descargadas con los servicios del stack..."
for mapping in "${SERVICE_IMAGES[@]}"; do
  compose_service="${mapping%%|*}"
  image="${mapping#*|}"
  swarm_service="${STACK_NAME}_${compose_service}"

  if [ -n "${PULL_FAILED[$image]+x}" ]; then
    FAILED_SERVICES+=("$swarm_service")
    continue
  fi

  if ! docker_cmd service inspect "$swarm_service" >/dev/null 2>&1; then
    log "ADVERTENCIA: $swarm_service no existe en el stack; se omite."
    FAILED_SERVICES+=("$swarm_service")
    continue
  fi

  new_digest="${PULLED_DIGESTS[$image]}"
  old_digest="$(current_service_digest "$swarm_service")"
  if [ -n "$old_digest" ] && [ "$old_digest" = "$new_digest" ]; then
    log "Sin cambios: $swarm_service"
    UNCHANGED_SERVICES+=("$swarm_service")
    continue
  fi

  log "Actualizando $swarm_service: ${old_digest:-sin-digest} -> $new_digest"
  if docker_cmd service update \
    --with-registry-auth \
    --image "${image%%@*}@${new_digest}" \
    "$swarm_service" 2>&1 | tee -a "$LOG_FILE"; then
    UPDATED_SERVICES+=("$swarm_service")
  else
    log "ERROR: fallo la actualizacion de $swarm_service."
    FAILED_SERVICES+=("$swarm_service")
  fi
done

log "Resumen: ${#UPDATED_SERVICES[@]} actualizado(s), ${#UNCHANGED_SERVICES[@]} sin cambios, ${#FAILED_SERVICES[@]} con error/omitido(s)."
if [ "${#UPDATED_SERVICES[@]}" -gt 0 ]; then
  log "Servicios actualizados: ${UPDATED_SERVICES[*]}"
fi
if [ "${#FAILED_SERVICES[@]}" -gt 0 ]; then
  log "Servicios con error u omitidos: ${FAILED_SERVICES[*]}"
  exit 1
fi

