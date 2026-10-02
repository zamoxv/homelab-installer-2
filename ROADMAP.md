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

## Backups: dos capas

| | HLI 2 (capa local) | Dokploy (capa externa) |
|---|---|---|
| Qué | Todo `/srv/appdata`, config Samba, config HLI, llaves SSH | Dumps de bases de datos + backup propio de Dokploy |
| Dónde | Tar local (`$BACKUP_ROOT`) | S3-compatible fuera de casa (Cloudflare R2 / Backblaze B2) |
| Para qué | Migrar o restaurar el servidor completo | Sobrevivir a la pérdida del disco o de la casa |

**Regla de consistencia**: el HLI 2 nunca copia en caliente la carpeta de una base de datos.
Postgres/MySQL se respaldan con dumps de Dokploy; SQLite (Vaultwarden, Jellyfin) se respalda
deteniendo el contenedor o con `sqlite3 .backup`.

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
      lo genera el módulo `samba` de v2.0). Disponible como módulo standalone
      (`modules/import-v1.sh`) y como paso opcional dentro de cada módulo de servicio. Solo
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
- Consumo de RAM de OpenCloud y comportamiento real de sus clientes de
  escritorio/móvil contra un dominio sin TLS válido todavía.
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

### v2.4 — Exposición externa

Requiere un dominio propio administrado en Cloudflare (DNS en Cloudflare).

- [ ] `cloudflared` apuntando a Traefik. Públicos: Vaultwarden, OpenCloud, sitios web.
      Solo LAN: AdGuard, qBittorrent, Home Assistant, panel de Dokploy.

### v2.5 — Backups

- [ ] Capa local sobre `/srv/appdata` con la regla de consistencia.
- [ ] Destino S3 externo configurado en Dokploy.
- [ ] Restore único guiado por el registro de servicios.

### v2.6 — Agente IA siempre activo (opcional)

- [ ] **Hermes Agent** (Nous Research) como contenedor, con **OpenRouter** como proveedor de
      modelos. Aislado: sin socket de Docker, sin montar `/srv`, sin red del host.
- [ ] **Telegram** como canal (modo polling: sin puertos entrantes), restringido al ID del usuario.
- [ ] Optimización de tokens: modelos auxiliares baratos en Hermes + `openrouter/auto` con nivel
      de costo `low`/`medium`. Límite de crédito en OpenRouter desde el primer día.
- [ ] LiteLLM como proxy de ruteo y presupuesto por agente, solo si hay varios agentes.
- [ ] **Open WebUI** (opcional, última tarea): interfaz tipo ChatGPT conectada al API server de
      Hermes, solo LAN.

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

Estado actual (2026-10-02): M70q en `192.168.1.10`, Ubuntu **26.04**
(incompatible con Dokploy), `/srv/media2` al **94,7 %** de 888 GB.

1. Backup completo con el HLI v1 (`/srv/backups/backup-<fecha>.tar.gz`) y
   copiarlo fuera del servidor.
2. Reinstalar con **Ubuntu Server 24.04 LTS** (obligatorio, no preferencia).
   Los discos de media no se formatean.
3. Instalar HLI 2: host base, `datadisk` con la opción "usar" para el disco de
   media (mantener `/srv/media2`, que es la ruta que tienen las bibliotecas de
   Jellyfin y los torrents), `dokploy` (crear la cuenta de admin y el token al
   terminar).
4. Desplegar los servicios, detenerlos, importar con `import-v1` desde el menú
   (no ejecutando el módulo suelto) y volver a desplegarlos. Con v2.3.1 esto
   último lo hará el propio importador.
5. Durante el corte, DNS secundario en el router (AdGuard es el DNS de la casa).
6. Planificar espacio: `/srv/media2` está casi lleno; evaluar un segundo disco
   para el pool (`/srv/media3`) o limpieza antes de migrar.

## Pendiente: uso diario

- [ ] **Paquete `.deb`**: instalar el HLI 2 en `/opt/hli2` con el comando
      `hli2` disponible desde cualquier carpeta; actualizar instalando una
      versión nueva del paquete.
- [ ] **Lanzador en el Fedora** (`.desktop` con ícono): abre una terminal con
      `ssh -t <servidor> hli2`. Requiere acceso SSH por clave.
- [ ] **Repositorio remoto en GitHub** para el HLI 2 (hoy los commits viven solo
      en el Fedora y se copian con `git bundle`).
