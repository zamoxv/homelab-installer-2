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

### v2.5 — Backups (restic: local + R2)

Requisitos: el disco de media montado **aparte** del disco del sistema, un
bucket de R2 con su token (Cloudflare → R2 → Create bucket; Manage R2 API
Tokens → permiso *Object Read & Write*, restringido a ese bucket) y
Vaultwarden funcionando. Los valores de abajo son genéricos.

| # | Prueba | Resultado esperado |
|---|---|---|
| 48 | `backup-setup`, aceptar R2 y cargar endpoint (`https://<ACCOUNT_ID>.r2.cloudflarestorage.com`), bucket, Access Key ID y Secret | Instala restic (`restic version` → 0.16.x en noble); muestra la contraseña **una vez** y no avanza hasta confirmar "guardada en Vaultwarden y en papel" (con "No" la muestra de nuevo) |
| 49 | `sudo ls -l /etc/hli2/ && sudo ls -ld /srv/media/.hli2-backups` | `restic-password` y `restic.env` `-rw------- root`; el repositorio local `drwx------ root` |
| 50 | `systemctl list-timers hli2-backup.timer`; `systemctl cat hli2-backup.service` | Próxima ejecución a las 04:00; `Type=oneshot`; `ExecStart=/usr/local/lib/hli2/bin/hli2-backup run` y `ExecStopPost=... recover` (nunca una ruta de `/home`) |
| 51 | Re-ejecutar `backup-setup` | No muestra otra contraseña ni reinicializa repositorios; ofrece reconfigurar R2 |
| 52 | Herramientas → "Hacer backup ahora" | Se ve la salida de restic; Vaultwarden, Jellyfin, Home Assistant y AdGuard se detienen unos segundos y vuelven (`docker ps`); resultado "correcto" |
| 53 | `sudo RESTIC_REPOSITORY=/srv/media/.hli2-backups RESTIC_PASSWORD_FILE=/etc/hli2/restic-password restic snapshots` | Dos fotos por corrida: tag `full` y tag `cloud`; la `cloud` no contiene `opencloud/data` (`restic ls <id> \| grep -c opencloud/data` → 0; en la `full` → mayor que 0) |
| 54 | Lo mismo contra R2 (cargar `RESTIC_REPOSITORY` y las claves de `/etc/hli2/restic.env` en un shell root) | Solo fotos con tag `cloud`, mismos ids que en local; ningún archivo de `jellyfin/cache` en ninguna |
| 55 | Dashboard | Bloque "Backups" con fecha, "Copia local: correcto" y "Copia externa: correcto"; `cat /var/lib/hli2-root/backup-status` legible sin sudo y sin secretos |
| 56 | Dejar correr el timer de las 04:00 (o `sudo systemctl start hli2-backup.service`) | Termina con éxito; `journalctl -u hli2-backup` y `sudo less /var/log/hli2/backup.log` sin errores |
| 57 | Cortar la red (o poner una clave de R2 errónea en `restic.env`) y repetir 52 | Los servicios igual quedan arriba; el estado marca `copia externa: ERROR` y `result=error`; el servicio systemd queda `failed` |
| 58 | `sudo kill -TERM $(pgrep -f 'hli2-backup run')` apenas el log muestre "Deteniendo" (`sudo tail -f /var/log/hli2/backup.log`) | Los contenedores detenidos vuelven a iniciar solos (`docker ps`) |
| 59 | Con el disco de media **desmontado** (`sudo umount /srv/media`), `sudo /ruta/hli2/bin/hli2-backup run` | Se niega ("está en el mismo disco que el sistema"); no detiene ningún contenedor ni escribe en el disco del sistema |
| 60 | Tras varios días: `restic snapshots` en ambos repositorios | Retención aplicada (7 diarios, 4 semanales, 6 mensuales por tag); semanalmente aparece `restic check` en el log |
| 61 | `sudo ls -ld /usr/local/lib/hli2 /usr/local/lib/hli2/lib/backup.sh /var/lib/hli2-root; cat /var/lib/hli2-root/backup-status` | Todo `root root`, directorios `drwxr-xr-x`, archivos sin escritura para otros; el estado es legible sin sudo y dice `result=ok` |
| 62 | Editar algo en el checkout (p. ej. un comentario de `lib/backup.sh`) y correr el timer sin refrescar | El servicio ejecuta la copia vieja (no la del checkout); "Hacer backup ahora" la refresca antes de correr |
| 63 | Primera corrida (repositorio vacío): ver `sudo less /var/log/hli2/backup.log` | "pasada previa con los servicios en marcha" ANTES de "Deteniendo"; la parada dura segundos |
| 64 | Con el repositorio ya hecho, `sudo systemctl kill -s KILL hli2-backup.service` en plena parada y luego reiniciar el equipo | Al arrancar, `hli2-backup-recover.service` levanta los contenedores que quedaron detenidos |
| 65 | `sudo chown -R $USER /srv/media` y re-ejecutar `storage` | `sudo ls -ld /srv/media/.hli2-backups` sigue `root` y `drwx------` |
| 66 | Samba: ver los recursos compartidos | Solo los de media; el repositorio de backups **no** aparece | Samba: ver los recursos compartidos | Solo los de media; el repositorio de backups **no** aparece |

