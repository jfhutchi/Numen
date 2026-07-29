# NUMEN

An original god-game: you are a deity over an island, acting through a divine hand and a
creature that **genuinely learns** from what it sees you do and from how you reward or punish it.

Everything else in the game exists to make that creature matter.

> NUMEN is an original work. It stands in the lineage of the god-game genre and draws on
> *publicly documented AI techniques* — perceptrons for motivation, decision-tree induction for
> learned opinion — as prior art for **mechanics only**. No assets, names, audio, or files from
> any other game are used, referenced, or shipped here.

## Play it in your browser

**https://jfhutchi.github.io/Numen/**

Built and deployed from `main` by CI, with the test suite gating the deploy. It is a ~37 MB
download on first load. The browser build runs on WebGL 2.0 (Compatibility) and single-threaded
WASM, so it looks a little plainer and runs slower than the desktop build — see
[ADR-008](DECISIONS.md).

## Controls

| Input | Does |
| --- | --- |
| Left mouse | Grab and throw — trees, rocks, food, villagers |
| Right mouse drag | Orbit the camera |
| Wheel / Arrow keys | Zoom / pan |
| **Middle mouse drag** | Draw a miracle gesture — spiral food, chevron wood, wave water, circle heal, bolt lightning |
| **P** / **L** | Pet (reward) / slap (punish) the creature |
| **1–4** | Leash: none / learning / compassion / aggression |
| **F** / **V** | Snap the camera to the creature / the village |
| **Tab** | Toggle the Mind Inspector |
| **F5** / **F9** | Save / load |

To watch the creature learn: find it with **F**, open the inspector with **Tab**, and watch the
`opinion` figure on whatever it chose. Slap it within ~6 seconds of an action and that action's
opinion goes negative; the "Why" panel shows the exact attribute it split on.

## Status

See [PROGRESS.md](PROGRESS.md) for the phase log, real test output, known gaps, and the current
**NEXT ACTION**. Architectural choices and their rejected alternatives live in
[DECISIONS.md](DECISIONS.md); the AI is specified in
[docs/design/creature_mind.md](docs/design/creature_mind.md).

## Requirements

- **Godot 4.6.3-stable** (a `.mono` build is fine — the game is pure GDScript)
- `bash` (Git Bash on Windows) to run the CI script

## Run

Open `project.godot` in the Godot editor and press F5, or from a shell:

```bash
godot --path .
```

If `godot` is not on your `PATH`, point `GODOT_BIN` at the binary:

```bash
export GODOT_BIN="/e/Documents/Godot_v4.6.3-stable_mono_win64/Godot_v4.6.3-stable_mono_win64/Godot_v4.6.3-stable_mono_win64_console.exe"
```

On Windows use the **`_console.exe`** variant. The plain `.exe` detaches from the console and
its stdout never reaches the terminal, so test results would silently vanish.

## Test

```bash
tools/ci.sh
```

That is the whole gate: project import check, the unit and behavioural suites, and the asset
licence check. It must exit `0` on a clean clone.

To run one suite directly:

```bash
"$GODOT_BIN" --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```

All AI tests run headless — no GPU, no window — so the creature's learning can be iterated and
verified without opening the game.

## Layout

| Path | Contents |
| --- | --- |
| `src/core/` | event bus, save/load, game state, seeded RNG service |
| `src/hand/` | input, raycast, grab/throw, gesture capture |
| `src/gesture/` | `$P` point-cloud recogniser and template set |
| `src/world/` | terrain, islands, resource nodes, weather |
| `src/village/` | villager agents, needs, jobs, buildings, store |
| `src/miracles/` | miracle definitions, casting, prayer power |
| `src/creature/mind/` | beliefs, desires, opinions, learning — **the crown jewel** |
| `src/creature/body/` | locomotion, animation, actions, IK |
| `src/ui/` | HUD, Mind Inspector, debug overlays |
| `tests/unit/` | fast isolated tests |
| `tests/behavioral/` | headless simulation harness |
| `tools/` | procedural asset generators, licence checker, CI |

## Licence and assets

Third-party assets are restricted to CC0, MIT, Apache-2.0, BSD, or CC-BY, and every one is
recorded in [ATTRIBUTIONS.md](ATTRIBUTIONS.md) with its source, author, licence, and date. CI
fails if anything under `assets/third_party/` is unlogged. Most art is generated procedurally by
scripts in `tools/` — licence-clean by construction.
