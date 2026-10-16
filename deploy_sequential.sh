#!/usr/bin/env bash
set -euo pipefail

LOG="./deploy.log"
MAIN_STACK="sistema"
COMPOSE_FILE="$(pwd)/docker-stack.yml"

log() { echo "[$(date +"%Y-%m-%d %H:%M:%S")] $*" | tee -a "$LOG"; }

print_service_logs() {
  local svc="$1"
  log "Últimos logs de $svc:"
  $SUDO_PREFIX $DOCKER_CMD service logs --timestamps --tail 200 "$svc" \
    2>&1 | tee -a "$LOG" || log "ADVERTENCIA: no fue posible obtener logs de $svc"
}

check_cmd() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: required command '$1' not found"; exit 1; } }


check_cmd docker

load_env_preserving_server_vars() {
  local line key value overrides=()
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    line="${line#export }"
    key="${line%%=*}"
    value="${line#*=}"
    key="$(printf '%s' "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { log "ERROR: variable inválida en .env: $key"; exit 1; }
    if [[ "$value" == \"*\" ]] || [[ "$value" == \'*\' ]]; then value="${value:1:${#value}-2}"; fi
    if printenv "$key" >/dev/null 2>&1; then
      [ "${!key-}" = "$value" ] || overrides+=("$key")
    else
      export "$key=$value"
    fi
  done < .env
  if [ "${#overrides[@]}" -gt 0 ]; then
    log "Variables del servidor que tienen prioridad sobre .env: $(printf '%s\n' "${overrides[@]}" | sort -u | tr '\n' ' ')"
  fi
}

generate_database_url() {
  case "${DB_URL:-}" in
    ""|*example.internal*|*REEMPLAZAR*|*CHANGE_ME*|*change_me*) ;;
    *) return 0 ;;
  esac
  if [ -n "${DB_HOST:-}" ] && [ -n "${DB_NAME:-}" ]; then
    export DB_PORT="${DB_PORT:-5432}"
    export DB_URL="jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}"
    log "DB_URL generado automáticamente desde DB_HOST, DB_PORT y DB_NAME"
  fi
}

generate_jwt_secret() {
  local jwt_file="${JWT_SECRET_FILE:-$(pwd)/.jwt-secret}"
  case "${JWT_SECRET:-}" in
    ""|*REEMPLAZAR*|*CHANGE_ME*|*change_me*) ;;
    *) return 0 ;;
  esac
  if [ -s "$jwt_file" ]; then
    export JWT_SECRET="$(<"$jwt_file")"
    log "JWT_SECRET cargado desde el archivo seguro local"
    return 0
  fi
  umask 077
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 64 > "$jwt_file"
  elif command -v sha256sum >/dev/null 2>&1; then
    head -c 128 /dev/urandom | sha256sum | awk '{print $1}' > "$jwt_file"
  else
    log "ERROR: se necesita openssl o sha256sum para generar JWT_SECRET"
    exit 1
  fi
  chmod 600 "$jwt_file"
  export JWT_SECRET="$(<"$jwt_file")"
  log "JWT_SECRET generado automáticamente y guardado en un archivo seguro local"
}

