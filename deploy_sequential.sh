#!/usr/bin/env bash
set -euo pipefail

LOG="./deploy.log"
MAIN_STACK="sistema"
COMPOSE_FILE="$(pwd)/docker-stack.yml"

log() { echo "[$(date +"%Y-%m-%d %H:%M:%S")] $*" | tee -a "$LOG"; }

check_cmd() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: required command '$1' not found"; exit 1; } }


check_cmd docker

log "Iniciando despliegue secuencial usando $COMPOSE_FILE"

# deploy full stack (services will start)
log "Iniciando despliegue del stack $MAIN_STACK"
if ! docker stack deploy -c "$COMPOSE_FILE" "$MAIN_STACK" 2>&1 | tee -a "$LOG"; then
  log "ERROR: fallo al desplegar el stack"
  exit 1
fi
log "Despliegue inicial del stack solicitado"

# gather services in the stack
SERVICES=$(docker service ls --filter label=com.docker.stack.namespace=$MAIN_STACK --format '{{.Name}}')
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
  rep=$(docker service inspect --format '{{if .Spec.Mode.Replicated}}{{.Spec.Mode.Replicated.Replicas}}{{end}}' "$svc" 2>/dev/null || true)
  if [ -n "$rep" ]; then
    echo "$svc $rep" >> "$MAPPING_FILE"
    log "Iniciando escala de $svc a 0 (antes $rep)"
    if docker service update --replicas 0 "$svc" 2>&1 | tee -a "$LOG"; then
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
  log "ERROR: auth-service no generó .pem en ./keys ni en ./keys/public después de ${WAIT_INITIAL}s"
  log "Revisando logs del servicio auth-service..."
  docker service logs ${MAIN_STACK}_auth-service --tail 200 2>&1 | tee -a "$LOG" || true
  exit 1
fi
log "PEM detectado: $PEM_PATH"

# wait for auth-service to have RUNNING task
log "Esperando que ${MAIN_STACK}_auth-service tenga una tarea en ejecución"
MAX_WAIT=180
SLEEP=5
elapsed=0
ready=0
while [ $elapsed -le $MAX_WAIT ]; do
  running=$(docker service ps --filter desired-state=running --format '{{.CurrentState}}' ${MAIN_STACK}_auth-service 2>/dev/null | grep -c Running || true)
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
  docker service ls --filter label=com.docker.stack.namespace=$MAIN_STACK | tee -a "$LOG"
  docker stack ps $MAIN_STACK | tee -a "$LOG"
  exit 1
fi

# check auth API by launching a temporary curl container attached to overlay network
log "Comprobando API de auth-service mediante la red overlay (http://auth-service:8082/api/services)"
API_OK=0
MAX_API_WAIT=120
elapsed=0
while [ $elapsed -le $MAX_API_WAIT ]; do
  if docker run --rm --network public-net curlimages/curl:latest curl -sS --connect-timeout 5 http://auth-service:8082/api/services >/tmp/auth_probe 2>/tmp/auth_probe_err; then
    log "API de auth-service accesible. Muestra de respuesta: $(head -c 400 /tmp/auth_probe | tr -d '\n')"
    API_OK=1
    break
  else
    log "API de auth-service no lista aún (intento a ${elapsed}s)"
  fi
  sleep 5
  elapsed=$((elapsed+5))
done
if [ $API_OK -ne 1 ]; then
  log "ERROR: la API de auth-service no respondió en ${MAX_API_WAIT}s"
  docker service logs ${MAIN_STACK}_auth-service --tail 200 2>&1 | tee -a "$LOG" || true
  exit 1
fi

# restore replicas for other services
log "Restaurando réplicas para otros servicios"
while read -r line; do
  svc_name=$(echo "$line" | awk '{print $1}')
  svc_rep=$(echo "$line" | awk '{print $2}')
  log "Iniciando escala de $svc_name -> $svc_rep"
  if docker service update --replicas "$svc_rep" "$svc_name" 2>&1 | tee -a "$LOG"; then
    log "Escalado completado para $svc_name -> $svc_rep"
  else
    log "ERROR: fallo al escalar $svc_name a $svc_rep"
  fi
done < "$MAPPING_FILE"

log "Despliegue secuencial finalizado con éxito"
