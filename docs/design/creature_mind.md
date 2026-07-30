# The Creature Mind

The reason this project exists. Everything else in NUMEN is here to make this matter.

This document describes what the code in `src/creature/mind/` actually does. **If the two
disagree, this document is wrong and gets fixed in the same commit as the code.**

A symbolic-connectionist hybrid: perceptrons supply motivation, decision trees supply learned
opinion, and the creature's choice is a softmax over the product. It is not a behaviour tree and
not a state machine — there is no authored plan anywhere in it.

---

## 1. Shape of a decision

```
             world ──▶ perceive ──▶ beliefs updated
                                        │
   internal state ──▶ desire perceptrons ──▶ top-K desires
                                        │
                      for each (desire, action, object):
                                        │
        score = desire_intensity × opinion_predicted × distance_falloff
                                        │
                              normalise ──▶ softmax(temperature)
                                        │
                                    sample ──▶ act
                                        │
                                  feedback ──▶ opinions + desires
```

Decisions run at `decision_hz` (5 Hz) with jitter, never per frame.

## 2. Beliefs — `belief_table.gd`

Ten attributes, all floats in `[0,1]`, in the order fixed by `object_attributes.gd`:

`nutritious, edible, wooden, heavy, alive, friendly, useful_for_building, dangerous, throwable,
mine`

Ground truth per type lives in `ObjectAttributes.TRUTH`. **The creature never reads it directly.**
It observes objects within `perception_radius`, and its belief drifts toward what it saw at
`belief_learning_rate`. Ignorance is the starting condition: everything unobserved sits at `0.5`.

**Beliefs are per instance, seeded from a learned per-type prior** (ADR-005). Both are updated on
observation, the prior more slowly (`type_prior_learning_rate`) so one strange individual does not
rewrite a whole category.

This is the single most important structural decision in the mind. Without the prior, punishment
does not generalise: slap the creature for eating villager #7 and it eats villager #8 with
undiminished enthusiasm, because #8 is a fresh object at flat uncertainty. Verified by
`test_learning_generalises_to_a_villager_it_has_never_met`.

## 3. Desires — `desires.gd`

Seven single-layer perceptrons: `Hunger, Tiredness, Anger, Compassion, Boredom, Curiosity, Fear`.

Each reads the same 7-element situation vector: hunger, fatigue, damage, food-near, villager-near,
threat-near, idle. Output is intensity in `[0,1]` through a sigmoid.

Weights start as **instinct** (`Desires.INSTINCTS`), not at zero. A newborn that had to discover
that hunger relates to eating would starve through its entire childhood, and that is not the
interesting learning. Bias starts negative so a drive sits near zero until its inputs speak up,
rather than every desire idling at 0.5 and the creature dithering.

Feedback adjusts these by the delta rule, at a rate that decays with age
(`desire_rate_age_halflife`) — young creatures swing hard on one experience, old ones barely budge.

**The nudge is deliberately small (0.15).** Desires are drives, not choices. Being slapped for
eating the wrong thing must change *what* the creature eats — which lives in its opinions — not
whether it gets hungry at all. An earlier version nudged by 0.5 and fifteen punishments
extinguished Hunger outright: the creature stopped considering food entirely and its hard-won
opinion about villagers was never consulted again.

## 4. Opinions — `id3.gd`, `opinion_store.gd`

One decision tree per `(desire, action)` pair, induced from experience by **information gain**,
mapping a believed attribute vector to the feedback the creature expects.

Actions: `eat, attack, pick_up, throw, give_to_village, water_field, heal, play_with, sleep,
follow_player, imitate, defecate, dance`. Each desire only considers a handful
(`ACTIONS_FOR_DESIRE`), which keeps candidate enumeration to a few pairs per tick instead of every
action against every object.

Two deliberate departures from textbook ID3:

1. **Attributes are binned, not categorical** (ADR-006). They are floats, so each is bucketed
   low / mid / high at induction time using `bin_low` and `bin_high`.
2. **Leaves store mean feedback, not a class label.** Splits are still chosen by information gain
   over discretised feedback classes, but the creature needs a *value* to rank options by; a bare
   good/bad label throws away the margin it needs to choose between two good options.
3. **Leaf values are shrunk toward neutral by how little evidence they rest on**, by the standard
   small-sample correction `n / (n + leaf_confidence_samples)`. At the default of 3, one experience
   carries a quarter of its face value, three carry half, ten carry three quarters.

   This is what makes the creature *persuadable* rather than programmable. Without it learning was
   one-shot: a single experience made a pure leaf, so one slap produced an opinion of exactly
   −1.0 and the creature was instantly and permanently certain. It passed the keystone test and it
   read as a light switch. The keystone now shows the opinion of eating a villager ramping
   −0.250 → −0.976 across its fifteen punishments instead of snapping to −1.0 on the first.

   Applied to the leaf **value** only, never to the split choice: information gain should see the
   evidence as it actually is, or the tree would refuse to split on genuine patterns merely because
   they are young.

Trees are capped at `max_tree_depth` (6) and experiences at `max_experiences` (200). Eviction
drops the oldest member of the **over-represented** feedback class — evicting the plain oldest
would discard the rare bad experience that actually taught the creature something, purely because
good ones are more common.

