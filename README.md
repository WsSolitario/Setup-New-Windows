# Workstation Setup API

Backend de preconfiguracion para equipos Windows 11. Registra cada equipo por numero de serie, entrega dos scripts de PowerShell y sirve el instalador de Ninite.

## Puesta en marcha con LXC Proxmox

La API queda en el LXC `10.10.10.25` y Nginx Proxy Manager (NPM) publica `windows.ssdevsolutions.com` hacia ese LXC. Cree el registro DNS que usa NPM y configure el Proxy Host con:

```text
Forward Hostname/IP: 10.10.10.25
Forward Port:        3000
Forward Scheme:      http
```

Seleccione en NPM el certificado Let's Encrypt para `windows.ssdevsolutions.com`. El LXC no necesita Certbot, certificado público ni Nginx; solo debe responder en LAN por `10.10.10.25:3000`. Dentro de un LXC Debian 12 o Ubuntu 24.04 con red y acceso saliente HTTPS, ejecute como `root`:

```bash
apt-get update && apt-get install -y curl
curl -fsSL https://raw.githubusercontent.com/WsSolitario/Setup-New-Windows/main/scripts/install-lxc.sh -o /tmp/install-lxc.sh
bash /tmp/install-lxc.sh \
  --no-nginx \
  --public-url https://windows.ssdevsolutions.com
```

El instalador instala Node.js 22 y PostgreSQL, crea el usuario de servicio `workstation`, inicializa la base de datos, descarga Ninite desde la URL oficial y registra la API como `workstation-setup.service`. `--public-url` debe seguir siendo HTTPS porque los equipos Windows consumirán la URL externa de NPM.

Si ya ejecutaste una instalación anterior con `--tls`, no necesitas reinstalar PostgreSQL ni la API. El fallo de Certbot no impide que el servicio funcione: valida directamente el backend y usa NPM para el acceso externo:

```bash
systemctl status workstation-setup
curl http://127.0.0.1:3000/health
curl http://10.10.10.25:3000/health
```

Si Nginx del LXC no se utiliza, puede detenerse después de confirmar que NPM llega al puerto 3000:

```bash
systemctl disable --now nginx
```

Si por algún motivo no usas NPM y quieres que el propio LXC gestione TLS, entonces sí puedes usar `--tls`. En tu arquitectura actual no debes usar esa opción.

Para una instalación sin dominio/HTTPS durante pruebas aisladas:

```bash
bash /tmp/install-lxc.sh --no-nginx --public-url http://10.10.10.25:3000
```

Después de instalar, el archivo queda en `/opt/workstation-setup/artifacts/ninite.exe`. La fase 2 no descarga directamente desde `ninite.com`: descarga el ejecutable desde la API mediante `https://windows.ssdevsolutions.com/ninite.exe`. Compruebe:

```bash
systemctl status workstation-setup
curl https://windows.ssdevsolutions.com/health
curl -I https://windows.ssdevsolutions.com/ninite.exe
```

El instalador está en `scripts/install-lxc.sh` y es idempotente para actualizaciones del mismo repositorio. Las credenciales quedan en `/etc/workstation-setup/workstation-setup.env` con permisos `0600`.

## Puesta en marcha manual

1. Copie `.env.example` como `.env` y cambie `POSTGRES_PASSWORD`, `LOCAL_ADMIN_PASSWORD` y `PUBLIC_BASE_URL`.
2. Coloque el instalador autorizado en `artifacts/ninite.exe`.
3. Inicie los servicios con `docker compose up -d --build`.
4. Compruebe `https://windows.ssdevsolutions.com/health` desde el proxy inverso.
5. En OOBE, abra una consola elevada con `Shift + F10` y ejecute:

```powershell
irm https://windows.ssdevsolutions.com/setup.ps1 | iex
```

La API debe publicarse exclusivamente por HTTPS con un certificado de confianza. No use opciones para omitir la validacion TLS.

## Endpoints

| Metodo | Ruta | Uso |
|---|---|---|
| GET | `/health` | Salud de API y PostgreSQL |
| GET | `/setup.ps1` | Fase 1 generada con la configuracion del entorno |
| GET | `/stage2.ps1` | Fase 2 ejecutada por la tarea programada |
| GET | `/ninite.exe` | Instalador aprovisionado en `artifacts/` |
| POST | `/api/register` | Registra `{ "serial_number": "...", "hostname": "..." }` |
| POST | `/api/status` | Actualiza `{ "serial_number": "...", "status": "actualizado" }` |

## Operacion y seguridad

- `setup.ps1` contiene temporalmente la contrasena local porque Windows necesita establecerla y configurar autologon. Por ello el endpoint no debe quedar expuesto fuera de la ventana de aprovisionamiento. Restrinja en el proxy por VPN, red de origen o allowlist y rote la contrasena al terminar los 34 equipos.
- La contrasena de autologon queda en el registro durante el aprovisionamiento. La fase 2 elimina `DefaultPassword` al finalizar correctamente.
- Los logs locales quedan en `C:\ProgramData\WorkstationSetup\stage1.log` y `stage2.log`.
- Si la fase 2 falla, informa `error_fase_2` y conserva la tarea para reintentar en el siguiente inicio de sesion.
- `BypassNRO` habilita la ruta de configuracion sin red en compilaciones compatibles, pero algunas versiones recientes de Windows 11 pueden seguir mostrando pasos de OOBE. Valide la imagen exacta antes del despliegue masivo; no hay garantia de que crear una cuenta desde `Shift + F10` marque OOBE como completado.
- Confirme que su instalador y licencia de Ninite admiten automatizacion silenciosa. El backend no descarga ni redistribuye Ninite por su cuenta.

## Desarrollo sin Docker

Requiere Node.js 20 o superior y PostgreSQL. Ejecute `sql/init.sql`, configure `.env`, instale dependencias con `npm install` e inicie con `npm start`.
