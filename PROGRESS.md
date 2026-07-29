# NUMEN — Progress Log

The contract with future sessions. Read this file top to bottom and you can resume without
re-deriving anything. The **NEXT ACTION** line at the very bottom is always current.

---

## 0. Mission

Build an original god-game whose defining feature is a creature that genuinely learns from
observation and from player reward/punishment. Everything else exists to make that creature
matter.

The deliverable is **not** a finished game. It is a repo that builds and runs at every commit, a
playable vertical slice, and enough structure that a future session resumes in one read.
Optimise for **provable working systems over surface area** — a creature that demonstrably
learns beats ten half-built subsystems.

## 1. Definition of Done — the vertical slice

In one continuous session a player can:

1. Orbit and zoom a camera over an island with terrain, water, trees, rocks.
2. Use a divine hand as the only cursor — grab, drag, throw, drop villagers, trees, rocks, food,
   with physics on held/thrown bodies.
3. Watch villagers autonomously farm, forage, build, sleep, worship, with the village's current
   need shown as a readable desire indicator.
4. Cast ≥5 miracles by mouse-drawn gesture (food, wood, water, heal, lightning), constrained to
   the area of influence and costing prayer power accrued from worshippers.
5. Command a creature — leash it, lead it to objects, give it pet (reward) and slap (punish).
6. **Observe the creature change behaviour as a direct result of that feedback**, and inspect why
   via a Mind Inspector showing desires, the chosen object, and the learned opinion behind it.
7. Save and reload — including learned state — with behaviour intact.
8. Gain belief, expand the influence ring, convert a second village.

**Cut order if time runs short:** item 8 first, then 4 down to three miracles, then 3's building
system. **Items 5, 6 and 7 are never cut.**

## 2. Environment (verified 2026-07-29)

| Fact | Value |
| --- | --- |
| Godot | `4.6.3.stable.mono.official.7d41c59c4` |
| Binary | `E:\Documents\Godot_v4.6.3-stable_mono_win64\Godot_v4.6.3-stable_mono_win64\Godot_v4.6.3-stable_mono_win64.exe` |
| CI binary | the **`_console.exe`** sibling — the plain `.exe` detaches from the console on Windows and never pipes stdout, so test output would be invisible |
| Physics | Godot 4.6 defaults new projects to Jolt — asserted in `project.godot` |
| Toolchain | `git`, `dotnet`, `winget` present; no `scoop`/`choco`; `curl` via Git Bash |
| Language | GDScript only. The mono build costs nothing and leaves C# open if a profiler ever demands it |

## 3. Phase order

Deviation from the original brief's ordering, and a deliberate one: the creature mind needs no
renderer, no terrain and no villagers — only a `WorldView` seam that yields perceived objects.
Building it **third** rather than fifth means the crown jewel is provable even if the
presentation layer runs short, which is what "never cut items 5, 6, 7" actually demands.

```
0 Scaffold ─▶ 1 World & Hand ─▶ 4 CREATURE MIND (headless) ─▶ 2 Village ─▶ 3 Miracles ─▶ 5 Body & Inspector ─▶ 6 Polish
```

| Phase | Name | Acceptance test | Status |
| --- | --- | --- | --- |
| 0 | Scaffold | `tools/ci.sh` exits 0 on a clean clone | ✅ done |
| 1 | World & Hand | thrown body lands within tolerance of ballistic prediction | ⬜ not started |
| 4 | **Creature Mind** | perceptron converges; ID3 learns pattern; **creature unlearns punished behaviour**; learned state round-trips | ⬜ not started |
| 2 | Village Sim | 20-min headless sim, pop 8 → ≥12, no deadlock/NaN, store never negative | ⬜ not started |
| 3 | Miracles & Gestures | recogniser ≥90% over ≥20 synthetic strokes per template | ⬜ not started |
| 5 | Body & Inspector | manual run demonstrating DoD items 5 and 6 | ⬜ not started |
| 6 | Alignment & Polish | DoD 1–8 demonstrable; ≥60fps @ 200 villagers | ⬜ not started |