**Re-induction is scheduled** (`reinduce_every`, default 8 new examples), not per example.
Induction is the expensive part of the whole mind and one more example barely moves a tree.

### Cross-desire fallback

When a `(desire, action)` pair has no experience, prediction falls back to the mean over every
other desire's tree for the *same action*.

Knowledge of what a thing is *to do to* has to survive the motive changing. Without this, a
creature slapped for eating people while hungry would eat one out of curiosity an hour later,
because curiosity keeps its notes in a different drawer. This was a real observed failure, not a
hypothetical: the keystone test collapsed at trial 13 when punishment pushed Hunger out of the
top-K and `eat` began being evaluated under Curiosity with a blank slate.

## 5. Action selection — `mind.gd`

Each tick: compute all desire intensities, take the top `top_desires` (3), enumerate
`(action, object)` candidates within `perception_radius`, and score each as

```
score = desire_intensity × opinion_predicted × 1/(1 + distance/distance_falloff)
```

Then **normalise by the largest absolute score** and softmax-sample at the current temperature.

The normalisation matters. Scores scale with desire intensity, and punishment also nudges desires
down — so without it a well-taught creature slowly became *less* decisive: its opinion of eating
villagers stayed pinned at −1.0 while the probability of doing it crept back toward uniform,
because the entire spread was shrinking underneath it. The rescale is linear, so ranking is
unaffected and a weak desire's options still lose to a strong desire's.

Temperature falls from `start_temperature` to `end_temperature` over `temperature_halflife`.
It must be scaled to the score range (roughly `[-1,1]`); at 0.85 the creature was nearly
indifferent to everything it had learned. Note that **exploration in a young creature does not
come from temperature** — an inexperienced mind predicts 0 for everything, so the softmax is
uniform at any temperature. Temperature governs how decisively it acts on what it *does* know.

## 6. Feedback — all four sources

| Source | Method | Weight |
| --- | --- | --- |
| Explicit — pet `+1` / slap `−1` | `apply_player_feedback` | 1.0, decayed by time since the action |
| Intrinsic — hunger relieved, damage taken, villager reaction | `apply_intrinsic_feedback` | 1.0 |
| Learning by being shown (leash of learning) | `learn_from_demonstration` | `shown_weight` (0.6) |
| Learning by imitation | `learn_from_imitation` | `imitation_weight` (0.25) |

### Teaching by demonstration

The genre's central mechanic, and the closest thing the original had to a thesis: you lead the
creature somewhere, you do a thing, and it learns from having watched you. `Creature.witness()` is
the entry point and it returns whether the lesson actually landed.

Three rules, each of which was wrong in the first version and made the mechanic reachable only by
accident:

- **It must be able to see it.** A demonstration outside `perception_radius` teaches nothing.
  Previously a rock thrown on the far side of the island taught as well as one thrown at its feet,
  which made the learning leash decorative.
- **Off the leash it must be closer still** — `imitation_reach_fraction` of perception — because
  glancing over at something is not the same as being shown it.
- **The lesson is filed under the desire that owns the action** (`OpinionStore.desire_for_action`),
  so healing is recorded against Compassion. Everything used to go to Curiosity whatever it was
  about; the cross-desire fallback meant the knowledge was still reachable, but it made the Mind
  Inspector's account of *why* the creature acted a fiction.

The player's real acts teach: throwing (cruel for a villager, unremarkable for a rock), and the
miracles whose effect the creature could imitate — heal, water, lightning. Food and wood teach
nothing and are deliberately absent from `MIRACLE_LESSONS`, because the creature cannot conjure
matter and should not form an opinion about doing so.

Explicit feedback credits every action still inside `feedback_window` (6 s), scaled by how long
ago it happened. Credit assignment must have a horizon or a slap five minutes later would blame
whatever the creature happened to do first.

Every credited event also nudges the responsible desire and updates **alignment**, an exponential
moving average of the moral weight of what the creature has done. Alignment drives creature shader
parameters and villager reaction in Phase 5/6.

## 7. Persistence

`CreatureMind.to_dict()` / `from_dict()` serialise perceptron weights, decision trees, the belief
table (instances *and* type priors), the experience lists, alignment, internal state, and the RNG.

**The RNG seed and state are stored as strings.** They are 64-bit values and JSON numbers parse
back as doubles, so anything past 2^53 silently loses its low bits — a reloaded creature resumed
from a *nearly* identical generator and diverged within one or two decisions. State is restored
after seed, because assigning the seed resets the state.

Verified by `test_learned_state_roundtrips`: save, reload, and compare the chosen action over 100
seeded ticks. Not the weights on disk — the behaviour.

## 8. Testing

Everything above runs headless with no renderer, no window and no scene, through
`tests/behavioral/sim_harness.gd`. The harness's "world" is a bare `object_registry.gd` instance —
the same class the live game uses, simply not in the tree — so the mind cannot tell the difference.
That seam (ADR-003) is why the mind could be built and proven third, before villages or miracles
existed.

Probabilities are read straight off the softmax rather than sampled, so a measurement is exact
instead of buried in sampling noise.

## 9. Known gaps

- Object-less actions (`sleep`, `dance`, `defecate`) are enumerated against nearby objects rather
  than against the creature itself, which reads oddly in the inspector.
- `query_near` is a linear scan. Fine for the low hundreds of objects at 5 Hz.
