# Fase 9 — juego en solitario y análisis con Stockfish

Implementada en una PR apilada sobre las fases 7 y 8.

## Objetivo

Permitir crear una partida física de una persona contra Stockfish 18 utilizando el Chessnut Air. La persona elegirá jugar con blancas o negras; Stockfish controlará el otro bando.

## Experiencia prevista

1. **Nueva partida** permanece siempre visible y permite elegir entre **Contra persona** y **Contra Stockfish**.
2. Contra Stockfish se elige el color humano: **Blancas**, **Negras** o **Aleatorio**.
3. Se elige la fuerza de Stockfish mediante niveles del 1 al 20 antes de iniciar la partida.
4. Contra Stockfish se configura únicamente la ayuda del jugador; contra una persona se mantienen ayudas independientes para ambos bandos.
5. En el turno humano, el tablero funcionará como ahora: detectará la jugada física, comprobará su legalidad y aplicará la ayuda configurada.
6. En el turno de Stockfish, la app calculará una única jugada y mostrará claramente su origen y destino en la pantalla y mediante los LEDs del Chessnut.
7. La persona ejecutará físicamente esa jugada por Stockfish. La app esperará hasta reconocer la posición final correcta; no avanzará el turno por una posición parcial o distinta.
7. La jugada se guardará en SAN/PGN como cualquier otra y la partida seguirá hasta mate, tablas, abandono o cancelación.

Si la persona elige negras, Stockfish propondrá su primera jugada inmediatamente después de sincronizar la posición inicial.

## Niveles del motor

La copia fijada de Stockfish 18 ofrece dos mecanismos oficiales de limitación:

- `Skill Level`: enteros de **0 a 20**;
- `UCI_LimitStrength` junto con `UCI_Elo`: rango de **1320 a 3190 Elo**.

La interfaz expone niveles del 1 al 20. Los niveles 1 a 19 se distribuyen dentro del rango real de esta versión mediante `UCI_LimitStrength=true` y `UCI_Elo`; el nivel 20 desactiva el límite para usar Stockfish a plena potencia. Los valores se validan en la capa Swift y de nuevo en el puente nativo antes de cambiar opciones UCI.

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

- Se puede crear una partida contra Stockfish con cualquiera de los dos colores o dejar que la app lo elija al azar.
- El nivel seleccionado se conserva y llega a Stockfish dentro de su rango real.
- Stockfish propone una jugada legal en cada turno suyo.
- Origen y destino se distinguen con claridad en pantalla y tablero físico.
- Posiciones parciales no se registran como jugadas completas.
- Enroque, capturas, en passant y promociones propuestas por Stockfish se pueden ejecutar físicamente.
- Elegir negras provoca una primera jugada de Stockfish sin intervención humana.
- La reconexión y el relanzamiento de la app no duplican ni pierden la jugada pendiente.
- El resultado, la biblioteca, la reproducción y el PGN siguen funcionando en modo solitario.
- Hay tests unitarios del mapeo de niveles, de la máquina de estados y de ambos colores, además de una validación completa con Chessnut Air real.

## Análisis integrado en partidas guardadas

La antigua pantalla independiente de diagnóstico se integra en el detalle de una partida finalizada. El reproductor analiza con Stockfish cada FEN seleccionado y actualiza evaluación, mejor movimiento y una barra vertical a la izquierda del tablero.

La evaluación se normaliza siempre a la perspectiva de blancas. `+0,00` produce una barra con mitad blanca y mitad negra; las ventajas positivas o negativas aumentan suavemente el color correspondiente. Los mates son estados completos: `#3` es 100 % blanco y `#-1` es 100 % negro. Los resultados obsoletos se descartan al cambiar rápidamente de movimiento.