## 4. Phase detail

### Phase 0 — Scaffold
`project.godot`, `.gitignore`, vendored `addons/gut` (from `main`; the 9.7.1 tag targets Godot
4.7, only `main` supports 4.6.x), `tools/ci.sh` running import check + test suites +
`tools/check_licenses.sh`. Docs written and committed **before any game code**.

### Phase 1 — World & Hand
`FastNoiseLite` heightmap → `ArrayMesh` + `HeightMapShape3D`. Water plane. `MultiMeshInstance3D`
trees/rocks. Physics bodies exist **only** for held, thrown, or actively simulated objects —
promoted out of the MultiMesh on grab, retired on rest. Hand: ray pick, kinematic hold, release
applying **smoothed** hand velocity (this is what makes throwing feel right and the ballistic
assertion reproducible). Seeded RNG service with named streams; seed logged.

### Phase 4 — Creature Mind (the crown jewel)
Build `tests/behavioral/sim_harness.gd` **first**, so learning is iterated without opening a
window.

- **Beliefs** — attribute vectors in `[0,1]` over `nutritious, edible, wooden, heavy, alive,
  friendly, useful_for_building, dangerous, throwable, mine`. Per-instance, but each instance is
  **seeded from a learned per-type prior**, and observation updates both. Without the prior
  nothing generalises: slap the creature for eating villager #7 and it cheerfully eats #8.
- **Desires** — single-layer perceptrons for `Hunger, Tiredness, Anger, Compassion, Boredom,
  Curiosity, Fear` over internal state + world features; delta rule, learning rate decaying with
  age.
- **Opinions** — one ID3 decision tree per `(desire, action)` over object attributes, predicting
  expected feedback. Attributes are floats, so they are **binned into 3 levels** at induction
  time (textbook ID3 is categorical — this divergence is documented in the design doc). Depth cap
  6, experience cap 200 with least-informative eviction, re-induced **on a schedule, not per
  example**.
- **Action selection** — 5 Hz jittered tick: desires → top-K → candidate `(action, object)` pairs
  in perception radius → `desire × opinion × distance_falloff` → softmax with age-decaying
  temperature. Explore early, exploit later.
- **Feedback** — all four sources: explicit pet/slap with time-decayed credit, intrinsic
  (hunger relief, damage, villager reactions), learning-by-being-shown via the leash, and
  lower-weight imitation.
- **Alignment** — EMA of moral valence, driving creature shader params and villager reaction.
- **Persistence** — weights, trees, beliefs, experience list, alignment.
- **Mind Inspector** — required deliverable, not a nice-to-have. It is how a human verifies the
  AI is real.

### Phase 2 — Village Sim
Needs by utility scoring; jobs farmer/forester/builder/breeder/priest; store with **reservations**
so concurrent claims cannot drive levels negative; house/storehouse/field/temple; growth on food
surplus + free housing. Decision ticks round-robin across frames, never all in one.

### Phase 3 — Miracles, Gestures, Belief
`$P` point-cloud recogniser written from the published algorithm (not copied from licensed
source). spiral=food, chevron=wood, zigzag=water, circle=heal, bolt=lightning. Prayer power
accrues from worshippers; influence ring gates casting and grows with belief.

### Phase 5 — Body & Feedback Loop
Locomotion, animation state machine, three leashes (learning/compassion/aggression), pet/slap with
clear visual + audio response, Mind Inspector UI.

### Phase 6 — Alignment, Save/Load, Second Village, Polish
Conversion, win condition, HUD, audio, perf.

## 5. Standing rules

- Repo runnable at every phase boundary. No phase starts with the previous one's test red.
- **Never assert a test passed without executing it.** Real pasted output only.
- Conventional commits at phase boundaries; small and atomic.
- No magic numbers in AI code — tunables live in an exported `Resource`.
- All gameplay randomness routes through the seeded RNG service so behavioural tests reproduce.
- `docs/design/creature_mind.md` stays in sync with the code. If they diverge, the doc is wrong
  and gets fixed in the same commit.
