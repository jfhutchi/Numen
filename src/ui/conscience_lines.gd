class_name ConscienceLines
extends RefCounted
## The script for the two inner voices, as data.
##
## Every remark either voice can make lives here, keyed by (topic, voice), so the
## presentation layer holds no prose and the writing can be edited without
## touching the timing rules. Several alternatives per entry because the same
## event fires many times a session and hearing the identical sentence twice is
## what makes an advisor feel like a tooltip.
##
## The two voices read the same event through different values, but both are
## meant to be *useful*: each line should tell the player something true about
## the mechanics — what a miracle costs, when feedback lands, why belief moves —
## while disagreeing about whether it was a good idea. Advice the player learns
## to ignore is worse than no advice.
##
## Every line is original writing. No voice is named, and neither is modelled on
## any existing character.

## The two voices. Unnamed on purpose — they are positions, not people.
const MERCIFUL := &"merciful"
const CRUEL := &"cruel"
const VOICES: Array[StringName] = [MERCIFUL, CRUEL]

## How much a topic is worth interrupting for. Anything absent is DEFAULT_PRIORITY.
## Zero is chatter the player causes constantly; five is an event that happens
## once or twice in a session and must not be swallowed by a rate limit.
const DEFAULT_PRIORITY := 1
const PRIORITY: Dictionary = {
	&"first_boot": 5,
	&"village_converted": 5,
	&"creature_ate_villager": 4,
	&"miracle_refused": 4,
	&"villager_died": 3,
	&"village_hungry": 3,
	&"drifting_kind": 3,
	&"drifting_cruel": 3,
	&"miracle_lightning": 3,
	&"belief_rising": 2,
	&"idle_nudge": 0,
	&"grabbed": 0,
	&"threw": 0,
}