Notas sobre el disco: si el repositorio queda bajo `MEDIA_ROOT`, **`MEDIA_ROOT`
tiene que ser un punto de montaje** (`mountpoint /srv/media`); si no, el backup
se niega a correr. Con el disco ausente al arrancar, `RequiresMountsFor=` impide
que el servicio arranque y eso **no** deja un estado de error: solo se nota por
el aviso de "más de 36 horas" del dashboard. Revisar `systemctl status
hli2-backup.timer` si aparece.

Nota: `/etc/hli2/restic.env` (claves de R2) **sí** se respalda, cifrado dentro de
los repositorios: hace falta para recuperarse de un desastre. La contraseña de
restic **no** se respalda (vive en Vaultwarden y en papel).

#### Restaurar (v2.5, parte 2)

Herramientas → "Restaurar un backup" (`modules/backup-restore.sh`). Requisitos:
al menos un backup hecho (pruebas 52 y 56). Preparación: en Vaultwarden, crear
un elemento de prueba **antes** del backup y otro **después**, para ver a qué
fecha vuelve.

| # | Prueba | Resultado esperado |
|---|---|---|
| 67 | Con el elemento A creado, "Hacer backup ahora"; crear el elemento B; "Restaurar un backup" → Copia local → la foto más nueva → Vaultwarden. Aceptar el resumen y **aceptar** el backup de seguridad | El resumen dice qué se reemplaza y la fecha de la foto; corre un backup de seguridad (sin retención); Vaultwarden se detiene unos segundos y vuelve (`docker ps`); resultado "correcto". Vaultwarden muestra A y **no** B. `sudo ls -d /srv/appdata/vaultwarden/data*` solo muestra `data` (con backup de seguridad no queda copia previa) |
| 68 | Repetir 67 pero **rechazando** el backup de seguridad | Resultado "correcto"; `sudo ls -d /srv/appdata/vaultwarden/data*` muestra también `data.hli2-before-restore-<fecha>` con lo anterior (el elemento B sigue ahí); el log lo avisa |
| 69 | Con el menú de fechas abierto, comprobar el orden y el formato | La más nueva primero, fecha y hora legibles (`2026-10-05 04:00`), con el id corto; solo fotos del repositorio elegido |
| 70 | Restaurar Vaultwarden a una fecha **anterior** (la 2.ª foto de la lista) | Vuelve al estado de esa fecha; ningún contenedor de otro servicio se detiene (`docker ps`, `sudo tail -f /var/log/hli2/backup.log`) |
| 71 | Restaurar Vaultwarden desde **R2** (origen: copia externa), foto más nueva | Mismo resultado que 67 (el log dice "Foto <id> (<fecha>)"); el origen en el resumen es "copia externa (R2)" |
| 72 | OpenCloud desde R2 | El resumen avisa que los archivos de OpenCloud **no están** en la copia externa; solo se restaura su configuración (`/srv/appdata/opencloud/config`); `data` no se toca y el resultado es "con avisos" con el motivo |
| 73 | OpenCloud desde la copia local | Restaura config **y** data; resultado "correcto" |
| 74 | `sudo hli2-backup restore --source local --snapshot 'x;id' --target all` y `--target ../x` (con `sudo /usr/local/lib/hli2/bin/hli2-backup`) | Se niega con código 2 y no toca nada (`docker ps`, carpetas) |
| 75 | Cortar la restauración a medias: `sudo kill -TERM $(pgrep -f 'hli2-backup restore')` mientras `sudo tail -f /var/log/hli2/backup.log` muestre "Restaurando" | Los contenedores detenidos vuelven a iniciar solos; `cat /var/lib/hli2-root/restore-status` dice `result=interrupted`; los datos siguen como estaban y no queda `*.hli2-restore-tmp` |
| 76 | Restaurar con un backup en curso (`sudo systemctl start hli2-backup.service` y, mientras corre, lanzar la restauración) | Espera el bloqueo (hasta 2 min) o lo rechaza con "Otro backup o restauración mantiene el bloqueo"; no se pisan |
| 77 | Restaurar **AdGuard** | Se detiene y vuelve; el DNS de la casa responde de nuevo (`dig @<IP> ejemplo.com`); panel en :3053 con la configuración de la foto |
| 78 | Restaurar **Samba** (smb.conf) | `systemctl is-active smbd` → `active`; el recurso compartido responde |
| 79 | `cat /var/lib/hli2-root/restore-status` | Legible sin sudo; fecha, `result`, origen, foto, destino, `message`; ningún secreto |
| 80 | **Simulacro en la X230 (recuperación ante un desastre)**: procedimiento de abajo, con "Todo" desde R2 | Los servicios que existen se restauran; el aviso final lista los módulos que faltan; tras ejecutarlos, cada servicio arranca con sus datos |

