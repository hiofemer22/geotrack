# GeoTrack — Sistema de geolocalización en tiempo real

```
Proyecto de rastreo de posición/
├── mobile/    App Flutter (Android) — el rastreador
├── backend/   API Node.js + Socket.IO + PostgreSQL (sirve también el dashboard)
├── web/       Dashboard React (Vite + Leaflet) — centro de monitoreo
└── infra/     Scripts de despliegue en AWS (EC2 + RDS)
```

> ⚠️ **La ruta de esta carpeta tiene un acento ("posición")** y eso rompe el analizador de Dart y Gradle.
> Antes de trabajar, mapea la carpeta a una unidad sin acentos (hay que repetirlo tras reiniciar el PC):
> ```powershell
> subst G: "C:\Users\User\Documents\Proyecto de rastreo de posición"
> ```
> y trabaja siempre desde `G:\`.

---

## Fase 1 — Entorno local

### Herramientas (ya instaladas en este PC)
| Herramienta | Para qué | Ubicación |
|---|---|---|
| Git | control de versiones | `C:\Program Files\Git` |
| Node.js LTS | backend y dashboard | `C:\Program Files\nodejs` |
| JDK 17 (Temurin) | compilación Android | `C:\Program Files\Eclipse Adoptium` |
| Flutter (stable) | app móvil | `C:\src\flutter` (añadido al `PATH` de usuario) |
| Android Studio | SDK de Android, `adb` | `C:\Program Files\Android\Android Studio` |
| AWS CLI v2 | despliegue | `C:\Program Files\Amazon\AWSCLIV2` |

### Pasos que debes hacer tú (una vez)
1. **Abrir Android Studio** → asistente *Standard* → deja que descargue el Android SDK (≈ 2–3 GB). Al terminar: *More Actions → SDK Manager → SDK Tools* → marca **Android SDK Command-line Tools** → *Apply*.
2. **Variables de entorno** (Win + R → `sysdm.cpl` → Opciones avanzadas → Variables de entorno → *Variables de usuario*):
   - `ANDROID_HOME` = `C:\Users\User\AppData\Local\Android\Sdk`
   - En `Path` añade: `%ANDROID_HOME%\platform-tools`
   - (`C:\src\flutter\bin` ya está añadido)
3. Cierra y abre la terminal y acepta las licencias de Android:
   ```powershell
   flutter doctor --android-licenses
   flutter doctor
   ```

### Conectar tu teléfono Android
1. *Ajustes → Acerca del teléfono* → toca **7 veces "Número de compilación"** → se activan las *Opciones de desarrollador*.
2. *Ajustes → Sistema → Opciones de desarrollador* → activa **Depuración USB**.
3. Conecta el cable USB → en el teléfono acepta **"¿Permitir depuración USB?"** (marca *Permitir siempre*).
4. Comprueba: `adb devices` debe listar tu equipo como `device`.
5. Teléfono y PC deben estar en **la misma red Wi-Fi** para las pruebas locales.

### Ejecutar todo en local
Terminal 1 — base de datos (PostgreSQL embebido, sin Docker):
```powershell
cd G:\backend
npm install
copy .env.example .env      # solo la primera vez
npm run db:local
```
Terminal 2 — API + dashboard:
```powershell
cd G:\web;  npm install; npm run build     # compila el dashboard a backend/public
cd G:\backend; npm run dev
```
Abre **http://localhost:8080** → token: `dev-dashboard-token`.
(Para desarrollar el dashboard con recarga en caliente: `cd G:\web; npm run dev` → http://localhost:5173)

Terminal 3 — app en el teléfono:
```powershell
cd G:\mobile
flutter pub get
flutter run            # instala y abre la app en el teléfono conectado
```
En la app: **Ajustes** → URL del servidor `http://<IP-de-tu-PC>:8080` (por defecto `http://10.228.181.57:8080`) → *Guardar y probar conexión*.
Si no conecta, permite Node.js en el Firewall de Windows (red privada) o ejecuta como administrador:
```powershell
New-NetFirewallRule -DisplayName "GeoTrack 8080" -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow -Profile Private
```

Simular dispositivos sin teléfonos: `cd G:\backend; node scripts/simulate.js http://localhost:8080 3`

APK instalable: `flutter build apk --release` → `mobile\build\app\outputs\flutter-apk\app-release.apk`

Si Windows (Smart App Control) bloquea la compilación local, compila en una EC2 temporal y se instala en el teléfono conectado:
```powershell
powershell -ExecutionPolicy Bypass -File infra\build-apk-cloud.ps1 -Install
```

