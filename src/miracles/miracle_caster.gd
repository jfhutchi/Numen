class_name MiracleCaster
extends RefCounted
## The rules of casting: is it a real miracle, is it in reach, can you afford it.
##
## Holds no world. The effect is a Callable set by whoever owns the world — in
## game, `caster.bind_effects(MiracleEffects.new(registry, rng))`; in a test,
## nothing at all, or a closure that just records what it was asked to do. That
## is what lets every rule below be proved without a scene.
##
## Refusals are returned rather than thrown, and they carry a sentence a player
## could actually read. "Nothing happened" is the worst outcome a god game can
## give someone learning what its gestures mean.

## Emitted after a successful cast, once the effect has been applied, with the
## same dictionary try_cast returns.
signal cast_performed(result: Dictionary)
## Emitted when a cast was refused. Carries the reason, for the HUD to say so.
signal cast_refused(result: Dictionary)

var power: PrayerPower
var influence: Influence
var library: MiracleLibrary

## Called as `effect_handler.call(miracle, at)` after the power is spent, and
## whatever it returns is placed in the result under "effect". Left invalid by
## default so the caster is useful with no world attached.
var effect_handler: Callable = Callable()

## Keeps the effects object alive — see bind_effects().
var _effect_owner: RefCounted = null


func _init(
	prayer: PrayerPower = null,
	ring: Influence = null,
	miracles: MiracleLibrary = null,
	handler: Callable = Callable()
) -> void:
	power = prayer if prayer != null else PrayerPower.new()
	influence = ring if ring != null else Influence.new()
	library = miracles if miracles != null else MiracleLibrary.new()
	effect_handler = handler


## Attempts a cast. Returns {ok, reason, ...}; on refusal nothing is spent and
## nothing is applied.
##
## The checks run id, then reach, then cost. Reach before cost because being
## outside the ring is the one the player can fix immediately, and reporting the
## cost first would have them wait for power only to be refused a second time for
## a reason that was already true.
func try_cast(miracle_id: StringName, at: Vector3) -> Dictionary:
	var miracle: Miracle = library.by_id(miracle_id)
	if miracle == null:
		return _refuse(miracle_id, at, "unknown miracle: %s" % miracle_id)

	if influence != null and not influence.contains(at):
		return _refuse(miracle_id, at, "that is outside your influence")

	# The affordability check and the spend are one call. Asking "can I afford
	# it" and then spending separately is where a refunded-but-still-cast bug
	# lives; spend() is all-or-nothing and mutates nothing when it says no.
	if power != null and not power.spend(miracle.prayer_cost):
		return _refuse(miracle_id, at, "not enough prayer power: %.1f of %.1f needed" % [
			power.current(), miracle.prayer_cost
		])

	var result: Dictionary = {
		"ok": true,
		"reason": "",
		"id": miracle.id,
		"miracle": miracle,
		"at": at,
		"cost": miracle.prayer_cost,
		"alignment_weight": miracle.alignment_weight,
		"remaining": power.current() if power != null else 0.0,
		"effect": null,
	}
	if effect_handler.is_valid():
		result["effect"] = effect_handler.call(miracle, at)
	# Emitted after the effect, so a listener that inspects the world sees the
	# world the miracle left behind rather than the one before it.
	cast_performed.emit(result)
	return result


## Casts whatever miracle the recognised gesture template is bound to.
##
## Takes a template *name*, never raw points. The recogniser stays out of this
## module's dependency graph entirely, so a change to how gestures are scored
## cannot break the economy, and the economy's tests need no gesture data.
func cast_from_gesture(template_name: StringName, at: Vector3) -> Dictionary:
	var miracle: Miracle = library.by_gesture(template_name)
	if miracle == null:
		return _refuse(&"", at, "no miracle is bound to the gesture '%s'" % template_name)
	return try_cast(miracle.id, at)


## Points the caster at a world, and holds on to it.
##
## The holding is the point. A Callable made from a method stores only an object
## id, so `caster.effect_handler = MiracleEffects.new(registry, rng).apply` leaves
## the effects object with no owner: it is freed on the spot and every miracle
## afterwards costs power and silently does nothing, with no error anywhere.
func bind_effects(effects: MiracleEffects) -> void:
	_effect_owner = effects
	effect_handler = effects.apply if effects != null else Callable()


## What a cast would cost, or -1 when the id is unknown. For the UI to grey a
## miracle out before the player wastes a gesture on it.
func cost_of(miracle_id: StringName) -> float:
	var miracle: Miracle = library.by_id(miracle_id)
	return miracle.prayer_cost if miracle != null else -1.0


func can_afford(miracle_id: StringName) -> bool:
	var cost: float = cost_of(miracle_id)
	return cost >= 0.0 and (power == null or power.current() >= cost)


func _refuse(miracle_id: StringName, at: Vector3, reason: String) -> Dictionary:
	var result: Dictionary = {
		"ok": false,
		"reason": reason,
		"id": miracle_id,
		"miracle": null,
		"at": at,
		"cost": 0.0,
		"alignment_weight": 0.0,
		"remaining": power.current() if power != null else 0.0,
		"effect": null,
	}
	cast_refused.emit(result)
	return result
