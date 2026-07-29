extends GutTest
## The reservation store. The one piece of the village that must never be wrong:
## every path to spending stock goes through commit(), and every path to commit()
## goes through reserve().

const STORE := preload("res://src/village/village_store.gd")

var _store: VillageStore


func before_each() -> void:
	_store = STORE.new()


func test_deposits_accumulate() -> void:
	_store.add(VillageStore.FOOD, 4.0)
	_store.add(VillageStore.FOOD, 6.5)
	assert_eq(_store.stock_of(VillageStore.FOOD), 10.5)
	assert_eq(_store.stock_of(VillageStore.WOOD), 0.0, "resources are kept apart")


func test_negative_and_zero_deposits_are_refused() -> void:
	# A negative deposit would be a withdrawal that skipped reservation entirely.
	_store.add(VillageStore.FOOD, 5.0)
	_store.add(VillageStore.FOOD, -3.0)
	_store.add(VillageStore.FOOD, 0.0)
	assert_eq(_store.stock_of(VillageStore.FOOD), 5.0)


func test_reserving_hides_stock_from_everyone_else() -> void:
	_store.add(VillageStore.FOOD, 10.0)
	var claim: int = _store.reserve(VillageStore.FOOD, 4.0)

	assert_ne(claim, 0, "a claim within stock should be granted")
	assert_eq(_store.stock_of(VillageStore.FOOD), 10.0, "reserving does not spend")
	assert_eq(_store.reserved_of(VillageStore.FOOD), 4.0)
	assert_eq(_store.available(VillageStore.FOOD), 6.0, "the claim is no longer on offer")


func test_concurrent_claims_beyond_stock_are_refused() -> void:
	# The whole reason reservations exist. Three villagers set off for the store
	# at the same moment; only two of them can be fed.
	_store.add(VillageStore.FOOD, 10.0)
	var first: int = _store.reserve(VillageStore.FOOD, 4.0)
	var second: int = _store.reserve(VillageStore.FOOD, 4.0)
	var third: int = _store.reserve(VillageStore.FOOD, 4.0)

	gut.p("claims granted: %d, %d, %d (0 means refused)" % [first, second, third])
	assert_ne(first, 0)
	assert_ne(second, 0)
	assert_eq(third, 0, "the third villager must be turned away, not overdrawn")

	_store.commit(first)
	_store.commit(second)
	assert_eq(_store.stock_of(VillageStore.FOOD), 2.0)
	assert_gte(_store.stock_of(VillageStore.FOOD), 0.0)


func test_a_crowd_of_claimants_cannot_drive_the_store_negative() -> void:
	_store.add(VillageStore.WOOD, 10.0)
	var granted: Array[int] = []
	for i in 50:
		var claim: int = _store.reserve(VillageStore.WOOD, 3.0)
		if claim != 0:
			granted.append(claim)
	for claim: int in granted:
		_store.commit(claim)

	gut.p("50 claimants of 3 wood against a stock of 10: %d granted, %.2f left" % [
		granted.size(), _store.stock_of(VillageStore.WOOD)
	])
	assert_eq(granted.size(), 3)
	assert_eq(_store.stock_of(VillageStore.WOOD), 1.0)
	assert_gte(_store.stock_of(VillageStore.WOOD), 0.0)


func test_released_reservations_return_to_stock() -> void:
	_store.add(VillageStore.FOOD, 10.0)
	var first: int = _store.reserve(VillageStore.FOOD, 8.0)
	assert_eq(_store.reserve(VillageStore.FOOD, 8.0), 0, "nothing spare while the claim stands")

	_store.release(first)

	assert_eq(_store.reserved_of(VillageStore.FOOD), 0.0)
	assert_eq(_store.stock_of(VillageStore.FOOD), 10.0, "a released claim was never spent")
	assert_ne(_store.reserve(VillageStore.FOOD, 8.0), 0, "and is on offer again")


