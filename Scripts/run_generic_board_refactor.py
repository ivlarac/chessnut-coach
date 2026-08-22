from pathlib import Path

script = Path("Scripts/apply_generic_board_refactor.py")
source = script.read_text()
lines = source.splitlines()
fixed = False

for index, line in enumerate(lines):
    stripped = line.strip()
    if 'Text("Las ayudas por LED no están disponibles con el tablero conectado actualmente.")' in line and stripped.startswith('"') and stripped.endswith('",'):
        body = stripped[1:-2]
        lines[index] = line[: len(line) - len(line.lstrip())] + repr(body) + ","
        fixed = True

if not fixed:
    raise RuntimeError("Expected temporary quoting issue was not found")

source = "\n".join(lines) + "\n"
exec(compile(source, str(script), "exec"), {"__name__": "__main__"})
