# Chessnut Coach

Aplicación nativa para iOS orientada a partidas OTB con un Chessnut Air y ayudas mediante los LEDs físicos del tablero.

## Estado actual: fase 4 — Stockfish 18 local

Las fases anteriores ya están validadas con un Chessnut Air real:

- Bluetooth LE, FEN físico y control de LEDs;
- posición lógica independiente de estados físicos temporales;
- detección de pieza levantada y movimientos legales;
- historial de partida, capturas, enroque, en passant, promociones y finales;
- ayuda independiente para blancas y negras;
- patrones LED fijo, lento y rápido.

La fase 4 integra **Stockfish 18** dentro de la aplicación:

- release oficial `sf_18` fijada al commit `cb3d4ee9b47d0c5aae855b12379378ea1439675c`;
- fuente oficial en el submódulo `Vendor/Stockfish`;
- compilación C++20 nativa para iPhone y simulador;
- dos redes NNUE oficiales verificadas mediante SHA-256;
- análisis completamente local, sin servidor;
- wrapper Swift que devuelve mejor movimiento, evaluación, profundidad y nodos;
- diagnóstico con FEN editable y accesos rápidos a la posición inicial y a la posición tras `1.e4`.

**Stockfish todavía no controla los LEDs.** La fase 5 conectará el motor al sistema de ayuda ya validado.

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

## Ejecutar en un iPhone

1. Actualiza tu copia local del repositorio.
2. Para probar la PR de fase 4, selecciona `feature/stockfish18-engine`.
3. Abre `ChessnutCoach.xcodeproj`.
4. Selecciona tu Personal Team si Xcode lo solicita.
5. Selecciona el iPhone como destino y ejecuta la app.
6. En la primera compilación deja que finalice la descarga/verificación y compilación de Stockfish 18.

## Diagnóstico Stockfish 18

En la sección **Stockfish 18 · diagnóstico**:

1. pulsa **Inicial** y después **Analizar FEN con Stockfish 18**;
2. debe aparecer `Stockfish 18`, un `bestmove`, una evaluación, profundidad y nodos;
3. pulsa **Tras 1.e4** y repite el análisis;
4. la posición y normalmente el mejor movimiento/evaluación deben cambiar.

El campo FEN es editable para permitir pruebas adicionales sin depender todavía de la partida física.

## Ayuda por bando

La fase 3 sigue disponible durante la fase 4:

- **No**: no muestra destinos;
- **Legales**: destinos legales fijos;
- **Calidad**: calidad simulada mediante fijo/lento/rápido.

La clasificación de **Calidad** sigue siendo deliberadamente simulada hasta la fase 5.

## Cómo funcionan los patrones

El Chessnut Air sólo dispone de LEDs monocromos:

- **fijo**: futuro movimiento bueno/mejor;
- **lento**: futuro movimiento aceptable;
- **rápido**: futuro blunder/movimiento a evitar.

Un único controlador compone la matriz completa de LEDs cada 250 ms para evitar carreras BLE.

## Pruebas automáticas

CI:

- inicializa el submódulo exacto de Stockfish 18;
- restaura/cachea las redes NNUE verificadas;
- compila la aplicación para iOS Simulator incluyendo el motor C++;
- ejecuta los tests del núcleo OTB y del controlador de ayuda.

## Dependencias y licencia

- EasyLinkSwiftSDK: Bluetooth/FEN/LEDs del Chessnut.
- ChessKit: reglas y posición lógica.
- Stockfish 18: GNU GPL v3 o posterior.

La versión exacta, commit y hashes NNUE están documentados en `STOCKFISH_VERSION.md`. Si la aplicación se distribuye a terceros, deberán revisarse y cumplirse las obligaciones de la GPL y la publicación del código fuente correspondiente.

## Roadmap

1. Fase 2: base completa de partida — completada.
2. Fase 3: ayuda por bando y patrones LED — completada y validada físicamente.
3. **Fase 4: Stockfish 18 local — en curso.**
4. Fase 5: evaluación real de destinos con Stockfish y clasificación de calidad.
5. Fase 6: persistencia de partidas, eliminación y exportación PGN.
6. Fase 7: interfaz final e icono de aplicación.