# Generar TRAEFIK_DASHBOARD_AUTH automáticamente desde TRAEFIK_USER y TRAEFIK_PASSWORD
# si TRAEFIK_DASHBOARD_AUTH no está definida en el .env
generate_traefik_auth() {
  if [ -z "${TRAEFIK_DASHBOARD_AUTH:-}" ] || \
     [[ "${TRAEFIK_DASHBOARD_AUTH}" == *REEMPLAZAR* ]] || \
     [[ "${TRAEFIK_DASHBOARD_AUTH}" == *CHANGE_ME* ]] || \
     [[ "${TRAEFIK_DASHBOARD_AUTH}" == *change_me* ]]; then
    if [ -z "${TRAEFIK_USER:-}" ] || [ -z "${TRAEFIK_PASSWORD:-}" ]; then
      log "ERROR: TRAEFIK_DASHBOARD_AUTH no está definida y faltan TRAEFIK_USER o TRAEFIK_PASSWORD para generarla."
      log "Agrega al .env:  TRAEFIK_USER=admin  y  TRAEFIK_PASSWORD=TuPassword"
      exit 1
    fi
    case "$TRAEFIK_PASSWORD" in
      *REEMPLAZAR*|*CHANGE_ME*|*change_me*)
        log "ERROR: TRAEFIK_PASSWORD conserva un valor de ejemplo."
        exit 1 ;;
    esac
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
  PLACEHOLDERS=()
  for var in DB_URL DB_USERNAME DB_PASSWORD JWT_SECRET; do
    val="${!var:-}"
    case "$val" in
      *example.internal*|*REEMPLAZAR*|*CHANGE_ME*|*change_me*) PLACEHOLDERS+=("$var") ;;
    esac
  done
  if [ ${#PLACEHOLDERS[@]} -gt 0 ]; then
    log "ERROR: variables con valores de ejemplo: ${PLACEHOLDERS[*]}"
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

# Preparación: crear carpetas necesarias para montajes bind.
# auth-service escribe ./keys/public_key.pem y los demás servicios montan la
# misma carpeta como /app/keys en modo lectura.
prepare_dirs() {
  DIRS=(
    "./keys"
    "./logs/auth"
    "./logs/losmolinos-store-backend"
    "./logs/crecilandia-store-backend"
    "./logs/losmolinos-restaurante-backend"
    "./logs/crecilandia-restaurante-backend"
    "./data/losmolinos-store"
    "./data/crecilandia-store"
    "./data/losmolinos-restaurante"
    "./data/crecilandia-restaurante"
    "./certs"
  )
  for d in "${DIRS[@]}"; do
    if [ ! -d "$d" ]; then
      log "Creando carpeta $d"
      mkdir -p "$d" || { log "ERROR: fallo creando $d"; exit 1; }
      if [ "$d" = "./certs" ]; then chmod 755 "$d" || true; else chmod 777 "$d" || true; fi
    else
      log "Carpeta $d ya existe"
    fi
  done
  # Permitir escritura en el directorio sin alterar los permisos de los PEM
  # existentes, que pueden pertenecer al usuario del contenedor o a root.
  if [ -d "./keys" ]; then
    chmod 777 ./keys || true
  fi
}

prepare_dirs

# Los restaurantes ejecutan como UID 1000 y necesitan identidades RSA
# persistentes e independientes.
prepare_restaurant_key_dirs() {
  local dir
  for dir in /opt/wagj/keys/losmolinos-restaurante /opt/wagj/keys/crecilandia-restaurante; do
    if [ "$(id -u)" -eq 0 ]; then
      install -d -m 700 -o 1000 -g 1000 "$dir"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo install -d -m 700 -o 1000 -g 1000 "$dir"
    else
      log "ERROR: se requiere root o sudo sin interacción para preparar $dir"
      exit 1
    fi
    log "Directorio RSA preparado: $dir (UID/GID 1000, modo 700)"
  done
}

prepare_auth_public_key_secret() {
  [ -s "./keys/public_key.pem" ] || {
    log "ERROR: falta ./keys/public_key.pem; no se puede crear el secreto auth_public_key"
    exit 1
  }
  # El stack anterior ya fue retirado, por lo que el secreto puede recrearse
  # para reflejar exactamente la llave pública persistida por Auth.
  if $SUDO_PREFIX $DOCKER_CMD secret inspect auth_public_key >/dev/null 2>&1; then
    $SUDO_PREFIX $DOCKER_CMD secret rm auth_public_key >/dev/null
  fi
  $SUDO_PREFIX $DOCKER_CMD secret create auth_public_key ./keys/public_key.pem >/dev/null
  log "Secreto Swarm auth_public_key creado desde ./keys/public_key.pem"
}

prepare_restaurant_key_dirs
prepare_auth_public_key_secret

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
  load_env_preserving_server_vars
else
  log "ADVERTENCIA: .env no encontrado en $(pwd); las variables no serán exportadas"
fi

generate_database_url
generate_jwt_secret
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
    if $SUDO_PREFIX $DOCKER_CMD service update --detach=true --replicas 0 "$svc" 2>&1 | tee -a "$LOG"; then
      log "Escalado completado para $svc"
    else
      log "ADVERTENCIA: fallo al escalar $svc a 0"
    fi
  else
    log "$svc es global o no tiene réplicas replicadas, se omite escalado"
  fi
done

# Esperar activamente a que auth-service inicialice y genere la llave. En
# instancias pequeñas Spring/JPA puede tardar varios minutos.
WAIT_INITIAL=300
WAIT_KEY_INTERVAL=5
waited_for_key=0
log "Esperando hasta ${WAIT_INITIAL}s para que auth-service genere ./keys/public_key.pem"
while [ "$waited_for_key" -lt "$WAIT_INITIAL" ] && [ ! -s "./keys/public_key.pem" ]; do
  sleep "$WAIT_KEY_INTERVAL"
  waited_for_key=$((waited_for_key + WAIT_KEY_INTERVAL))
done

# Verificar que auth generó la llave compartida.
PEM_PATH=""
if [ -s "./keys/public_key.pem" ]; then
  PEM_PATH="./keys/public_key.pem"
fi
if [ -z "$PEM_PATH" ]; then
  log "ADVERTENCIA: auth-service no generó ./keys/public_key.pem después de ${WAIT_INITIAL}s"
  log "Revisando logs del servicio auth-service..."
  $SUDO_PREFIX $DOCKER_CMD service logs ${MAIN_STACK}_auth-service --tail 200 2>&1 | tee -a "$LOG" || true

  # Intentar forzar reinicio de tareas del servicio auth-service
  log "Intentando forzar reinicio del servicio ${MAIN_STACK}_auth-service (service update --force)"
  if $SUDO_PREFIX $DOCKER_CMD service update --detach=true --force ${MAIN_STACK}_auth-service 2>&1 | tee -a "$LOG"; then
    log "Comando --force enviado. Esperando hasta ${WAIT_INITIAL}s para que se genere la llave..."
    waited_for_key=0
    while [ "$waited_for_key" -lt "$WAIT_INITIAL" ] && [ ! -s "./keys/public_key.pem" ]; do
      sleep "$WAIT_KEY_INTERVAL"
      waited_for_key=$((waited_for_key + WAIT_KEY_INTERVAL))
    done
  else
    log "ADVERTENCIA: fallo al forzar update del servicio ${MAIN_STACK}_auth-service"
  fi

  # Reintentar detectar la llave después del forzado
  PEM_PATH=""
  if [ -s "./keys/public_key.pem" ]; then
    PEM_PATH="./keys/public_key.pem"
  fi

  # Si aún no hay .pem, registrar error y mostrar logs del servicio
  if [ -z "$PEM_PATH" ]; then
    log "ERROR: tras forzar reinicio no se encontró ./keys/public_key.pem"
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

# Restaurar los demás servicios estrictamente uno por uno. La llave ya fue
# validada; aun así se espera la convergencia de cada servicio antes de iniciar
# el siguiente para limitar picos de memoria y detectar fallos temprano.
wait_service_replicas() {
  local svc="$1" wanted="$2" elapsed=0 running state
  while [ "$elapsed" -le 300 ]; do
    running=$($SUDO_PREFIX $DOCKER_CMD service ps --filter desired-state=running \
      --format '{{.CurrentState}}' "$svc" 2>/dev/null | grep -c '^Running' || true)
    state=$($SUDO_PREFIX $DOCKER_CMD service inspect \
      --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' "$svc" 2>/dev/null || true)
    case "$state" in
      paused|rollback_paused|rollback_completed) return 1 ;;
    esac
    if [ "$running" -eq "$wanted" ]; then return 0; fi
    sleep 5
    elapsed=$((elapsed+5))
  done
  return 1
}

# restore replicas for other services
log "Restaurando réplicas para otros servicios"
while read -r line; do
  svc_name=$(echo "$line" | awk '{print $1}')
  svc_rep=$(echo "$line" | awk '{print $2}')
  log "Iniciando escala de $svc_name -> $svc_rep"
  if $SUDO_PREFIX $DOCKER_CMD service update --detach=true --replicas "$svc_rep" "$svc_name" 2>&1 | tee -a "$LOG"; then
    log "Esperando que $svc_name alcance $svc_rep/$svc_rep antes de continuar"
    if wait_service_replicas "$svc_name" "$svc_rep"; then
      log "Escalado completado para $svc_name -> $svc_rep"
    else
      log "ERROR: $svc_name no alcanzo $svc_rep/$svc_rep"
      $SUDO_PREFIX $DOCKER_CMD service ps --no-trunc "$svc_name" 2>&1 | tee -a "$LOG" || true
      print_service_logs "$svc_name"
      exit 1
    fi
  else
    log "ERROR: fallo al escalar $svc_name a $svc_rep"
    exit 1
  fi
done < "$MAPPING_FILE"

# Esperar que todos los servicios restaurados estén running y permanezcan
# estables. Un 1/1 momentáneo no basta: una aplicación puede iniciar y salir
# segundos después, mientras Swarm crea inmediatamente otra tarea.
MAX_WAIT_UP="${DEPLOY_READY_TIMEOUT:-300}"
STABLE_REQUIRED="${DEPLOY_STABLE_SECONDS:-90}"
log "Esperando que todos los servicios estén en ejecución y estables durante ${STABLE_REQUIRED}s (máx ${MAX_WAIT_UP}s)..."
elapsed=0
all_up=0
stable_elapsed=0
previous_tasks=""
while [ $elapsed -le $MAX_WAIT_UP ]; do
  not_ready=$($SUDO_PREFIX $DOCKER_CMD service ls \
    --filter label=com.docker.stack.namespace=$MAIN_STACK \
    --format '{{.Name}} {{.Replicas}}' 2>/dev/null | \
    awk -F'[ /]' '{if($2!=0 && $2!=$3) print $1}' || true)
  if [ -z "$not_ready" ]; then
    current_tasks=$($SUDO_PREFIX $DOCKER_CMD stack ps "$MAIN_STACK" \
      --filter desired-state=running --format '{{.Name}} {{.ID}}' 2>/dev/null | sort || true)
    if [ -n "$current_tasks" ] && [ "$current_tasks" = "$previous_tasks" ]; then
      stable_elapsed=$((stable_elapsed+5))
    else
      [ -n "$previous_tasks" ] && log "Se detectó un reinicio; reiniciando comprobación de estabilidad."
      previous_tasks="$current_tasks"
      stable_elapsed=0
    fi
    if [ "$stable_elapsed" -ge "$STABLE_REQUIRED" ]; then
      all_up=1
      break
    fi
    if [ $((elapsed % 30)) -eq 0 ]; then
      log "Servicios en ejecución; estabilidad ${stable_elapsed}/${STABLE_REQUIRED}s."
    fi
  else
    stable_elapsed=0
    previous_tasks=""
    if [ $((elapsed % 30)) -eq 0 ]; then
      log "Servicios pendientes: $not_ready (${elapsed}s)"
    fi
  fi
  sleep 5
  elapsed=$((elapsed+5))
done
if [ $all_up -ne 1 ]; then
  log "ERROR: los servicios no permanecieron estables durante ${STABLE_REQUIRED}s dentro del límite de ${MAX_WAIT_UP}s:"
  $SUDO_PREFIX $DOCKER_CMD service ls --filter label=com.docker.stack.namespace=$MAIN_STACK | tee -a "$LOG"
  log "Tareas fallidas más recientes:"
  $SUDO_PREFIX $DOCKER_CMD stack ps "$MAIN_STACK" --no-trunc \
    --filter desired-state=shutdown --format '{{.Name}} | {{.CurrentState}} | {{.Error}}' 2>&1 | head -n 20 | tee -a "$LOG" || true
  exit 1
else
  log "Todos los servicios permanecieron estables durante ${STABLE_REQUIRED}s."
fi
