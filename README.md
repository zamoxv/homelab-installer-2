# HLI 2 — HomeLab Installer 2

Herramienta del host para un servidor doméstico donde el sistema operativo se
mantiene mínimo y los servicios corren en contenedores administrados con
[Dokploy](https://dokploy.com). HLI 2 configura, monitorea y respalda el host;
Dokploy opera los servicios. Ver [`ROADMAP.md`](./ROADMAP.md) para la visión
completa y el estado de cada fase.

**Proyecto independiente de [HLI v1](../homelab-installer):** no lo modifica
ni depende de él. De v1 se toman ideas como referencia de lectura; nunca se
importa código.

## Estado actual (v2.0)

Esqueleto del instalador y módulos base del host:

- `bootstrap.sh`, biblioteca (`lib/`) y menú (`ui/menu.sh`) con sistema de
  plugins: agregar `modules/x.sh` con la metadata `# HLI-*` lo hace aparecer
  solo en el menú.
- Registro declarativo de servicios (`services/*.conf`): fuente única de
  puertos, rutas de datos y tipo de backup para el dashboard y el healthcheck.
- Módulos de host: `base`, `power`, `wol`, `storage` (grupo `media`, pool de
  media, expansión de LVM), `datadisk` (sumar un disco al pool), `samba`
  (un recurso por disco de media).

Docker, Dokploy y los servicios en contenedor (Jellyfin, qBittorrent,
AdGuard, Vaultwarden, Home Assistant, OpenCloud, Dokploy) llegan en las fases
siguientes del roadmap; hasta entonces el dashboard los muestra como "no
instalado".

## Requisitos

- Ubuntu Server (u otra distribución basada en Debian/systemd).
- Usuario con acceso `sudo`.
- Conexión a internet (instala paquetes con `apt`).

## Cómo ejecutar

```bash
git clone <este repositorio>
cd hli2
bash bootstrap.sh
```

El instalador pide la contraseña de `sudo` una sola vez al inicio y pregunta
por consola (dialog) cualquier valor que necesite (usuario, interfaz de red,
disco, punto de montaje, etc.); nunca asume valores en silencio.

## Estructura

```
bootstrap.sh          Punto de entrada
config/default.conf   Configuración por defecto (usuario, rutas, grupo media)
lib/core.sh           Logging, estado, envoltorios de dialog, plugin system
lib/hw.sh             Detección de hardware y red
lib/storage.sh        Discos, LVM y raíces de media
lib/services.sh       Registro declarativo de servicios
ui/menu.sh            Menú principal y dashboard
modules/*.sh          Módulos de host (auto-descubiertos)
services/*.conf       Un archivo por servicio (nativo o en contenedor)
```

Logs por módulo en `/var/log/hli2/`; estado persistente en
`/var/lib/hli2/state`.
