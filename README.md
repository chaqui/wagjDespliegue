# Grupo WAGJ — despliegue multiempresa

Stack Docker Swarm para cuatro unidades de negocio aisladas por esquema PostgreSQL y publicadas por Traefik en `https://grupowagj.duckdns.org`.

## Arquitectura

| Unidad | Frontend | Backend | Esquema PostgreSQL |
|---|---|---|---|
| Los Molinos Store | `/losmolinos/store` · `3000` | `/losmolinos/store-api` · `8101` | `LosMolinosStore` |
| Crecilandia Store | `/crecilandia/store` · `3000` | `/crecilandia/store-api` · `8102` | `CrecilandiaStore` |
| Los Molinos Restaurante | `/losmolinos/restaurante` · `3103` | `/losmolinos/restaurante-api` · `8001` | `LosMolinosRestaurante` |
| Crecilandia Restaurante | `/crecilandia/restaurante` · `3104` | `/crecilandia/restaurante-api` · `8001` | `CrecilandiaRestaurante` |

Servicios compartidos:

- `traefik`: proxy inverso, TLS Let's Encrypt y dashboard en `/traefik/dashboard/`.
- `auth-service`: autenticación compartida publicada en `/usuarios-api`.
- `frontend-usuarios`: gestión de usuarios publicada en `/usuarios`.

Todos los servicios pertenecen a la red overlay externa `sistema_public-net`. Cada unidad tiene routers, middlewares, servicios Traefik, volúmenes y cookie sticky independientes. Los backends Store incluyen routers WebSocket dedicados para `ws-inventario`.

Todos los servicios Java ejecutan el perfil Spring `postgres`, usan explícitamente `org.postgresql.Driver` y tienen Flyway desactivado mediante `SPRING_FLYWAY_ENABLED=false`. La estructura requerida debe existir en PostgreSQL o ser administrada por la estrategia JPA propia de cada aplicación.

Cada backend fija además su esquema con `SPRING_JPA_PROPERTIES_HIBERNATE_DEFAULT_SCHEMA` y `SPRING_DATASOURCE_HIKARI_SCHEMA`. Esto evita que Hibernate valide o consulte las tablas en `public` cuando los esquemas tienen nombres específicos como `CrecilandiaRestaurante`.

Los cuatro backends reciben `AUTH_SERVICE_URL=http://auth-service:8082`. Los servicios Store anuncian la URL pública de su frontend. Cada restaurante anuncia en `SERVICE_BASE_URL` su endpoint interno alcanzable por Auth: `http://losmolinos-restaurante-backend:8001` o `http://crecilandia-restaurante-backend:8001`.

Cada restaurante conserva su par RSA en un directorio bind independiente y escribible por el UID/GID `1000`: `/opt/wagj/keys/losmolinos-restaurante` y `/opt/wagj/keys/crecilandia-restaurante`. La llave pública de Auth se distribuye mediante el secreto externo de Swarm `auth_public_key` en `/run/secrets/auth_public_key.pem`; las llaves `restaurant_public_key.pem` y `restaurant_private_key.pem` se generan dentro del directorio propio y sobreviven a reinicios y actualizaciones. Los scripts preparan permisos `0700` y crean el secreto desde `./keys/public_key.pem`.

La URL entregada a cada backend incluye también `currentSchema=<esquema>`. Esta es la protección principal para imágenes que construyen un `DataSource` personalizado desde `DB_URL` y no respetan todas las propiedades estándar de Spring.

La imagen Store se construye con `<base href="./">`, por lo que una misma imagen funciona bajo la ruta pública de cada instancia (`/losmolinos/store/` o `/crecilandia/store/`) sin modificar `index.html` al arrancar. Traefik redirige la ruta base sin diagonal final a su versión con `/`, para que el navegador resuelva estilos, chunks y `config.json` dentro del prefijo correcto.

Los backends de restaurante usan el tag móvil `ghcr.io/chaqui/restaurant-java:main`. El actualizador descarga ese tag, compara su digest con el desplegado y actualiza los servicios únicamente cuando el contenido publicado cambia. El flujo de CI debe publicar también `:main`, además del tag inmutable `main-<commit>`.

Los frontends de restaurante están fijados en `ghcr.io/chaqui/fronted-restaurante:main-92745dd`. En modo `--images-only`, el actualizador compara el digest descargado con el digest de cada servicio y evita reinicios cuando ya coinciden.

La suma de los límites configurados para los 11 servicios es `1616 MiB` (`1,694,498,816` bytes, aproximadamente `1.695 GB` decimales), por debajo de `1.7 GB`. Los límites no son reservas, pero el host debe disponer de memoria física y swap suficientes cuando todos los servicios ejecuten una réplica. Se distribuyen así: Traefik `64 MiB`, autenticación `288 MiB`, usuarios `48 MiB`, cada backend tenant `256 MiB` y cada frontend tenant `48 MiB`. Autenticación utiliza `-Xms64m -Xmx176m`; los backends usan `-Xms64m -Xmx128m`, dejando `128 MiB` por backend para Metaspace, hilos, buffers y memoria nativa. Las actualizaciones usan `stop-first` para no duplicar temporalmente el consumo del servicio actualizado.

