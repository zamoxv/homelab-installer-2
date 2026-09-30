# Validación de HLI 2 en una máquina virtual

Guía para probar v2.0–v2.3 en una VM con Ubuntu Server 24.04 antes de tocar
el M70q. Todo lo que el HLI 2 haga queda dentro de la VM.

Cada prueba tiene un **resultado esperado**. Anote lo que no coincida y los
logs de `/var/log/hli2/` de ese módulo.

---

## 0. Preparar el Fedora (una sola vez)

```bash
sudo dnf group install --with-optional virtualization
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt "$USER"     # cerrar sesión y volver a entrar
```

**Espacio en disco**: la VM usa discos *thin* (`qcow2`), que ocupan solo lo
escrito (~12–15 GB tras instalar todo). Con ~32 GB libres en `/home` alcanza,
pero conviene vigilar `df -h ~`.

## 1. Red aislada en 10.99.0.0/24

Se usa una red en `10.x` a propósito: así se prueba la protección de v2.1
contra el choque entre el pool de Docker Swarm (`10.0.0.0/8`) y la LAN.

```bash
cat > /tmp/hli2net.xml <<'EOF'
<network>
  <name>hli2net</name>
  <forward mode='nat'/>
  <bridge name='virbr-hli2'/>
  <ip address='10.99.0.1' netmask='255.255.255.0'>
    <dhcp><range start='10.99.0.100' end='10.99.0.200'/></dhcp>
  </ip>
</network>
EOF
virsh -c qemu:///system net-define /tmp/hli2net.xml
virsh -c qemu:///system net-start hli2net
virsh -c qemu:///system net-autostart hli2net
```

## 2. Crear la VM

Descargue la última **Ubuntu Server 24.04.x** (`live-server-amd64.iso`) desde
<https://releases.ubuntu.com/24.04/> y verifique el SHA256 contra
`SHA256SUMS` del mismo sitio.

```bash
virt-install --connect qemu:///system \
  --name hli2-test --memory 6144 --vcpus 4 --cpu host-passthrough \
  --os-variant ubuntu24.04 \
  --disk size=40,format=qcow2,serial=HLI2SYS \
  --disk size=8,format=qcow2,serial=HLI2DATA1 \
  --disk size=8,format=qcow2,serial=HLI2DATA2 \
  --network network=hli2net \
  --cdrom ~/Descargas/ubuntu-24.04.*-live-server-amd64.iso \
  --graphics spice
```

Los `serial=` son necesarios: los discos virtuales no informan número de
serie por sí solos, y la huella de `datadisk` quedaría reducida al tamaño.

En el instalador de Ubuntu:
- Disco: **solo `vda`** (40 GB), con **LVM** (opción por defecto). El
  instalador deja parte del VG sin asignar: sirve para probar la expansión.
- Marcar **Instalar OpenSSH server**.
- No instalar snaps adicionales.

Al terminar, **snapshot** para poder volver atrás en cada prueba:

```bash
virsh -c qemu:///system snapshot-create-as hli2-test limpio
# volver: virsh -c qemu:///system snapshot-revert hli2-test limpio
```

## 3. Preparar los discos de prueba (dentro de la VM)

`vdb` queda vacío. `vdc` se prepara **con una partición y datos**, para probar
el aviso de particiones:

```bash
sudo parted /dev/vdc --script mklabel gpt mkpart datos ext4 1MiB 100%
sudo mkfs.ext4 -L datos /dev/vdc1
sudo mount /dev/vdc1 /mnt && echo prueba | sudo tee /mnt/archivo && sudo umount /mnt
```

## 4. Copiar el HLI 2 a la VM

Desde el Fedora (el repo no tiene remoto todavía):

```bash
git -C ~/dev/hli2 bundle create /tmp/hli2.bundle --all
scp /tmp/hli2.bundle <usuario>@<ip-vm>:
```

En la VM:

```bash
git clone hli2.bundle hli2 && cd hli2 && bash bootstrap.sh
```

La IP de la VM aparece con `ip -4 addr` dentro de ella (rango `10.99.0.100–200`).

---

## 5. Pruebas

### v2.0 — Host base

| # | Prueba | Resultado esperado |
|---|---|---|
| 1 | Instalación completa (módulos por defecto) | Termina; si algo falla, lo lista al final con la ruta del log |
| 2 | `storage` con VG libre | Ofrece expandir; tras aceptar, `df -h /` muestra ~40 GB. Re-ejecutar: no ofrece nada |
| 3 | En cualquier aviso de `storage`, presionar **ESC** | El módulo sigue; la instalación completa no se corta |
| 4 | `datadisk` | Lista `vdb` y `vdc`; **nunca** `vda` |
| 5 | `datadisk` → elegir **`vdc`** (disco entero) | Avisa que tiene particiones (`vdc1 ext4`) y ofrece solo cancelar/formatear. Cancelar |
| 6 | `datadisk` → elegir **`vdc1`** → "usar" | Monta en `/srv/mediaN` sin borrar; `archivo` sigue ahí. Entrada en `/etc/fstab` por UUID con `nofail` |
| 7 | `datadisk` → `vdb` → formatear | Tres confirmaciones; queda montado en el siguiente `/srv/mediaN` |
| 8 | Re-ejecutar 7 con el mismo disco | `/etc/fstab` no duplica la línea |
| 9 | **Hacerla antes que la 7**, con `vdb` sin montar. **Cambio de disco en caliente** (ver comandos abajo): `datadisk` → elegir `vdb` y, *antes de confirmar*, cambiar el disco desde el Fedora | Aborta con "ya no está disponible o cambió"; **no formatea** el disco nuevo |
| 10 | `samba` | Un recurso por cada `/srv/media*` + backups; `testparm -s` sin errores |
| 11 | Reiniciar la VM | Monta los discos solo; `status` muestra Samba activo |

