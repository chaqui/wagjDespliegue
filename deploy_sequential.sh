#!/usr/bin/env bash
set -euo pipefail

LOG="./deploy.log"
MAIN_STACK="sistema"
COMPOSE_FILE="$(pwd)/docker-stack.yml"

log() { echo "[$(date +"%Y-%m-%d %H:%M:%S")] $*" | tee -a "$LOG"; }

check_cmd() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: required command '$1' not found"; exit 1; } }


check_cmd docker

# Generar TRAEFIK_DASHBOARD_AUTH automáticamente desde TRAEFIK_USER y TRAEFIK_PASSWORD
# si TRAEFIK_DASHBOARD_AUTH no está definida en el .env
generate_traefik_auth() {
  if [ -z "${TRAEFIK_DASHBOARD_AUTH:-}" ]; then
    if [ -z "${TRAEFIK_USER:-}" ] || [ -z "${TRAEFIK_PASSWORD:-}" ]; then
      log "ERROR: TRAEFIK_DASHBOARD_AUTH no está definida y faltan TRAEFIK_USER o TRAEFIK_PASSWORD para generarla."
      log "Agrega al .env:  TRAEFIK_USER=admin  y  TRAEFIK_PASSWORD=TuPassword"
      exit 1
    fi
    # Requiere htpasswd (apache2-utils) o openssl
    if command -v htpasswd >/dev/null 2>&1; then
      HASH=$(htpasswd -nb "${TRAEFIK_USER}" "${TRAEFIK_PASSWORD}" | sed -e 's/\$/\$\$/g')
    elif command -v openssl >/dev/null 2>&1; then
      HASHED=$(openssl passwd -apr1 "${TRAEFIK_PASSWORD}")
      HASH="${TRAEFIK_USER}:$(echo "$HASHED" | sed -e 's/\$/\$\$/g')"
    else
      log "ERROR: se necesita 'htpasswd' (apache2-utils) u 'openssl' para generar TRAEFIK_DASHBOARD_AUTH."
      log "Instala con: sudo apt-get install -y apache2-utils"
      exit 1
    fi
    export TRAEFIK_DASHBOARD_AUTH="$HASH"
    log "TRAEFIK_DASHBOARD_AUTH generado para usuario '${TRAEFIK_USER}'"
  else
    log "TRAEFIK_DASHBOARD_AUTH cargado desde .env"
  fi
}

