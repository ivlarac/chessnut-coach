# Chessnut Coach

PoC nativa para iOS orientada a partidas OTB con un Chessnut Air y futuras ayudas de motor mediante los LEDs físicos del tablero.

## Estado actual: PoC BLE

Esta primera versión valida únicamente la base de hardware:

- conexión Bluetooth LE con Chessnut Air/Air+/Go/Pro usando el perfil `classic`;
- recepción en tiempo real de la posición física como FEN placement;
- consulta de batería;
- encendido de un LED individual;
- parpadeo de un LED generado por software;
- selección manual de `rankIndex` y `fileIndex` para comprobar la orientación real de la matriz del Air.

Todavía **no** incluye reglas de ajedrez, detección de movimientos ni Stockfish. Se añadirán sólo después de validar esta PoC con un Chessnut Air real.

## Requisitos

- Xcode 26 o compatible con Swift 6.2.
- iPhone/iPad con iOS 16 o posterior.
- Chessnut Air (también debería funcionar con Air+, Go y Pro mediante el mismo perfil BLE).
- Un Apple ID es suficiente para instalarla en tu propio dispositivo desde Xcode; no hace falta una cuenta de desarrollador de pago para esta prueba.

## Ejecutar en un iPhone

1. Clona este repositorio.
2. Abre `ChessnutCoach.xcodeproj` en Xcode.
3. Espera a que Swift Package Manager descargue `EasyLinkSwiftSDK`.
4. En **Signing & Capabilities**, selecciona tu *Personal Team* si Xcode lo solicita.
5. Conecta el iPhone al Mac y selecciónalo como destino.
6. Cierra Chessnut Next, White Pawn u otras apps que puedan mantener una conexión BLE con el tablero.
7. Enciende el Chessnut Air.
8. Ejecuta `ChessnutCoach` en el iPhone y acepta el permiso de Bluetooth.

## Prueba mínima

La PoC se considera validada si se cumplen estas cuatro comprobaciones:

1. Al pulsar **Conectar**, el estado cambia a `Conectado`.
2. La sección **Posición física** muestra una cadena similar a:
   `rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR`.
3. Al levantar y volver a colocar una pieza, la cadena cambia inmediatamente.
4. Seleccionando un `rankIndex` y `fileIndex`, **Encender LED** ilumina una casilla física y **Parpadear LED** hace parpadear esa misma casilla.

Prueba primero las cuatro esquinas `(0,0)`, `(0,7)`, `(7,0)` y `(7,7)`. Así podremos fijar después una conversión estable entre coordenadas del SDK y notación de ajedrez (`a1`…`h8`).

## Dependencia

La comunicación con el tablero usa [EasyLinkSwiftSDK](https://github.com/NSStudent/EasyLinkSwiftSDK), que utiliza CoreBluetooth y expone lectura de FEN y control de la matriz de LEDs de los Chessnut clásicos.

## Siguiente fase

Una vez confirmada la PoC en hardware real:

1. mantener por separado la posición lógica de la partida y la posición física temporal;
2. detectar pieza levantada y movimiento completado;
3. integrar una biblioteca de reglas para movimientos legales;
4. integrar Stockfish local;
5. permitir asistencia por bando (`White`, `Black`, `Both`, `None`);
6. convertir la evaluación del motor en patrones de LED (fijo/lento/rápido).
