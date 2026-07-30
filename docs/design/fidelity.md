# Fidelity audit — what the genre did, and where NUMEN stands

The brief's goal is a spiritual successor to Lionhead's *Black & White* (2001), as close to the
original **in mechanics and feel** as possible.

> **Scope of this document.** Game mechanics are not copyrightable; assets, names, characters,
> dialogue and audio are. This file names the original as prior art **for mechanics only**, which
> the project's own rules permit for design docs. Nothing here licenses copying content. No name
> from those titles appears in shipped strings, filenames, UI text or metadata, and
> `tests/unit/test_conscience.gd` asserts that as a test rather than trusting good intentions.

This exists so the remaining phases have a target to work against instead of being re-guessed each
time. Ordered by how much each mechanic defined the original.

## Done

| Mechanic | NUMEN |
| --- | --- |
| A creature that learns from observation and from reward/punishment | The whole of `src/creature/mind/`. Punishment collapses `P(eat villager)` to 1.5% of baseline while food-eating rises, generalises to unseen villagers, and survives save/load |
| The hand as the only cursor — grab, drag, throw, drop | `src/hand/hand.gd`, with a trimmed-mean throw estimator |
| Gesture-drawn miracles | `$P` recogniser from the published paper, 100% on 100 synthetic strokes |
| Prayer power from worshippers, spent per cast | `src/miracles/prayer_power.gd` |
| An area of influence that gates action and grows with belief | `src/miracles/influence.gd` |
| An autonomous village with needs, jobs and buildings | `src/village/`, utility-scored, 8 → 24 population |
| Pet and slap as the teaching verbs | `Creature.pet()` / `slap()`, credited within a 6 s window |
| Leashes | Three, biasing desires without overriding learning |
| Alignment changing the creature's appearance | EMA driving a material overlay on the wolf |
| Converting a second village by belief | `src/village/conversion.gd` |
| Two conscience voices arguing over your shoulder | `src/ui/conscience.gd` — 24 topics, alignment-weighted, rate-limited three ways |
| Teaching by demonstration, as a real loop | `Creature.witness()` — perception-gated, filed under the owning desire, driven by the player's real acts. Was reachable only by accident |
| Conviction accumulating rather than arriving at once | ID3 leaves shrunk by evidence: the keystone now ramps −0.250 to −0.976 over 15 punishments instead of snapping to −1.0 on the first |

## Missing, ranked by how much it mattered to the original
1. **Consequence.** Nothing threatens the player. No raids, no rival god, no failure state. Every
   decision is therefore free, which is what makes the current build a sandbox rather than a game.
2. **Creature combat.** Creature-vs-creature fights were the original's late game and its payoff
   for having taught one well. NUMEN's mind is headless-testable, so pitting two *learned* minds
   against each other is unusually cheap here — and a genuinely novel thing to be able to test.
3. **Sacrifice and worship as player verbs.** Putting a villager on the altar for power was the
   original's sharpest moral mechanic: the cheapest prayer came at the highest cost. NUMEN has a
   village centre that counts worship but nothing the player *does* there.
4. **Picking up and moving buildings.** Rearranging a village by hand. The hand already promotes
   scenery to physics bodies; buildings are registry objects with meshes, so the machinery exists.
5. **Creature can be taught village work.** Watering fields, carrying food to the store. `water_field`
   and `give_to_village` are already in the action set and reachable, but nothing rewards them.
6. **The world reflecting alignment.** The original's landscape and architecture shifted with the
   player's morality. NUMEN tints the creature only.
7. **Miracle dispensers at worship sites.** Power localised to places rather than a global pool.
8. **Creature growth with age.** Age already decays learning rate and softmax temperature; nothing
   shows it. The creature never visibly grows up.
9. **Music that follows alignment.** The audio layer exists and is synthesised; nothing is wired.
10. **Multiple islands.** The island generator is seeded and parameterised, so mostly camera and
   save-state work.

## Deliberate divergences

- **No land sculpting.** The original's sequel had it; the first did not, and the brief describes
  the first. Not planned.
- **No voiced dialogue.** The advisors are text. Voice acting is out of scope and any imitation of
  the original's performances would cross from mechanics into content.
- **Fewer creature species.** One rigged animal, chosen from a CC0 pack. The original's roster is
  content, not mechanics.
- **The village centre doubles as storehouse and temple.** A separate perceivable temple needs a
  row in `ObjectAttributes.TRUTH`; deferred until the creature has a reason to tell them apart.

## How the remaining phases map onto this

- **Phase 8** — done. The conscience voices, an action-verified tutorial, a gesture guide, a desire
  indicator, and the audio layer finally wired.
- **Phase 10** — done ahead of Phase 9, because teaching by demonstration was the biggest gap and a
  wiring one. Confidence-weighted learning landed with it.
- **Phase 9** — next: consequence and combat. Now the top of the list.
- **Later** — sacrifice at the altar, movable buildings, the world reflecting alignment, localised
  miracle dispensers, creature growth, alignment-driven music, multiple islands.

The remaining gap that matters most is **consequence**: nothing threatens the player, so no decision
costs anything, and that is what still makes this a sandbox rather than a game.
