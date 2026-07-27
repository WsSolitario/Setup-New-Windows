# Workstation Setup API

Backend de preconfiguracion para equipos Windows 11. Registra cada equipo por numero de serie, entrega dos scripts de PowerShell y sirve el instalador de Ninite.

## Puesta en marcha con LXC Proxmox

La API quedara en el LXC `10.10.10.25` y se publicara como `windows.ssdevsolutions.com`. Cree primero un registro DNS `A` interno que resuelva ese nombre a `10.10.10.25`. Dentro de un LXC Debian 12 o Ubuntu 24.04 con red y acceso saliente HTTPS, ejecute como `root`:

```bash
apt-get update && apt-get install -y curl
curl -fsSL https://raw.githubusercontent.com/WsSolitario/Setup-New-Windows/main/scripts/install-lxc.sh -o /tmp/install-lxc.sh
bash /tmp/install-lxc.sh \
  --domain windows.ssdevsolutions.com \
  --public-url https://windows.ssdevsolutions.com \
  --tls
```

El instalador instala Node.js 22, PostgreSQL, Nginx opcional, Certbot opcional, crea el usuario de servicio `workstation`, inicializa la base de datos y registra la API como `workstation-setup.service`.

`--tls` requiere que el dominio sea validable por Let's Encrypt desde Internet. Si `10.10.10.25` es una IP privada y el servicio solo existe en la red interna, use un certificado interno o termine TLS en su Nginx Proxy Manager, y ejecute el instalador sin `--tls`:

```bash
bash /tmp/install-lxc.sh \
  --domain windows.ssdevsolutions.com \
  --public-url https://windows.ssdevsolutions.com
```

En ese caso, configure el proxy para enviar `windows.ssdevsolutions.com` a `10.10.10.25:3000` y mantenga el certificado de confianza instalado en los equipos Windows.

Si el DNS esta proxificado por Cloudflare, la validacion HTTP puede terminar en otro origen o fallar por un registro `AAAA`. Usa el desafio DNS con un API Token de Cloudflare que tenga solo `Zone.DNS:Edit` para la zona `ssdevsolutions.com`:

```bash
export CLOUDFLARE_API_TOKEN='TOKEN_DE_CLOUDFLARE'
bash /tmp/install-lxc.sh \
  --domain windows.ssdevsolutions.com \
  --public-url https://windows.ssdevsolutions.com \
  --cloudflare-dns
unset CLOUDFLARE_API_TOKEN
```

El token se usa solo durante la solicitud y se elimina el archivo temporal de credenciales. La opcion `--cloudflare-dns` es la adecuada cuando el subdominio sigue detras del proxy naranja de Cloudflare.

Para una instalación sin dominio/HTTPS durante pruebas aisladas:

```bash
bash /tmp/install-lxc.sh --no-nginx --public-url http://10.10.10.25:3000
```

En producción, el dominio debe apuntar al LXC antes de usar `--tls`. Después de instalar, copie el `ninite.exe` autorizado a `/opt/workstation-setup/artifacts/ninite.exe` y compruebe:

```bash
systemctl status workstation-setup
curl https://windows.ssdevsolutions.com/health
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
