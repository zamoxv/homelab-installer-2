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
falta confirmar en un AdGuard real si un `AdGuardHome.yaml` "sembrado" a mano (solo
`http.address`/`dns.bind_hosts`) evita del todo el asistente de instalación o si igual pide crear
el usuario admin (esperable, no es un bug) — y correr la validación canaria una vez contra el
Dokploy real antes de desplegar Jellyfin/qBittorrent/AdGuard de verdad.

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

- [ ] Vaultwarden (`SIGNUPS_ALLOWED=false`, `ADMIN_TOKEN` como secreto).
- [ ] Home Assistant (Container, red del host).
- [ ] OpenCloud (validar clientes desktop/móvil y consumo de RAM).

### v2.4 — Exposición externa

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

## Riesgos a validar primero

- Dokploy sobre Ubuntu 26.04 (no soportado oficialmente).
- `network_mode: host` en compose administrado por Dokploy.
- Cloudflare Tunnel exige un dominio administrado en Cloudflare.

## Migración del M70q

1. Backup completo con el HLI v1 y copiarlo fuera del servidor.
2. Reinstalar Ubuntu (preferir 24.04 LTS). Los discos de media no se formatean.
3. Instalar HLI 2 e importar la config desde el tar del v1.
4. Durante el corte, DNS secundario en el router (AdGuard es el DNS de la casa).