func test_commit_decrements_exactly_once() -> void:
	_store.add(VillageStore.FOOD, 10.0)
	var claim: int = _store.reserve(VillageStore.FOOD, 4.0)

	assert_eq(_store.commit(claim), 4.0)
	assert_eq(_store.stock_of(VillageStore.FOOD), 6.0)
	assert_eq(_store.reserved_of(VillageStore.FOOD), 0.0)

	# A villager that somehow commits twice — a duplicated arrival, a reloaded
	# errand — must not get a second helping.
	assert_eq(_store.commit(claim), 0.0, "a spent claim is worth nothing")
	assert_eq(_store.stock_of(VillageStore.FOOD), 6.0)


func test_unknown_claims_are_ignored() -> void:
	_store.add(VillageStore.FOOD, 5.0)
	_store.release(9999)
	assert_eq(_store.commit(9999), 0.0)
	assert_eq(_store.stock_of(VillageStore.FOOD), 5.0)
	assert_eq(_store.reserved_of(VillageStore.FOOD), 0.0)


func test_claim_ids_are_never_reused() -> void:
	# Reuse would let a villager whose errand ended long ago spend the claim of
	# whoever inherited its id.
	_store.add(VillageStore.FOOD, 100.0)
	var first: int = _store.reserve(VillageStore.FOOD, 1.0)
	_store.commit(first)
	var second: int = _store.reserve(VillageStore.FOOD, 1.0)
	assert_ne(first, second)


func test_reserving_more_than_exists_is_refused() -> void:
	_store.add(VillageStore.FOOD, 2.0)
	assert_eq(_store.reserve(VillageStore.FOOD, 2.5), 0)
	assert_eq(_store.reserve(VillageStore.FOOD, 0.0), 0, "an empty claim is not a claim")
	assert_eq(_store.reserve(VillageStore.FOOD, -5.0), 0, "nor is a negative one")
	assert_eq(_store.claim_count(), 0)


func test_thousands_of_cycles_leave_no_floating_point_debris() -> void:
	# Regression. Repeated add/commit of the same amount leaves residue around
	# 1e-16, and a stock of -2.8e-17 fails "never negative" for a reason no
	# player or programmer can act on. The store snaps that noise band to zero.
	# Three harvests of 0.1 do not add up to 0.3 in binary, they add up to
	# 0.30000000000000004. Taking 0.3 back out therefore leaves 5.6e-17 behind.
	for i in 3:
		_store.add(VillageStore.FOOD, 0.1)
	gut.p("three deposits of 0.1 hold %.20f" % _store.stock_of(VillageStore.FOOD))

	_store.commit(_store.reserve(VillageStore.FOOD, 0.3))

	gut.p("after withdrawing 0.3: %.20f" % _store.stock_of(VillageStore.FOOD))
	assert_eq(_store.stock_of(VillageStore.FOOD), 0.0, "the residue should be snapped away")
	assert_gte(_store.stock_of(VillageStore.FOOD), 0.0)
	assert_eq(_store.available(VillageStore.FOOD), 0.0)
	assert_eq(_store.claim_count(), 0, "no claim should have leaked")


func test_long_runs_of_traffic_never_go_negative() -> void:
	var lowest: float = INF
	for i in 3000:
		_store.add(VillageStore.FOOD, 0.7)
		var claim: int = _store.reserve(VillageStore.FOOD, 0.65)
		if claim != 0:
			_store.commit(claim)
		lowest = minf(lowest, _store.stock_of(VillageStore.FOOD))

	gut.p("3000 deposits of 0.7 against withdrawals of 0.65: low water %.6f, final %.6f" % [
		lowest, _store.stock_of(VillageStore.FOOD)
	])
	assert_gte(lowest, 0.0, "stock must never dip below zero, not even by float noise")


func test_claims_do_not_leak_when_villagers_change_their_minds() -> void:
	_store.add(VillageStore.WOOD, 20.0)
	for i in 10:
		var claim: int = _store.reserve(VillageStore.WOOD, 2.0)
		if i % 2 == 0:
			_store.commit(claim)
		else:
			_store.release(claim)

	assert_eq(_store.claim_count(), 0)
	assert_eq(_store.reserved_of(VillageStore.WOOD), 0.0)
	assert_eq(_store.stock_of(VillageStore.WOOD), 10.0, "five of ten claims were spent")
	assert_eq(_store.available(VillageStore.WOOD), _store.stock_of(VillageStore.WOOD))
