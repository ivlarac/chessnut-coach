# Chessnut Coach

PoC nativa para iOS orientada a partidas OTB con un Chessnut Air y futuras ayudas de motor mediante los LEDs físicos del tablero.

## Estado actual: PoC OTB con reglas

La base de hardware ya se ha validado con un Chessnut Air real:

- conexión Bluetooth LE correcta;
- recepción de la posición física en tiempo real;
- LEDs individuales correctos;
- parpadeo por software correcto;
- mapeo físico confirmado:
  - `(rankIndex: 0, fileIndex: 0)` = `a8`;
  - `(0,7)` = `h8`;
  - `(7,0)` = `a1`;
  - `(7,7)` = `h1`.

La versión `0.0.2` añade la primera lógica de partida:

- posición lógica independiente de las posiciones físicas temporales;
- reglas legales mediante ChessKit;
- detección de la pieza levantada del jugador que tiene el turno;
- iluminación automática de todos sus destinos legales;
- detección del movimiento final comparando el tablero físico con todas las transiciones legales posibles;
- cambio de turno al completar un movimiento legal;
- visualización del último movimiento y de las posiciones física/lógica;
- tratamiento de estados intermedios de capturas, enroque y en passant sin avanzar prematuramente la partida.

Todavía **no** incluye Stockfish ni clasificación de las jugadas por calidad. La promoción de peones queda fuera de esta fase inicial.

## Requisitos

- Xcode 26 o compatible con Swift 6.
- iPhone/iPad con iOS 16 o posterior.
- Chessnut Air. Air+, Go y Pro deberían usar el mismo perfil BLE `classic`.
- Un Apple ID es suficiente para instalar la aplicación en un dispositivo propio mediante el *Personal Team* gratuito de Xcode.

## Ejecutar en un iPhone

1. Clona este repositorio y cambia a la rama `poc/chessnut-air-ble` mientras la PR #1 siga abierta.
2. Abre `ChessnutCoach.xcodeproj` en Xcode.
3. Espera a que Swift Package Manager descargue `EasyLinkSwiftSDK` y `ChessKit`.
4. En **Signing & Capabilities**, selecciona tu *Personal Team* si Xcode lo solicita.
5. Conecta el iPhone al Mac y selecciónalo como destino.
6. Cierra Chessnut Next, White Pawn, ChessFlow u otras apps que puedan mantener una conexión BLE con el tablero.
7. Enciende el Chessnut Air y coloca las 32 piezas en la posición inicial.
8. Ejecuta `ChessnutCoach` en el iPhone, acepta Bluetooth y pulsa **Conectar**.

## Prueba de la partida

Con el tablero en la posición inicial:

1. La app debe mostrar **Turno: Blancas** y **Tablero: Sincronizado**.
2. Levanta el peón de `e2`.
3. Deben encenderse físicamente únicamente `e3` y `e4`.
4. Vuelve a dejarlo en `e2`: los LEDs deben apagarse y la partida no debe avanzar.
5. Levanta otra vez `e2` y colócalo en `e4`.
6. La app debe registrar `e4`, apagar los LEDs y cambiar a **Turno: Negras**.
7. Levanta el caballo negro de `g8`: en esa posición deben iluminarse sus destinos legales (`f6` y `h6`).

También puedes probar un movimiento ilegal colocando una pieza en una casilla que no sea uno de sus destinos. La posición lógica no debe avanzar y la app debe pedir que se corrija el tablero.

## Cómo funciona

El Chessnut envía una posición física nueva cada vez que se levanta o coloca una pieza. Esos estados intermedios no son necesariamente posiciones de ajedrez legales, por lo que la app **no los toma directamente como estado de la partida**.

En su lugar mantiene dos estados:

- **posición física**: lo que detecta el Chessnut en este instante;
- **posición lógica**: la última posición de ajedrez legal confirmada.

Cuando se levanta una pieza del color que tiene el turno, ChessKit calcula sus destinos legales y esos destinos se envían a los LEDs. Cuando la posición física final coincide con el resultado de un movimiento legal completo, ese movimiento se confirma y cambia el turno.

Esta separación permite manejar correctamente el orden físico de una captura (retirar primero la pieza capturada o levantar primero la atacante) y prepara el terreno para el enroque y en passant.

## Dependencias

- [EasyLinkSwiftSDK](https://github.com/NSStudent/EasyLinkSwiftSDK): Bluetooth, FEN físico, batería y control de LEDs.
- [ChessKit](https://github.com/chesskit-app/chesskit-swift): posición lógica y reglas de ajedrez.

## Siguiente fase

1. validar esta lógica con varias partidas reales y ajustar estados intermedios;
2. añadir soporte explícito de promoción;
3. integrar Stockfish local;
4. permitir asistencia por bando (`White`, `Black`, `Both`, `None`);
5. evaluar los destinos de la pieza levantada;
6. convertir la evaluación en patrones de LED, por ejemplo fijo / lento / rápido.
