# Chessnut Coach

Aplicación nativa para iOS orientada a partidas OTB con un Chessnut Air y futuras ayudas de motor mediante los LEDs físicos del tablero.

## Estado actual: fase 3 — ayuda por bando y patrones LED

La base de hardware y seguimiento OTB ya se ha validado con un Chessnut Air real:

- conexión Bluetooth LE correcta;
- recepción de la posición física en tiempo real;
- LEDs individuales y parpadeo por software correctos;
- mapeo físico confirmado: `(0,0)=a8`, `(0,7)=h8`, `(7,0)=a1`, `(7,7)=h1`;
- posición lógica independiente de los estados físicos temporales;
- detección de pieza levantada y destinos legales;
- confirmación de movimientos y cambio de turno;
- historial completo de jugadas en memoria;
- capturas, enroque, en passant, promociones y finales de partida.

La fase 3 añade la infraestructura de ayuda visual previa a Stockfish:

- configuración independiente para blancas y negras;
- tres modos por bando: **Sin ayuda**, **Movimientos legales** y **Calidad simulada**;
- `Sin ayuda`: levantar una pieza no ilumina destinos;
- `Movimientos legales`: todos los destinos legales quedan encendidos de forma fija;
- `Calidad simulada`: los destinos se reparten de forma determinista entre tres patrones para validar el hardware y la interfaz;
- patrón fijo = futura jugada **mejor**;
- parpadeo lento = futura jugada **jugable**;
- parpadeo rápido = futura jugada **a evitar**;
- composición simultánea de los tres patrones en un único frame BLE cada 250 ms;
- cambio de modo en caliente mientras una pieza permanece levantada;
- prueba diagnóstica directa en `a1`, `b1` y `c1`.

La clasificación de calidad de esta fase **no es ajedrecística**. Todavía no hay Stockfish: la asignación es deliberadamente simulada para validar selección por bando, temporización y estabilidad BLE antes de conectar el motor.

## Requisitos

- Xcode 26 o compatible con Swift 6.
- iPhone/iPad con iOS 16 o posterior.
- Chessnut Air. Air+, Go y Pro deberían usar el mismo perfil BLE `classic`.
- Un Apple ID es suficiente para instalar la aplicación en un dispositivo propio mediante el *Personal Team* gratuito de Xcode.

## Ejecutar en un iPhone

1. Clona este repositorio o actualiza tu copia local.
2. Para probar la fase 3 antes del merge, cambia a `feature/assistance-led-patterns`.
3. Abre `ChessnutCoach.xcodeproj` en Xcode.
4. Espera a que Swift Package Manager descargue `EasyLinkSwiftSDK` y `ChessKit`.
5. En **Signing & Capabilities**, selecciona tu *Personal Team* si Xcode lo solicita.
6. Conecta el iPhone al Mac y selecciónalo como destino.
7. Cierra otras apps que puedan estar conectadas al Chessnut Air.
8. Enciende el Chessnut Air, coloca las piezas en posición inicial y ejecuta la app.

## Prueba de fase 3

### 1. Controlador simultáneo de patrones

Con el tablero conectado, pulsa **Probar fijo + lento + rápido**:

- `a1` debe permanecer encendida fija;
- `b1` debe parpadear lentamente;
- `c1` debe parpadear claramente más rápido;
- los tres comportamientos deben coexistir sin que la lectura de piezas se bloquee.

Pulsa **Apagar todos los LEDs** al terminar.

### 2. Ayuda independiente por color

Configura:

- Blancas: **Calidad simulada**;
- Negras: **Sin ayuda**.

Levanta una pieza blanca con movimientos legales: deben aparecer LEDs con los patrones de calidad simulada. Completa la jugada y, en el turno negro, levanta una pieza negra: no debe encenderse ningún destino.

Después invierte la configuración para comprobar el caso contrario.

### 3. Movimientos legales

Selecciona **Movimientos legales** para uno de los bandos. Al levantar una pieza de ese color, todos sus destinos legales deben quedar encendidos de forma fija, sin parpadeo.

### 4. Cambio en caliente

Con una pieza levantada y los LEDs visibles, cambia el modo de ayuda de ese mismo bando. Los LEDs deben actualizarse sin tener que devolver primero la pieza a su casilla.

### 5. Regresión OTB

Comprueba que siguen funcionando:

1. `e2-e4` y cambio de turno;
2. historial de jugadas;
3. una captura sencilla;
4. nueva partida;
5. rendición o tablas por acuerdo.

## Cómo funcionan los patrones

El Chessnut Air sólo dispone de LEDs monocromos, así que la aplicación codifica categorías mediante tiempo:

- **fijo**: siempre encendido;
- **lento**: 750 ms encendido / 750 ms apagado;
- **rápido**: 250 ms encendido / 250 ms apagado.

No se crean tareas BLE independientes por casilla. Un único controlador calcula qué casillas deben estar encendidas en cada tick y envía una matriz completa al tablero. Esto evita carreras entre patrones y permite mantener una casilla fija mientras otras parpadean a distintas velocidades.

## Modelo físico y lógico

El Chessnut envía posiciones físicas que pueden ser transitorias o ilegales mientras una mano mueve piezas. La aplicación conserva por separado:

- **posición física**: lectura actual del tablero;
- **posición lógica**: última posición legal confirmada.

Sólo cuando la posición física coincide con una transición legal completa se modifica la partida lógica y se añade una entrada al historial. Levantar una pieza puede disparar ayuda visual, pero nunca modifica por sí mismo la posición lógica.

## Pruebas automáticas

CI compila la app para iOS Simulator y ejecuta los tests del núcleo. Además de las reglas de la fase 2, la fase 3 comprueba:

- selección independiente de ayuda para blancas y negras;
- modo de movimientos legales exclusivamente con LEDs fijos;
- clasificación simulada determinista en fijo/lento/rápido;
- composición temporal de patrones sin perder los LEDs fijos.

## Dependencias

- [EasyLinkSwiftSDK](https://github.com/NSStudent/EasyLinkSwiftSDK): Bluetooth, FEN físico, batería y control de LEDs.
- [ChessKit](https://github.com/chesskit-app/chesskit-swift): posición lógica y reglas de ajedrez.

## Roadmap inmediato

1. **Fase 2**: base de partida completa y tests — completada y validada físicamente.
2. **Fase 3**: ayuda por bando y controlador de patrones LED fijo/lento/rápido con calidades simuladas — en curso.
3. **Fase 4**: Stockfish 18 local.
4. **Fase 5**: evaluación real de destinos con Stockfish y clasificación de calidad.
5. **Fase 6**: persistencia de partidas, eliminación y exportación PGN.
6. **Fase 7**: interfaz final e icono de aplicación.