## topic -> voice -> alternatives.
const LINES: Dictionary = {
	&"first_boot": {
		MERCIFUL: [
			"They are waiting for you. Reach into the world with your hand and touch it.",
			"Begin gently. Lift something, set it down again, let them see you are here.",
			"Draw a shape over the land and the sky will answer. Take your time with it.",
		],
		CRUEL: [
			"They will not believe until you make them. Do something they cannot ignore.",
			"Take hold of the world. Whatever you cannot lift is beneath your attention.",
			"Trace a shape in the air. Power comes to whoever bothers to learn the sign.",
		],
	},
	&"idle_nudge": {
		MERCIFUL: [
			"Nothing is happening. Look in on the village; they always need something.",
			"Your creature learns fastest while you are watching it. Stay near a while.",
			"Show it one kind act and it will copy the act long before it copies the reason.",
		],
		CRUEL: [
			"You are wasting the daylight. Lift something heavy and let go of it high up.",
			"Standing still earns no belief. Belief comes of spectacle, so make one.",
			"The beast is learning nothing from your dithering. Give it something to imitate.",
		],
	},
	&"grabbed": {
		MERCIFUL: [
			"Careful with that. Set it down where it will do somebody some good.",
			"Whatever is in your hand, they are all watching to see where it lands.",
			"Dropped into the village store, that feeds someone tonight.",
		],
		CRUEL: [
			"Good. Now carry it somewhere high and open your hand.",
			"Hold it where the beast can see it. Wanting is how it learns.",
			"That is not a tool, it is a projectile. You have simply not thrown it yet.",
		],
	},
	&"threw": {
		MERCIFUL: [
			"Thrown things break, and they remember which of us broke them.",
			"If you must throw, throw food into the store, not stone into the crowd.",
			"Your creature saw that. It will copy the throw before it understands the aim.",
		],
		CRUEL: [
			"Better. Distance is how you tell them the sky belongs to you.",
			"It flew well. Put the next one somewhere it will be missed.",
			"The beast is watching. Teach it that everything loose is yours to hurl.",
		],
	},
	&"miracle_food": {
		MERCIFUL: [
			"Food in the fields. They eat tonight, and by morning they believe.",
			"Twelve prayers for a full store. Few bargains are that plain.",
			"Cast it close to the village and the gatherers will have it in quickly.",
		],
		CRUEL: [
			"Feeding them makes them comfortable, and comfortable things forget to pray.",
			"Grain buys shallow faith. Hunger makes them far louder at the altar.",
			"That prayer was owed to lightning. Remember it when they starve anyway.",
		],
	},
	&"miracle_wood": {
		MERCIFUL: [
			"Timber. Now they can raise a roof instead of standing about wishing for one.",
			"Wood in the store becomes a house eventually. Slow kindness still counts.",
			"The builders will be at it before you have finished the gesture.",
		],
		CRUEL: [
			"Eighteen prayers for planks. You are running errands for farmers.",
			"Let them fell their own trees. A god who fetches is a servant with weather.",
			"Fine. Give them a village worth burning down later.",
		],
	},
	&"miracle_water": {
		MERCIFUL: [
			"Water on the fields. The harvest comes in, and it costs you almost nothing.",
			"Eight prayers is the cheapest thing you can do for them. Do it often.",
			"Dry fields yield nothing at all. Keep them wet and the store fills itself.",
		],
		CRUEL: [
			"Watering crops. So this is what divine power is for.",
			"It is cheap, so it is not quite a waste. Rain while they are watching.",
			"Every field you save is a famine you will not get to make use of.",
		],
	},
	&"miracle_heal": {
		MERCIFUL: [
			"You mended them. Nothing else you can do buys belief that quickly.",
			"Twenty-five prayers well spent. Cast it into a crowd, not over one person.",
			"The mended ones will tell the rest. That is how a reputation starts.",
		],
		CRUEL: [
			"Twenty-five prayers to undo an injury. The injury was the useful part.",
			"Mend them and they learn that pain has no consequences worth fearing.",
			"Heal the strong if you must. The weak are a poor investment of prayer.",
		],
	},
	&"miracle_lightning": {
		MERCIFUL: [
			"You burned everything standing there. That was somebody's father.",
			"Forty prayers to make a scar. Mending costs less and they love you for it.",
			"They believe in you now, and they will never come near you again.",
		],
		CRUEL: [
			"Yes. That is what a sky is for.",
			"Forty prayers, and worth each one. Fear does not need repeating as often.",
			"Strike nearer the huts next time. A crowd learns quicker than a field.",
		],
	},
	&"miracle_cast": {
		MERCIFUL: [
			"Power spent. See that what you spent it on outlives the gesture.",
			"The sky answered you. They saw it, and they will pray a little harder.",
			"Every miracle costs prayer. Keep enough in hand for the one you will need.",
		],
		CRUEL: [
			"Something happened and every one of them looked up. That much was worth it.",
			"A miracle they can see is worth two they cannot. Do it where they gather.",
			"Spend prayer on what frightens them, not on what comforts them.",
		],
	},
	&"miracle_refused": {
		MERCIFUL: [
			"Not enough prayer. Give them what they need and they will refill you.",
			"You are empty. More worshippers at the altar means more you can spend.",
			"Nothing happened. Build belief first, then ask the sky for favours.",
		],
		CRUEL: [
			"Nothing. You are poorer than you thought, and they watched you fail.",
			"Empty. Frighten them into praying, then come back with a full hand.",
			"Beg for prayer before you reach for the expensive miracles.",
		],
	},
	&"creature_ate_villager": {
		MERCIFUL: [
			"It ate one of them. Strike it now, while it still joins the two together.",
			"That was a person. Punish it at once or it will file that away as a meal.",
			"It was hungry and it learned the wrong lesson. Feed it, then correct it.",
		],
		CRUEL: [
			"It fed itself. Praise it now, so it knows the pantry has always been open.",
			"One villager, and every other one is terrified. That is good arithmetic.",
			"Reward that quickly. A beast rewarded for this wins arguments you never make.",
		],
	},
	&"creature_ate_food": {
		MERCIFUL: [
			"It ate properly. Praise it, so hunger and grain stay joined in its head.",
			"Good. A fed creature stops looking at the villagers so thoughtfully.",
			"Reward that. It is the habit you want in place before the store runs dry.",
		],
		CRUEL: [
			"Grain. Your beast has the appetite of a sheep.",
			"It settled for scraps. Let it go hungry and see what it chooses instead.",
			"Feeding it grain teaches it to queue. I would rather it hunted.",
		],
	},
	&"creature_slept": {
		MERCIFUL: [
			"Let it rest. A tired creature learns nothing and forgets what it knew.",
			"It sleeps because it is worn out. That is not disobedience.",
			"While it sleeps, see to the village. It will wake sharper for the quiet.",
		],
		CRUEL: [
			"Asleep. Put it on the leash and remind it who owns the hours.",
			"Rest becomes a habit. Break it early or you will keep a lazy animal.",
			"It dreams of nothing useful. Strike it awake if you are impatient.",
		],
	},
	&"creature_attacked": {
		MERCIFUL: [
			"It struck something. Strike it back now, or the next thing that moves suffers.",
			"Violence rewarded becomes violence expected. Correct it while it is fresh.",
			"It is testing what you will allow. Answer plainly and answer immediately.",
		],
		CRUEL: [
			"There it is. Praise it while the blow is still warm in its memory.",
			"Good. A creature that hits things is a creature they run from.",
			"Reward that now. Approval that arrives late teaches it nothing at all.",
		],
	},
	&"petted": {
		MERCIFUL: [
			"Kindness lands hardest straight after the act. It will remember that one.",
			"Well done. Praise is how you teach it without breaking anything.",
			"It felt that. Do it every time it does something you want done again.",
		],
		CRUEL: [
			"Stroking it. Splendid. Perhaps it will learn to fetch.",
			"Praise does work, I grant you. It works just as well on cruelty.",
			"Praise the right things and I have no complaint — only about your taste in them.",
		],
	},
	&"slapped": {
		MERCIFUL: [
			"It cannot know why unless you strike within a heartbeat of the deed.",
			"Punishment teaches faster than it heals. Use it sparingly.",
			"You hurt it. Be certain it was for something the creature actually chose.",
		],
		CRUEL: [
			"Harder, and sooner. It learns from the shock, not from your reasoning.",
			"Good. A beast that flinches is a beast that is paying attention.",
			"Now do it again next time, or the lesson rots before it sets.",
		],
	},
	&"village_hungry": {
		MERCIFUL: [
			"They are hungry. Food, or water on the fields — whichever you can afford.",
			"An empty store empties the altar next. Feed them before belief slips.",
			"Hunger kills them slowly, and it kills their faith in you first.",
		],
		CRUEL: [
			"They are hungry. Let them pray louder and then decide whether to answer.",
			"Starvation is a lever. Feed them at the last moment and they worship the rescue.",
			"Let them thin out. Fewer mouths, and the survivors pray twice as hard.",
		],
	},
	&"villager_born": {
		MERCIFUL: [
			"A child. Keep the store full and they will keep filling the village.",
			"One more voice at the altar, in time. Growth is belief, slowly.",
			"They breed when they are fed. That is very nearly the whole of it.",
		],
		CRUEL: [
			"Another mouth. Useful if it prays, useful if the beast is hungry.",
			"More of them. More for them to lose, which is what you want them feeling.",
			"A birth means the store is overflowing. You are being too generous.",
		],
	},
	&"villager_died": {
		MERCIFUL: [
			"Someone died. The rest felt it, and their belief in you thinned with it.",
			"That was avoidable. Water, food, mending — you had all three.",
			"Deaths cost you worship. Grief is not the only reason to prevent them.",
		],
		CRUEL: [
			"One fewer. The survivors are paying much closer attention now.",
			"Death is a lesson they teach one another, and it costs you no prayer.",
			"Do not mourn the arithmetic. Fear rose further than belief fell.",
		],
	},
	&"belief_rising": {
		MERCIFUL: [
			"Belief is climbing. Belief is prayer power, and prayer power is your hands.",
			"They trust you more today than yesterday. Kept promises compound.",
			"Keep to this and your reach will spread further across the land than you can walk.",
		],
		CRUEL: [
			"Belief is rising and I do not much care how. Get more of it.",
			"Their faith is a fuel gauge. Spend it on something they will remember.",
			"They believe. Now find out how much they will bear and still believe.",
		],
	},
	&"village_converted": {
		MERCIFUL: [
			"Another village is yours. Look after them as well as you did the first.",
			"Their belief tipped over to you. More worshippers, more power to spend.",
			"You reached them from a distance. Kindness travels further than you think.",
		],
		CRUEL: [
			"Another village taken. Their prayer counts the same as anybody's.",
			"Taken. Now do it again, faster, and with rather less patience.",
			"A second altar. Twice the prayer, and twice the lightning.",
		],
	},
	&"drifting_kind": {
		MERCIFUL: [
			"You are becoming someone they can rely upon. Hold to it.",
			"Your hand is gentler than it was. They can feel the difference.",
			"Mercy is showing on you now — and on the creature copying you.",
		],
		CRUEL: [
			"You are going soft. It shows in your hands, and it shows in the beast.",
			"Every kind act narrows what you are still willing to do. Mind that.",
			"They are comfortable. Comfortable people forget who fed them.",
		],
	},
	&"drifting_cruel": {
		MERCIFUL: [
			"You are hardening. The creature is watching and learning the same.",
			"This is how it starts — small cruelties, then no reason left not to.",
			"There is still time to be something they run toward instead of from.",
		],
		CRUEL: [
			"Good. You are becoming legible at last: something to be afraid of.",
			"Harder by the day. The sky suits you.",
			"Fear is cheaper than bread, and it never spoils.",
		],
	},
}


## Every topic the voices have an opinion about.
static func topics() -> Array[StringName]:
	var out: Array[StringName] = []
	for topic: StringName in LINES:
		out.append(topic)
	return out


## The alternatives one voice can offer on one topic; empty if it has none.
static func lines_for(topic: StringName, voice: StringName) -> PackedStringArray:
	var by_voice: Dictionary = LINES.get(topic, {})
	return PackedStringArray(by_voice.get(voice, []))


static func other_voice(voice: StringName) -> StringName:
	return MERCIFUL if voice == CRUEL else CRUEL


static func priority_of(topic: StringName) -> int:
	return int(PRIORITY.get(topic, DEFAULT_PRIORITY))


## The topic for a cast of `miracle_id`, falling back to the generic cast topic.
##
## The fallback is the point: a sixth miracle added to the library gets a
## sensible remark from both voices instead of silence, which is the failure
## mode nobody notices.
static func miracle_topic(miracle_id: StringName) -> StringName:
	var specific := StringName("miracle_%s" % miracle_id)
	return specific if LINES.has(specific) else &"miracle_cast"
