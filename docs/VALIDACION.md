# Validación de HLI 2 en un equipo de prueba

Guía para probar v2.0–v2.3 en hardware real **antes** de tocar el M70q
(que sirve el DNS y los servicios de la casa). Todo se prueba en una sola
instalación de Ubuntu Server 24.04 en la **X230**.

**Orden recomendado**: correr primero el módulo `power` (pruebas 31–32), para
que cerrar la tapa no suspenda el equipo en medio de otra prueba.

**Memoria**: revisar `free -h`. Con 4 GB, Dokploy más todos los servicios van
justos: si OpenCloud o Home Assistant fallan, revisar primero `dmesg | grep -i oom`
(falta de memoria, no un error del HLI). Con 8 GB o más no debería haber problema.

Cada prueba tiene un **resultado esperado**. Anote lo que no coincida y
adjunte `/var/log/hli2/<módulo>.log`.

---

## 1. Preparar el equipo

1. Instalar **Ubuntu Server 24.04.x** (`live-server-amd64.iso`, de
   <https://releases.ubuntu.com/24.04/>; verificar el SHA256 contra `SHA256SUMS`).
   - Disco interno con **LVM** (opción por defecto): el instalador deja parte
     del VG sin asignar, y eso prueba la expansión automática.
   - Marcar **Instalar OpenSSH server**.
   - No instalar ningún snap de la lista final (en especial el de Docker: el
     HLI detectaría un Docker que no instaló).
2. Conectarlo **por cable** a la red de la casa (`10.20.30.x`). Eso prueba la
   protección de v2.1 contra el choque entre Docker Swarm (`10.0.0.0/8`) y la LAN.
3. **No** configurar el router para usar este equipo como DNS: así AdGuard de
   prueba no afecta a la casa.

### Discos USB para `datadisk`

Hacen falta **dos discos o pendrives USB** que se puedan borrar:

- **USB-A**: vacío (o con datos descartables).
- **USB-B**: con una partición y un archivo, para probar el aviso de
  particiones. Prepararlo en el equipo de prueba (verificar la letra con `lsblk`):

```bash
sudo parted /dev/sdX --script mklabel gpt mkpart datos ext4 1MiB 100%
sudo mkfs.ext4 -L datos /dev/sdX1
sudo mount /dev/sdX1 /mnt && echo prueba | sudo tee /mnt/archivo && sudo umount /mnt
```

Anotar qué informa cada uno: `lsblk -dno NAME,SIZE,SERIAL,WWN,MODEL`. Si un
USB no informa serie ni WWN, la huella de `datadisk` depende solo del tamaño
(limitación conocida, ver ROADMAP): es útil saberlo.

## 2. Copiar el HLI 2 al equipo

Desde el Fedora (el repo no tiene remoto todavía):

```bash
git -C ~/dev/hli2 bundle create /tmp/hli2.bundle --all
scp /tmp/hli2.bundle <usuario>@<ip-equipo>:
```

En el equipo:

```bash
git clone hli2.bundle hli2 && cd hli2 && bash bootstrap.sh
```

Para actualizar después de una corrección: repetir el `bundle`/`scp` y, en el
equipo, `git -C hli2 pull ~/hli2.bundle main`.

---

## 3. Pruebas

### v2.0 — Host base

| # | Prueba | Resultado esperado |
|---|---|---|
| 1 | Instalación completa (módulos por defecto) | Termina; si algo falla, lo lista al final con la ruta del log |
| 2 | `storage` con VG libre | Ofrece expandir; tras aceptar, `df -h /` muestra todo el disco. Re-ejecutar: no ofrece nada |
| 3 | En cualquier aviso de `storage`, presionar **ESC** | El módulo sigue; la instalación completa no se corta |
| 4 | `datadisk` con USB-A y USB-B conectados | Lista ambos; **nunca** el disco interno |
| 5 | `datadisk` → elegir **USB-B** (disco entero) | Avisa que tiene particiones y ofrece solo cancelar/formatear. Cancelar |
| 6 | `datadisk` → elegir **la partición de USB-B** → "usar" | Monta en `/srv/mediaN` sin borrar; `archivo` sigue ahí. Entrada en `/etc/fstab` por UUID con `nofail` |
| 7 | **Cambio de disco en caliente**: `datadisk` → elegir USB-A y, *antes de confirmar*, desconectarlo y conectar otro USB en el mismo puerto | Aborta con "ya no está disponible o cambió"; **no formatea** el otro disco |
| 8 | `datadisk` → USB-A → formatear | Tres confirmaciones; queda montado en el siguiente `/srv/mediaN` |
| 9 | Re-ejecutar 8 con el mismo disco | `/etc/fstab` no duplica la línea |
| 10 | `samba` | Un recurso por cada `/srv/media*` + backups; `testparm -s` sin errores; se ve desde el Fedora |
| 11 | Reiniciar sin los USB conectados | Arranca igual (`nofail`); `status` muestra Samba activo |

Para la prueba 7: si los dos USB son del mismo modelo y tamaño y no informan
serie, el cambio **no** se detectará (limitación conocida). En ese caso,
anotarlo y repetir con dos USB distintos.

### v2.1 — Dokploy

| # | Prueba | Resultado esperado |
|---|---|---|
| 12 | Módulo `dokploy` | Pregunta IP y versión; el resumen muestra un pool `172.20.0.0/16` (porque la LAN es `10.20.30.0/24`) |
| 13 | Tras instalar | `docker info` → Swarm activo; `docker network inspect ingress` fuera de `10.x`; panel en `http://<ip>:3000` |
| 14 | Crear la cuenta admin en el panel | Inmediatamente (el primero en entrar queda como admin) |
| 15 | Re-ejecutar `dokploy` | **Solo** ofrece actualizar o nada; nunca reinstala |
| 16 | `sudo systemctl stop docker.socket docker` y re-ejecutar | Aborta: "no se pudo determinar el estado". Después: `sudo systemctl start docker` |

### v2.2 — Servicios actuales

Generar el token en el panel de Dokploy: Configuración → Perfil → API/CLI.

| # | Prueba | Resultado esperado |
|---|---|---|
| 17 | Primer servicio (p. ej. `qbittorrent`) | Pide el token; `sudo ls -l /etc/hli2/` → `dokploy.env` con `-rw------- root` |
| 18 | Canary | Se ejecuta antes del primer servicio; tarda unos minutos; termina OK y borra el compose de prueba |
| 19 | `qbittorrent` | Contenedor activo; WebUI en `:8080`; descargas en `/srv/media*/downloads` con grupo `media` |
| 20 | `jellyfin` | Activo en `:8096` |
| 21 | Aceleración de Jellyfin | `ls /dev/dri` muestra `renderD128`; el contenedor lo ve (`docker exec jellyfin ls /dev/dri`); en Jellyfin → Panel → Reproducción, elegir **VA-API** con el dispositivo `/dev/dri/renderD128` (QSV en Linux solo funciona desde la 5.ª generación, Broadwell; en el M70q, de 12.ª generación, usar QSV) y reproducir algo que requiera transcodificar. Lo que valida al HLI es que `/dev/dri` y el grupo `render` lleguen al contenedor; si la transcodificación en sí falla, puede ser la generación del chip (Ivy Bridge, soporte limitado en Jellyfin) y no un error del HLI: anotarlo igual |
| 22 | `adguard` | Panel en `:3053`; desde el Fedora: `dig @<ip> ubuntu.com` responde (`sudo dnf install bind-utils` si falta `dig`); en el equipo `getent hosts ubuntu.com` sigue funcionando |
| 23 | Forzar fallo de AdGuard: antes de desplegar, `sudo nc -lu 0.0.0.0 53` en otra terminal | Revierte el DNS: `/etc/resolv.conf` vuelve a su estado anterior y el equipo sigue resolviendo |
| 24 | `import-v1` con un respaldo real del v1 | Importa a `/srv/appdata/*`; Jellyfin conserva bibliotecas; qBittorrent conserva torrents |

Para la prueba 24: generar el respaldo en el M70q con el módulo `backup` del
HLI v1 (solo crea un `.tar.gz`, no cambia nada más) y copiarlo al equipo de
prueba. Las rutas de media del respaldo (`/srv/media...`) tienen que existir
en el equipo de prueba para que las bibliotecas se vean.

### v2.3 — Servicios nuevos

| # | Prueba | Resultado esperado |
|---|---|---|
| 25 | `vaultwarden` | Pide dominio y la contraseña del panel (dos veces, en la terminal) |
| 26 | Verificar el token | `docker exec vaultwarden env \| grep ADMIN_TOKEN` → hash completo `$argon2id$...`, **sin comillas** y con todos los `$` |
| 27 | Entrar a `/admin` | Acepta la contraseña ingresada en 25 |
| 28 | `homeassistant` | Activo en `:8123` (red host); detecta dispositivos Xiaomi de la red en Integraciones |
| 29 | `opencloud` | Despliega; el login **no** funcionará sin dominio con TLS (esperado hasta v2.4). Anotar RAM: `docker stats --no-stream` |
| 30 | Re-ejecutar `opencloud` | No falla por `opencloud init` repetido |

### v2.4a — Cloudflare Tunnel y Tailscale

Requisitos: un dominio con su DNS en Cloudflare y un túnel **administrado
remotamente** creado en Cloudflare (Zero Trust → Networks → Tunnels → Create a
tunnel → Cloudflared). Los nombres de abajo son genéricos: reemplazar
`<dominio>` por el propio. Tener `vaultwarden`, `opencloud` y `homeassistant`
desplegados.

| # | Prueba | Resultado esperado |
|---|---|---|
| 33 | `cloudflared`, pegar el token (o el comando completo que muestra Cloudflare) | Acepta ambos; `sudo ls -l /etc/hli2/` → `cloudflared.env` con `-rw------- root` |
| 34 | Pegar un texto cualquiera como token | Rechaza con un aviso; no crea `cloudflared.env` |
| 35 | Cancelar el cuadro del token | Aviso "Se cancela el despliegue de Cloudflare Tunnel" |
| 36 | `docker ps --filter name=cloudflared`; en Cloudflare, el túnel | Contenedor activo; el túnel figura `Healthy` |
| 37 | `docker exec cloudflared env \| grep -c TUNNEL_TOKEN` y `sudo ss -ltn` | `1`; ningún puerto nuevo escuchando en el host |
| 38 | Crear las rutas en este orden: `vault.<dominio>` ruta `^/admin` → HTTP_STATUS 404; `vault.<dominio>` → HTTP `dokploy-traefik:80`; `cloud.<dominio>` → HTTP `opencloud:9200`; `casa.<dominio>` → HTTP `<IP LAN>:8123` | Con datos móviles: `https://vault.<dominio>` abre; `https://vault.<dominio>/admin` da 404; `https://cloud.<dominio>` abre; `https://casa.<dominio>` abre |
| 39 | Verificar que el conector llega a Traefik por nombre: `docker network inspect dokploy-network --format '{{range .Containers}}{{.Name}} {{end}}'` | Aparecen `cloudflared` y `dokploy-traefik` (si Traefik tiene otro nombre, anotarlo: hay que cambiar la URL de las rutas); la prueba 38 con `vault.<dominio>` abierto lo confirma |
| 40 | Un subdominio no listado (`otro.<dominio>`) | No responde / 404 de Cloudflare |
| 41 | Re-ejecutar `cloudflared` | Ofrece reemplazar el token; con "No" no vuelve a pedirlo y re-despliega |
| 42 | `tailscale` en el servidor | Muestra aviso, luego `tailscale up` imprime una URL de inicio de sesión **en la terminal**; al aprobarla muestra IP `100.x.y.z` y nombre MagicDNS |
| 43 | `apt-cache policy tailscale` y `cat /etc/apt/sources.list.d/tailscale.list` | Origen `pkgs.tailscale.com/stable/ubuntu noble`; `systemctl is-active tailscaled` → `active` |
| 44 | Instalar la app de Tailscale en el teléfono (misma cuenta), apagar el Wi-Fi | `http://<IP Tailscale>:3000` (Dokploy) y `:8096` (Jellyfin) abren |
| 45 | Re-ejecutar `tailscale` | Solo muestra estado e IP; no reinstala ni vuelve a pedir inicio de sesión |
| 46 | Paso opcional de AdGuard: aceptar | Confirma que AdGuard escucha en `0.0.0.0:53` y explica los pasos del panel de Tailscale (DNS → Nameservers → IP de Tailscale → Override DNS servers) |
| 47 | Tras configurar 46, en el teléfono con Tailscale | `ping` a un dominio de lista de bloqueo no resuelve; el resto de Internet funciona |

### Energía (correr primero)

| # | Prueba | Resultado esperado |
|---|---|---|
| 31 | Módulo `power`, luego cerrar la tapa | El equipo **no** suspende: sigue respondiendo por SSH y `ping` |
| 32 | Reiniciar y repetir 31 | Igual: la configuración persiste |

### Respuestas de la API de Dokploy

Es lo más importante de confirmar: el cliente de la API se escribió sin
conocer la forma exacta de las respuestas. Si algún despliegue falla,
guardar la salida del módulo y `/var/log/hli2/<módulo>.log`.

---

## 4. Al terminar

Enviar la lista de pruebas con su resultado (OK / falló + qué pasó) y los
logs de los módulos que fallaron. Con eso se corrige antes de v2.4.
