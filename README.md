# Chessnut Coach

Aplicación nativa para iOS orientada a partidas OTB con un Chessnut Air y ayudas mediante los LEDs físicos del tablero.

## Estado actual: fase 5 — coaching real con Stockfish 18

Las fases anteriores ya están validadas con un Chessnut Air real:

- Bluetooth LE, FEN físico y control de LEDs;
- posición lógica independiente de estados físicos temporales;
- detección de pieza levantada y movimientos legales;
- historial de partida, capturas, enroque, en passant, promociones y finales;
- ayuda independiente para blancas y negras;
- patrones LED fijo, lento y rápido;
- Stockfish 18 ejecutándose localmente en el iPhone.

La fase 5 conecta **Stockfish 18** con la ayuda física del Chessnut Air:

- al comenzar un turno asistido se precalcula la evaluación global de la posición;
- al levantar una pieza se analizan únicamente sus destinos legales;
- cada destino se compara contra la **mejor jugada global de la posición**, no sólo contra la mejor jugada de la pieza levantada;
- pérdida de hasta 50 centipeones: **bueno → LED fijo**;
- pérdida de 51 a 200 centipeones: **aceptable → parpadeo lento**;
- pérdida superior a 200 centipeones: **blunder → parpadeo rápido**;
- si se devuelve o mueve la pieza mientras Stockfish analiza, el resultado anterior se descarta y no puede encender LEDs atrasados;
- en una promoción se analizan dama, torre, alfil y caballo y la casilla utiliza la valoración de la mejor promoción;
- el diagnóstico y el coaching comparten una única instancia del motor para no duplicar Stockfish y sus redes NNUE en memoria.

## Stockfish 18

La integración utiliza exactamente la release oficial `sf_18`, fijada al commit `cb3d4ee9b47d0c5aae855b12379378ea1439675c`:

- fuente oficial en el submódulo `Vendor/Stockfish`;
- compilación C++20 nativa para iPhone y simulador;
- dos redes NNUE oficiales verificadas mediante SHA-256;
- análisis completamente local, sin servidor;
- wrapper Swift con mejor movimiento, evaluación, profundidad y nodos.

La versión exacta, commit y hashes NNUE están documentados en `STOCKFISH_VERSION.md`.

## Primera compilación

La red NNUE grande supera el límite de 100 MiB por archivo de GitHub, por lo que no se guarda en el repositorio. La primera compilación ejecuta automáticamente `Scripts/fetch_stockfish_networks.sh`, descarga las dos redes oficiales y comprueba sus SHA-256 completos antes de utilizarlas.

El build también inicializa el submódulo Stockfish si fuese necesario y deja la biblioteca nativa compilada en DerivedData. Por eso la primera compilación puede ser sensiblemente más pesada que las siguientes.

Si por algún motivo el submódulo no se inicializase automáticamente, desde la carpeta del repositorio puede ejecutarse:

```bash
git submodule update --init --recursive
```

## Requisitos

- Xcode 26 o compatible con Swift 6.
- iPhone/iPad con iOS 16 o posterior.
- Chessnut Air. Air+, Go y Pro usan el mismo perfil BLE `classic`.
- Un Apple ID es suficiente para instalar la aplicación en un dispositivo propio mediante el Personal Team gratuito de Xcode.

## Ejecutar la fase 5 en un iPhone

1. Actualiza tu copia local del repositorio.
2. Selecciona la rama `feature/stockfish-led-coaching`.
3. Abre `ChessnutCoach.xcodeproj`.
4. Selecciona tu Personal Team si Xcode lo solicita.
5. Selecciona el iPhone como destino y ejecuta la app.
6. En la primera compilación deja que finalice la descarga/verificación y compilación de Stockfish 18.

## Ayuda por bando

Blancas y negras se configuran de forma independiente:

- **No**: no ilumina destinos;
- **Legales**: todos los destinos legales permanecen fijos;
- **Calidad**: Stockfish 18 valora cada destino y decide el patrón LED.

Por defecto, durante la validación de fase 5:

- Blancas: **Calidad**;
- Negras: **No**.

## Clasificación de calidad

La referencia es la mejor jugada global encontrada por Stockfish en la posición antes de mover:

| Pérdida | Calidad | LED |
| ---: | --- | --- |
| 0–50 cp | Bueno | Fijo |
| 51–200 cp | Aceptable | Parpadeo lento |
| >200 cp | Blunder | Parpadeo rápido |

Esto implica que si se levanta una pieza cuya mejor continuación sigue siendo mucho peor que la mejor jugada disponible con otra pieza, sus destinos pueden aparecer como aceptables o blunders. Es intencionado: el tablero evalúa la calidad real de la decisión, no sólo cuál es el mejor movimiento de la pieza elegida.

Las posiciones con mate forzado o resultado de tablebase se sitúan fuera de la escala normal de centipeones para que perder una victoria forzada se considere un deterioro decisivo.