- Third-party assets: CC0/MIT/Apache-2.0/BSD/CC-BY only, logged in `ATTRIBUTIONS.md` in the same
  commit. Unverifiable in two minutes → discard, generate a procedural placeholder.
- No files, names, or assets from any other studio's game, in strings, filenames, or metadata.

## 6. Phase log

### Phase 0 — Scaffold — ✅ done (2026-07-29)

Docs committed before any game code (`5f1c1b6`). GUT vendored from `main` at commit
`c80954f4` (version 9.6.1 — the 9.7.1 tag targets Godot 4.7 and would not run here). Repo
structure, `project.godot`, boot scene, `tools/ci.sh`, `tools/check_licenses.sh`.

**Both CI gates were verified in both directions** — a check that cannot go red is worthless:

| Gate | Green case | Red case |
| --- | --- | --- |
| `check_licenses.sh` | empty tree → `exit 0`; planted file with a logged parent dir → `exit 0` | planted unattributed file → `FAIL: assets/third_party/_probe/unlogged.png has no entry`, `exit 1` |
| `ci.sh` tests | clean suite → `exit 0` | planted failing test → `Failing Tests 1`, `FAIL: gut exited 1`, `exit 1` |

Real output of `tools/ci.sh` on a clean tree (ANSI stripped):

```
== NUMEN CI ==
godot: .../Godot_v4.6.3-stable_mono_win64_console.exe
4.6.3.stable.mono.official.7d41c59c4

-- licences --
licences: 0 third-party file(s) checked, all attributed

-- import check --
WARNING: ObjectDB instances leaked at exit (run with --verbose for details).
   at: cleanup (core/object/object.cpp:2663)
import: ok

-- tests --
---  GUT  ---
Godot version:  4.6.3
GUT version:  9.6.1

res://tests/unit/test_project_config.gd
* test_main_scene_is_the_configured_entry_point
* test_main_scene_loads_and_instantiates
* test_physics_backend_is_pinned_explicitly
* test_boot_report_is_populated
4/4 passed.

Totals
------
Scripts               1
Tests                 4
Passing Tests         4
Asserts               7
Time              0.638s

---- All tests passed! ----

== CI OK ==
```

## 7. Known issues

- **The active 3D physics backend cannot be confirmed from headless output.** Godot 4.6 exposes
  no runtime identifier for it: `ProjectSettings` reports the literal string `DEFAULT`,
  `PhysicsServer3D.get_class()` returns the binding name `PhysicsServer3D`, and `--verbose`
  startup says nothing. Worse, feeding it a **deliberately bogus** engine name produced no error
  or warning at all — so "it started without complaining" proves nothing. We therefore pin
  `physics/3d/physics_engine="Jolt Physics"` explicitly and guard the pin with
  `test_physics_backend_is_pinned_explicitly`. The pin is the source of truth; that Jolt is the
  one actually executing is *asserted, not yet observed*. Confirm visually in the editor's
  Project Settings during the Phase 1 manual smoke run.
- `--import` emits `ObjectDB instances leaked at exit` on a cold cache. Benign Godot headless
  behaviour, exit code is 0. Noted so nobody chases it later.
- `--quit` is **not** sufficient as an import check: it imports resources but does not register
  script `class_name`s, so GUT aborts with "Some GUT class_names have not been imported".
  `tools/ci.sh` uses `--import`.

---

**NEXT ACTION:** Begin Phase 1 (World & Hand): `src/core/rng.gd` seeded RNG service, then
`src/world/island.gd` (FastNoiseLite heightmap → `ArrayMesh` + `HeightMapShape3D`), water plane,
MultiMesh trees/rocks, orbit/zoom camera, and `src/hand/hand.gd` grab/throw. Acceptance test:
headless assertion that a thrown body lands within tolerance of a ballistic prediction.