El despliegue inicial exige por defecto `90` segundos continuos sin cambios de tareas antes de considerarlo estable. Los valores pueden ajustarse con `DEPLOY_STABLE_SECONDS` y `DEPLOY_READY_TIMEOUT`; este último tiene un valor predeterminado de `300` segundos.

En el YAML solamente `auth-service` inicia con una réplica. Los demás servicios comienzan en cero para garantizar que la llave pública exista antes de montarla. El script los restaura uno por uno, espera que cada servicio converja y usa comandos desacoplados para que el progreso interactivo de Docker no bloquee la ejecución.

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
mkdir -p keys certs \
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

Defina el usuario y la contraseña del dashboard. El script genera
`TRAEFIK_DASHBOARD_AUTH` automáticamente sin mostrar el hash ni la contraseña:

```dotenv
TRAEFIK_USER=admin
TRAEFIK_PASSWORD=CAMBIAR_CONTRASENA
```

Las variables ya exportadas en el servidor tienen prioridad sobre `.env`. Si
`DB_URL` no está definida o conserva un placeholder, también puede generarse
automáticamente usando `DB_HOST`, `DB_PORT` (por defecto `5432`) y `DB_NAME`.
Si ejecuta manualmente mediante `sudo`, use `sudo -E` para conservar las
variables exportadas del servidor.

Si `JWT_SECRET` falta o conserva un placeholder, se genera automáticamente una
clave aleatoria de 128 caracteres hexadecimales. Se guarda en `.jwt-secret` con
permisos `600`, se reutiliza en ejecuciones posteriores y nunca se imprime en
los logs. Incluya ese archivo en sus copias de seguridad seguras: cambiarlo
invalida los tokens JWT emitidos anteriormente.

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
para realizar el primer despliegue. Si ya existe, revisa `.env` y aplica las
variables nuevas, modificadas o eliminadas; despues descarga todas las imagenes,
compara sus digests y actualiza solamente los servicios que cambiaron. El estado
de `.env` se guarda como hashes en `.env.applied.sha256`, sin copiar secretos.

```bash
chmod +x update_images.sh
./update_images.sh
```

Variables opcionales: `STACK_NAME`, `COMPOSE_FILE`, `INITIAL_DEPLOY_SCRIPT`,
`LOG_FILE`, `LOCK_FILE`, `ENV_FILE` y `ENV_STATE_FILE`. Para imagenes privadas, ejecute previamente
`docker login ghcr.io` con una credencial que tenga permiso `read:packages`.

El actualizador valida las variables obligatorias y `docker-stack.yml` antes de
aplicar cambios, conserva el escalado actual, espera que las replicas queden
saludables y solicita `docker service rollback` si una actualizacion falla. El
estado de `.env` se escribe atomicamente y sus hashes usan una clave HMAC local.

Modos disponibles:

```bash
./update_images.sh --dry-run          # informar sin cambiar servicios
./update_images.sh --env-only         # solamente variables
./update_images.sh --images-only      # solamente imagenes
./update_images.sh --force auth-service  # forzar un servicio
./update_images.sh --status           # ultimo resultado y estado Swarm
```

Las notificaciones se habilitan con `TELEGRAM_BOT_TOKEN` y
`TELEGRAM_CHAT_ID`, o con `WEBHOOK_URL`. La limpieza de imagenes no
referenciadas está desactivada por defecto; se habilita mediante
`PRUNE_OLD_IMAGES=true` y respeta `PRUNE_UNTIL` (por defecto siete dias).

`watch_and_deploy.sh` es ahora un envoltorio compatible que llama al mismo
actualizador y muestra la cuenta regresiva en una sola linea; ya no elimina el
stack.

Ejemplo de cron cada cinco minutos (el bloqueo integrado evita ejecuciones
simultaneas):

```cron
*/5 * * * * cd /ruta/despliegue-inventario && ./update_images.sh >> update-images-cron.log 2>&1
```

Para systemd se recomienda el timer incluido (edite primero las rutas de ambos
archivos):

```bash
sudo cp update-images.service update-images.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now update-images.timer
systemctl list-timers update-images.timer
journalctl -u update-images.service -f
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

Compruebe que la llave pública compartida esté disponible en
`./keys/public_key.pem`. `auth-service` monta `./keys` con escritura y los
demás servicios montan esa misma carpeta como `/app/keys` en modo de solo
lectura. Verifique también que cada esquema exista y que el usuario PostgreSQL
tenga permisos sobre los cuatro esquemas.