## Latencia y concurrencia

Para reducir el tiempo desde que se levanta una pieza hasta que aparecen las luces:

1. Stockfish precalcula y cachea la evaluación base cuando empieza un turno con ayuda de Calidad.
2. Al levantar una pieza sólo analiza sus destinos legales.
3. Los análisis usan límites de nodos pequeños orientados a respuesta rápida en el dispositivo.
4. Si cambia la posición física mientras el análisis sigue en curso, el resultado se invalida antes de llegar a los LEDs.

El controlador de LEDs mantiene un único bucle que compone la matriz completa cada 250 ms. No se crean procesos BLE independientes por casilla.

## Pantalla bloqueada y Bluetooth en segundo plano

La app declara `bluetooth-central` como modo de ejecución en segundo plano. La sesión de partida y el cliente Chessnut pertenecen al ciclo de vida de la app, no a una pantalla concreta, por lo que se conservan al bloquear el iPhone o cambiar temporalmente de aplicación.

Al pasar a segundo plano se cancelan únicamente los análisis Stockfish y patrones LED transitorios que ya estaban en curso. Las notificaciones FEN del Chessnut siguen activas: una nueva pieza levantada crea un análisis nuevo y puede encender sus LEDs con la pantalla bloqueada.

Al volver al primer plano la app:

1. invalida cualquier resultado de ayuda iniciado antes de la suspensión;
2. comprueba que la conexión BLE continúa respondiendo;
3. vuelve a solicitar las notificaciones en tiempo real;
4. espera una posición física nueva antes de confirmar la sincronización;
5. conserva la partida lógica, el turno, el FEN y el historial.

Si CoreBluetooth informa de una desconexión, se descartan los LEDs y análisis asociados al cliente antiguo y se crea un cliente nuevo con reintentos automáticos cada dos segundos. La reconexión nunca reinicia la partida. Como en cualquier app iOS Bluetooth, este comportamiento cubre bloqueo y suspensión normal; cerrar la app expresamente desde el selector de aplicaciones finaliza la sesión del proceso.

Validación física obligatoria antes del merge:

1. conecta el Chessnut Air y juega al menos `1.e4`;
2. levanta una pieza y confirma los LEDs de Calidad;
3. devuelve la pieza, bloquea el iPhone y levanta la pieza del bando que tiene el turno;
4. confirma que aparecen LEDs con la pantalla apagada y completa el movimiento;
5. desbloquea y confirma turno, historial y posición sincronizada;
6. verifica que no aparece ningún patrón del análisis anterior al bloqueo;
7. con una partida en curso, apaga y enciende el Chessnut para forzar la reconexión;
8. confirma que la app indica reconexión y recupera la misma partida sin duplicar movimientos.

## Diagnóstico Stockfish 18

La sección **Stockfish 18 · diagnóstico** continúa disponible para pruebas manuales con FEN:

1. pulsa **Inicial** y después **Analizar FEN con Stockfish 18**;
2. debe aparecer `Stockfish 18`, un `bestmove`, evaluación, profundidad y nodos;
3. pulsa **Tras 1.e4** y repite el análisis.

El diagnóstico reutiliza el mismo motor que el coaching OTB.

## Pruebas automáticas

CI:

- inicializa el submódulo exacto de Stockfish 18;
- restaura/cachea las redes NNUE verificadas;
- compila la aplicación para iOS Simulator incluyendo el motor C++;
- ejecuta todos los tests del núcleo OTB;
- comprueba los umbrales 50/200 cp y su mapeo a fijo/lento/rápido;
- verifica que Calidad Stockfish no utiliza pistas simuladas como fallback;
- verifica las directivas de ciclo `active` / `inactive` / `background`;
- verifica que la desconexión BLE se reenvía tanto al cliente como al coordinador de reconexión;
- arranca Stockfish 18 realmente en iOS Simulator;
- analiza los destinos `e2→e3` y `e2→e4` mediante la misma capa de coaching usada por el Chessnut.

## Dependencias y licencia

- EasyLinkSwiftSDK: Bluetooth/FEN/LEDs del Chessnut.
- ChessKit: reglas y posición lógica.
- Stockfish 18: GNU GPL v3 o posterior.

Si la aplicación se distribuye a terceros, deberán revisarse y cumplirse las obligaciones de la GPL y la publicación del código fuente correspondiente.

## Roadmap

1. Fase 2: base completa de partida — completada.
2. Fase 3: ayuda por bando y patrones LED — completada y validada físicamente.
3. Fase 4: Stockfish 18 local — completada y validada físicamente.
4. **Fase 5: evaluación real de destinos con Stockfish y LEDs por calidad — en validación física.**
5. Fase 6: persistencia de partidas, eliminación y exportación PGN.
6. Fase 7: interfaz final e icono de aplicación.
7. Fase 8: robustez, rendimiento y pruebas de partidas completas.