**Procedimiento de recuperación ante un desastre (también es la prueba 80)**

1. Instalar Ubuntu Server y el HLI 2 (`bootstrap.sh`); montar el disco de media
   con el módulo `datadisk`/`storage`. **Mismo nombre de equipo** que el
   original si es posible (la retención agrupa por equipo: con otro nombre, las
   fotos viejas de R2 no se podan nunca; se limpian a mano con `restic forget`).
2. Ejecutar `backup-setup`. En "Contraseña de los backups" elegir
   **"Recuperación ante un desastre"** e ingresar (dos veces) **la misma
   contraseña de restic** guardada en Vaultwarden o en papel. Configurar R2 con
   el **mismo bucket** (endpoint, bucket y claves). `backup-setup` NO
   inicializa nada que ya exista: comprueba el repositorio de R2 con
   `restic cat config`, y si la contraseña no lo abre, se niega (no inicializa
   encima). El repositorio local sí se crea nuevo (vacío).
3. Herramientas → "Restaurar un backup" → **copia externa (R2)** → la foto más
   nueva → **Todo**. Se restauran todos los servicios con datos, `smb.conf` y los
   secretos de los servicios de `/etc/hli2`. **No** se tocan `restic-password`
   (nunca viaja en los backups), `restic.env` (se acaba de configurar en el paso
   2) ni `dokploy.env` (describe la instancia de Dokploy anterior; en el equipo
   nuevo es otra). Los archivos de OpenCloud no están en R2 (solo en la copia
   local): si el disco original no se recuperó, esa parte se pierde por diseño.
4. Instalar Dokploy (módulo `dokploy`, y `dokploy-api` si lo pide) y luego los
   módulos que indique el aviso final ("Falta: ... ejecute sus módulos: ...").
   Cada módulo despliega el contenedor y encuentra sus datos y secretos ya en
   su lugar (reutiliza el secreto existente: no pide uno nuevo).
5. Comprobar el dashboard y hacer "Hacer backup ahora": la primera subida a R2
   desde el equipo nuevo vuelve a enviar todo (el repositorio local nuevo tiene
   otros parámetros de troceado, así que no se deduplica contra lo ya subido).

Qué NO restaura "Todo": el estado del propio HLI (`/var/lib/hli2`, los módulos
marcados como hechos) ni su configuración (`config/`): vuelven al reinstalar el
HLI. Tampoco `tailscale` ni Cloudflare Tunnel (sin datos en backups: se
reconfiguran con sus módulos).

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
