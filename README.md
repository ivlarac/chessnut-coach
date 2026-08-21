# Chessnut Coach

Aplicación nativa para iOS orientada a partidas OTB con un Chessnut Air y futuras ayudas de motor mediante los LEDs físicos del tablero.

## Estado actual: fase 2 — base de partida

La base de hardware y seguimiento OTB ya se ha validado con un Chessnut Air real:

- conexión Bluetooth LE correcta;
- recepción de la posición física en tiempo real;
- LEDs individuales y parpadeo por software correctos;
- mapeo físico confirmado: `(0,0)=a8`, `(0,7)=h8`, `(7,0)=a1`, `(7,7)=h1`;
- posición lógica independiente de los estados físicos temporales;
- detección de pieza levantada y destinos legales;
- confirmación de movimientos y cambio de turno.

La versión `0.0.3` añade la base de una partida completa:

- `GameRecord` con fecha de inicio/fin, estado y resultado;
- historial completo de jugadas en memoria;
- SAN, LAN, origen/destino, FEN antes/después y fecha por jugada;
- finales automáticos por jaque mate y tablas detectadas por ChessKit;
- abandono, tablas acordadas y cancelación manual;
- promoción física a dama, torre, alfil o caballo;
- promoción directa o en dos pasos (peón a octava y posterior sustitución física);
- historial visible durante la partida;
- pruebas automáticas de reglas y transiciones especiales.

La persistencia entre ejecuciones, el historial de partidas terminadas, el PGN y Stockfish pertenecen a fases posteriores.

## Requisitos

- Xcode 26 o compatible con Swift 6.
- iPhone/iPad con iOS 16 o posterior.
- Chessnut Air. Air+, Go y Pro deberían usar el mismo perfil BLE `classic`.
- Un Apple ID es suficiente para instalar la aplicación en un dispositivo propio mediante el *Personal Team* gratuito de Xcode.

## Ejecutar en un iPhone

1. Clona este repositorio o actualiza tu copia local.
2. Para probar esta fase, cambia a `feature/game-session-foundation` mientras la PR #2 siga abierta.
3. Abre `ChessnutCoach.xcodeproj` en Xcode.
4. Espera a que Swift Package Manager descargue `EasyLinkSwiftSDK` y `ChessKit`.
5. En **Signing & Capabilities**, selecciona tu *Personal Team* si Xcode lo solicita.
6. Conecta el iPhone al Mac y selecciónalo como destino.
7. Cierra otras apps que puedan estar conectadas al Chessnut Air.
8. Enciende el Chessnut Air, coloca las piezas en posición inicial y ejecuta la app.

## Prueba básica de regresión

1. Conecta el tablero: debe mostrar **Turno: Blancas** y **Sincronizado**.
2. Levanta `e2`: deben encenderse únicamente `e3` y `e4`.
3. Devuelve el peón a `e2`: los LEDs deben apagarse sin registrar jugada.
4. Juega `e2-e4`: debe aparecer `1. e4` en el historial y pasar a negras.
5. Levanta `g8`: deben iluminarse `f6` y `h6`.
6. Completa varias jugadas y comprueba que el historial se conserva en orden.
7. Prueba **Rendirse** o **Tablas por acuerdo** y confirma que el resultado se fija y dejan de aceptarse nuevas jugadas.

## Promoción

Cuando un peón llega a la última fila hay dos flujos válidos:

- sustituirlo directamente por dama, torre, alfil o caballo al completar el movimiento;
- dejar primero el peón en la última fila y sustituirlo después.

En el segundo caso la jugada permanece pendiente y la casilla de promoción queda iluminada hasta que el Chessnut reconozca la nueva pieza. La jugada se registra únicamente cuando la promoción está completa.

## Cómo funciona

El Chessnut envía posiciones físicas que pueden ser transitorias o ilegales mientras una mano mueve piezas. La aplicación conserva por separado:

- **posición física**: lectura actual del tablero;
- **posición lógica**: última posición legal confirmada.

Sólo cuando la posición física coincide con una transición legal completa se modifica la partida lógica y se añade una entrada al historial. Esto permite tolerar el orden físico de capturas y movimientos especiales sin corromper el estado de la partida.

## Pruebas automáticas

La PR ejecuta pruebas en un simulador iOS para cubrir, entre otros casos:

- `e2-e4` y cambio de turno;
- pieza levantada y destinos legales;
- rechazo de movimientos ilegales;
- capturas;
- enroque;
- en passant;
- promoción directa y en dos pasos;
- jaque mate;
- tablas por material insuficiente;
- abandono y tablas acordadas.

## Dependencias

- [EasyLinkSwiftSDK](https://github.com/NSStudent/EasyLinkSwiftSDK): Bluetooth, FEN físico, batería y control de LEDs.
- [ChessKit](https://github.com/chesskit-app/chesskit-swift): posición lógica y reglas de ajedrez.

## Roadmap inmediato

1. **Fase 2**: base de partida completa y tests — PR #2.
2. **Fase 3**: ayuda por bando y controlador de patrones LED fijo/lento/rápido con calidades simuladas.
3. **Fase 4**: Stockfish 18 local.
4. **Fase 5**: evaluación real de destinos con Stockfish y clasificación de calidad.
5. **Fase 6**: persistencia de partidas, eliminación y exportación PGN.
6. **Fase 7**: interfaz final e icono de aplicación.
