# Roadmap — HomeLab Installer 2 (HLI 2)

## Misión

Un servidor doméstico donde el **host se mantiene mínimo** y **todos los servicios que lo
justifican corren en contenedores**, administrados con [Dokploy](https://dokploy.com). El mismo
servidor sirve para media, domótica, contraseñas, nube personal, sitios web y proyectos de IA.

El HLI 2 es la herramienta del host: **configura, monitorea y respalda**. Dokploy opera los
servicios.

## Principios

- **Proyecto independiente**: no modifica ni depende del HLI v1 (`homelab-installer`). Del v1 se
  toman ideas como referencia de lectura; nunca se importa código.
- **Plugin system / auto-discovery**: el menú lee `modules/`. Agregar `modules/x.sh` lo hace
  aparecer en el menú.
- **Registro de servicios declarativo**: una sola fuente (nombre, puerto, rutas de datos, tipo de
  backup) alimenta dashboard, healthcheck, backup y restore. Nada de rutas ni puertos hardcodeados
  en varios lugares.
- **Backups del v1 solo desde la herramienta dedicada** (decisión 2026-10-05): importar un
  backup del HLI v1 se hace únicamente desde Herramientas → `import-v1`. Los módulos
  `jellyfin`, `qbittorrent` y `adguard` no preguntan por backups del v1 (AdGuard sigue creando su
  usuario admin en una instalación nueva, y no lo pide si el YAML ya trae usuarios).
- **Idempotencia**: re-ejecutar cualquier módulo no rompe el sistema.
- **Bash estricto**: `set -euo pipefail` y rutas siempre entre comillas.
- **El instalador pregunta** lo que necesita; no asume valores.
- **Logs por módulo** en `/var/log/hli2/`; **estado persistente** en `/var/lib/hli2/state`.

## Arquitectura

| Capa | Dueño | Contenido |
|---|---|---|
| Host base | HLI 2 | SO, energía, WOL, LVM, discos (`/srv/mediaN`), grupo `media`, Samba, puerto 53 |
| Plataforma | HLI 2 instala, Dokploy opera | Docker + Dokploy + Traefik |
| Servicios | Dokploy | Compose por servicio, dominios, TLS, deploys |
| Operación | HLI 2 | Dashboard/healthcheck vía `docker`, backup local de `/srv/appdata`, migración |

### Hechos de Dokploy que condicionan el diseño

- Ocupa **80/443 (Traefik)** y **3000 (panel)**; la instalación falla si están ocupados.
- Usa Docker Swarm y Traefik como reverse proxy (Let's Encrypt incluido).
- Soporte oficial de Ubuntu hasta 24.04.
- Sus backups van **solo a destino S3-compatible**, y los de volúmenes solo cubren *named volumes*.

### Decisiones

1. **Nginx no va en el borde**: Traefik es el único dueño de 80/443. Nginx es un contenedor más,
   solo para sitios estáticos.
2. **Panel de AdGuard en 3053** (el 3000 es de Dokploy).
3. **Permisos**: contenedores de media con `PUID`/`PGID` = usuario del servidor / grupo `media`;
   setgid 2775 sobre `/srv/media*`.
4. **Rutas de media idénticas dentro y fuera del contenedor** (`/srv/media` → `/srv/media`).
5. **Red del host** para AdGuard (53) y Home Assistant (descubrimiento mDNS/SSDP).
6. **Samba nativo**: depende de usuarios Unix y rutas del host.
7. **Home Assistant en modo Container** (sin add-ons): el uso previsto son integraciones Xiaomi y
   Samsung.
8. **Exposición externa con Cloudflare Tunnel**: sin puertos abiertos, compatible con CGNAT.

## Catálogo de servicios

### Contenedores

| Servicio | Imagen | Red | Datos (`/srv/appdata/…`) | Acceso |
|---|---|---|---|---|
| Jellyfin | `jellyfin/jellyfin` | bridge + Traefik, `/dev/dri` (QuickSync) | `jellyfin/{config,cache}` | LAN (opcional público) |
| qBittorrent | `lscr.io/linuxserver/qbittorrent` | bridge, 6881 tcp/udp | `qbittorrent/config` | Solo LAN |
| AdGuard Home | `adguard/adguardhome` | host (53), panel 3053 | `adguard/{conf,work}` | Solo LAN |
| Vaultwarden | `vaultwarden/server` | bridge + Traefik | `vaultwarden/data` | Público vía tunnel |
| Home Assistant | `ghcr.io/home-assistant/home-assistant:stable` | host (8123) | `homeassistant/config` | Solo LAN |
| OpenCloud | imagen oficial OpenCloud | bridge + Traefik | `opencloud/{config,data}` | Público vía tunnel |
| cloudflared | `cloudflare/cloudflared` | bridge | token (secreto en Dokploy) | — |
| nginx (por sitio) | `nginx:alpine` | bridge + Traefik | `sites/<sitio>` | Público vía tunnel |

### Nativo en el host

Docker Engine, Samba, WOL, energía (sleep/lid), LVM, discos `/srv/mediaN`, systemd-resolved sin
stub (puerto 53 libre), SSH y el propio HLI 2.

## Backups: dos copias, una herramienta (decidido 2026-10-06)

Los servicios guardan todo en bind mounts de `/srv/appdata` (y SQLite), no en
bases de datos ni volúmenes que administre Dokploy: los backups de Dokploy
(solo dumps de sus DB y named volumes hacia S3) no cubren nada de esto. Por eso
**el HLI 2 hace las dos copias** con **restic** (cifrado, incremental,
deduplicado, restaurable por fecha):

| | Copia local | Copia externa |
|---|---|---|
| Dónde | Repositorio restic en el SSD de media (`$BACKUP_ROOT`), otro disco que el del sistema | Repositorio restic en Cloudflare R2 (S3), cifrado |
| Qué | Todo lo respaldable (ver v2.5) | Lo mismo **menos** `opencloud/data` (decisión del usuario: los archivos de OpenCloud ya viven también en los clientes que sincronizan) |
| Para qué | Restaurar rápido un servicio o el servidor si falla el NVMe | Sobrevivir a la pérdida del equipo o de la casa |

**Regla de consistencia**: nunca se copia en caliente una carpeta con base de
datos. Los contenedores con SQLite u otra base embebida se detienen durante la
toma de la foto local (segundos) y se levantan siempre, aunque falle algo.

---

## Fases

Cada fase es **un commit + un push**.

### v2.0 — Esqueleto + host base

- [x] `bootstrap.sh`, `lib/`, `ui/menu.sh` con plugin system por metadatos `# HLI-*`.
- [x] Registro de servicios declarativo (fuente única para dashboard, healthcheck y backup).
- [x] Módulos de host: base, power, wol, storage (auto-expandir LVM), datadisk (pool multi-disco
      `/srv/mediaN`), samba.

### v2.1 — Plataforma

- [x] Módulo `dokploy`: verifica 80/443/3000 libres, advierte si el SO no está soportado, instala
      Docker + Dokploy, crea `/srv/appdata`.

**Riesgos conocidos**: el instalador oficial de Dokploy (`https://dokploy.com/install.sh`) es
**destructivo en una re-ejecución** — hace `docker swarm leave --force` y
`docker network rm -f dokploy-network` de forma incondicional, sin preguntar, lo que borraría todo
lo desplegado si se lo corre dos veces sobre un servidor ya instalado. El módulo `dokploy` de HLI 2
nunca deja que esto pase: si detecta una instalación existente (`docker service inspect dokploy` o
`/etc/dokploy`), jamás vuelve a correr el instalador — solo ofrece `update` (ruta no destructiva:
`docker pull` + `docker service update`) o no hacer nada. También aborta si el nodo ya pertenece a
un Swarm activo que no es de Dokploy (evita destruir un swarm ajeno). El pool de direcciones de
Swarm/Docker se elige evitando colisión con la LAN (10.0.0.0/8, 172.17.0.0/16) antes de instalar,
en vez de dejar que el instalador oficial elija a ciegas.

### v2.2 — Servicios actuales en contenedores

- [x] Cliente de la API de Dokploy (`lib/dokploy_api.sh`): auth `x-api-key` (token guardado en
      `/etc/hli2/dokploy.env`, root-only 0600, nunca se loguea ni se imprime), `project.all` /
      `project.create` / `environment.byProjectId` / `compose.create` / `compose.update` /
      `compose.deploy` / `compose.one` / `compose.delete`. Idempotente: encuentra o crea el
      proyecto "homelab" y el compose por `appName` antes de crear (nunca duplica).
- [x] Validación canaria obligatoria antes del primer despliegue real
      (`lib/canary.sh`, `dokploy_preflight`): compose descartable con un bind mount de prueba,
      dos redeploys vía la API, confirma que el archivo centinela sobrevive intacto. Si falla,
      aborta v2.2 sin tocar ningún servicio real. Se corre una sola vez (queda en el estado
      persistente).
- [x] Compose de Jellyfin, qBittorrent y AdGuard (`compose/<servicio>/docker-compose.yml`,
      renderizados por `lib/compose.sh`), desplegados vía la API (`composeType: docker-compose`,
      no `stack`, porque AdGuard necesita `network_mode: host`). `container_name` explícito en
      los tres (ver `services/*.conf`).
- [x] Importador de config desde el tar de backup del HLI v1 (`lib/importer.sh`): `jellyfin/`,
      `qbittorrent/`, `adguard/` hacia `/srv/appdata/*` (con reescritura de rutas absolutas
      viejas en la config de Jellyfin y normalización del YAML de AdGuard a 0.0.0.0:3053), más
      fusión de `ssh/authorized_keys` y `samba/smb.conf` como referencia (nunca se aplica: Samba
      lo genera el módulo `samba` de v2.0). Disponible SOLO como herramienta
      (Herramientas → `import-v1`, `modules/import-v1.sh`): detener → importar → redesplegar.
      Los módulos de servicio ya no ofrecen la importación (decisión 2026-10-05). Solo
      corre con el contenedor destino detenido/ausente (fail-closed ante "activo"/"desconocido").
- [x] Mapeo del layout nativo de Jellyfin/qBittorrent a las imágenes elegidas, verificado contra
      la documentación de cada imagen (2026-09-29): Jellyfin oficial usa
      `JELLYFIN_DATA_DIR=/config` (antes `/var/lib/jellyfin`) y
      `JELLYFIN_CONFIG_DIR=/config/config` (antes `/etc/jellyfin`, subcarpeta DENTRO del mismo
      volumen, no un mount aparte); linuxserver/qbittorrent unifica `~/.config/qBittorrent` y
      `~/.local/share/qBittorrent` (BT_backup incluido) bajo `/config/qBittorrent`.

**Pendiente de validar en un servidor real** (no se pudo probar contra un Dokploy real desde
acá): la forma exacta de la respuesta JSON de `project.all`/`project.create`/`compose.one` (la
documentación pública no la renderiza completa) — el cliente resuelve el `environmentId` con
`environment.byProjectId` (sí documentado) y guarda el `composeId` en estado local para no
depender de un endpoint de listado de composes no confirmado; si `compose.one` devolviera un
`composeId` que Dokploy ya no reconoce, se trata como "no existe" y se vuelve a crear. También
falta correr la validación canaria una vez contra el Dokploy real antes de desplegar
Jellyfin/qBittorrent/AdGuard de verdad.

**Hallazgo de seguridad CRÍTICO, validado en hardware real**: el `AdGuardHome.yaml` "sembrado" a
mano (solo `http.address`/`dns.bind_hosts`, ver `modules/adguard.sh:_adguard_seed_if_missing`) SÍ
evita el asistente de instalación por completo — y ese asistente es, precisamente, donde AdGuard
crea el usuario admin. Sin un usuario creado de antemano, el panel en `:3053` arrancaba **SIN
AUTENTICACIÓN**: cualquiera en la LAN podía entrar y cambiar el DNS de toda la casa. Corregido:
`modules/adguard.sh` (`_adguard_ensure_admin_user`) ahora crea el usuario admin A MANO, escrito
directo en el YAML (`lib/importer.sh`: `adguard_yaml_has_users`/`adguard_yaml_append_user`) ANTES
del primer arranque del contenedor, pidiendo usuario (`input_box`, default `admin`, charset
validado) y contraseña dos veces (`password_box`, mínimo 8 caracteres, deben coincidir). El hash
se genera con `htpasswd -B` (bcrypt), el método que documenta la propia wiki de AdGuard Home
(<https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration>, sección de reseteo de
contraseña: `htpasswd -B -C 10 -n -b <USERNAME> <PASSWORD>`), corrido dentro de un contenedor
descartable (`httpd:2-alpine`, trae `htpasswd` de Apache) porque Ubuntu Server no lo trae
instalado por defecto. Se usa `-i` en vez de `-b`: `-b` pone la contraseña en el ARGV del proceso
(visible por `ps`/`/proc/<pid>/cmdline` para cualquier usuario local — mismo problema de fondo que
el token de la API de Dokploy en v2.2); `-i` la lee por STDIN sin que aparezca nunca en argv, log
ni entorno (manual de Apache: <https://httpd.apache.org/docs/current/programs/htpasswd.html>). El
hash resultante (prefijo `$2y$`, el que usa `crypt_blowfish`/`apache2-utils`) se valida con una
regex ANCLADA A AMBOS LADOS antes de guardarse; AdGuard Home (Go) lo acepta sin conversión porque
compara con `golang.org/x/crypto/bcrypt.CompareHashAndPassword`, cuyo parseo del hash
(`bcrypt.go:decodeVersion`) solo rechaza una *major version* mayor a `2` — cualquier *minor
version* (`a`/`b`/`x`/`y`) es válida. La escritura en el YAML nunca pasa por `sed` (el hash
contiene `$` y puede contener `/`, ambos especiales para los delimitadores/reemplazos de `sed`):
va por `awk` con el usuario/hash como variables (`-v`, nunca interpolados en el texto del programa
awk), preservando el resto del archivo. El archivo queda en `0600 root:root` al escribir el
usuario (antes solo tenía `chown root:root`, pero `$APPDATA_ROOT` es `0755` — mundialmente
listable/atravesable — así que sin este endurecimiento el hash bcrypt quedaba legible por
cualquier usuario local del host), con el mismo patrón `install -m 0600` + `tee` (nunca `tee` +
`chmod` después) que ya usa `secret_file_write` (`lib/secrets.sh`). Si el YAML ya tiene usuarios
(importado de un backup del v1 con la instalación del wizard ya completada, o de una corrida
anterior de este mismo módulo), nunca se pregunta nada ni se pisan: idempotente. Tests en
`tests/test_adguard.sh` (instalación nueva pide credenciales y genera el hash; config importada
con usuarios no pregunta nada y los preserva tal cual; contraseñas que no coinciden o de menos de
8 caracteres abortan SIN escribir ningún usuario y SIN marcar el módulo como hecho; la contraseña
nunca aparece en el log de argv de ningún proceso real).

**Pendiente de validar en un servidor real**: que el login contra el panel de AdGuard Home en
`:3053` funcione de verdad con el hash generado por este flujo (`htpasswd -B` corrido vía
`httpd:2-alpine`) — solo se probó contra un stub de `docker` en los tests, nunca contra el binario
real de `htpasswd` ni contra un AdGuard Home real comparando el hash.

**Revisión de seguridad (post-implementación)**: se corrigieron 3 hallazgos críticos — el token de
la API viajaba en el argv de `curl` (visible por `ps`/`/proc/<pid>/cmdline` para cualquier usuario
local; ahora va por stdin vía `curl -K -`), `/etc/hli2/dokploy.env` tenía una ventana
mundialmente-legible entre crearse y aplicársele `chmod 0600` (ahora se crea ya con el modo final
vía `install -m 0600`), y la validación canaria quedaba marcada "válida" de forma global sin
importar a qué Dokploy apuntara (ahora la clave incluye la URL y la versión de la imagen de
Dokploy: un servidor nuevo o una actualización de Dokploy vuelven a disparar la validación). Además
se endureció el import del tar de v1 contra miembros no seguros (rutas absolutas, `..`,
symlinks/hardlinks — se rechaza el tar ENTERO antes de extraer nada) y el cambio de DNS del host
para AdGuard ahora se aplica lo más tarde posible (justo antes del deploy) y se revierte solo
(`restore_dns_port()`) ante cualquier fallo posterior, nunca dejando el host sin resolución DNS.
Detalle completo en Engram (`hli2/v2.2`).

### v2.3 — Servicios nuevos

- [x] Vaultwarden (`SIGNUPS_ALLOWED=false`, `ADMIN_TOKEN` como secreto): imagen
      oficial `vaultwarden/server`, un solo volumen de datos
      (`/srv/appdata/vaultwarden/data` → `/data`), `DOMAIN=https://<dominio
      pedido al usuario>`. `ADMIN_TOKEN` se genera como hash Argon2id PHC con
      la propia CLI de Vaultwarden (`vaultwarden hash --preset owasp`,
      corrida con `docker run --rm -it`, heredando la terminal del módulo:
      esa CLI exige una TTY real, entra en pánico con stdin sin tty — ver
      `modules/vaultwarden.sh`) y se guarda en `/etc/hli2/vaultwarden.env`
      (root-only 0600). Todavía no se expone a Internet (eso es v2.4): se
      despliega en la red `dokploy-network` con un dominio propio enrutado
      por el Traefik de Dokploy (`dokploy_domain_ensure`,
      `lib/dokploy_api.sh`), alcanzable solo desde la LAN.
- [x] Home Assistant (Container, red del host): imagen oficial
      `ghcr.io/home-assistant/home-assistant:stable`, `network_mode: host`
      (necesario para mDNS/SSDP). A diferencia del compose de ejemplo
      oficial, sin `privileged` ni dispositivos montados: el uso previsto
      (Xiaomi, Samsung) es por red local, no por Bluetooth/USB del host.
      Sin importación desde el HLI v1 (no lo tenía).
- [x] OpenCloud (validar clientes desktop/móvil y consumo de RAM): imagen
      `opencloudeu/opencloud-rolling:8.0.1` (plantilla oficial
      `opencloud-eu/opencloud-compose`, recortada a lo esencial para v2.3:
      sin CSP/apps/lista de contraseñas prohibidas ni SMTP). `OC_URL` exige
      un dominio público fijo para funcionar del todo (cookies/login), pero
      la exposición real es v2.4: el módulo pide igual el dominio futuro,
      despliega con la contraseña guardada localmente como
      `INITIAL_ADMIN_PASSWORD` (`/etc/hli2/opencloud.env`, la clave que usa
      `secret_file_write`/`secret_get`) — el compose la referencia como
      `${INITIAL_ADMIN_PASSWORD}` y la mapea a la variable que en verdad lee
      OpenCloud, `IDM_ADMIN_PASSWORD=${INITIAL_ADMIN_PASSWORD}` (ver
      `compose/opencloud/docker-compose.yml`) — y avisa que el login completo (y los
      clientes de escritorio/móvil) solo funcionan una vez que el dominio
      resuelva de verdad y tenga TLS. Almacenamiento POSIX plano bajo
      `/srv/appdata/opencloud/{config,data}` (no named volumes de Docker),
      con `user: "<uid>:<gid>"` de `SERVER_USER` para que quede legible desde
      el host.
- [x] Canal de secretos hacia Dokploy: `dokploy_compose_create_or_update`
      (`lib/dokploy_api.sh`) ahora acepta un cuarto parámetro opcional
      (`env_content`) que va al campo `env` de `compose.create`/
      `compose.update` — el compose versionado solo referencia `${ADMIN_TOKEN}`
      / `${INITIAL_ADMIN_PASSWORD}` (sintaxis de sustitución de Dokploy),
      nunca el valor real. Revisión de seguridad propia (ver más abajo):
      tanto el body de `dokploy_api_call` como este `env` pasan a `curl`/`jq`
      por archivo temporal (`--data @archivo` / `--rawfile`), nunca por argv.
- [x] Dominios vía Traefik: `dokploy_domain_ensure` (`lib/dokploy_api.sh`,
      `domain.create`/`domain.byComposeId`) para enrutar Vaultwarden y
      OpenCloud por nombre de dominio dentro de la red `dokploy-network`,
      sin publicar ningún puerto de host — idempotente por
      (composeId, serviceName, host).

**Revisión de seguridad (post-implementación, propia de v2.3)**: al sumar el
campo `env` de Dokploy (canal de secretos) se encontraron y corrigieron 2
fugas antes de que llegaran a ejecutarse contra un servidor real: (1) el
body de `dokploy_api_call` viajaba en el argv de `curl` (`-d "$body"`) —
mismo problema que ya se había corregido para el token de la API en v2.2,
pero reintroducido acá porque ahora el body puede contener un secreto
(`ADMIN_TOKEN`/`INITIAL_ADMIN_PASSWORD`); se corrigió pasándolo por
`--data @<archivo temporal>`. (2) el `env_content` se armaba con
`jq --arg env "$valor"`, que pone el valor directo en el argv del proceso
`jq`; se corrigió con `jq --rawfile env <archivo temporal>`. Además se
confirmó A MANO (no solo por lectura de código) que `trap ... RETURN` en
bash NO es local a la función donde se define — es un trap único y GLOBAL
del shell que una función anidada que arme su propio `trap ... RETURN` pisa
sin avisar — así que la limpieza de esos archivos temporales de secretos se
hizo con `rm -f` explícito en cada punto de salida de la función, nunca con
ese trap (se había intentado primero y se revirtió tras la prueba).

**Revisión de seguridad — ronda 2 (fresh review posterior)**: encontró y se
corrigieron 2 críticos más un hallazgo de endurecimiento, ninguno detectado
por la ronda 1 porque el harness de tests de esa ronda no podía verlos
estructuralmente (los tests se corrigieron junto con el código, ver
`tests/`):
1. **Secretos ilegibles por el usuario que invoca**: `/etc/hli2` se crea
   0700 root:root, pero `secret_get`/`secret_file_exists`
   (`lib/secrets.sh`) y `_dokploy_env_get`/`dokploy_api_configured`
   (`lib/dokploy_api.sh`, mismo patrón desde v2.2 para
   `DOKPLOY_ENV_FILE`) leían con `[[ -f ]]`/`sed` SIN privilegios —
   `bootstrap.sh` corre como usuario normal, así que esas lecturas
   fallaban siempre (permiso denegado para ATRAVESAR el directorio, no
   por el modo del archivo en sí), y "reutilizar el token/credencial
   existente" nunca funcionaba de verdad. Corregido: toda lectura de estos
   archivos pasa por `priv_file_exists`/`priv_file_read`
   (`lib/secrets.sh`, nuevas), que usan `sudo -n test -f --`/`sudo -n cat
   --` y fallan cerrado (con mensaje claro por stderr) si `sudo -n` en sí
   no funciona — nunca asumen "no existe" cuando en realidad "no se pudo
   preguntar". De paso, el parseo de `CLAVE=valor` dejó de usar `sed`
   con la clave interpolada en una regex: ahora es un `case` con
   comparación EXACTA de la clave y valor = todo lo que sigue al PRIMER
   `=`, nunca `source` del archivo. `secret_file_write` además rechaza
   (sin escribir nada) cualquier línea que no tenga forma `CLAVE=valor`.
2. **`\r` colado en el ADMIN_TOKEN** (`modules/vaultwarden.sh`): `docker
   run -it` asigna una pty; con ONLCR cada `\n` que imprime `vaultwarden
   hash` sale como `\r\n`, así que la línea capturada por
   `tee`/`grep` (que solo parten por `\n`) terminaba con un `\r` de
   sobra. La validación anterior solo anclaba el PRINCIPIO de la regex
   (`^\$argon2id\$`), así que ese `\r` pasaba, se guardaba y se
   desplegaba tal cual — el login de `/admin` habría fallado siempre
   contra un Vaultwarden real (el hash real nunca coincide con uno con un
   byte de más). Corregido: `tr -d '\r'` sobre la salida capturada, y una
   regex ANCLADA A AMBOS LADOS (`^\$argon2id\$v=[0-9]+\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$[A-Za-z0-9+/]+\$[A-Za-z0-9+/]+$`)
   contra la forma completa de un PHC Argon2id, no solo el prefijo.
3. **Namespacing de rutas overridables** (endurecimiento, no un bug
   explotado): `LOG_DIR`/`STATE_DIR`/`STATE_FILE` (`lib/core.sh`),
   `SECRETS_DIR` (`lib/secrets.sh`), `DOKPLOY_ENV_FILE`/
   `DOKPLOY_STATE_FILE` (`lib/dokploy_api.sh`) y `DNS_PORT_*`
   (`lib/dns.sh`) se overrideaban con nombres genéricos
   (`: "${STATE_DIR:=...}"`) que una variable de entorno ambiental
   cualquiera (heredada por casualidad en la sesión de quien corre
   `bootstrap.sh`) podría secuestrar en silencio. Ahora el override real
   requiere el prefijo `HLI2_` (ej. `HLI2_STATE_DIR`); sin él, se usa
   siempre la ruta real de producción.
4. **Dominios sin validar** (mejora, no crítico): `modules/vaultwarden.sh`
   y `modules/opencloud.sh` ahora validan la FORMA del dominio pedido
   (`hli2_valid_hostname`, `lib/core.sh`: etiquetas `[A-Za-z0-9-]`, sin
   guion al principio/final, ≥2 etiquetas, largo total ≤253) antes de
   usarlo, en vez de aceptar cualquier texto no vacío.

Los tests `tests/test_secrets.sh` (lectura root-only simulada con un área
0000 que solo el stub de `sudo` puede "desbloquear" temporalmente) y
`tests/test_vaultwarden.sh` (docker stub emitiendo `\r\n` como una pty
real) prueban que ambos críticos fallaban antes de estos cambios y pasan
después — ver `tests/lib/harness.sh` (`STUB_ROOT_AREA`) y
`tests/stubs/sudo`/`tests/stubs/docker`. (El crítico 2, el `\r` colado,
quedó sin objeto más adelante: ver el hallazgo de hardware real más abajo,
que abandona por completo el `docker run -it` para el ADMIN_TOKEN — el test
que lo probaba se retiró junto con ese código.)

**Hallazgo de usabilidad/seguridad, validado en hardware real (Ubuntu
24.04.5, 2026-09-30)**: `_vaultwarden_ensure_admin_token`
(`modules/vaultwarden.sh`) corría `docker run --rm -it vaultwarden/server
/vaultwarden hash --preset owasp` heredando la terminal del módulo (esa CLI
exige una tty real: con stdin sin tty entra en pánico). En el servidor real
el prompt de contraseña **nunca apareció** y las teclas tipeadas se
mostraban en eco en la terminal local **sin llegar al contenedor**: el
módulo quedaba colgado esperando una respuesta que el contenedor jamás
recibía. No es razonable pedirle a cada usuario que depure esto a mano en su
propio hardware. Causa más probable (no confirmada con un `strace` contra el
servidor real, pero consistente con el síntoma): `hli_docker` es `sudo -n
docker ...` (`lib/core.sh`), y el `use_pty` por defecto de `sudo` intercala
su PROPIA pty entre la terminal real y el proceso hijo; combinado con `-it`
(que además le pide a Docker asignarle otra pty al contenedor) y con la
salida yendo a `tee`, la cadena de ptys/pipes no garantiza que el teclado
llegue transparente hasta `vaultwarden hash` dentro del contenedor.
Corregido abandonando el contenedor interactivo por completo: la contraseña
ahora se pide con la propia TUI del HLI (`password_box`, `dialog
--passwordbox`, sin pty de por medio — mismo patrón que
`_adguard_ensure_admin_user` en `modules/adguard.sh`: mínimo 8 caracteres,
debe repetirse igual, se limpia la variable en toda salida, Cancelar aborta
sin guardar nada y sin marcar el módulo como hecho) y el hash se genera con
la CLI `argon2` de los repositorios de Ubuntu (paquete `argon2`, instalado
con `hli_apt install argon2` si falta), con la contraseña **solo por
stdin**, nunca por argv (mismo criterio que ya motivó pasar el token de la
API de Dokploy por stdin en vez de argv, v2.2). Parámetros: preset
"Bitwarden" (`m=65540` KiB, `t=3`, `p=4` — el que `vaultwarden hash` usa POR
DEFECTO sin `--preset owasp`; confirmado contra la wiki oficial,
<https://github.com/dani-garcia/vaultwarden/wiki/Enabling-admin-page>,
sección "Using argon2 CLI tool": `echo -n 'MySecretPassword' | argon2
"$(openssl rand -base64 32)" -e -id -k 65540 -t 3 -p 4`). La sal sale de
`head -c 16 /dev/urandom | base64` (no de `openssl rand -base64 32` como en
el ejemplo de la wiki): verificado a mano dentro de un contenedor
`ubuntu:24.04` descartable (paquete `argon2` 0~20190702+dfsg-4build1) que
con 16 bytes de entrada la sal re-codificada por `argon2` en el PHC de
salida **nunca** lleva padding `=` (24 caracteres ASCII, múltiplo de 3); con
32 bytes (44 caracteres, no múltiplo de 3) el padding ocasional rompería la
regex anclada existente (sin `=` en la clase de caracteres). El binario no
exige tty, lee la contraseña de stdin sin problema y devuelve el PHC con un
`\n` final que la propia sustitución de comandos de bash recorta sola —
ya no hace falta limpiar ningún `\r` (no hay pty) ni quitar comillas simples
(formato propio de `vaultwarden hash`, no de `argon2`). Se eliminó también
el código que limpiaba ese `\r`/esas comillas (ya sin objeto) y el test que
lo probaba (`test_vaultwarden_admin_token_strips_pty_carriage_return`); el
resto de `tests/test_vaultwarden.sh` se reescribió para el nuevo flujo
(`tests/stubs/argon2`, nuevo: lee la contraseña de stdin, nunca de argv) y
suma casos para contraseña corta y contraseñas que no coinciden. Vaultwarden
no tiene una CLI propia de verificación de hashes: la validación de que el
valor generado es aceptado por el `bcrypt.go`/`argon2` que compara Vaultwarden
se apoya en el formato PHC completo (regex anclada a ambos lados) y en que
la librería `argon2` que usa Vaultwarden (crate `argon2`, Rust) es
compatible con el formato PHC estándar que emite la CLI `argon2` de
referencia (ambas implementan la misma RFC 9106). **Verificado end-to-end
(2026-10-01)**: hash generado con la CLI `argon2` de `ubuntu:24.04` y los
mismos parámetros del módulo, cargado como `ADMIN_TOKEN` en un
`vaultwarden/server:latest` descartable: `POST /admin` con la contraseña
correcta → 200 y cookie `VW_ADMIN`; con una incorrecta → 401 "Invalid admin
token". Detalle completo en Engram (`hli2/vaultwarden-hash`).

**Pendiente de validar en un servidor real** (no se pudo probar contra un
Dokploy real desde acá):
- El campo `env` de `compose.create`/`compose.update` (documentado para
  `compose.update`, asumido también en `compose.create`) y si Dokploy
  sustituye `${CLAVE}` en el compose exactamente como un `.env` de Docker
  Compose.
- Que Dokploy escriba el campo `env` al `.env` **sin alterarlo**, y que las
  comillas simples (`ADMIN_TOKEN='$argon2id$...'`,
  `INITIAL_ADMIN_PASSWORD='...'`) eviten la interpolación de `$` como en
  Docker Compose. Verificación: tras desplegar, `docker exec vaultwarden env
  | grep ADMIN_TOKEN` debe mostrar el hash completo, sin comillas y con
  todos sus `$`; y el login en `/admin` debe funcionar.
- `domain.create`/`domain.byComposeId` contra un compose real: el shape
  exacto de la respuesta, y si el servicio necesita explícitamente la red
  externa `dokploy-network` (creada por Dokploy) o si Dokploy la inyecta solo.
- ~~Si `vaultwarden hash --preset owasp` corrido con `docker run --rm -it`
  desde dentro de un módulo TUI de HLI 2 (bajo `dialog`) hereda la terminal
  correctamente en todos los casos~~ — **resuelto, y mal**: en hardware real
  NO heredaba la terminal (ver el hallazgo de arriba). Reemplazado por
  `password_box` + CLI `argon2`.
- ~~Que el login en `/admin` de Vaultwarden funcione con un hash de la CLI
  `argon2`~~ — **verificado** contra un Vaultwarden real descartable (ver
  arriba). Falta solo repetirlo en la X230 con el despliegue completo.
- ~~Consumo de RAM de OpenCloud y comportamiento real de sus clientes de
  escritorio/móvil~~ — **verificado** en el M70q (2026-10-05) con el dominio
  público vía Cloudflare Tunnel: web, cliente de escritorio (Fedora) y app
  Android inician sesión; ~230 MiB de RAM y <1 % de CPU en reposo.
- Si `opencloud init` tolera bien corridas repetidas del módulo (el propio
  proyecto documenta que falla en la segunda vez y por eso se ignora con
  `|| true`, pero no se probó contra la imagen real).
- Que `sudo -n` (usado ahora también para LEER `/etc/hli2/*`, no solo para
  escribir) siga cacheado en el momento exacto en que un módulo llama a
  `secret_get`/`dokploy_api_configured` — `bootstrap.sh` mantiene un
  keepalive de fondo, pero nunca se probó el camino de lectura contra un
  `sudo` real (solo contra el stub de tests).

### v2.3.1 — Importador y diagnóstico (en curso)

Encontrado al validar la importación real del M70q en la X230 (2026-10-02):

- [x] Si un servicio está corriendo, ofrecer detenerlo, importar y volver a
      desplegarlo (hoy lo omite y deja que el usuario lo resuelva).
- [x] Consultar el estado de los contenedores ANTES de extraer el backup (hoy
      extrae todo, que es lo lento, y recién después decide omitir).
- [x] Aviso de "trabajando" y progreso durante la extracción y la copia.
- [x] Mensajes separados: "está activo" vs "no se pudo consultar Docker (falta
      sudo)".
- [x] Un módulo ejecutado directamente (fuera de bootstrap.sh) pide sudo al
      inicio si no está en caché (hoy todo da "desconocido").
- [x] Los módulos interactivos dejan sus errores en un log: hoy van a stderr,
      la siguiente ventana los tapa y no queda rastro en /var/log/hli2.

### v2.4 — Exposición externa: Cloudflare Tunnel (público) + Tailscale (privado)

Decidido 2026-10-05: el túnel solo para lo público; lo privado por Tailscale.
Cloudflare Access queda como alternativa documentada (ver más abajo), no se
implementa. Requiere un dominio con su DNS en Cloudflare.

| Servicio | Acceso desde fuera | Cómo |
|---|---|---|
| Vaultwarden | Público (login + 2FA) | Túnel; `/admin` responde 404 desde Internet |
| OpenCloud | Público (login propio) | Túnel |
| Home Assistant | Público (login + 2FA + bloqueo de IP) | Túnel directo a `<IP LAN>:8123` (red del host) |
| Sitios web | Público | Túnel |
| Panel de Dokploy, qBittorrent, Seerr, Jellyfin, Samba, AdGuard | Privado | Tailscale |

**v2.4a — módulos (primero):**
- [x] `cloudflared`: túnel **administrado remotamente**, creado por el usuario en
      Cloudflare (Zero Trust → Networks → Tunnels). El módulo pide el token,
      lo guarda root-only y despliega `cloudflare/cloudflared` como compose de
      Dokploy en `dokploy-network` (`tunnel --no-autoupdate run`, token por el
      canal `env` entre comillas simples). Verificar que llega a
      `dokploy-traefik:80` por nombre.
- [ ] Nombres públicos (por ahora a mano en el panel de Cloudflare, en este
      orden): `vault.<dominio>` ruta `^/admin` → `http_status:404`;
      `vault.<dominio>` → `http://dokploy-traefik:80`; `cloud.<dominio>` →
      `http://opencloud:9200` (directo, sin Traefik: Traefik le pasa
      `X-Forwarded-Proto: http` y OpenCloud, con `OC_URL` https, responde 308
      a https en bucle — verificado en el M70q); `casa.<dominio>` →
      `http://<IP LAN>:8123`.
      Nada más: lo no listado no existe desde fuera.
      Estado (2026-10-06, M70q): `vault` (con `/admin` 404), `cloud` y
      `casa` publicados y verificados con datos móviles.
- [x] Home Assistant antes de publicarlo: 2FA en cada usuario y en
      `configuration.yaml` `use_x_forwarded_for`, `trusted_proxies` (red de
      Docker de `cloudflared`), `ip_ban_enabled`, `login_attempts_threshold: 5`.
      Hecho en el M70q (2026-10-06). Hallazgos:
      - Las versiones nuevas de Home Assistant migran el bloque `http:` de
        YAML a la interfaz (Configuración → Sistema → Red → Servidor HTTP) y
        piden borrarlo del archivo (deja de funcionar en 2027.2).
      - La migración copió `trusted_proxies` pero dejó APAGADO "Confiar en
        X-Forwarded-For": sin eso, todo Internet llega como la IP del túnel y
        el bloqueo de IP castigaría al túnel entero. Revisarlo siempre.
      - El proxy de confianza es la subred de `docker_gwbridge`
        (`172.18.0.0/16` en el M70q), no `dokploy-network`: `cloudflared`
        llega a `<IP LAN>:8123` saliendo por esa red. Se obtiene del propio
        Home Assistant: publicar la ruta, abrirla (400 esperado) y leer la
        IP en `docker logs homeassistant` ("A request from a reverse proxy
        was received from ...").
- [x] `tailscale`: instala Tailscale en el host desde su repositorio oficial
      (con `hli_apt`), ejecuta `tailscale up` mostrando la URL de inicio de
      sesión, y explica cómo instalar la app en los dispositivos. Opcional:
      AdGuard como DNS de la tailnet (bloqueo de publicidad en el teléfono).
- [x] Vaultwarden y OpenCloud con su dominio final (`https://`); OpenCloud
      necesita la URL pública fija desde su primer arranque.

**v2.4b — sincronización (después):** herramienta que mantiene los nombres
públicos del túnel desde el registro de servicios vía la API de Cloudflare
(token con permisos mínimos, por stdin), idempotente y manual.

**Alternativa no implementada — Cloudflare Access:** protegería por navegador
lo privado (con Google), pero no cubre apps móviles, Samba ni DNS; Tailscale
sí. Se reconsidera si hace falta entrar desde equipos ajenos.

**Verificación:** `https://vault.<dominio>` abre con HTTPS desde el teléfono
con datos móviles; `/admin` da 404 desde fuera y funciona por Tailscale/LAN;
un subdominio no listado no responde; `dig <dominio>` no muestra la IP de la
casa; puertos 80/443 cerrados en el router; con Tailscale activo, el panel de
Dokploy y Jellyfin responden fuera de casa y el resto de Internet funciona
normal.

### v2.5 — Backups (restic: local + Cloudflare R2)

Especificación acordada con el usuario (2026-10-06):

- [x] **Qué se respalda** (desde el registro de servicios, `SERVICE_DATA`):
      todo `/srv/appdata` **excepto cachés** (`jellyfin/cache`), `/etc/samba/smb.conf`,
      `/etc/hli2` (secretos, root 0600) y la configuración del HLI. La media
      (`/srv/media*`) NO se respalda. Dokploy no se respalda: se reinstala y
      los composes se regeneran con los módulos del HLI.
- [x] **Consistencia**: `SERVICE_BACKUP_KIND` gobierna. `sqlite` (o base
      embebida) = detener el contenedor durante la foto local y levantarlo
      siempre (trap). Corregir el registro: Home Assistant (SQLite) y AdGuard
      (bbolt) pasan a ese tipo. Los contenedores parados lo menos posible: la
      subida a R2 ocurre con los servicios ya levantados.
- [x] **Dos fotos en la misma ventana de parada**, ambas en el repositorio
      local (deduplicadas, casi gratis): una completa (tag `full`) y otra sin
      `opencloud/data` (tag `cloud`). Con los servicios ya levantados,
      `restic copy --tag cloud` lleva esa foto al repositorio de R2: la copia
      externa es idéntica a la local, sin una segunda parada.
- [x] **Repositorio local** en el SSD de media (`$BACKUP_ROOT`, por defecto
      `$MEDIA_ROOT/.hli2-backups`; el módulo `storage` ya no le cambia dueño
      ni modo y Samba no lo comparte), carpeta root 0700 (`/srv/media` sí se
      comparte por Samba). **Falla cerrado** si esa ruta no está en un punto de montaje
      distinto del disco del sistema (lección del 2026-10-06: un disco montado
      tarde deja escribir en la carpeta oculta del NVMe).
- [x] **Repositorio externo**: Cloudflare R2 (bucket propio, token S3 con
      permiso solo sobre ese bucket). Endpoint, bucket y claves en
      `/etc/hli2/restic.env` root 0600 (`RESTIC_REPOSITORY`,
      `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION=auto`),
      nunca en argv ni en logs: llegan a restic solo por su entorno. El
      archivo SÍ se respalda (cifrado): se necesita para recuperarse de un
      desastre; la contraseña de restic NO se respalda.
- [x] **Contraseña de restic**: generada al configurar, guardada root 0600,
      mostrada UNA vez con confirmación explícita de que el usuario la guardó
      en Vaultwarden **y en papel** (sin ella la copia externa es irrecuperable;
      si el servidor muere, Vaultwarden muere con él).
- [x] **Automático**: timer de systemd diario a las 04:00 (`Persistent=true`)
      que corre `bin/hli2-backup run` como root **desde una copia root-owned del
      código** en `/usr/local/lib/hli2` (la deja `backup-setup` y la refresca
      `backup-now`; root nunca ejecuta el checkout del usuario; el estado de
      root vive en `/var/lib/hli2-root`). La primera corrida hace una pasada
      previa en vivo para que la parada sea corta; una lista de recuperación
      levanta lo que un backup interrumpido deje detenido (módulos `backup-setup` y
      `backup-now`; la lógica vive en `lib/backup.sh`). Supuestos de restic
      0.16.4 (noble): `restic copy --from-repo --from-password-file --tag`,
      retención con `--group-by host,tags`; región `auto` de R2 sin verificar
      en hardware. **Manual**: "Hacer backup ahora" en el menú.
- [x] **Retención** en ambos repositorios: `--keep-daily 7 --keep-weekly 4
      --keep-monthly 6`, más `prune`. Chequeo de integridad periódico
      (`restic check`, con una muestra de datos).
- [x] **Restaurar** desde el menú (parte del entregable, no opcional):
      Herramientas → "Restaurar un backup" (`modules/backup-restore.sh`):
      origen (copia local, o R2 si está configurada), fecha (foto, la más nueva
      primero), y qué (un servicio con datos o "todo", para migrar a un equipo
      nuevo). Resumen claro de lo que se reemplaza y de la fecha, y
      "¿Hacer un backup de seguridad del estado actual antes de restaurar?"
      (por defecto sí; corre `hli2-backup run --no-retention`, porque la
      retención podría borrar justo la foto elegida). Lo hace root con
      `hli2-backup restore --source local|r2 --snapshot <id> --target
      <servicio|all>` (más `snapshots --source` para la lista), desde la misma
      copia root-owned, con el mismo bloqueo, lista de recuperación y reinicio
      garantizado que el backup; los argumentos se validan de forma estricta
      (id hexadecimal, destino del registro, origen enum) y las rutas salen
      siempre del registro, nunca de los argumentos. Detalle (ver
      `lib/restore.sh`):
      - Se verifica la foto (existe en ese repositorio con el tag `full` en
        local o `cloud` en R2), el espacio libre (estimado con `du` o con
        `restic stats`) y que ni la ruta ni su padre ni la carpeta de paso sean
        enlaces simbólicos. Cada ruta se restaura primero en
        `<ruta>.hli2-restore-tmp` (mismo sistema de archivos, creada con `mkdir`
        sin `-p` y comprobada) **con los contenedores aún en marcha**; recién con
        todo listo se detienen **todos** los contenedores del servicio y se
        intercambia: lo actual pasa a `<ruta>.hli2-before-restore-<fecha>` y lo
        restaurado ocupa su lugar (reemplazo, no mezcla). Cada servicio se
        intercambia con las señales ignoradas de principio a fin, con un diario
        en el estado de root: si el proceso aborta, se deshace; si el equipo se
        cae a medias, `hli2-backup recover` (o el siguiente `run`/`restore`) lo
        deshace antes de iniciar ningún contenedor. Una restauración fallida o
        interrumpida nunca deja una carpeta a medias. Dueños y modos vienen de la
        foto (restic como root). `smb.conf` se valida con `testparm` antes.
      - Copias previas: se conservan la más vieja (el estado anterior a las
        restauraciones) y la más nueva de cada ruta, solo las de corridas
        exitosas (registro en el estado de root); no se borra nada tras una
        corrida fallida o si la anterior quedó interrumpida. Si el módulo acaba
        de hacer el backup de seguridad **y su estado lo confirma** (resultado
        correcto, con foto, de esa corrida) pasa `--discard-old` y se borran
        todas. Las copias de los `.env` de `/etc/hli2` van fuera de `/etc/hli2`
        pero en su mismo sistema de archivos (`/etc/hli2-old-secrets`, 0700; se
        comprueba el dispositivo): el `mv` es un renombrado y los secretos viejos
        no entran en los backups.
      - El diario se sincroniza (`sync`) antes del primer `mv`; al recuperar solo
        se aceptan destinos del registro de servicios (o `<servicio>.env`) y
        copias con el nombre exacto que genera la biblioteca. La recuperación
        corre también en el arranque, antes de Docker
        (`hli2-restore-journal.service` → `hli2-backup journal-recover`, sin
        docker), deja constancia (`reverted=1`; el dashboard y el módulo avisan) y,
        si un `mv` falla, conserva el diario como `.failed`, deja el estado en
        `error`. Mientras ese `.failed` exista, los contenedores de los servicios
        afectados no se inician (los demás sí), los backups no podan, no se acepta
        otra restauración y el dashboard lo avisa (pasos a mano en
        docs/VALIDACION.md); una línea del diario rechazada por la validación
        también lo deja como `.failed`. Con R2 ambiguo y una instalación nueva,
        `backup-setup` pregunta si el bucket es nuevo y está vacío (por defecto No;
        `init --r2-assume-new`); nunca en una recuperación.
      - Un backup (timer) que espera el bloqueo durante una restauración
        termina bien: no refresca la fecha del último backup real ni pisa su
        resultado, solo anota `last_skip` ("restauración en curso") en el estado y
        el dashboard.
      - `opencloud/data` solo desde la copia local: desde R2 no se pide ni se
        toca y el resultado queda "con avisos" explicando por qué.
      - "Todo": todos los servicios con datos, `smb.conf` (unidad `smbd` se
        reinicia) y los `<servicio>.env` de `/etc/hli2`, uno por uno y atómicos.
        **Nunca** `restic-password`; `restic.env` solo con pedido explícito
        (el módulo lo pregunta, por defecto No); `dokploy.env` nunca.
      - Contenedores que no existen (equipo nuevo): se restauran los datos y se
        avisa qué módulos ejecutar (y Dokploy primero si Docker no está).
      - Recuperación ante un desastre: reinstalar Ubuntu y el HLI, ejecutar
        `backup-setup` con la **misma contraseña de restic** ("Recuperación
        ante un desastre"). `hli2-backup init` comprueba R2 primero (`restic cat
        config`) y no inicializa nada si la contraseña no lo abre o no se puede
        comprobar (solo inicializa ante un "no hay repositorio" explícito: código 10 de
        restic >= 0.17, o "specified key does not exist"/NoSuchKey sin marcadores de
        acceso o red); con un repositorio local existente, la contraseña se verifica
        contra él; sin R2 ni repositorio local no se crea uno nuevo en silencio;
        con R2 existente, el repositorio local nuevo copia sus parámetros de
        troceado. Se puede reingresar la contraseña tras un fallo. Luego,
        restaurar "todo" desde R2 (procedimiento completo en docs/VALIDACION.md,
        prueba 80).
      - Resultado en `/var/lib/hli2-root/restore-status` (0644, sin secretos) y
        en `/var/log/hli2/backup.log`. Supuestos de restic 0.16.4 sin verificar
        en hardware: `restore <id> --target <dir> --include <ruta-absoluta>`
        (crea `<dir>` y restaura la ruta con todo su contenido bajo
        `<dir>/<ruta>`), `snapshots --json` con `id`, `short_id`, `time` y
        `tags`, y `snapshots --tag T <id-corto>`.
- [x] **Estado visible**: resultado del último backup (fecha, OK/error, qué
      copia falló) legible por el usuario y mostrado en el dashboard del HLI.
      Avisos por Telegram: v2.6.
- [x] **Validado en el M70q (2026-10-09)**: `backup-setup` con un bucket R2
      nuevo y vacío (restic 0.16.4 lo reconoce como "repositorio inexistente":
      no hizo falta confirmar), backup local + R2 correctos (dashboard),
      restaurar Vaultwarden desde local y desde R2 a la foto anterior (la
      entrada borrada volvió en ambos casos). El backup nocturno del timer
      corrió solo (2026-10-10). Pendiente: simulacro "todo" en la X230.
- [x] **Registro local de servicios** (`/etc/hli2.d/services/*.conf`): servicios
      propios del usuario, fuera del repositorio público, con el formato de
      `services/*.conf`. Entran en la misma corrida de backup (mismas fotos y
      repositorios), en la restauración ("Todo" restaura primero el registro y
      después los datos) y en el dashboard con la marca "(local)". Pensado para
      aplicaciones desplegadas a mano en Dokploy, como JASJIC (ver la sección
      correspondiente). Los archivos se cargan con `source`, así que solo se
      aceptan si son de root, regulares, sin escritura para grupo/otros y en
      directorios de root; las rutas de datos deben quedar bajo `/srv/appdata`.
      Un id que coincide con un servicio incluido se ignora (gana el incluido)
      y se avisa en el log. `/etc/hli2.d` se respalda. Documentado en el
      README (pruebas en docs/VALIDACION.md).
- [ ] Verificación en el M70q: backup manual, backup del timer, restaurar
      Vaultwarden desde local y desde R2 a una fecha anterior, y un
      "restaurar todo" de prueba en la X230 (docs/VALIDACION.md, pruebas
      48-80; la validación en hardware sigue pendiente).

### v2.6 — Agente IA siempre activo

Arquitectura acordada con el usuario (2026-10-16). Objetivo: un agente 24/7 en
el M70q que atienda consultas y tareas (y en el futuro el correo) **pagando lo
menos posible**, sin dejar de tener Claude para el trabajo pesado.

**Conceptos que fijan el diseño (verificados):**
- **Hermes es el cuerpo, no el cerebro.** Aporta memoria, herramientas,
  canales y tareas programadas; el cerebro es el modelo que se le conecta, y
  se puede cambiar según la tarea.
- **Estar encendido no cuesta.** Un agente esperando no gasta tokens; el costo
  es solo por trabajo hecho.
- **Paralelizar no ahorra.** N agentes terminan antes pero cada uno lee su
  contexto: el gasto se multiplica, no se divide.
- **La suscripción de Claude NO puede usarse en Hermes.** Los términos de
  Anthropic (aclaración de febrero de 2026, con bloqueos desde enero y abril
  de 2026) limitan el OAuth de Free/Pro/Max a Claude Code y Claude.ai; las
  herramientas de terceros deben usar claves de API (pago por token).
- **Por qué un agente por API "gasta más tokens" que el chat (y cómo se
  controla):** el token es la misma unidad en ambos casos, pero la API no
  tiene memoria: en cada llamada el agente reenvía instrucciones, definiciones
  de herramientas, memoria e historial, y un agente hace varias llamadas por
  pedido (piensa → usa una herramienta → lee el resultado → responde). Con la
  suscripción ese costo existe igual, solo que queda oculto en la tarifa fija.
  Se controla con: caché de prompts (el prefijo repetido se cobra mucho más
  barato en los proveedores que lo soportan), compresión del contexto
  (tarea auxiliar de Hermes, con modelo barato), menos herramientas activas
  (cada definición viaja en cada llamada), sesiones cortas (empezar una nueva
  por tema), límite de iteraciones por tarea, modelos baratos para lo simple y
  **medición** (panel de actividad de OpenRouter, por modelo y por día).

**Dos agentes complementarios:**

| | Hermes (24/7, en el M70q) | Claude Code (suscripción fija) |
|---|---|---|
| Para qué | Consultas, investigación, recordatorios, tareas programadas, diagnóstico del servidor, (futuro) correo | Trabajo pesado: código, el HLI, proyectos |
| Cerebro | Modelos abiertos baratos vía OpenRouter + IA local; Claude por API solo a pedido | Claude, con la suscripción |
| Cómo se usa | hermes-android (Tailscale) o Telegram | Terminal, o desde el teléfono con Remote Control y rutinas programadas (producto oficial: permitido) |
| Costo | Por token, con tope mensual | Fijo (la suscripción actual) |

Hermes no invoca a Claude Code (sería usar la suscripción desde un tercero);
si una tarea lo amerita, Hermes avisa y el usuario la abre en Claude Code.

#### v2.6a — Hermes base
- [x] Compose en Dokploy (proyecto propio) partiendo de la plantilla oficial de
      Dokploy: imagen `nousresearch/hermes-agent` **fijada a una versión**
      (`X.Y.Z` o digest), `command: gateway run`, datos en
      `/srv/appdata/hermes` → `/opt/data` (bind, ext4), `HERMES_UID/GID`
      coherentes con el dueño de la carpeta, `restart: unless-stopped`,
      `shm_size: 1g` (navegador), límites 4 GB / 2 CPU.
- [x] Aislamiento: **sin** socket de Docker (descarta el backend de terminal
      `docker`: equivale a root en el host), sin montar `/srv` ni el home, sin
      red del host, nunca como root. La frontera es el contenedor
      (`terminal.backend: local`).
- [x] API (8642, `API_SERVER_ENABLED`, `API_SERVER_HOST=0.0.0.0` dentro del
      contenedor, `API_SERVER_KEY` de 64 hex): la clave equivale a control total
      del agente → secreto root-only en `/etc/hli2`, publicada en el host solo
      en las IPs de LAN y Tailscale (nunca `0.0.0.0` del host, nunca por el
      túnel ni el router).
- [x] Dashboard (9119) con autenticación obligatoria (basic auth con
      `HERMES_DASHBOARD_BASIC_AUTH_SECRET`), mismo criterio de exposición.
- [x] Aprobaciones: arrancar con `approvals.mode: manual`; pasar a `smart`
      cuando haya confianza. `security.website_blocklist` y protección SSRF
      activas.
- [x] Backup: registrar `hermes` en `/etc/hli2.d/services` (tipo con parada:
      usa SQLite) para que entre en el backup nocturno.
- [x] Canal principal **[hermes-android](https://github.com/rusty4444/hermes-android)**
      (Android; Hermex es solo iOS): habla con la API 8642 y opcionalmente con
      el dashboard. Solo por Tailscale/LAN (el propio README lo exige). APK de
      GitHub Releases. Verificar: chat con streaming y voz fuera de casa con
      Tailscale encendido; con Tailscale apagado no responde.

**Implementación (módulo `hermes`, pendiente de validar en el M70q) y hechos
verificados el 2026-10-16** (fuentes: documentación oficial de Hermes —
`user-guide/docker`, `configuration`, `security`, `features/api-server`,
`features/web-dashboard`, `features/fallback-providers` —, plantilla de
Dokploy `dokploy.com/templates/hermes`, Docker Hub, código v0.22.2 de
`github.com/NousResearch/hermes-agent` y `openrouter.ai`):
- Imagen **fijada a `nousresearch/hermes-agent:v0.22.2`** (publicada el
  2026-10-15; `latest` y `stable` apuntan a la misma, pasó la compuerta de
  versión estable; reemplaza a v0.22.1, "construida desde el commit
  equivocado"). La plantilla de Dokploy usa `v2026.6.19` (más vieja). Se
  actualiza cambiando la línea de `compose/hermes/docker-compose.yml`.
- Variables: `API_SERVER_ENABLED/HOST/PORT/KEY` (clave obligatoria, mínimo 8
  caracteres; da acceso a todas las herramientas, incluida la terminal),
  `HERMES_DASHBOARD=1`, `HERMES_DASHBOARD_BASIC_AUTH_USERNAME/PASSWORD/SECRET`
  (con bind no-loopback el dashboard se niega a arrancar sin autenticación;
  el proveedor basic es solo para redes de confianza o VPN),
  `HERMES_UID/HERMES_GID`, `OPENROUTER_API_KEY`. La imagen arranca con
  s6-overlay y baja a ese uid; `gateway run` como root se rechaza.
- Valores por defecto que **no** son los deseados y por eso se fijan en el
  `config.yaml` sembrado: `approvals.mode` es `smart` (se fija `manual`);
  `security.website_blocklist.enabled` es `false` (se activa); la protección
  SSRF (`security.allow_private_urls: false`) ya viene activa y bloquea
  también el rango CGNAT de Tailscale.
- Tareas auxiliares que usan un LLM en v0.22.2 (`DEFAULT_CONFIG["auxiliary"]`):
  `vision`, `compression`, `skills_hub`, `approval`, `review`, `mcp`,
  `title_generation`, `memory_query_rewrite`, `tts_audio_tags`, `voice_chat`,
  `triage_specifier`, `kanban_decomposer`, `profile_describer`, `goal_judge`,
  `curator`, `monitor`, `background_review`, `moa_reference`,
  `moa_aggregator` (`web_extract` y `session_search` ya no usan un LLM). El
  módulo fija las 19 a `provider: openrouter` + el modelo auxiliar barato.
  Esta lista debe revisarse al actualizar la imagen.
- Modelos propuestos por defecto (precios de OpenRouter al 2026-10-16, por
  millón de tokens): principal `deepseek/deepseek-v4.1-flash` (0,032 USD de
  entrada / 0,144 de salida, contexto 1M, herramientas, texto+imagen);
  auxiliar y respaldo `qwen/qwen3.7-flash` (0,03 / 0,13; 0,10 / 0,40 sobre 32k
  de prompt; herramientas, texto+imagen+video). Ambos editables en el cuadro
  de entrada; el módulo valida solo la forma `autor/modelo`.
- Las plataformas sin canal de aprobación (`api_server`, webhook) usan
  `approvals.unattended_mode` (por defecto `deny`): con hermes-android y
  `manual` un comando peligroso se **bloquea** en vez de preguntar, salvo que
  la app use el canal `POST /v1/runs/{id}/approval` (el README de
  hermes-android menciona aprobaciones nativas). A confirmar en la prueba
  111 de `docs/VALIDACION.md`.
- Sin verificar: que `openrouter.ai` permita reinicio **mensual** del límite de
  una clave (la documentación solo describe `limit` y `limit_reset` sin listar
  valores); que `data_collection: deny` deje al menos un proveedor disponible
  para cada modelo elegido (la API pública no expone la política de datos por
  proveedor; si no queda ninguno, OpenRouter responde error y se usa el
  respaldo); que `hermes config set` acepte rutas `auxiliary.<tarea>.model`
  (se usa solo al cambiar modelos en una re-ejecución).
- Digest: además de la etiqueta, la imagen se fija por digest
  (`@sha256:36099926…`, lista de manifiestos amd64+arm64 de `v0.22.2` según
  la API de Docker Hub, verificada el 2026-10-16). Al actualizar se cambian
  etiqueta y digest juntos.
- Endurecimiento: `security_opt: no-new-privileges` y `pids_limit: 512`. El
  arranque de la imagen baja de root al uid del agente con `s6-setuidgid`
  (llamadas `setuid`/`setgid`, no binarios setuid; `docker/main-wrapper.sh` y
  `stage2-hook.sh` de v0.22.2) y la imagen no trae `sudo`, así que
  `no-new-privileges` no debería interferir; no se probó en el servidor
  (plan de contingencia: prueba 119 de `docs/VALIDACION.md`). `cap_drop` no se
  fija (el entrypoint hace `chown`/`usermod`).
- **Aislamiento de salida (egress).** La terminal del agente podría alcanzar
  el panel de Dokploy (:3000), AdGuard, Home Assistant, el router. El módulo
  pone al contenedor en su propia red (`hermes-net`, subred /24 fija
  `10.213.144.0/24`, configurable con `HLI2_HERMES_SUBNET`) e instala reglas
  de iptables en dos cadenas propias:
  `HLI2-HERMES-FWD` (enganchada en `DOCKER-USER`, tráfico hacia otras
  máquinas): ESTABLISHED/RELATED aceptado, hook `HLI2-HERMES-ALLOW`, DNS, DROP
  de conexiones nuevas hacia 0/8, 10/8, 100.64/10 (Tailscale), 127/8,
  169.254/16, 172.16/12, 192.0.0/24, 192.168/16, 198.18/15, 224/4 y 240/4; el
  resto (Internet pública) sigue; y `HLI2-HERMES-IN` (enganchada en `INPUT`,
  tráfico hacia la propia máquina: AdGuard y Home Assistant usan la red del
  host y NO pasan por `DOCKER-USER`): ESTABLISHED/RELATED, hook y DNS, todo lo
  demás DROP. Razonamiento de las entradas publicadas (8642/9119): la
  conexión entrante LAN/Tailscale → contenedor tiene origen en la LAN, no en la
  subred, así que no se filtra, y las respuestas (origen = subred) son
  ESTABLISHED y las acepta la primera regla. DNS: el contenedor usa `dns:`
  explícito (la IP de la LAN del servidor solo si el módulo `adguard` está
  hecho; si no, 1.1.1.1/9.9.9.9) y se permite solo ese destino en el puerto 53.
  - Validación previa de la subred (antes de preguntar o instalar nada): forma
    `a.b.c.0/24` con octetos numéricos, solo RFC 1918 (se rechazan 127/8,
    100.64/10, 169.254/16 y públicas), sin contener la IP de la LAN, y sin
    solaparse con ninguna ruta de `ip -4 route show` ni con las subredes de
    las redes de Docker existentes (la propia `hermes-net` con la misma
    subred no cuenta como choque).
  - Servicio `hli2-hermes-egress` (script `/usr/local/sbin/hli2-hermes-egress`
    con `apply`/`remove`): unidad `Before=docker.service`, `RemainAfterExit`,
    `WantedBy=multi-user.target docker.service` (Docker la arrastra), sin
    `PartOf`; el script crea `DOCKER-USER` si falta. Docker lo tolera: en moby
    (`libnetwork/firewall_linux.go`, v27.3.1) `setupUserChain` solo crea la
    cadena si no existe, agrega un `RETURN` solo si falta, asegura el salto
    desde `FORWARD` y su comentario dice que el demonio "does not delete or
    modify any pre-existing rules from the DOCKER-USER filter chain" (leído en
    el código; la documentación publicada de Docker no lo afirma). Además un
    drop-in de `docker.service` (`ExecStartPost=-…/hli2-hermes-egress apply`,
    rápido, sin esperas) reaplica tras `systemctl restart docker`. Así no
    queda ventana sin reglas al arrancar.
  - Aplicación atómica: se arma la cadena `…-new` completa, se inserta el salto
    a ella, se borran TODOS los saltos a la anterior (de cualquier subred
    de origen, leídos con `iptables -S INPUT` y `-S DOCKER-USER`: limpia restos
    de una subred vieja), se elimina la anterior y la nueva se renombra con
    `-E`. Nunca hay un salto a una cadena vacía o a medio armar.
  - Usa la ruta absoluta `/usr/sbin/iptables` (sobrescribible con
    `HLI2_IPTABLES`) y registra `iptables -V` en el journal: el backend
    (legacy o nf_tables) debe coincidir con el de Docker.
  - Hook para permitir un destino local concreto (v2.6c Ollama): reglas
    ACCEPT en la cadena `HLI2-HERMES-ALLOW`, que `apply` no reconstruye. Ojo:
    `remove` SÍ la vacía y la borra. Para quitarlo todo:
    `systemctl disable --now hli2-hermes-egress`, `hli2-hermes-egress remove`
    y borrar el script, la unidad y `docker.service.d/hli2-hermes-egress.conf`.
  - Tras el despliegue se verifica con `docker inspect` que el contenedor
    esté SOLO en `hermes-net`; si Dokploy le agregó otra red (por ejemplo
    `dokploy-network`) se avisa con un mensaje de ATENCIÓN. IPv6 no está
    habilitado en la red.
- IPs: la IP de la LAN se toma de la interfaz de la ruta por defecto
  (`ip -4 route get 1.1.1.1`, campo `src`; `get_ip` toma la primera de
  `hostname -I`, que puede ser un puente de Docker) y debe ser privada
  (RFC 1918); la de Tailscale debe estar en 100.64.0.0/10; si coinciden se
  publica una sola vez.
- Arranque con Tailscale, sin retrasar a Docker (Docker → AdGuard es el DNS
  de toda la LAN): no hay esperas ni `network-online.target`. Si hay IP de
  Tailscale publicada, el módulo instala `/etc/sysctl.d/90-hli2-hermes.conf`
  con `net.ipv4.ip_nonlocal_bind = 1` (aplicado también con `sysctl -w`) y,
  si existe `tailscaled.service`, `docker.service.d/hli2-tailscale.conf` con
  solo `After=tailscaled.service` (sin `Wants`). Razonamiento: docker-proxy
  hace `bind()` sobre la IP publicada y sin `ip_nonlocal_bind` falla con
  "cannot assign requested address" si `tailscale0` aún no existe; las reglas
  DNAT de Docker se crean con `-d <ip>` y no exigen que la IP esté asignada, el
  kernel solo las evalúa cuando llega un paquete con ese destino. Efecto
  lateral: el sistema acepta `bind()` a IPs no locales (riesgo menor). No
  verificado en el servidor: si no alcanzara, la alternativa sin esperas es
  reiniciar el contenedor cuando `tailscale0` obtenga IP (path/dispatcher),
  nunca retrasar Docker.
- Backup: se mantiene `sqlite` (parada de unos segundos a las 04:00; costo
  aceptado a cambio de una copia consistente de `state.db`). Alternativa
  descartada: `files` sin parada, con riesgo de copiar la base a medio escribir.
- Diseño: puertos publicados solo en la IP de LAN y la de Tailscale (compose
  "docker-compose", no "stack"); conviene una reserva DHCP para la IP de la
  LAN, y si cambia alguna IP basta volver a correr el módulo. Si el servidor
  arranca antes que Tailscale, Docker no puede publicar en esa IP hasta que
  exista (el módulo instala el drop-in de Docker descrito arriba; además se
  reintenta por `restart: unless-stopped`).
- [x] **Validado en el M70q (2026-10-18)**: hermes-android responde por
      Tailscale (con Tailscale apagado no conecta), aislamiento de salida
      verificado (`curl` del contenedor a `<IP LAN>:3000` → timeout), reinicio
      del servidor sin intervención (Hermes y el resto vuelven solos).
      Errores reales corregidos en la validación: `pids_limit` duplicado que
      Compose v2 rechaza, clave de API cortada en el textbox y AdGuard
      rechazando la red de Hermes por su lista de "Allowed clients" (el
      módulo ahora avisa).

#### v2.6b — Modelos y costo
- [ ] OpenRouter: clave propia **con límite de gasto mensual en la clave**
      (monto pendiente de decidir por el usuario) y `data_collection: deny`.
- [ ] Niveles: modelo abierto barato por defecto; `openrouter/auto` con nivel
      de costo bajo/medio donde convenga; Claude (vía OpenRouter, por token)
      solo cuando el usuario lo pida explícitamente.
- [ ] **Cada tarea auxiliar con proveedor y modelo explícitos** (títulos,
      compresión, visión, etc.) y `fallback_providers` definido: el issue
      #24029 (auxiliares que caían en un modelo pago) está cerrado desde
      2026-06-28, pero no se depende de los valores automáticos.
- [ ] Caché de prompts, compresión de contexto, herramientas mínimas
      activas, límite de iteraciones.
- [ ] Medición: una semana de uso real y revisión del gasto por modelo en
      OpenRouter antes de ajustar niveles o el tope.

#### v2.6c — IA local (Ollama) como cerebro privado opcional

**Medición en el M70q (2026-10-18, Ollama en CPU, i5-12400T, 32 GB):**

| Modelo | Lectura (contexto de 2.419 tokens) | Escritura |
|---|---|---|
| `gemma4:e4b` | 54 tokens/s (45 s) | 12–16 tokens/s |
| `gemma4:e2b` | 103 tokens/s (23 s) | 26 tokens/s |

Con el "pensamiento" del modelo activado, 5 frases tardaron 45 s (85 % en
razonamiento): para tareas de fondo se apaga (`think: false`).

**Decisión del usuario:** el modelo local también puede ser **cerebro de
Hermes** (no solo trabajador de fondo): la espera no le importa y gana
privacidad total y costo cero. Se elige el cerebro **por conversación**
(hermes-android permite elegir modelo por chat): local para lo privado o sin
apuro, OpenRouter para lo urgente o difícil. Ollama guarda en caché el
contexto ya leído, así que la espera larga es sobre todo el primer mensaje
de cada conversación (a medir).

- [x] Medición de velocidad (tabla de arriba).
- [ ] Módulo `ollama` (Dokploy, imagen fijada por versión/digest), modelos
      en `/srv/appdata/ollama` (excluidos del backup: se vuelven a descargar),
      sin puertos publicados en el host (solo alcanzable desde Hermes).
- [ ] Límite de CPU/RAM del contenedor (y `num_thread`) para que, mientras
      piensa, no deje sin recursos a AdGuard (DNS de la casa), Home Assistant
      y el resto.
- [ ] Ventana de contexto explícita (`num_ctx` amplio, p. ej. 32k): por
      defecto Ollama usa una ventana chica y **corta el contexto sin avisar**,
      fatal para un agente.
- [ ] Hermes: Ollama como proveedor compatible con OpenAI (modelo local
      seleccionable por chat), tiempos de espera largos para que una
      respuesta lenta no se trate como error, y sin respaldo automático a
      OpenRouter en los chats locales (si no, se pierde la privacidad sin
      que el usuario lo note).
- [ ] Firewall de Hermes: una única excepción en `HLI2-HERMES-ALLOW` hacia la
      IP/puerto de Ollama (el resto de la LAN sigue bloqueado).
- [ ] Modelos: `gemma4:e4b` como cerebro local (mejor calidad para
      herramientas) y `gemma4:e2b` para tareas de fondo rápidas.
- [ ] **Prueba que decide:** tareas reales con herramientas desde un chat
      local (buscar en la web, crear un recordatorio, leer el informe del
      servidor de v2.6d). Si las hace bien, queda como cerebro opcional; si
      no, solo trabajador de fondo. BitNet sigue descartado (sin evidencia de
      soporte de herramientas).

#### v2.6d — Diagnóstico del servidor (solo lectura)
- [ ] Timer del HLI (cada 5 min) que genera un **informe filtrado**: estado de
      servicios, disco, último backup, errores recientes de logs, recursos;
      **sin secretos** (redacción antes de escribir). Montado en Hermes en solo
      lectura. Hermes diagnostica y recomienda; el usuario aplica.
- [ ] Descartados: socket de Docker (aun con `:ro` da root en el host) y proxy
      del socket solo-lectura (`inspect` y logs exponen secretos que un agente
      manipulado por una página web podría enviar afuera).

#### v2.6e — Canal alternativo: Telegram
- [ ] Polling (sin puertos entrantes), `TELEGRAM_ALLOWED_USERS` con el ID del
      usuario (sin lista, todos rechazados). Las conversaciones pasan por los
      servidores de Telegram.

#### v2.6f — Claude Code como segundo agente
- [ ] Documentar el uso desde el teléfono (Remote Control, sesiones en la nube,
      rutinas programadas) con la suscripción actual. Sin integración con
      Hermes.

#### v2.6g — Correo (futuro)
- [ ] Lectura del correo con diseño anti-*prompt injection*: cualquiera puede
      enviar un correo con instrucciones ocultas. Solo lectura y clasificación
      (idealmente con el modelo local), sin acciones automáticas: toda acción
      derivada de un correo requiere confirmación del usuario.

#### v2.6h — Gateway (solo si hay varios agentes)
- [ ] Evaluar **Bifrost** (Go, binario único, presupuestos en la versión
      libre según su fabricante) frente a **LiteLLM** para ruteo y presupuesto
      por agente. Con un solo agente no aporta: agrega un servicio a mantener.

#### v2.6i — Open WebUI (opcional, última tarea)
- [ ] Interfaz tipo ChatGPT conectada a la API de Hermes, solo LAN/Tailscale.

### v2.7 — Espacio de trabajo: proyectos en el servidor + Obsidian

Acordado con el usuario (2026-10-16).

- [ ] **Proyectos en el M70q con VS Code Remote-SSH** (por Tailscale): el
      editor corre en el equipo del usuario; archivos, terminal y compilación en
      el servidor. Claude Code puede correr en esa sesión (producto oficial, con
      la suscripción) y seguirse desde el teléfono con Remote Control.
- [ ] Backup de los proyectos: git cubre lo publicado, pero el trabajo sin
      commit debe entrar en el backup nocturno (definir la ruta, p. ej.
      `~/src`, y cómo se registra: hoy el registro solo admite datos bajo
      `$APPDATA_ROOT`). Excluir dependencias regenerables (`node_modules`,
      `.venv`, `target`, cachés de build).
- [ ] **Bóveda de Obsidian en el servidor**, sincronizada con la Fedora y el
      teléfono. Opción por defecto: **Syncthing** (contenedor, por Tailscale,
      gratis, simple). Alternativas: *Self-hosted LiveSync* (plugin sobre
      CouchDB, tiempo real) u OpenCloud (bien en escritorio, la sincronización
      de carpetas en Android es limitada). La bóveda entra en el backup.
- [ ] **Hermes y Obsidian**: Hermes lee la bóveda (contexto y memoria de largo
      plazo legible y corregible por el usuario) y escribe solo en una
      subcarpeta propia (p. ej. `Hermes/`: resúmenes, recordatorios, diario).
      Montaje: bóveda en solo lectura + `Hermes/` en lectura/escritura. Si un
      contenido web manipulara al agente, no puede alterar el resto de las
      notas; el backup cubre cualquier error.
- [ ] Buenas prácticas para que la bóveda ahorre tokens de verdad: notas
      cortas, bien nombradas y enlazadas; el agente busca y lee solo las notas
      relevantes en vez de arrastrar historial.

**Descartado por ahora — "cluster" con la Fedora:** la Fedora es un notebook
(ThinkPad T480, sin GPU dedicada) que sale de casa. Un cluster no fusiona la
RAM de dos equipos en uno; repartir un modelo entre máquinas por la red (p. ej.
llama.cpp RPC) solo sirve para cargar modelos que no caben y suele ser más
lento; en el M70q el límite es la CPU, no la RAM. Se reconsidera si se suma un
equipo fijo con GPU: Hermes lo usaría primero como backend local y, si no
responde, pasaría al servidor o a la API (cadena de respaldo).

## Limitaciones conocidas

- **Huella de discos en `datadisk`**: se compone de tamaño, serie, WWN, modelo
  y PARTUUID (más serie/modelo del disco padre en particiones). Discos que no
  informan serie ni WWN (discos virtuales `virtio` sin `serial=`, algunas
  carcasas USB) quedan identificados solo por tamaño: un cambio por otro disco
  del mismo tamaño mientras el diálogo está abierto no se detectaría. Las tres
  confirmaciones muestran dispositivo, tamaño y modelo como última defensa.

- **Permisos de `AdGuardHome.yaml`**: el HLI lo deja en 0600 root (contiene
  el hash de la contraseña del panel), pero AdGuard Home lo reescribe con
  0644 al guardar cambios
  ([AdGuardHome#764](https://github.com/AdguardTeam/AdGuardHome/issues/764)).
  Limitación de AdGuard, no del HLI. Mitigación aplicada: las carpetas
  `/srv/appdata/adguard/{conf,work}` quedan en 0700 root, así que el archivo
  no es alcanzable por otros usuarios aunque AdGuard le cambie el modo.

## Riesgos a validar primero

- ~~Dokploy sobre Ubuntu 26.04~~ — **confirmado incompatible** en la X230: el
  instalador fija Docker 28.5.0 (Docker 29 rompe su Traefik) y no existe para
  26.04. El módulo `dokploy` bloquea sistemas posteriores a 24.04.
- ~~`network_mode: host` en compose administrado por Dokploy~~ — **validado**
  (AdGuard sirve DNS en 53; Home Assistant descubre dispositivos de la LAN).
- Cloudflare Tunnel exige un dominio administrado en Cloudflare (v2.4).

## Migración del M70q

Plan de discos (decidido 2026-10-05):

| Disco | Uso | Montaje |
|---|---|---|
| NVMe | Sistema y servicios (`/srv/appdata`) | `/` (LVM) |
| SSD SATA 2 TB (interno, nuevo) | Media | `/srv/media` |
| HDD 2 TB (USB) | Media | `/srv/media2` |
| HDD 1 TB (el de hoy) | Solo durante la copia, en carcasa USB | temporal (p. ej. `/mnt/viejo`), fuera del pool |

El M70q tiene una sola bahía SATA de 2,5": el SSD nuevo va adentro y el HDD
viejo pasa a una carcasa USB para la copia (~840 GB, unas 2–2,5 h por USB).

Pasos:
1. Backup completo con el HLI v1 (`/srv/backups/backup-<fecha>.tar.gz`) y una
   copia fuera del M70q (Fedora).
2. DNS secundario en el router (p. ej. `1.1.1.1`) antes de apagar: AdGuard es
   el DNS de la casa.
3. Instalar **Ubuntu Server 24.04 LTS** solo en el NVMe, con LVM, OpenSSH, sin
   snaps, mismo usuario (UID 1000). **No seleccionar** ningún disco de media en
   el instalador.
4. Misma IP que antes (reserva por MAC en el router).
5. HLI 2: `git clone https://github.com/zamoxv/homelab-installer-2.git hli2`,
   host base, `datadisk` (SSD → `/srv/media` formateado; HDD USB 2 TB →
   `/srv/media2`), `dokploy` (cuenta de admin y token al terminar).
6. Copiar la media del HDD viejo al SSD con `rsync` (progreso, reanudable,
   verificación al final).
7. Importar del backup del v1 **solo AdGuard y las claves SSH**. Jellyfin y
   qBittorrent se instalan limpios (las rutas cambian de `/srv/media2` a
   `/srv/media`; se acepta perder los estados de visto de Jellyfin).
8. Desplegar el resto de servicios; bibliotecas de Jellyfin en `/srv/media`.
9. Quitar el DNS secundario del router cuando AdGuard responda.

## Orden acordado (2026-10-02)

1. ~~Repositorio remoto en GitHub~~ (hecho).
2. Migración del M70q (sección anterior).
3. JASJIC: de la Raspberry Pi al M70q, en su propio proyecto de Dokploy.
4. v2.4 — Cloudflare Tunnel.

## JASJIC: proyecto separado en Dokploy

Objetivo: migrar JASJIC (hoy en una Raspberry Pi) al M70q como contenedor,
separado de los servicios del hogar.

- Dokploy organiza todo en **proyecto → entornos → servicios**. Cada proyecto
  nace con un entorno `production` que no se puede renombrar ni borrar: el
  `production` de `homelab` es ese entorno por defecto, no "mis proyectos".
- La separación correcta es un **proyecto propio** (`jasjic`), no un entorno
  dentro de `homelab`. Opcional: un entorno `staging` dentro de `jasjic` para
  probar cambios antes de publicarlos.
- Los proyectos separan configuración, variables y despliegues, pero
  comparten CPU, RAM y disco del M70q. Para aislamiento de red, evaluar los
  "isolated deployments" de Dokploy según si JASJIC se expone a Internet.

Por definir antes de diseñar el módulo:
- [ ] Stack de JASJIC (lenguaje, base de datos, servicios auxiliares) y cómo
      corre hoy en la Raspberry Pi.
- [ ] Datos a migrar (base de datos, archivos subidos) y su tamaño.
- [ ] Si se expone a Internet (depende de v2.4) o queda solo en la LAN.
- [ ] Arquitectura: la Raspberry Pi es ARM y el M70q x86_64 — las imágenes o
      dependencias compiladas para ARM no sirven tal cual.
- [ ] Respaldo: dumps de su base de datos (capa Dokploy) y archivos (capa HLI;
      se registra como servicio local en `/etc/hli2.d/services`, ver v2.5).

## Pendiente: uso diario

- [ ] **Jellyfin importado del v1 no decodificaba HEVC 8 bits por hardware.**
      En el M70q (UHD 730, 2026-10-06) el `encoding.xml` del v1 traía QSV
      pero solo "HEVC 10bit" marcado: el log mostraba
      `hevc (native) -> h264 (h264_qsv)` y la CPU iba al 80–100 %. Marcando
      HEVC, MPEG2, VP9, AV1 y HEVC RExt (VP8 no: Gen12 no lo decodifica) más
      "Throttle Transcodes", bajó a ~10–20 % (también con HDR). Evaluar que
      el importador o el módulo `jellyfin` avisen (o ajusten) los códecs de
      decodificación según la GPU detectada.

- [ ] **Montar un disco de media con los contenedores ya corriendo los deja
      ciegos.** Docker fija los bind mounts al arrancar el contenedor: si
      después se monta un disco sobre `/srv/media` (o `/srv/mediaN`),
      Jellyfin y qBittorrent siguen viendo la carpeta vacía del disco del
      sistema que quedó debajo, y qBittorrent descarga ahí (oculto para Samba).
      Pasó en la migración del M70q (2026-10-06); se resolvió con
      `docker restart qbittorrent jellyfin`. `datadisk` (y `storage`) deben,
      tras montar, reiniciar los contenedores que usan rutas de media (y
      Jellyfin/qBittorrent deberían avisar si se despliegan con una raíz de
      media que no es punto de montaje mientras hay un disco de datos
      configurado en `fstab`).
- [ ] **Herramienta "Cambiar usuario/contraseña de AdGuard"**: AdGuard no permite
      cambiarla desde su panel (solo editando `AdGuardHome.yaml`). Reusar la
      generación de hash de la instalación (htpasswd en contenedor, contraseña
      por stdin) y reemplazar el usuario con AdGuard detenido, reiniciándolo
      al final (también si algo falla).

- [ ] **Cancelar o fallar una pregunta no debe ser silencioso.** Validado en el
      M70q: cuando dialog no pudo dibujar la pregunta del dominio de
      Vaultwarden, el módulo lo tomó como "Cancelar" y terminó sin aviso (solo
      figuró en el resumen final). Cada `input_box`/`confirm` que corte el
      módulo debe mostrar por qué ("se canceló la pregunta X o no se pudo
      mostrar").
- [ ] **El log de errores debe señalar el paso que falló**, no la línea donde
      terminó el módulo: registrar la pila de funciones (`FUNCNAME`,
      `BASH_LINENO`) en la trampa ERR o en cada `return 1` relevante.
- [ ] **Tests: punto ciego de `set -e`.** El harness corre cada test en un
      contexto (`if`/`||`) donde bash ignora `set -e` incluso si un subshell lo
      vuelve a activar. Los 24 usos de `( set -euo pipefail; … )` en
      `tests/` no detectan un aborto por `set -e` que sí ocurriría en el
      servidor. Pasarlos a un proceso aparte (`bash -c`) o hacer que el harness
      ejecute cada test en su propio proceso. Los tests que corren módulos
      completos (`bash modules/x.sh`) no están afectados.

- [ ] **Módulo "copiar media"** (el v1 tenía `media-transfer`): copiar de un
      disco a otro del pool con `rsync` (progreso, reanudable, verificación al
      final), sin pasos manuales.

- [ ] **Paquete `.deb`**: instalar el HLI 2 en `/opt/hli2` con el comando
      `hli2` disponible desde cualquier carpeta; actualizar instalando una
      versión nueva del paquete.
- [ ] **Lanzador en el Fedora** (`.desktop` con ícono): abre una terminal con
      `ssh -t <servidor> hli2`. Requiere acceso SSH por clave.
- [x] **Repositorio remoto en GitHub** para el HLI 2 (hoy los commits viven solo
      en el Fedora y se copian con `git bundle`).

- [ ] **Webhook de autodeploy para apps propias en Dokploy** (caso JASJIC: hoy
      los deploys son manuales porque GitHub no llega al panel, que es solo
      LAN/Tailscale). Exponer SOLO la ruta del webhook por el túnel, con un
      nombre dedicado y en este orden: `deploy.<dominio>` ruta `^/api/deploy/`
      → HTTP `dokploy:3000`; `deploy.<dominio>` (resto) → `HTTP_STATUS 404`.
      El panel nunca queda expuesto; la URL del webhook lleva un token secreto.
      Opcional: regla WAF de Cloudflare que solo acepte `POST` (y, si se
      quiere, solo las IPs `hooks` publicadas en `https://api.github.com/meta`).
      Verificar: `https://deploy.<dominio>/` da 404 desde fuera; "Recent
      Deliveries" del webhook en GitHub responde 200 y el push despliega. Si el
      túnel no resuelve `dokploy`, usar el nombre real del servicio en
      `dokploy-network`. Alternativa sin exponer nada: GitHub Actions + Tailscale
      (más compleja).
