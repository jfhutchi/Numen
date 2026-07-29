class_name VillageStore
extends RefCounted
## The village's food and wood, held under reservation.
##
## A villager claims what it needs *before* it walks over to fetch it, and spends
## the claim on arrival. The claim is the whole point: without it two villagers
## both read "3 food left", both set off, and both eat — and the store goes
## negative with nothing in the code able to say which of them was wrong. With
## it, the second one is refused at the moment it asks and goes and does
## something useful instead, which is also better behaviour.
##
## Pure logic — no node, no scene, no registry. It is the easiest thing in the
## module to get wrong and the easiest to test exhaustively, so it owes nothing
## to the rest of the game.

const FOOD := &"food"
const WOOD := &"wood"

## Below this a level is floating-point debris rather than stock. Thousands of
## add/commit pairs of the same amount leave residue of the order of 1e-16, and
## a stock of -2e-16 fails "never negative" for no reason anyone can act on. Real
## over-draws are orders of magnitude larger and are left visible.
const EPSILON := 0.0001

var _stock: Dictionary[StringName, float] = {}
var _reserved: Dictionary[StringName, float] = {}
## Claim id to {resource, amount}. Ids are never reused, so a stale id from a
## villager that died mid-errand cannot spend someone else's claim.
var _claims: Dictionary[int, Dictionary] = {}
var _next_claim: int = 1


## Deposits produce. Non-positive amounts are ignored rather than trusted —
## a negative "deposit" would be a silent withdrawal that skipped reservation.
func add(resource: StringName, amount: float) -> void:
	if amount <= 0.0 or is_nan(amount):
		return
	_stock[resource] = stock_of(resource) + amount


func stock_of(resource: StringName) -> float:
	return float(_stock.get(resource, 0.0))


func reserved_of(resource: StringName) -> float:
	return float(_reserved.get(resource, 0.0))


## What is left once every outstanding claim is honoured. This, not stock_of, is
## what a villager must ask before deciding it can eat.
func available(resource: StringName) -> float:
	return _snap(stock_of(resource) - reserved_of(resource))


## Claims `amount` for one villager. Returns a claim id, or 0 when the stock is
## already spoken for. Zero is deliberately not a valid id so callers can test it
## as a plain falsy result.
func reserve(resource: StringName, amount: float) -> int:
	if amount <= 0.0 or is_nan(amount) or available(resource) < amount:
		return 0
	var claim: int = _next_claim
	_next_claim += 1
	_reserved[resource] = reserved_of(resource) + amount
	_claims[claim] = {"resource": resource, "amount": amount}
	return claim


## Hands a claim back unspent — the villager died, or gave up on the errand.
## Unknown ids are ignored, so releasing twice is harmless.
func release(claim: int) -> void:
	var row: Dictionary = _claims.get(claim, {})
	if row.is_empty():
		return
	_claims.erase(claim)
	var resource: StringName = row["resource"]
	_reserved[resource] = _snap(reserved_of(resource) - float(row["amount"]))


## Spends a claim. Returns what was actually taken, or 0.0 for an unknown or
## already-spent id — which is what makes a double commit a no-op rather than a
## second withdrawal.
func commit(claim: int) -> float:
	var row: Dictionary = _claims.get(claim, {})
	if row.is_empty():
		return 0.0
	_claims.erase(claim)
	var resource: StringName = row["resource"]
	var amount: float = float(row["amount"])
	_reserved[resource] = _snap(reserved_of(resource) - amount)
	_stock[resource] = _snap(stock_of(resource) - amount)
	return amount


## Outstanding claims. Used by tests to prove errands are not leaking claims:
## a village that never releases would slowly reserve itself to a standstill.
func claim_count() -> int:
	return _claims.size()


func _snap(value: float) -> float:
	return 0.0 if absf(value) < EPSILON else value
