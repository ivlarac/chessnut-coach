# Fase 9 — juego en solitario contra Stockfish

Esta fase se implementará después de validar y fusionar conjuntamente las fases 7 y 8. No forma parte de la PR actual.

## Objetivo

Permitir crear una partida física de una persona contra Stockfish 18 utilizando el Chessnut Air. La persona elegirá jugar con blancas o negras; Stockfish controlará el otro bando.

## Experiencia prevista

1. Al pulsar **Nueva partida**, se podrá elegir entre **Dos jugadores** y **En solitario**.
2. En solitario se elegirá el color humano: **Blancas** o **Negras**.
3. Se elegirá la fuerza de Stockfish de menor a mayor antes de iniciar la partida.
4. En el turno humano, el tablero funcionará como ahora: detectará la jugada física, comprobará su legalidad y aplicará la ayuda configurada.
5. En el turno de Stockfish, la app calculará una única jugada y mostrará claramente su origen y destino en la pantalla y mediante los LEDs del Chessnut.
6. La persona ejecutará físicamente esa jugada por Stockfish. La app esperará hasta reconocer la posición final correcta; no avanzará el turno por una posición parcial o distinta.
7. La jugada se guardará en SAN/PGN como cualquier otra y la partida seguirá hasta mate, tablas, abandono o cancelación.

Si la persona elige negras, Stockfish propondrá su primera jugada inmediatamente después de sincronizar la posición inicial.

## Niveles del motor

La copia fijada de Stockfish 18 ofrece dos mecanismos oficiales de limitación:

- `Skill Level`: enteros de **0 a 20**;
- `UCI_LimitStrength` junto con `UCI_Elo`: rango de **1320 a 3190 Elo**.

La interfaz expondrá una escala sencilla ordenada de menor a mayor, con el Elo aproximado visible. Internamente se utilizará `UCI_LimitStrength=true` y `UCI_Elo` dentro del rango real de esta versión. El nivel máximo desactivará el límite de fuerza para usar Stockfish a plena potencia. Los valores se validarán en la capa Swift y de nuevo en el puente nativo antes de cambiar opciones UCI.

La fuerza y el tiempo de respuesta son conceptos separados: habrá un límite de pensamiento adecuado para móvil para que una jugada no bloquee indefinidamente la partida.

## Modelo y persistencia

La partida guardará, además de los datos actuales:

- modo: dos jugadores o solitario;
- color humano;
- configuración de fuerza elegida;
- nombre y versión del motor;
- identidad de cada jugada como humana o generada por el motor.

El PGN utilizará el nombre del jugador y `Stockfish 18` en las cabeceras `White`/`Black`. La configuración del motor se conservará en etiquetas adicionales compatibles sin alterar la secuencia SAN estándar.

## Estados y seguridad

El controlador tendrá estados explícitos: turno humano, motor pensando, jugada del motor propuesta, ejecución física parcial y posición sincronizada. Se cancelará cualquier cálculo obsoleto al iniciar otra partida, cambiar la posición, desconectar o finalizar.

Stockfish nunca moverá automáticamente la posición lógica antes de que el Chessnut confirme que la jugada sugerida se ha ejecutado físicamente. Una jugada humana durante el turno del motor se rechazará como desincronización y la sugerencia correcta seguirá visible.

En reconexión o reapertura, si era turno de Stockfish, se reconstruirá la partida guardada y se recalculará o restaurará la sugerencia sin duplicar el movimiento.

## Criterios de aceptación

- Se puede crear una partida en solitario con cualquiera de los dos colores.
- El nivel seleccionado se conserva y llega a Stockfish dentro de su rango real.
- Stockfish propone una jugada legal en cada turno suyo.
- Origen y destino se distinguen con claridad en pantalla y tablero físico.
- Posiciones parciales no se registran como jugadas completas.
- Enroque, capturas, en passant y promociones propuestas por Stockfish se pueden ejecutar físicamente.
- Elegir negras provoca una primera jugada de Stockfish sin intervención humana.
- La reconexión y el relanzamiento de la app no duplican ni pierden la jugada pendiente.
- El resultado, la biblioteca, la reproducción y el PGN siguen funcionando en modo solitario.
- Hay tests unitarios del mapeo de niveles, de la máquina de estados y de ambos colores, además de una validación completa con Chessnut Air real.