Comandos para la prueba 9, desde el Fedora, con el diálogo de `datadisk`
abierto en la VM:

```bash
qemu-img create -f qcow2 /tmp/otro.qcow2 8G
virsh -c qemu:///system detach-disk hli2-test vdb --live
virsh -c qemu:///system attach-disk hli2-test /tmp/otro.qcow2 vdb \
  --live --subdriver qcow2 --serial OTRO
```

Después, confirmar en la VM. Al terminar: `virsh ... detach-disk hli2-test vdb --live`
y volver al snapshot si hace falta.

### v2.1 — Dokploy

| # | Prueba | Resultado esperado |
|---|---|---|
| 12 | Módulo `dokploy` | Pregunta IP y versión; el resumen muestra un pool `172.20.0.0/16` (porque la LAN es `10.99.0.0/24`) |
| 13 | Tras instalar | `docker info` → Swarm activo; `docker network inspect ingress` fuera de `10.99.x`; panel en `http://<ip-vm>:3000` |
| 14 | Crear la cuenta admin en el panel | Inmediatamente (el primero en entrar queda como admin) |
| 15 | Re-ejecutar `dokploy` | **Solo** ofrece actualizar o nada; nunca reinstala |
| 16 | `sudo systemctl stop docker.socket docker` y re-ejecutar (el socket volvería a levantar Docker) | Aborta: "no se pudo determinar el estado". Después: `sudo systemctl start docker` |

### v2.2 — Servicios actuales

Generar el token en el panel: Configuración → Perfil → API/CLI.

| # | Prueba | Resultado esperado |
|---|---|---|
| 17 | Primer servicio (p. ej. `qbittorrent`) | Pide el token; `sudo ls -l /etc/hli2/` → `dokploy.env` con `-rw------- root` |
| 18 | Canary | Se ejecuta antes del primer servicio; tarda unos minutos; termina OK y borra el compose de prueba |
| 19 | `qbittorrent` | Contenedor activo; WebUI en `:8080`; archivos en `/srv/media*/downloads` con grupo `media` |
| 20 | `jellyfin` | Activo en `:8096`; la VM no tiene `/dev/dri`: debe desplegar **sin** aceleración y sin error |
| 21 | `adguard` | Panel en `:3053`; desde el Fedora: `dig @<ip-vm> ubuntu.com` responde (`sudo dnf install bind-utils` si falta `dig`); en la VM `getent hosts ubuntu.com` sigue funcionando |
| 22 | Forzar fallo de AdGuard (p. ej. ocupar el 53 con `sudo nc -lu 53` antes de desplegar) | Revierte el DNS: `/etc/resolv.conf` vuelve a su estado anterior y el host sigue resolviendo |
| 23 | `import-v1` con un tar del HLI v1 (opcional; ver abajo) | Importa a `/srv/appdata/*`; Jellyfin conserva bibliotecas; qBittorrent conserva torrents |

Para la prueba 23 hace falta un respaldo real del v1: generarlo en el M70q
con el módulo `backup` del HLI v1 (solo crea un `.tar.gz`) y copiarlo a la VM.

### v2.3 — Servicios nuevos

| # | Prueba | Resultado esperado |
|---|---|---|
| 24 | `vaultwarden` | Pide dominio y contraseña del panel (dos veces, en la terminal) |
| 25 | Verificar el token | `docker exec vaultwarden env \| grep ADMIN_TOKEN` → hash completo `$argon2id$...`, **sin comillas** y con todos los `$` |
| 26 | Entrar a `/admin` | Acepta la contraseña ingresada en 24 |
| 27 | `homeassistant` | Activo en `:8123` (red host) |
| 28 | `opencloud` | Despliega; el login **no** funcionará sin dominio con TLS (esperado hasta v2.4). Anotar RAM: `docker stats --no-stream` |
| 29 | Re-ejecutar `opencloud` | No falla por `opencloud init` repetido |

### Respuestas de la API de Dokploy

Esto es lo que más importa confirmar. Si algún despliegue falla, guardar la
salida del módulo y `/var/log/hli2/<módulo>.log`: el cliente de la API se
escribió sin conocer la forma exacta de las respuestas.

---

## 6. Al terminar

Enviar la lista de pruebas con su resultado (OK / falló + qué pasó) y los
logs de los módulos que fallaron. Con eso se corrige antes de v2.4.

Para liberar espacio:

```bash
virsh -c qemu:///system destroy hli2-test
virsh -c qemu:///system undefine hli2-test --remove-all-storage --snapshots-metadata
```
