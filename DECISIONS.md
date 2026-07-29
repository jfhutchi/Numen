# Architecture Decision Records

Numbered, append-only. Each records the context, the decision, what was rejected, and what it
costs us. Superseding an ADR means writing a new one that says so, not editing the old one.

---

## ADR-001 — Godot 4.6.3-stable (mono build), GDScript only

**Date:** 2026-07-29

**Context.** A Godot 4.6.3-stable **mono** build was already installed at
`E:\Documents\Godot_v4.6.3-stable_mono_win64\`. No `godot` on `PATH`. `dotnet` is present, so C#
would work if wanted.

**Decision.** Target the installed 4.6.3 mono build. Write **GDScript only**. C# is permitted
only if a profiler capture shows the creature mind or village sim is frame-budget-bound, and
only with its own ADR.

**Rejected.** Installing a separate non-mono 4.6.x — pointless, the mono build runs GDScript
projects identically and costs nothing. Starting in C# "just in case" — that is speculative
optimisation, and it would slow iteration on the one system that matters most (the mind), which
is where iteration speed is worth the most.

**Consequences.** The editor build differs from the shipping runtime flavour; harmless for a
GDScript project. CI and every headless test must invoke the **`_console.exe`** variant: on
Windows the plain `.exe` detaches from the console and its stdout never reaches the terminal,
which would silently swallow test results — exactly the failure mode the "never assert a test
passed without executing it" rule exists to prevent.

---

## ADR-002 — Vendor GUT from `main`, not from the release tag

**Date:** 2026-07-29

**Context.** GUT is the specified test framework. Its current tagged release, 9.7.1, targets
Godot **4.7.x**. Only the `main` branch supports 4.6.x, which is what we run.

**Decision.** Vendor `addons/gut` from `main` and commit it. Pin the exact commit in
`ATTRIBUTIONS.md`.

**Rejected.** Installing the 9.7.1 tag — targets the wrong engine minor and would fail or
misbehave on 4.6.3. Upgrading the project to Godot 4.7 to match the tag — churns the engine
under the project before a single line of game code exists, to satisfy a test dependency.

**Consequences.** We track an unreleased branch, so GUT could shift under us; vendoring a pinned
commit removes that risk. If GUT proves unstable on 4.6.3 the fallback is a ~40-line `SceneTree`
script runner — the AI tests are plain `RefCounted` assertions and need no framework at all. That
fallback gets its own ADR if used.

---

## ADR-003 — Build the creature mind third, not fifth

**Date:** 2026-07-29

**Context.** The original brief ordered the work World → Village → Miracles → Creature Mind. The
mind is the reason the project exists, and the brief also states items 5, 6 and 7 (creature
feedback, observable learning, persistence of learned state) are never cut.

**Decision.** Reorder to `0 → 1 (World & Hand) → 4 (Mind, headless) → 2 (Village) → 3 (Miracles)
→ 5 → 6`. Introduce a `WorldView` seam so the mind depends on an interface yielding perceived
objects, never on the live scene: `SceneWorldView` queries the real world, `MockWorldView`
fabricates objects for tests. The same mind code runs behind both.

**Rejected.** The literal brief ordering — if budget runs out before Phase 4, the defining
feature does not exist at all, and the two orderings differ *only* in that failure mode. Building
the mind against live scene nodes — would have chained the crown jewel to a renderer and made its
tests slow, flaky, and impossible to run headless.

**Consequences.** Village and miracles may land thinner. The `WorldView` indirection is a small
permanent cost paid on every perception query, and it buys headless testability of the entire
learning system — the thing the keystone acceptance test depends on.

---

## ADR-004 — No terrain, camera, or behaviour-tree addons

**Date:** 2026-07-29

**Context.** Terrain3D/HTerrain, `phantom_camera`, and LimboAI/Beehave were all pre-approved as
optional dependencies.

**Decision.** Use none of them. A `FastNoiseLite` heightmap → `ArrayMesh` + `HeightMapShape3D` is
roughly 80 lines; an orbit/zoom camera rig is roughly 60.

**Rejected.** Terrain3D/HTerrain — large dependencies, and we need exactly one scripted island
whose collision shape we want precise control over. `phantom_camera` — a whole addon for a
fixed-behaviour orbit rig. LimboAI/Beehave — the decisive one: a behaviour tree would sit
*beside* the learning layer without serving it. The mind **is** the decision-maker; bolting a
hand-authored tree next to it would blur exactly the thing the project is trying to prove.

**Consequences.** More code owned in-tree, all of it small and shaped to the game. No addon
version churn, no licence surface beyond GUT. If terrain needs ever grow past one island,
revisit with a new ADR.

---

## ADR-005 — Beliefs are per-instance but seeded from a learned per-type prior

**Date:** 2026-07-29

**Context.** The spec says the creature maintains an attribute vector for each *perceived object*.
Read strictly, that means beliefs are per-instance only.

**Decision.** Keep per-instance belief vectors, but seed each new instance from a **learned
per-type prior**, and update both the instance vector and the type prior on observation.

**Rejected.** Pure per-instance — nothing generalises. Slap the creature for eating villager #7
and it eats villager #8 with undiminished enthusiasm, because #8 is a fresh object at 0.5
uncertainty. The keystone acceptance test (punishment generalises across villagers while
`eat(food_pile)` stays untouched) is unpassable under that reading. Pure per-type — the creature
could never form an opinion about a *specific* villager, losing the individuality that makes the
creature feel like it knows your world.

**Consequences.** Two structures to serialise instead of one. Generalisation speed becomes a
tunable (how strongly the prior seeds a new instance), which is a knob that will need tuning
against feel, not just against the test.

---

## ADR-006 — ID3 attributes are binned, not threshold-split

**Date:** 2026-07-29

**Context.** ID3 induces trees over *categorical* attributes. Our object attributes are
continuous floats in `[0,1]`.

**Decision.** Bin each attribute into 3 levels (low/mid/high) at induction time, with the bin
edges exported as tunables.

**Rejected.** C4.5-style continuous threshold search — better splits, but it sorts candidate
thresholds per attribute per node, and the trees are re-induced on a schedule during play. Not
worth the cost at depth 6. Storing attributes as discrete symbols from the start — would throw
away the graded confidence that belief updating depends on.

**Consequences.** Slightly coarser trees than optimal splitting would give. Bin edges become a
tuning surface that can mask or cause learning failures, so they are exported and documented.
Revisit if a learning failure traces to binning rather than to data.

---

## ADR-007 — Pin the 3D physics backend explicitly; treat the pin as the only source of truth

**Date:** 2026-07-29

**Context.** Godot 4.6 is documented as defaulting new projects to Jolt, and we wanted to confirm
it rather than assume it. It turned out not to be confirmable from headless output:

- `ProjectSettings.get_setting("physics/3d/physics_engine")` returns the literal string
  `DEFAULT`, whose resolution is not exposed.
- `PhysicsServer3D.get_class()` returns `PhysicsServer3D` — the binding name, not the backend.
- `--verbose` startup logs say nothing about the physics backend.
- Decisively: feeding the setting a **deliberately bogus** engine name produced no error and no
  warning. So "it booted without complaining" carries zero information.

**Decision.** Pin `physics/3d/physics_engine="Jolt Physics"` explicitly in `project.godot` rather
than leaving it on `DEFAULT`, and guard the pin with
`test_physics_backend_is_pinned_explicitly`. Record in `PROGRESS.md` that Jolt being the backend
actually executing is **asserted, not observed**, to be confirmed visually in the editor's
Project Settings during the Phase 1 manual smoke run.

**Rejected.** Leaving it on `DEFAULT` — the value is undocumented at runtime and could shift with
an engine patch release, silently changing physics behaviour underneath the creature and the
Phase 1 ballistic test with nothing going red. Asserting "Jolt confirmed" on the strength of a
clean boot — the bogus-name control proves that inference is unsound, and writing it down as
confirmed would be a false claim in the project's own record.

**Consequences.** One more guarded setting. An honest gap stays open in `PROGRESS.md` until
someone eyeballs Project Settings. The Phase 1 ballistic test exercises whichever backend is
live and asserts correct behaviour regardless, so the gap does not block progress.
