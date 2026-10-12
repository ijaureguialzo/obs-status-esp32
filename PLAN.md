# PLAN.md — Plan de mejoras: obs-status-esp32

> Plan de trabajo para mejorar **calidad de código, seguridad y rendimiento**.
> Cada tarea incluye: objetivo, archivos, pasos concretos y criterio de aceptación.
> Marca las casillas al completar cada tarea. El plan está pensado para poder
> retomarse en cualquier momento: cada tarea es autocontenida y termina con su
> verificación y su commit.

**Fecha del análisis:** 2026-10-12
**Estado verificado en el momento del análisis:**
- `swift build --package-path macos-app` → OK, con 1 warning (`Models/ObsStatusVersion.swift` unhandled)
- `swift test --package-path macos-app` → 16/16 tests OK
- `pio test -d esp32-firmware -e host-tests` → 26/26 tests OK

## Componentes

| Componente | Ubicación | Notas |
|---|---|---|
| Protocolo | `protocol/obs_protocol.h` ↔ `macos-app/.../Models/ObsProtocol.swift` | Check de sync en CI (`scripts/check_protocol_sync.sh`) |
| Firmware | `esp32-firmware/` (ESP-IDF vía PlatformIO) | 2 envs: `esp32-s3-dev-kit-n8r8` (LED), `esp32-c6-touch-lcd-1_47` (LCD táctil) |
| App macOS | `macos-app/` (SwiftUI + SwiftPM/Xcode) | OBS WebSocket v5, USB CDC vía IOKit, Keychain para token |

## Convenciones de commit (ver AGENTS.md)

- Conventional commits (`feat:`, `fix:`, `perf:`, `build:`, `test:`, `chore:`, `docs:`).
- Siempre incluir el trailer: `Co-authored-by: opencode <opencode@assistant.dev>`
- Una tarea = un commit (o pocos, agrupados por tarea).

## Comandos de verificación (usar al cerrar cada tarea)

```bash
bash scripts/check_protocol_sync.sh                 # sync C <-> Swift
pio test -d esp32-firmware -e host-tests            # tests de protocolo (host)
pio run  -d esp32-firmware -e esp32-s3-dev-kit-n8r8     # build firmware S3
pio run  -d esp32-firmware -e esp32-c6-touch-lcd-1_47   # build firmware C6
swift build --package-path macos-app                # app (SwiftPM) — sin warnings
swift test  --package-path macos-app                # tests Swift
cd macos-app && xcodebuild -scheme obs-status-macos-ui -configuration Debug build
```

---

## FASE 1 (P0) — Fiabilidad CI / Seguridad

### 1.1 ✅ `build: firmar en CI sin team personal`
- **Objetivo:** el job `macos-app` de CI no debe depender del team `RSEH385M54`
  (hardcodeado en el pbxproj) ni de la firma.
- **Archivos:** `.github/workflows/ci.yml`
- **Pasos:**
  - En el paso `xcodebuild ... build` añadir `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`.
  - No cambiar el pbxproj (el team sigue valiendo para builds/instales locales con `make install-macos`).
- **Aceptación:** el job de CI de macOS compila sin errores de code signing.
- [x] Hecho (commit: `build: ...`)

### 1.2 ✅ `build: cachear PlatformIO en CI y pin de versión`
- **Objetivo:** evitar re-descargas de la toolchain en cada run (~1.5 GB × 2 matrix jobs) y
  evitar deriva de la versión de PlatformIO Core.
- **Archivos:** `.github/workflows/ci.yml`
- **Pasos:**
  - `pip install platformio==<versión actual del proyecto>` (consultar la versión en uso local: `pio --version`).
  - `actions/cache@v4` sobre `~/.platformio` (key: `pio-${{ runner.os }}-${{ hashFiles('esp32-firmware/platformio.ini') }}` + ref).
- **Aceptación:** los jobs de firmware usan caché en runs consecutivos.
- [x] Hecho (commit: `build: ...`; pin `platformio==6.2.0`, la versión local en uso)