**Firma de la app:** el APK de release se firma con `mobile\android\geotrack-release.jks` (contraseñas en `mobile\android\key.properties`; ambos ignorados por git).
Así las actualizaciones se instalan encima sin perder el historial del teléfono. **Guarda una copia de esos dos archivos fuera del PC**: si se pierden, para actualizar habrá que desinstalar la app (y se borran las rutas locales).

---

## Fase 2 — AWS

| Componente | Servicio AWS | Motivo |
|---|---|---|
| API + WebSockets + dashboard | **EC2** t3.small (Amazon Linux 2023) + Nginx + IP elástica | Socket.IO necesita conexiones persistentes; un servidor es simple y barato |
| Base de datos | **RDS PostgreSQL 16** db.t4g.micro, privada, cifrada, backups 7 días | Gestionada, con backups automáticos |
| Red | VPC por defecto + 2 Security Groups | La BD solo acepta conexiones desde la API; SSH solo desde tu IP |

Costo aproximado: ~US$ 30/mes (EC2 t3.small ≈ 15, RDS t4g.micro ≈ 13, almacenamiento) — en capa gratuita puede ser menor.

1. **Credenciales** (nunca las pegues en un chat): en la consola de AWS crea un usuario IAM con acceso programático y ejecuta en tu terminal:
   ```powershell
   aws configure        # Access key, Secret key, región (ej. us-east-1), formato json
   ```
2. **Crear infraestructura y desplegar** (~15 min):
   ```powershell
   powershell -ExecutionPolicy Bypass -File infra\deploy-aws.ps1 -Region us-east-1
   ```
   Al terminar imprime la IP pública. Los secretos (token del dashboard, API key de dispositivos, URL de BD) quedan en `infra\.deploy.json` (ignorado por git).
3. **Actualizar código** después de cambios: `infra\update-app.ps1`
4. **Borrar todo** (deja de cobrar): `infra\destroy-aws.ps1`

En la app: Ajustes → URL `http://<IP-pública>` y la API key de `.deploy.json`.
**Si los scripts se quedan colgados en SSH**, probablemente cambió tu IP pública (el Security Group solo admite SSH desde la IP registrada). Permite la nueva:
```powershell
$ip = (Invoke-RestMethod https://checkip.amazonaws.com).Trim()
$sg = (Get-Content infra\.deploy.json | ConvertFrom-Json).sgApi
aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 22 --cidr "$ip/32"
```

Para HTTPS: apunta un dominio a la IP y en el servidor ejecuta `sudo dnf install -y certbot python3-certbot-nginx && sudo certbot --nginx`.

---

## Fase 3 — App móvil (cómo funciona)
- **Rastreo persistente:** `flutter_background_service` corre un *foreground service* de Android (`foregroundServiceType=location`, `stopWithTask=false`) en un isolate propio, independiente de la UI. Sigue grabando con la app cerrada o la pantalla bloqueada, se reanuda tras reiniciar el teléfono (`autoStartOnBoot`) y tiene un *watchdog* que fuerza una lectura si el GPS deja de entregar posiciones. La app pide "Permitir todo el tiempo" y la exclusión de la optimización de batería.
- **Offline-first:** cada punto se guarda primero en SQLite (`points.synced = 0`) y las operaciones en una tabla `outbox`. Cada 5–10 s se vacía la cola en lotes de 500; el servidor es idempotente (`UNIQUE(device_id, ts)`), así que los reintentos no duplican datos.
- **Historial on-device:** sesiones con ruta dibujada, estadísticas, renombrar y borrar.
- **Telemetría:** velocidad (Doppler del GPS, mediana de 3 lecturas), clasificación *Detenido / Caminata / Alta velocidad / Vehículo* y calorías por MET × peso × tiempo (ver `lib/services/telemetry.dart`).

## Fase 4 — Dashboard web
- Panel en vivo con todos los dispositivos, ruta en tiempo real con color único y etiqueta por dispositivo.
- Historial con filtros por dispositivo, fecha/hora y atajos (1 h, Hoy, 24 h, 7 días).
- Reproductor con Play/Pausa, barra de progreso y velocidades x1/x10/x20/x30/x60 (salta huecos sin señal).

## Fase 5 — Funcionalidades adicionales implementadas
1. **Geocercas con alertas** de entrada/salida (se dibujan en el mapa con clic + radio).
2. **Botón SOS** en la app (mantener 2 s) → alerta roja inmediata en el dashboard.
3. **Alertas automáticas**: batería baja (≤ 15 %) y dispositivo *sin señal* (> 2 min sin datos mientras rastrea).
4. **Exportación GPX / CSV** del historial y **estadísticas** (distancia, duración, velocidad media y máxima).
5. **Autenticación**: API key para dispositivos y token para el dashboard.
