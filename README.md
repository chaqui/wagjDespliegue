# Grupo WAGJ — despliegue multiempresa

Stack Docker Swarm para cuatro unidades de negocio aisladas por esquema PostgreSQL y publicadas por Traefik en `https://grupowagj.duckdns.org`.

## Arquitectura

| Unidad | Frontend | Backend | Esquema PostgreSQL |
|---|---|---|---|
| Los Molinos Store | `/losmolinos/store` · `3101` | `/losmolinos/store-api` · `8101` | `LosMolinosStore` |
| Crecilandia Store | `/crecilandia/store` · `3102` | `/crecilandia/store-api` · `8102` | `CrecilandiaStore` |
| Los Molinos Restaurante | `/losmolinos/restaurante` · `3103` | `/losmolinos/restaurante-api` · `8103` | `LosMolinosRestaurante` |
| Crecilandia Restaurante | `/crecilandia/restaurante` · `3104` | `/crecilandia/restaurante-api` · `8104` | `CrecilandiaRestaurante` |

Servicios compartidos:

- `traefik`: proxy inverso, TLS Let's Encrypt y dashboard en `/traefik/dashboard/`.
- `auth-service`: autenticación compartida publicada en `/usuarios-api`.
- `frontend-usuarios`: gestión de usuarios publicada en `/usuarios`.
- `catalogos`: catálogos compartidos publicados en `/catalogos`.

Todos los servicios pertenecen a la red overlay externa `sistema_public-net`. Cada unidad tiene routers, middlewares, servicios Traefik, volúmenes y cookie sticky independientes. Los backends Store incluyen routers WebSocket dedicados para `ws-inventario`.

La suma de los límites de memoria de los 12 servicios es `1424 MiB` (`1,493,172,224` bytes), por debajo del presupuesto global de `1.5 GB`, incluso si todos se ejecutan con una réplica. Los límites se distribuyen así: Traefik `80 MiB`, autenticación `192 MiB`, usuarios `64 MiB`, catálogos `64 MiB`, cada backend tenant `184 MiB` y cada frontend tenant `72 MiB`.

## Requisitos

- Docker Engine en modo Swarm.
- La red overlay externa `sistema_public-net`.
- DNS de `grupowagj.duckdns.org` apuntando al nodo que publica 80/443.
- Acceso del cluster a PostgreSQL y a las imágenes privadas de GHCR.
- Los directorios bind deben existir en cada nodo elegible para ejecutar las réplicas.

## Preparación

```bash
cp .env.example .env
docker network create --driver overlay --attachable sistema_public-net
mkdir -p keys pubkeys certs \
  logs/auth \
  logs/losmolinos-store-backend logs/crecilandia-store-backend \
  logs/losmolinos-restaurante-backend logs/crecilandia-restaurante-backend \
  data/losmolinos-store data/crecilandia-store \
  data/losmolinos-restaurante data/crecilandia-restaurante
```

Cree los esquemas conectándose a la base indicada por `DB_URL`:

```bash
psql "postgresql://USUARIO:CONTRASENA@HOST:5432/BASE" -f schemas.sql
```

Genere el valor de autenticación básica del dashboard con los signos `$` duplicados para Docker Compose:

```bash
echo $(htpasswd -nb admin 'CAMBIAR_CONTRASENA') | sed -e 's/\$/\$\$/g'
```

## Despliegue

Docker Swarm sustituye las variables desde el entorno del shell. Cargue `.env` y despliegue:

```bash
set -a
. ./.env
set +a
docker stack deploy --with-registry-auth -c docker-stack.yml sistema
```

### Despliegue inicial y actualizacion automatica de imagenes

El script `update_images.sh` puede ejecutarse manualmente, desde cron o desde un
timer de systemd. Si el stack todavia no existe, llama a `deploy_sequential.sh`
para realizar el primer despliegue. Si ya existe, descarga todas las imagenes,
compara sus digests y actualiza solamente los servicios que cambiaron:

```bash
chmod +x update_images.sh
./update_images.sh
```

Variables opcionales: `STACK_NAME`, `COMPOSE_FILE`, `INITIAL_DEPLOY_SCRIPT`,
`LOG_FILE` y `LOCK_FILE`. Para imagenes privadas, ejecute previamente
`docker login ghcr.io` con una credencial que tenga permiso `read:packages`.

Ejemplo de cron cada cinco minutos (el bloqueo integrado evita ejecuciones
simultaneas):

```cron
*/5 * * * * cd /ruta/despliegue-inventario && ./update_images.sh >> update-images-cron.log 2>&1
```

El archivo conserva los valores de réplicas existentes: Traefik y los backends nuevos están inicialmente en `0`; actívelos cuando corresponda, por ejemplo:

```bash
docker service scale sistema_traefik=1
docker service scale sistema_losmolinos-store-backend=1
docker service scale sistema_crecilandia-store-backend=1
docker service scale sistema_losmolinos-restaurante-backend=1
docker service scale sistema_crecilandia-restaurante-backend=1
```

## Verificación

```bash
docker stack config -c docker-stack.yml
docker stack services sistema
docker service logs -f sistema_traefik
```

Compruebe que las llaves públicas compartidas estén disponibles en `./pubkeys`, que cada esquema exista y que el usuario PostgreSQL tenga permisos sobre los cuatro esquemas.