### 1.3 ✅ `fix(macos): no procesar eventos del ESP32 sin confirmación del usuario`
- **Objetivo (seguridad):** hoy, un dispositivo USB malicioso que clone VID Espressif
  (`0x303A`) y coincida con `lastESPDevicePath` se conecta solo (`autoConnect`) y sus líneas
  `EVENT:TOGGLE_PAUSE` pausarían/reanudarían la grabación de OBS sin intervención del usuario.
  El protocolo no tiene autenticación; se mitiga con un estado de confianza en la app.
- **Diseño (mínimo viable, sin cambio de protocolo):**
  - `AppViewModel`: añadir `espDeviceTrusted: Bool` (y persistirlo en `AppSettings`
    como `lastESPDeviceTrusted: Bool`, o como dict `path+serialNumber -> trusted`).
  - `autoConnect`/`prepare()`: tras conectar, el dispositivo queda como **no confirmado**
    (salvo que `AppSettings` indique confianza previa para ese path+serial).
  - Comandos de LED/scene/status: se envían con normalidad.
  - `observeESPEvents()`: si el dispositivo no está confirmado, **ignorar** `EVENT:*`
    y mostrar aviso en la UI (`espError`/nuevo `espWarning`: "Dispositivo no confirmado:
    el toque en pantalla no controlará OBS").
  - `ESP32ConnectionView`: botón "Confirmar dispositivo" cuando no está confirmado.
  - La confianza se guarda por `path` + `serialNumber` (si existe); un clon sin el mismo
    serial no hereda la confianza.
- **Archivos:** `AppViewModel.swift`, `AppSettings.swift`, `ESP32ConnectionView.swift`,
  `ObsStatusMenuBar.swift` (aviso), `Localizable.xcstrings`, `specs/03-macos-app/APP_SPEC.md`.
- **Aceptación:** con un dispositivo "nuevo" (path distinto al confianza), los eventos
  se ignoran y se muestra el aviso; tras confirmar, funcionan. Tests de `AppViewModel`
  con el fake de la tarea 3.2.
- [x] Hecho (commit: `fix(macos): ...`; `USBDevice.trustID` = serial o path, `AppSettings.trustedESPDevices`
  persistido, botón "Trust this device" en panel y barra de menú, 4 tests de regresión)

### 1.4 ✅ `fix: autenticación real con secreto del dispositivo`
- **Objetivo:** defensa fuerte contra un clon que implemente todo el protocolo.
- **Diseño:**
  - Firmware: secreto aleatorio persistido en NVS (generado en el primer boot);
    nuevo comando `AUTH:<nonce>` → el dispositivo responde `OK:<HMAC>` (o simplemente
    requiere `AUTH:<secret>` leído de la pantalla/logs el primer día).
  - App: al conectar, pedir `STATUS`, y solo después de `AUTH` armar el procesamiento de eventos.
  - Actualizar `protocol/obs_protocol.h` + `ObsProtocol.swift` + `PROTOCOL_SPEC.md`
    (el check de sync de CI lo cubre).
- **Nota:** es la versión fuerte; 1.3 ya mitiga el vector práctico. Valorar si se hace ahora.
- [x] Hecho (commit: `feat(protocol): ...`; `AUTH:<secret>` con secreto NVS aleatorio (32 hex, primero boot),
  `|AUTH=1` en STATUS, secreto en pantalla de arranque y log, app guarda el secreto en Keychain por
  trustID, `authenticateDevice()` + replay automático al reconectar, firmware legacy → confianza manual)

---

## FASE 2 (P1) — Rendimiento / Robustez

### 2.1 ✅ `perf(firmware): sdkconfig.defaults con optimización para producción`
- **Objetivo:** hoy NO hay `sdkconfig.defaults`; el `sdkconfig` que PlatformIO genera por
  defecto trae `CONFIG_COMPILER_OPTIMIZATION_DEBUG` (`-O0`) → el firmware entero compila
  en modo debug. En la C6 (single-core, 160 MHz) el redraw con rotación en software de
  110 KB es la mayor carga; además, sin defaults, los builds no son reproducibles
  entre versiones de IDF.
- **Pasos:**
  - Crear `esp32-firmware/sdkconfig.defaults`:
    ```
    CONFIG_COMPILER_OPTIMIZATION_SIZE=y
    CONFIG_COMPILER_OPTIMIZATION_ASSERTIONS_DISABLE=y
    CONFIG_LOG_DEFAULT_LEVEL_INFO=y
    ```
  - Borrar los `sdkconfig.esp32-*` locales (generados, ya gitignoreados) y re-ejecutar
    `pio run` en los 2 envs para regenerarlos y verificar que se aplican.
  - (Opcional) añadir un env `esp32-c6-touch-lcd-1_47-debug` con `CONFIG_COMPILER_OPTIMIZATION_DEBUG=y`
    para desarrollo en vivo.
- **Aceptación:** el sdkconfig generado de CI/fresco trae SIZE; `pio run` OK en ambos envs;
  el binario resultante es visiblemente menor que el anterior.
- [x] Hecho (commit: `perf(firmware): ...`; S3: flash −24% / RAM −25%, C6: flash −24%; env `-debug`
  con `sdkconfig.defaults.debug` vía pre-script (PIO 6.2 ignora `build_env`); además fix del vendor
  AXS5106 `i2c_write` sin return que rompía el build `-Werror`)

### 2.2 ✅ `fix(firmware): lock de aplicación para las escrituras USB`
- **Objetivo:** `usb_cdc_send` (app task), `usb_cdc_send_nowait` (touch task) y `ESP_LOG`
  (cualquier task) llaman a `usb_serial_jtag_write_bytes`. La app **descarta** cualquier
  línea malformada: si un log se intercala dentro de una respuesta de protocolo, el host
  la ve como basura → timeout → desconexión falsa. El driver de ESP-IDF serializa
  internamente cada llamada, pero el contrato debe ser explícito y no depender de un
  detalle interno del driver.
- **Pasos:**
  - Verificar en el source de `esp_driver_usb_serial_jtag` (IDF 5.x, el que trae
    `espressif32@7.1.3`) que `usb_serial_jtag_write_bytes` y el console comparten lock
    para la llamada completa (dejar un comentario citándolo).
  - Añadir un mutex/`portMUX` `s_tx_lock` en `usb_cdc.c` que proteja **ambas** funciones
    de escritura (`usb_cdc_send` y `usb_cdc_send_nowait`).
  - `main.c`: chequear el `ret` del segundo `nvs_flash_init()` (nítido de robustez).
- **Archivos:** `esp32-firmware/src/usb/usb_cdc.c`, `esp32-firmware/src/main.c`
- **Aceptación:** `pio run` OK en ambos envs; comentarios explicando por qué existe el lock.
- [x] Hecho (commit: `fix(firmware): ...`; mutex `s_tx_lock` en `usb_cdc_send`/`send_nowait`; verificado en el
  driver IDF: `write_bytes` atómico por llamada, el console escribe por caracteres; chequeo del 2º
  `nvs_flash_init` ya hecho en 1.4)

### 2.3 ✅ `feat(firmware): truncado determinista de SCENE (host) + doc en el protocolo`
- **Objetivo:** el host envía `SCENE:<nombre>` sin límite; el firmware trunca a 127 chars
  (line buffer) y la pantalla muestra ≤96. El parser ya es estricto ante basura (los
  comandos cortos no pueden "acertar" por truncado), pero conviene que el truncado sea
  determinista y documentado, no un efecto colateral.
- **Pasos:**
  - `ObsProtocol.swift`: `ObsCommand.scene(name:)` trunca a 96 chars (máximo de la
    pantalla: `SCENE_MAX_LEN`) además de sustituir `\n`/`\r`.
  - `PROTOCOL_SPEC.md`: documentar el comportamiento de línea sobredimensionada en el
    firmware (se procesan los primeros 127 bytes) y el límite de scene.
  - Tests Swift: scene >96 chars se trunca a 96 (sin newline extra).
- **Archivos:** `Models/ObsProtocol.swift`, `Tests/ObsStatusTests/ObsProtocolTests.swift`,
  `specs/02-protocol/PROTOCOL_SPEC.md`
- **Aceptación:** tests nuevos pasan; `check_protocol_sync.sh` sigue en verde.
- [x] Hecho (commit: `fix(app): ...`; truncado 95 chars / 121 bytes con corte en frontera de
  carácter; test multi-byte CJK 95→40 chars; doc en PROTOCOL_SPEC)

### 2.4 ⬜ `test(macos): tests de LineRouter y del flujo de comandos de USBCDCService`
- **Objetivo:** `LineRouter` (y `DeviceEventBroadcaster`) es la parte de mayor riesgo de
  la app (races: respuesta stash vs `registerPending`, discard stale, timeout,
  generaciones de reader) y **no tiene ningún test**.
- **Pasos:**
  - `USBCDCService.swift`: `private final class LineRouter` → `final class LineRouter`
    (internal, visible con `@testable import ObsStatus`); mismo para `DeviceEventBroadcaster`
    si se quiere testear.
  - Nuevo `Tests/ObsStatusTests/LineRouterTests.swift`:
    - línea de respuesta sin pending → se stashea; `registerPending` consume el stash.
    - `discardStaleResponse()` antes de un comando → la respuesta tarde no se reentrega.
    - `timeout(id)` → resume throwing solo si el id coincide; no-op si ya resolvió.
    - `stop()` → falla el pending con `notConnected`; `restart()` incrementa la generación.
    - líneas `EVENT:` → ruteadas a suscriptores, no a pending; logs basura → descartadas.
  - (Opcional) `USBCDCServiceTests.swift` con un par de "dispositivos" falsos vía
    `pipe()`/socketpair para el loop de reader.
- **Aceptación:** `swift test` verde con los nuevos tests.
- [ ] Hecho (commit: `test(macos): ...`)

### 2.5 ⬜ `test(macos): tests de AppViewModel (retries, sesión, confianza)`
- **Objetivo:** cubrir `deliver()` (reintentos ante timeout transitorio, fallo definitivo
  desconecta, `ERROR:` de bien formado NO se reintenta, sesión obsoleta no rompe el link
  nuevo) y la confianza de la tarea 1.3.
- **Pasos:**
  - Fakes inyectables ya existen (`init(obsService:usbService:settings:)`):
    `FakeOBSWebSocketService`, `FakeUSBCDCService`, `AppSettings` aislada (tmp dir).
    `AppSettings.shared` es singleton: parametrizar `init(fileURL:)` para tests.
  - Nuevo `Tests/ObsStatusTests/AppViewModelTests.swift` con los casos de arriba.
- **Aceptación:** `swift test` verde.
- [ ] Hecho (commit: `test(macos): ...`)

---

## FASE 3 (P2) — Calidad / DX

### 3.1 ⬜ `chore(macos): silenciar warning de SwiftPM sobre ObsStatusVersion.swift`
- **Objetivo:** `swift build` avisa "found 1 file(s) which are unhandled: Models/ObsStatusVersion.swift".
  El Xcode project sí usa ese archivo (lee la versión del Info.plist a runtime); SwiftPM
  usa el `ObsStatusVersion.swift` **generado** por el plugin `VersionGenerator`. Las dos
  copias son un riesgo de divergencia.
- **Pasos:**
  - `Package.swift`: añadir `"Models/ObsStatusVersion.swift"` a `exclude:` del target
    (el parámetro `exclude` aplica aunque haya `sources:` explícitas) → warning desaparece.
  - Comentario en el `Models/ObsStatusVersion.swift` y en `Package.swift` explicando la
    dualidad (Xcode: Info.plist; SwiftPM: plugin) para que no "arreglen" la otra mitad.
- **Aceptación:** `swift build` sin warnings.
- [ ] Hecho (commit: `chore(macos): ...`)

### 3.2 ⬜ `build: targets de test/verificación en Makefile`
- **Archivos:** `Makefile`
- **Pasos:**
  - `test:` → `swift test --package-path macos-app` + `pio test -d esp32-firmware -e host-tests` + `bash scripts/check_protocol_sync.sh`
  - `check:` → `test` + los 2 `pio run` + `swift build` (todo el conjunto).
  - Actualizar `help`.
- **Aceptación:** `make test` y `make check` locales pasan.
- [ ] Hecho (commit: `build: ...`)

### 3.3 ⬜ `fix(macos): enumerar todos los puertos USB Serial JTAG`
- **Objetivo:** con dos placas conectadas, el fallback solo añade `/dev/cu.debug-console`
  (el primero); el segundo (`/dev/cu.debug-console1`, ...) puede faltar.
- **Pasos:**
  - `USBCDCService.enumerateDevices()`: en el fallback, listar `/dev/cu.debug-console*`
    (p. ej. `FileManager.default.contentsOfDirectory` sobre `/dev/cu` filtrando por prefijo)
    y añadir cada uno.
- **Aceptación:** con dos dispositivos JTAG, ambos aparecen.
- [ ] Hecho (commit: `fix(macos): ...`)

### 3.4 ⬜ `test(firmware): layout de texto y UTF-8 del display como módulo host-testable`
- **Objetivo:** `layout_text`/`utf8_decode` (word-wrap, centrado, multi-línea) viven
  dentro de `display_controller.c` (con dependencias ESP) y no se prueban. Además,
  `utf8_decode` no soporta secuencias de 4 bytes (un emoji imprime "????").
- **Pasos:**
  - Extraer a `src/display/display_text.c` + `include/display_text.h` (solo `<string.h>`,
    `<stdint.h>`, `<stdbool.h>`, fuentes 8x8 y constantes de layout) lo que hoy es
    `utf8_decode`, `glyph_for`, `draw_glyph`, `layout_text` (operando sobre un mask
    pasable por parámetro, no sobre el `s_text` global).
  - `display_controller.c` los reutiliza; `src/CMakeLists.txt` añade el nuevo archivo.
  - Soportar secuencias UTF-8 de 4 bytes mapeadas a `'?'` (una sola) en `utf8_decode`.
  - `test/test_display_text.c` (Unity, env `host-tests`): wrap por palabras, hard-split de
    palabras largas, líneas explícitas `\n`, centrado, 2-byte/3-byte/4-byte UTF-8, bytes
    inválidos → `'?'`.
- **Aceptación:** `pio test -e host-tests` verde; `pio run` C6 OK.
- [ ] Hecho (commit: `test(firmware): ...`)

### 3.5 ⬜ `build: gate de warnings (CI)`
- **Pasos:**
  - `platformio.ini`: `-Werror` solo para el job de CI es inviable por env compartido;
    mejor: añadir a `ci.yml` un paso `pio run -d esp32-firmware -e <env> -e host-tests`
    ya existe; añadir `build_flags = ${env.build_flags} -Werror` vía variable de entorno
    de PlatformIO (`-e` no inyecta flags) → alternativa: usar `pio run ... --verbose`
    y un grep de `warning:` para fallar el job (sin tocar el build local).
  - `swift-format`: añadir `.swift-format` a la raíz de `macos-app/` y paso de CI
    `swift format lint --recursive obs-status-macos-ui` (ajustar al formato vigente;
    si el toolchain del runner no trae `swift format`, usar la acción de descarga).
- **Aceptación:** los jobs de CI fallan ante warnings nuevos.
- [ ] Hecho (commit: `build: ...`)

---

## FASE 4 (P3) — Limpieza / nice-to-have

### 4.1 ⬜ `fix(firmware): fallback para cabecera de versión generada`
- `firmware_version.h`: envolver el `#include "firmware_version_generated.h"` en
  `#if __has_include(...)` con valores de fallback (`1.0.0`/`1`). Así `protocol/obs_protocol.h`
  (que lo incluye) compila en cualquier contexto, incluso un checkout sin build previo.
- **Aceptación:** compila `protocol_message.c` en host con la cabecera generada borrada.
- [ ] Hecho

### 4.2 ⬜ `chore(macos): modernizar swift-tools-version`
- `Package.swift`: `// swift-tools-version: 6.0` + `swiftLanguageMode: .v5` en el target
  (conserva la semánta 5 y evita una avalancha de cambios de concurrencia estricta).
- **Aceptación:** `swift build` y `swift test` locales y en CI.
- [ ] Hecho

### 4.3 ⬜ `chore: micro-limpiezas`
- `esp_lcd_touch_axs5106.c` (vendor local): `g_dev_handle` → `static`.
- `ObsProtocol.swift`: eliminar `ObsProtocolUtil` (duplica `ObsResponse.isErrorResponse`)
  o dejarlo con un único uso; actualizar `AppViewModel` y tests.
- `USBDevice.isESP32Device`: quitar ST `0x28E9` (no es Espressif; evita falsos positivos
  como ST-Link).
- `AGENTS.md`: el título dice "CLAUDE.md" → "AGENTS.md".
- **Aceptación:** builds y tests en verde.
- [ ] Hecho

### 4.4 ⬜ `chore(macos): unificar identidades de settings/Keychain`
- El bundle ID del build SwiftPM (`com.unknown.obs-status`) difiere del `.app`
  (`com.jaureguialzo.obs-status-macos-ui`) → dos entradas Keychain y dos JSON de settings.
  Opciones (elegir una):
  - Fijar un bundle ID estable en `Package.swift`? (SwiftPM no permite bundle ID en el
    manifest) → en su lugar: unificar el ID del Keychain en una constante (`"obs-status"`)
    en `AppSettings.Key.bundleID` para ambos modos.
- Mover el JSON a `Application Support/obs-status/` (más idiomático que `Preferences/`).
- **Aceptación:** token y settings compartidos entre el binario SwiftPM y el `.app`.
- [ ] Hecho

### 4.5 ⬜ `perf(firmware): micro-optimización de la rotación de frame`
- `redraw_locked()`: precomputar la permutación `out_idx -> in_idx` (tablas estáticas de
  320×172 por orientación) en init, para que el loop de composición sea un solo lookup
  en vez de aritmética/ternarios por píxel.
- **Aceptación:** `pio run` C6 OK; (si es medible) menor tiempo de redraw.
- [ ] Hecho

### 4.6 ⬜ `build: release automation (opcional)`
- Workflow de release: tag → artefactos (firmware `.bin` de ambos envs + `.app` ad-hoc)
  + `version.txt` como source de verdad del tag.
- **Aceptación:** un tag produce un release con binarios.
- [ ] Hecho

---

## Orden de ejecución recomendado

1. **Fase 1:** 1.1 → 1.2 → 1.3 (todas pequeñas/montañas de alto impacto: CI sana +
   vector de seguridad cerrado).
2. **Fase 2:** 2.1 → 2.2 → 2.3 → 2.4 → 2.5 (producción rápida del firmware +
   cobertura de lo más arriesgado).
3. **Fase 3:** 3.1 → 3.2 → 3.3 → 3.4 → 3.5.
4. **Fase 4:** en cualquier momento (son independientes).

> Nota de refino vs el análisis inicial: la antigua "tarea 7" (descartar la línea
> sobredimensionada en el firmware) se rehízo a 2.3: descartarla rompería el `OK`
> que el host espera para scenes largas; el parser ya es estricto ante basura, así
> que lo correcto es truncar en el host (≤96) y documentar el comportamiento.

## Estado resumido

| Fase | Tareas | Estado |
|---|---|---|
| 1 (P0) | 1.1 ✅ · 1.2 ✅ · 1.3 ✅ · 1.4 ✅ | ✅ completa |
| 2 (P1) | 2.1 ✅ · 2.2 ✅ · 2.3 ✅ · 2.4, 2.5 ⬜ | 🚧 en curso |
| 3 (P2) | 3.1 – 3.5 | ⬜ pendiente |
| 4 (P3) | 4.1 – 4.6 | ⬜ pendiente |
