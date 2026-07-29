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
| 1 | World & Hand | thrown body lands within tolerance of ballistic prediction | ✅ done |
| 4 | **Creature Mind** | perceptron converges; ID3 learns pattern; **creature unlearns punished behaviour**; learned state round-trips | ✅ done |
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

### Phase 1 — World & Hand — ✅ done (2026-07-29)

Seeded RNG service with independent named streams; procedural island (noise heightmap → ArrayMesh
+ `HeightMapShape3D`); MultiMesh scenery; orbit/zoom camera; divine hand with proximity grab,
kinematic carry and smoothed-velocity throw. World object registry added early because it is the
same seam the creature's perception will read in Phase 4.

**Acceptance test — thrown body vs. closed-form ballistics:**

```
* test_thrown_body_follows_a_ballistic_arc
    predicted landing: (20.35825, 0.5, -9.04811)
    measured  landing: (20.2555, 0.5, -9.002449)
    horizontal error : 0.1124 m (tolerance 0.40 m)
* test_thrown_body_comes_to_rest_on_the_ground
    resting position: (27.23427, 0.499992, -12.1041) (vy 0.0000)
2/2 passed.
```

Full suite: `Scripts 6 | Tests 38 | Passing Tests 38 | Asserts 207 | Time 8.699s | CI OK`.

**Manual smoke run:** `docs/captures/phase1_island.png` — island with grass, sand shoreline, rock
outcrop, scattered trees and rocks, water, HUD. Boot log reports `Vulkan 1.4.341 - Forward+`.

**Three bugs worth remembering, because of how each was caught:**

1. *The terrain was invisible and no test noticed.* Triangle winding was reversed, so the whole
   island was culled as backfaces — and `generate_normals()` had pointed every normal at the sea
   floor, so what did show was lit by ambient only. Eight passing island tests said nothing;
   a screenshot found it in one look. Now guarded by `test_ground_normals_point_up`. **Geometry
   needs an eye on it, or an invariant that stands in for one.**
2. *Vertex colours washed out.* The renderer consumes vertex colours as linear, so sRGB numbers
   handed over directly rendered pale — the rock band looked like snow. Fixed with
   `srgb_to_linear()` at the point of authoring.
3. *Throw smoothing did not actually reject jitter.* Displacement-over-window only divides an
   outlier by the window length; one stray frame still read as 60 m/s sideways. Replaced with a
   trimmed mean that discards the single fastest sample — a 300 m/s spike now leaves the estimate
   at exactly `(10, 0, 0)`.

### Phase 4 — Creature Mind — ✅ done (2026-07-29) — **the keystone**

Full §5 spec implemented in `src/creature/mind/`, documented in
[docs/design/creature_mind.md](docs/design/creature_mind.md), and proven headless through
`tests/behavioral/sim_harness.gd`.

**Keystone acceptance test — real trial-by-trial output:**

```
baseline  P(eat villager)=0.1250  P(eat food_pile)=0.1250
trial | P(eat villager) | P(eat food_pile) | opinion(villager) | opinion(food)
    1 |          0.0016 |           0.5607 |            -1.000 |        0.850
    2 |          0.0016 |           0.5607 |            -1.000 |        0.850
    ...  (trials 3-14 identical)
   15 |          0.0016 |           0.5607 |            -1.000 |        0.850
final     P(eat villager)=0.0016 (1.2% of baseline)
final     P(eat food_pile)=0.5607 (448.5% of baseline)

* test_learning_generalises_to_a_villager_it_has_never_met
    opinion of eating a never-before-seen villager: -1.000
* test_learned_state_roundtrips
    first 6 original: ["eat:food_pile", "eat:food_pile", "eat:food_pile", "give_to_village:villager", ...]
    first 6 restored: ["eat:food_pile", "eat:food_pile", "eat:food_pile", "give_to_village:villager", ...]
6/6 passed.
```

Punishment collapsed villager-eating to **1.2% of baseline** (target: under 10%) while food-eating
*rose* to 448% — the aversion stayed specific. Learned opinions separate cleanly at −1.000 vs
+0.850, generalise to a villager never encountered, and reproduce 100 seeded ticks exactly across
a save/load cycle.

Primitives: `converged after 2568 epochs (worst error 0.0500)`; ID3 held-out `high=1.000
low=-1.000`. Full suite: `Scripts 8 | Tests 54 | Passing Tests 54 | Asserts 243 | Time 9.419s`.

**Four bugs, each of which the naive version would have shipped:**

1. *The creature forgot at trial 13.* Punishment pushed Hunger out of the top-K desires, so `eat`
   began being evaluated under Curiosity — which had a blank slate, because trees are per
   `(desire, action)`. Opinions snapped to 0.000 and the collapse reversed. Fixed with a
   cross-desire fallback: knowledge of what a thing is *to do to* survives the motive changing.
2. *Punishment was extinguishing the drive itself.* Reinforcing desires at 0.5 per event meant
   fifteen slaps stopped the creature being hungry at all. Desires are drives, not choices —
   nudge reduced to 0.15.
3. *A well-taught creature grew less decisive over time.* Scores scale with desire intensity, and
   punishment also nudges desires down, so the whole spread shrank: opinion stayed pinned at
   −1.0 while P crept back from 0.0088 toward uniform. Fixed by normalising scores before the
   softmax, making temperature scale-invariant.
4. *Save/load diverged after one decision.* RNG seed and state are 64-bit; JSON numbers parse back
   as doubles and silently drop the low bits. Stored as strings now.

Also: softmax temperature had to be recalibrated from 0.85 to 0.30. With opinions in `[-1,1]` the
creature was nearly indifferent to everything it knew. Exploration in a young creature does not
come from temperature anyway — a blank mind predicts 0 for everything, so the softmax is uniform
regardless.

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
- **MultiMesh instance data cannot be read back under `--headless`.** The dummy renderer discards
  it, so `get_instance_transform()` always returns identity — verified in isolation, it is not a
  bug in our code. `src/world/scatter.gd` therefore keeps its own authoritative transforms and
  treats the MultiMesh as write-only. Better at runtime too, since reading back from the
  rendering server stalls. **Do not write tests that read MultiMesh state.**
- Autoload singletons must not be referenced by their global identifier (`World`, `Rng`) in
  scripts that tests load directly — GDScript resolves them at compile time and the script fails
  to compile wherever the autoload is not registered. Use `get_node(^"/root/World")`.
- Detached props are parented to the hand's parent, not `get_tree().current_scene`, which is null
  outside a booted game.
- Thrown props stay as `RigidBody3D` after they come to rest rather than being reabsorbed into
  the MultiMesh. Harmless at this scale; revisit if a player can litter the island with hundreds.

---

**NEXT ACTION:** Begin Phase 5 — creature body and Mind Inspector, so the learning proven in
Phase 4 becomes visible in play. Build `src/creature/body/creature.gd` (CharacterBody3D,
locomotion, animation states) driving `CreatureMind` on a 5 Hz jittered tick; wire pet/slap input
in `src/hand/hand.gd` to `mind.apply_player_feedback(+1/-1)`; add the three leashes; then
`src/ui/mind_inspector.gd` showing live desire bars, the chosen `(action, object)` with its score,
the decision path from `opinions.decision_path()`, and `mind.recent_feedback()` as a scrolling
log. Everything it needs is already exposed — `CreatureMind.last_options()`, `last_choice()`,
`recent_feedback()`. Acceptance: manual run demonstrating DoD items 5 and 6.

After that, Phase 2 (village), then Phase 3 (miracles), then Phase 6.