# Validar que las variables críticas estén definidas y no vacías
validate_required_vars() {
  REQUIRED_VARS=(
    "ACME_EMAIL"
    "TRAEFIK_DASHBOARD_AUTH"
    "DB_URL"
    "DB_USERNAME"
    "DB_PASSWORD"
    "JWT_SECRET"
  )
  MISSING=()
  for var in "${REQUIRED_VARS[@]}"; do
    val="${!var:-}"
    if [ -z "$val" ]; then
      MISSING+=("$var")
    fi
  done
  if [ ${#MISSING[@]} -gt 0 ]; then
    log "ERROR: las siguientes variables requeridas están vacías o no definidas en .env:"
    for m in "${MISSING[@]}"; do
      log "  - $m"
    done
    exit 1
  fi
  log "Variables requeridas validadas correctamente."
}

# Detectar versión de API de Docker del servidor e inyectarla en el stack
# Esto evita que DOCKER_API_VERSION fija cause incompatibilidades con el proveedor Docker de Traefik
detect_docker_api_version() {
  DETECTED_API=$($SUDO_PREFIX $DOCKER_CMD version --format '{{.Server.APIVersion}}' 2>/dev/null || true)
  if [ -n "$DETECTED_API" ]; then
    export DOCKER_API_VERSION="$DETECTED_API"
    log "Docker API versión detectada: $DOCKER_API_VERSION"
  else
    log "ADVERTENCIA: no se pudo detectar la versión de API de Docker; DOCKER_API_VERSION no será enviada a Traefik"
    unset DOCKER_API_VERSION 2>/dev/null || true
  fi
}

# Determinar si se debe usar sudo para Docker (permiso sobre /var/run/docker.sock)
if docker info >/dev/null 2>&1; then
  DOCKER_CMD="docker"
  SUDO_PREFIX=""
else
  # usar -E para preservar variables de entorno cuando se ejecute con sudo
  DOCKER_CMD="docker"
  SUDO_PREFIX="sudo -E"
  log "Nota: usando sudo -E para comandos Docker (permiso sobre /var/run/docker.sock). Se preservarán variables de entorno." 
fi

detect_docker_api_version

log "Iniciando despliegue secuencial usando $COMPOSE_FILE"
# Verificar si el nodo es parte de un Swarm y, si no lo es, intentar inicializarlo
check_and_init_swarm() {
  SWARM_LOCAL=$($SUDO_PREFIX $DOCKER_CMD info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "inactive")
  CONTROL_AVAILABLE=$($SUDO_PREFIX $DOCKER_CMD info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || echo "false")
  if [ "$SWARM_LOCAL" != "active" ]; then
    log "Swarm no activo en este nodo. Se intentará inicializar swarm localmente..."
    ADVERTISE_ADDR=""
    ADVERTISE_ADDR=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
    if [ -z "$ADVERTISE_ADDR" ]; then
      ADVERTISE_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
    if [ -z "$ADVERTISE_ADDR" ]; then
      ADVERTISE_ADDR=$(hostname -i 2>/dev/null || true)
    fi
    if [ -z "$ADVERTISE_ADDR" ]; then
      log "ERROR: no se pudo detectar una IP para --advertise-addr. Ejecuta 'docker swarm init' manualmente."
      exit 1
    fi
    log "Inicializando swarm con --advertise-addr $ADVERTISE_ADDR"
    if $SUDO_PREFIX $DOCKER_CMD swarm init --advertise-addr "$ADVERTISE_ADDR" 2>&1 | tee -a "$LOG"; then
      log "Swarm inicializado correctamente en este nodo (manager)."
    else
      log "ERROR: fallo al inicializar swarm en este nodo."
      exit 1
    fi
  else
    if [ "$CONTROL_AVAILABLE" != "true" ]; then
      log "ERROR: este nodo pertenece a un swarm pero no es manager (ControlAvailable=false)."
      log "Para desplegar un stack debes usar un manager. Ejecuta 'docker swarm join' en este nodo con el token de manager, o ejecuta este script en un manager."
      exit 1
    fi
    log "Swarm activo y nodo es manager."
  fi
}

check_and_init_swarm

# Si ya existe un despliegue previo del stack, eliminarlo antes de desplegar de nuevo
remove_stack_if_exists() {
  if $SUDO_PREFIX $DOCKER_CMD stack ls --format '{{.Name}}' 2>/dev/null | grep -wq "$MAIN_STACK"; then
    log "Detectado despliegue previo del stack '$MAIN_STACK'. Procediendo a remover..."
    if $SUDO_PREFIX $DOCKER_CMD stack rm "$MAIN_STACK" 2>&1 | tee -a "$LOG"; then
      log "Comando stack rm enviado para $MAIN_STACK. Esperando a que los servicios se retiren..."
      # esperar hasta que no queden servicios con la etiqueta del stack (timeout)
      WAIT=0
      MAX_WAIT_REMOVE=60
      while [ $WAIT -lt $MAX_WAIT_REMOVE ]; do
        remaining=$($SUDO_PREFIX $DOCKER_CMD service ls --filter label=com.docker.stack.namespace=$MAIN_STACK --format '{{.Name}}' 2>/dev/null || true)
        if [ -z "$remaining" ]; then
          log "Servicios del stack $MAIN_STACK eliminados."
          break
        fi
        sleep 3
        WAIT=$((WAIT+3))
      done
      if [ $WAIT -ge $MAX_WAIT_REMOVE ]; then
        log "ADVERTENCIA: tiempo de espera agotado al eliminar servicios del stack $MAIN_STACK"
      fi
    else
      log "ERROR: fallo al ejecutar 'docker stack rm $MAIN_STACK'"
      exit 1
    fi
  else
    log "No existe un despliegue previo del stack '$MAIN_STACK'."
  fi
}

remove_stack_if_exists

# Preparación: crear carpetas necesarias para montajes bind (keys, logs, certs, pubkeys)
prepare_dirs() {
  DIRS=("./keys" "./keys/public" "./logs/auth" "./logs/clinica-backend" "./certs" "./pubkeys")
  for d in "${DIRS[@]}"; do
    if [ ! -d "$d" ]; then
      log "Creando carpeta $d"
      mkdir -p "$d" || { log "ERROR: fallo creando $d"; exit 1; }
      chmod 777 "$d" || true
    else
      log "Carpeta $d ya existe"
    fi
  done
  # Asegurar permisos mínimos de keys
  if [ -d "./keys" ]; then
    # Permitir que el proceso dentro del contenedor pueda escribir en ./keys
    # (algunas imágenes de contenedor ejecutan con un UID distinto al host)
    chmod -R 777 ./keys || true
  fi
}

prepare_dirs

# Inicializar acme.json en el volumen de Traefik con permisos 600
# (Traefik requiere que exista y tenga chmod 600; si no, ignora ACME silenciosamente)
init_acme_json() {
  ACME_VOL="${MAIN_STACK}_traefik-certificates"
  log "Inicializando acme.json en volumen $ACME_VOL con permisos 600"
  $SUDO_PREFIX $DOCKER_CMD run --rm \
    -v "${ACME_VOL}:/certs" \
    alpine sh -c "
      touch /certs/acme.json
      chmod 600 /certs/acme.json
      echo 'acme.json listo'
      ls -la /certs/
    " 2>&1 | tee -a "$LOG" || log "ADVERTENCIA: no se pudo inicializar acme.json"
}

init_acme_json

# deploy full stack (services will start)
log "Iniciando despliegue del stack $MAIN_STACK"
# Cargar variables desde .env al entorno para que sudo -E las preserve
if [ -f .env ]; then
  log "Cargando variables desde .env al entorno (export)"
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
else
  log "ADVERTENCIA: .env no encontrado en $(pwd); las variables no serán exportadas"
fi

generate_traefik_auth
validate_required_vars

# Pre-crear la red overlay antes del stack deploy para evitar race condition
NETWORK_NAME="${MAIN_STACK}_public-net"
log "Recreando red overlay ${NETWORK_NAME} (limpieza preventiva)"
$SUDO_PREFIX $DOCKER_CMD network rm "${NETWORK_NAME}" 2>&1 | tee -a "$LOG" || true
# Esperar hasta que la red desaparezca realmente (máx 15s)
for _i in $(seq 1 15); do
  if ! $SUDO_PREFIX $DOCKER_CMD network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
    break
  fi
  sleep 1
done
$SUDO_PREFIX $DOCKER_CMD network create --driver overlay --attachable "${NETWORK_NAME}" 2>&1 | tee -a "$LOG"

if ! $SUDO_PREFIX $DOCKER_CMD stack deploy -c "$COMPOSE_FILE" "$MAIN_STACK" --with-registry-auth 2>&1 | tee -a "$LOG"; then
  log "ERROR: fallo al desplegar el stack"
  exit 1
fi
log "Despliegue inicial del stack solicitado"

# gather services in the stack
SERVICES=$($SUDO_PREFIX $DOCKER_CMD service ls --filter label=com.docker.stack.namespace=$MAIN_STACK --format '{{.Name}}')
if [ -z "$SERVICES" ]; then
  log "ERROR: no se encontraron servicios para el stack $MAIN_STACK"
  exit 1
fi

# record desired replicas and scale down non-auth services to 0
MAPPING_FILE="/tmp/${MAIN_STACK}_replicas.txt"
> "$MAPPING_FILE"
for svc in $SERVICES; do
  # skip auth service
  if [[ "$svc" == "${MAIN_STACK}_auth-service" ]]; then
    log "Dejando $svc en ejecución (servicio auth)"
    continue
  fi
  # inspect desired replicas (empty => global)
  rep=$($SUDO_PREFIX $DOCKER_CMD service inspect --format '{{if .Spec.Mode.Replicated}}{{.Spec.Mode.Replicated.Replicas}}{{end}}' "$svc" 2>/dev/null || true)
  if [ -n "$rep" ]; then
    # Forzar una réplica por servicio al restaurar
    desired_rep=1
    echo "$svc $desired_rep" >> "$MAPPING_FILE"
    log "Iniciando escala de $svc a 0 (antes $rep, se restaurará a $desired_rep)"
    if $SUDO_PREFIX $DOCKER_CMD service update --replicas 0 "$svc" 2>&1 | tee -a "$LOG"; then
      log "Escalado completado para $svc"
    else
      log "ADVERTENCIA: fallo al escalar $svc a 0"
    fi
  else
    log "$svc es global o no tiene réplicas replicadas, se omite escalado"
  fi
done

# esperar 15s para que auth-service inicialice y genere certificados
WAIT_INITIAL=15
log "Esperando ${WAIT_INITIAL}s para que auth-service inicialice y genere certificados"
sleep $WAIT_INITIAL

# verificar si auth generó un .pem en ./keys o ./keys/public
PEM_PATH=""
if compgen -G "./keys/*.pem" >/dev/null; then
  PEM_PATH=$(ls ./keys/*.pem | head -n1)
elif compgen -G "./keys/public/*.pem" >/dev/null; then
  PEM_PATH=$(ls ./keys/public/*.pem | head -n1)
fi
if [ -z "$PEM_PATH" ]; then
  log "ADVERTENCIA: auth-service no generó .pem en ./keys ni en ./keys/public después de ${WAIT_INITIAL}s"
  log "Revisando logs del servicio auth-service..."
  $SUDO_PREFIX $DOCKER_CMD service logs ${MAIN_STACK}_auth-service --tail 200 2>&1 | tee -a "$LOG" || true

  # Intentar forzar reinicio de tareas del servicio auth-service
  log "Intentando forzar reinicio del servicio ${MAIN_STACK}_auth-service (service update --force)"
  if $SUDO_PREFIX $DOCKER_CMD service update --force ${MAIN_STACK}_auth-service 2>&1 | tee -a "$LOG"; then
    log "Comando --force enviado. Esperando 10s para reinicio..."
    sleep 10
  else
    log "ADVERTENCIA: fallo al forzar update del servicio ${MAIN_STACK}_auth-service"
  fi

  # Reintentar detectar .pem después del forzado
  PEM_PATH=""
  if compgen -G "./keys/*.pem" >/dev/null; then
    PEM_PATH=$(ls ./keys/*.pem | head -n1)
  elif compgen -G "./keys/public/*.pem" >/dev/null; then
    PEM_PATH=$(ls ./keys/public/*.pem | head -n1)
  fi

  # Si aún no hay .pem, registrar error y mostrar logs del servicio
  if [ -z "$PEM_PATH" ]; then
    log "ERROR: tras forzar reinicio no se encontró .pem en ./keys ni en ./keys/public"
    log "Revisando logs del servicio auth-service para diagnosticar..."
    $SUDO_PREFIX $DOCKER_CMD service logs ${MAIN_STACK}_auth-service --tail 500 2>&1 | tee -a "$LOG" || true
    exit 1
  fi
fi
log "PEM detectado: $PEM_PATH"

# wait for auth-service to have RUNNING task
log "Esperando que ${MAIN_STACK}_auth-service tenga una tarea en ejecución"
MAX_WAIT=180
SLEEP=5
elapsed=0
ready=0
while [ $elapsed -le $MAX_WAIT ]; do
  running=$($SUDO_PREFIX $DOCKER_CMD service ps --filter desired-state=running --format '{{.CurrentState}}' ${MAIN_STACK}_auth-service 2>/dev/null | grep -c Running || true)
  if [ "$running" -ge 1 ]; then
    log "auth-service tiene tarea(s) en ejecución"
    ready=1
    break
  fi
  sleep $SLEEP
  elapsed=$((elapsed+SLEEP))
done
if [ $ready -ne 1 ]; then
  log "ERROR: las tareas de auth-service no están en ejecución después de ${MAX_WAIT}s"
  $SUDO_PREFIX $DOCKER_CMD service ls --filter label=com.docker.stack.namespace=$MAIN_STACK | tee -a "$LOG"
  $SUDO_PREFIX $DOCKER_CMD stack ps $MAIN_STACK | tee -a "$LOG"
  exit 1
fi

# check auth API by launching a temporary curl container attached to overlay network
log "Comprobando API de auth-service mediante la red overlay (http://auth-service:8082/api/services)"
API_OK=0
MAX_API_WAIT=120
elapsed=0
while [ $elapsed -le $MAX_API_WAIT ]; do
  HTTP_CODE=$($SUDO_PREFIX $DOCKER_CMD run --rm --network ${MAIN_STACK}_public-net curlimages/curl:latest \
    curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 http://auth-service:8082/api/services \
    2>/tmp/auth_probe_err || true)
  CURL_ERR=$(cat /tmp/auth_probe_err 2>/dev/null || true)
  log "HTTP status curl (intento ${elapsed}s): '${HTTP_CODE}'"
  [ -n "$CURL_ERR" ] && log "Stderr curl: ${CURL_ERR}"
  if echo "$HTTP_CODE" | grep -qE '^[0-9]+$' && [ "$HTTP_CODE" -ge 100 ]; then
    log "API de auth-service accesible (HTTP ${HTTP_CODE})."
    API_OK=1
    break
  fi
  sleep 5
  elapsed=$((elapsed+5))
done
if [ $API_OK -ne 1 ]; then
  log "ERROR: la API de auth-service no respondió en ${MAX_API_WAIT}s"
  $SUDO_PREFIX $DOCKER_CMD service logs ${MAIN_STACK}_auth-service --tail 200 2>&1 | tee -a "$LOG" || true
  exit 1
fi

# restore replicas for other services
log "Restaurando réplicas para otros servicios"
while read -r line; do
  svc_name=$(echo "$line" | awk '{print $1}')
  svc_rep=$(echo "$line" | awk '{print $2}')
  log "Iniciando escala de $svc_name -> $svc_rep"
  if $SUDO_PREFIX $DOCKER_CMD service update --replicas "$svc_rep" "$svc_name" 2>&1 | tee -a "$LOG"; then
    log "Escalado completado para $svc_name -> $svc_rep"
  else
    log "ERROR: fallo al escalar $svc_name a $svc_rep"
  fi
done < "$MAPPING_FILE"

# Esperar que todos los servicios restaurados estén running
log "Esperando que todos los servicios estén en ejecución (máx 120s)..."
MAX_WAIT_UP=120
elapsed=0
all_up=0
while [ $elapsed -le $MAX_WAIT_UP ]; do
  not_ready=$($SUDO_PREFIX $DOCKER_CMD service ls \
    --filter label=com.docker.stack.namespace=$MAIN_STACK \
    --format '{{.Name}} {{.Replicas}}' 2>/dev/null | \
    awk -F'[ /]' '{if($2!=0 && $2!=$3) print $1}' || true)
  if [ -z "$not_ready" ]; then
    all_up=1
    break
  fi
  log "Servicios pendientes: $not_ready (${elapsed}s)"
  sleep 5
  elapsed=$((elapsed+5))
done
if [ $all_up -ne 1 ]; then
  log "ADVERTENCIA: algunos servicios no alcanzaron el estado deseado en ${MAX_WAIT_UP}s:"
  $SUDO_PREFIX $DOCKER_CMD service ls --filter label=com.docker.stack.namespace=$MAIN_STACK | tee -a "$LOG"
else
  log "Todos los servicios están en ejecución."
fi
