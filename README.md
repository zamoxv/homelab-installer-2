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
/etc/hli2.d/services  Servicios propios del usuario (registro local, ver más abajo)
```

Logs por módulo en `/var/log/hli2/`; estado persistente en
`/var/lib/hli2/state`.

## Servicios propios (registro local)

Si usted despliega a mano una aplicación (por ejemplo, desde Dokploy) y quiere
que entre en los backups, en la restauración y en el dashboard, puede
registrarla como **servicio local**, sin tocar este repositorio. El archivo vive
en `/etc/hli2.d/services/` (directorio de root, **fuera** de `/etc/hli2`, que
es de acceso exclusivo de root y guarda los secretos) y usa el mismo formato que
`services/*.conf`. No debe contener secretos.

Ejemplo (`miapp.conf`; el nombre del archivo es el identificador del servicio):

```bash
SERVICE_NAME="Mi App"
SERVICE_KIND="container"
SERVICE_CONTAINER="miapp-db-1"
SERVICE_PORT=""
SERVICE_URL_SCHEME=""
SERVICE_DATA=("$APPDATA_ROOT/miapp/db")
# "files": copia sin detener nada. "sqlite": el backup detiene el contenedor
# unos segundos durante la foto local (para bases embebidas como SQLite o
# CouchDB). "none": no se respalda.
SERVICE_BACKUP_KIND="sqlite"
```

Instalación (el directorio y el archivo deben ser de root y no escribibles por
otros; si no, se ignoran):

```bash
sudo install -d -m 0755 /etc/hli2.d /etc/hli2.d/services
sudo install -m 0644 -o root -g root miapp.conf /etc/hli2.d/services/miapp.conf
```

Después ejecute **"Hacer backup ahora"** (`backup-now`) para comprobar que el
servicio entra en la copia; si el archivo se rechaza, el motivo queda en
`/var/log/hli2/backup.log` (línea `servicio local '<id>' ignorado`).

Reglas:

- **Nombre del archivo**: `^[a-z0-9][a-z0-9-]*\.conf$`.
- **Seguridad**: estos archivos se cargan con `source`, de modo que solo se
  aceptan si son archivos regulares (no enlaces simbólicos) de root, sin permiso
  de escritura para grupo ni otros, dentro de un directorio de root (y con
  `/etc/hli2.d` también de root) no escribible por otros.
- **Campos**: `SERVICE_KIND` debe ser `container`; `SERVICE_CONTAINER` debe ser
  un nombre de contenedor válido de Docker; `SERVICE_BACKUP_KIND` puede ser
  `files`, `sqlite` o `none`; cada ruta de `SERVICE_DATA` debe ser absoluta, sin
  `..`, bajo `$APPDATA_ROOT` (nunca `$APPDATA_ROOT` mismo ni rutas como `/etc`);
  `SERVICE_BACKUP_EXCLUDE` y `SERVICE_BACKUP_LOCAL_ONLY` solo pueden listar
  rutas de su propio `SERVICE_DATA`.
- **Formato permitido** (filtro previo a cargar el archivo): solo líneas en
  blanco, comentarios (`#`) y asignaciones de una sola línea `SERVICE_X="texto"`
  o `SERVICE_X=("texto" "texto")`. Se rechaza todo lo que ejecute o redirija
  (`$(`, comillas invertidas, `;`, `&`, `|`, `<`, `>`, barra invertida) y
  cualquier `$` que no sea `$APPDATA_ROOT` o `${APPDATA_ROOT}`. Los arrays no
  pueden partirse en varias líneas.
- **Rutas**: cada ruta debe estar en forma canónica (sin `.`, `..`, `//` ni
  barra final) y no puede coincidir ni anidarse (en ningún sentido) con los datos
  de un servicio incluido ni con `/etc/hli2`, el estado del HLI o el
  repositorio de backups.
- **Colisiones**: el identificador no puede coincidir con el de un servicio
  incluido en el HLI (por ejemplo `jellyfin`). Gana siempre el incluido; el
  archivo local se ignora y el backup lo avisa en su log.
- **Backups**: los servicios locales entran en la **misma** corrida nocturna,
  las mismas fotos y los mismos repositorios (local y R2); no hay un backup
  aparte. `/etc/hli2.d` también se respalda, para que el registro sobreviva a un
  desastre.
- **Restauración**: aparecen como destinos en "Restaurar un backup". Al restaurar
  **"Todo"** (por ejemplo, en un equipo nuevo) se devuelve primero
  `/etc/hli2.d/services` y después los datos de cada servicio, de modo que los
  servicios locales se reconocen aunque el equipo no tuviera nada. Solo se
  restaura `/etc/hli2.d/services` (no el resto de `/etc/hli2.d`) y con
  semántica de equipo nuevo: se instalan únicamente los `.conf` que no existen
  (los existentes no se sobrescriben y se informan), pasando antes por el mismo
  filtro de formato; los enlaces simbólicos y los nombres inválidos se omiten.
  Los restos de restauraciones (`*.hli2-restore-tmp`, `*.hli2-before-restore-*`)
  dentro de `/etc/hli2.d` no entran en los backups. Restaurar un
  solo servicio local requiere que su archivo ya esté registrado. El
  contenedor no se vuelve a crear: se restauran los datos y usted lo despliega
  de nuevo (por ejemplo, en Dokploy), con la misma ruta de datos.
- **Dashboard**: se muestran junto a los demás con la marca "(local)".

