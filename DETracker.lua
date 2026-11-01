-- CraftShuffle :: DETracker
-- Records what the player's own Disenchant casts actually produce and blends those observations with the
-- built-in estimates (DEData.lua).
--
-- Detection chain (all guarded, any link can be missing on a beta build):
--   1. (No item-use hooks: they taint protected item use on build 70374. Tracker.candidate is only set by tests.)
--   2. UNIT_SPELLCAST_SENT with the Disenchant spell starts a "pending" cast. The event's target (the item
--      name) is resolved by scanning the bags; without one, the item is found from the bag change.
--   3. UNIT_SPELLCAST_SUCCEEDED marks the pending cast as done; FAILED / INTERRUPTED clears it.
--   4. The next LOOT_OPENED within a few seconds whose slots are all enchanting materials is the result.
--   Several casts can be in flight (macro spam); each keeps its own entry, and a loot window that arrives
--   just before its cast's SUCCEEDED is held until the cast confirms.
--
-- Observations are stored per item and per quality/level band (bracket), so a brand-new item benefits
-- from what similar items produced before its own count builds up.

local _, CS = ...
local Tracker = {}
CS.Tracker = Tracker

local DISENCHANT = CS.DISENCHANT_SPELL
local CANDIDATE_TTL = 3   -- seconds a bag click stays a candidate
local LOOT_TTL = 6        -- seconds between the successful cast and its loot window
local BRACKET_CAP = 200   -- most "similar" casts a bracket contributes to an item's yield blend
local OVERRULE_MIN_CASTS = 5  -- real casts needed before they can overrule the built-in table
local OVERRULE_P = 0.02       -- ... and a table material never seen must be this unlikely to miss by chance

Tracker.candidate = nil   -- { itemID, link, t }
Tracker.pending = nil     -- { itemID, link, castGUID, t, succeeded }
Tracker.recorded = {}     -- castGUID -> true (LOOT_OPENED can fire more than once)
Tracker.stats = { casts = 0, missedItem = 0, ignoredLoot = 0 }

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------

local function NewRecord()
	return { n = 0, hits = {}, mats = {}, first = time(), last = time() }
end

-- lo / hi: the smallest and largest amount of each material one cast gave (records from before 0.2.4 have
-- none; QtyRange infers what it can)
local function Widen(rec, matID, lo, hi)
	rec.lo, rec.hi = rec.lo or {}, rec.hi or {}
	rec.lo[matID] = math.min(rec.lo[matID] or lo, lo)
	rec.hi[matID] = math.max(rec.hi[matID] or hi, hi)
end
Tracker.Widen = Widen

local function AddTo(rec, mats)
	rec.n = (rec.n or 0) + 1
	rec.hits = rec.hits or {}
	rec.mats = rec.mats or {}
	for matID, qty in pairs(mats) do
		rec.hits[matID] = (rec.hits[matID] or 0) + 1
		rec.mats[matID] = (rec.mats[matID] or 0) + qty
		Widen(rec, matID, qty, qty)
	end
	rec.last = time()
end

-- Per-cast amount range of a material in a record, or nil when unknown. Old records without lo / hi still
-- tell when every cast gave exactly one (quantity == casts it appeared in).
local function QtyRange(rec, matID)
	if not rec then return nil end
	local lo, hi = rec.lo and rec.lo[matID], rec.hi and rec.hi[matID]
	if lo and hi then return lo, hi end
	local hits, qty = rec.hits and rec.hits[matID], rec.mats and rec.mats[matID]
	if hits and hits > 0 and qty == hits then return 1, 1 end
	return nil
end

-- mats: { [matItemID] = quantity }. Returns the item record.
function Tracker:Record(itemID, mats)
	if not itemID or not next(mats) then return nil end
	local db = CS.db
	local rec = db.disenchant[itemID]
	if not rec then
		rec = NewRecord()
		db.disenchant[itemID] = rec
	end
	AddTo(rec, mats)

	local meta = CS.DEData:GetItemMeta(itemID)
	if meta then
		local key = CS.DEData:BracketKey(meta)
		local brk = db.brackets[key]
		if not brk then
			brk = NewRecord()
			db.brackets[key] = brk
		end
		AddTo(brk, mats)
		rec.bracket = key
	end

	self.stats.casts = self.stats.casts + 1
	CS:Fire("DE_RECORDED", itemID, mats, rec)
	return rec
end

-- Gear the game refused to disenchant. Excluded everywhere (estimates, planner, scan, tooltip) from now on.
function Tracker:Block(itemID, reason)
	if not itemID then return false end
	CS.db.blocked = CS.db.blocked or {}
	if CS.db.blocked[itemID] then return false end
	CS.db.blocked[itemID] = { reason = reason or "manual", t = time() }
	CS:Fire("DE_RECORDED")
	return true
end

function Tracker:Unblock(itemID)
	if not (itemID and CS.db.blocked and CS.db.blocked[itemID]) then return false end
	CS.db.blocked[itemID] = nil
	CS:Fire("DE_RECORDED")
	return true
end

-- Item records inflated by old self-merges: each merge of a copy into itself doubled every count of every
-- record (a saved file held 25.7M casts over 58 items, 2026-10-13). A record over MAX_ITEM_N casts cannot
-- be real. Undo the doublings:
--   * when n, every hit count and every quantity share a factor 2^k (k >= 10), divide by it: exact
--     (3,670,016 = 28 x 2^17);
--   * otherwise casts were added between doublings; divide by the factor most of the exact records share
--     (the number of doublings they all went through), an estimate;
--   * with no such factor, scale the record down to MAX_ITEM_N.
-- Proportions are kept either way. Returns how many records were repaired.
local MAX_ITEM_N = 1000
Tracker.MAX_ITEM_N = MAX_ITEM_N

local function TwoAdic(x)
	x = math.floor(x or 0)
	if x <= 0 then return 64 end
	local k = 0
	while x % 2 == 0 do x = x / 2 k = k + 1 end
	return k
end

local function CommonTwoPower(rec)
	local k = TwoAdic(rec.n)
	for _, c in pairs(rec.hits or {}) do k = math.min(k, TwoAdic(c)) end
	for _, q in pairs(rec.mats or {}) do k = math.min(k, TwoAdic(q)) end
	return k
end

local function ScaleRecord(rec, newN)
	local k = newN / rec.n
	rec.n = newN
	for matID, c in pairs(rec.hits or {}) do
		local v = math.min(newN, math.floor(c * k + 0.5))
		rec.hits[matID] = v > 0 and v or nil
	end
	for matID, q in pairs(rec.mats or {}) do
		local v = math.floor(q * k + 0.5)
		if rec.hits and rec.hits[matID] then v = math.max(v, rec.hits[matID]) end
		rec.mats[matID] = (v > 0 and rec.hits and rec.hits[matID]) and v or nil
	end
end

function Tracker:RepairRecords(db)
	db = db or CS.db
	if not db then return 0 end
	local bad, votes = {}, {}
	for _, rec in pairs(db.disenchant or {}) do
		if (rec.n or 0) > MAX_ITEM_N then
			local k = CommonTwoPower(rec)
			bad[#bad + 1] = { rec = rec, k = k }
			if k >= 10 and k < 64 then votes[k] = (votes[k] or 0) + 1 end
		end
	end
	local common, best = nil, 0
	for k, c in pairs(votes) do
		if c > best or (c == best and k > (common or 0)) then common, best = k, c end
	end
	for _, b in ipairs(bad) do
		local rec, d = b.rec, nil
		if b.k >= 10 and b.k < 64 then d = 2 ^ b.k elseif common then d = 2 ^ common end
		local newN = d and math.max(1, math.floor(rec.n / d + 0.5)) or MAX_ITEM_N
		ScaleRecord(rec, math.min(newN, MAX_ITEM_N))
	end
	return #bad
end

-- Brackets are derived data: the sum of the item records in each quality / level band. They are rebuilt
-- from the items at load and after a late SavedVariables merge instead of being merged themselves (an
-- additive merge of a copy into itself doubled them each time, up to millions of "similar" casts).
-- Returns the number of bracket casts after the rebuild.
function Tracker:RebuildBrackets(db)
	db = db or CS.db
	if not db then return 0 end
	local brackets = {}
	local total = 0
	for itemID, rec in pairs(db.disenchant or {}) do
		local key = rec.bracket
		if not key then
			local meta = CS.DEData:GetItemMeta(itemID)
			if meta then
				key = CS.DEData:BracketKey(meta)
				rec.bracket = key
			end
		end
		if key and (rec.n or 0) > 0 then
			local brk = brackets[key]
			if not brk then
				brk = { n = 0, hits = {}, mats = {}, first = rec.first, last = rec.last }
				brackets[key] = brk
			end
			brk.n = brk.n + rec.n
			for matID, c in pairs(rec.hits or {}) do brk.hits[matID] = (brk.hits[matID] or 0) + c end
			for matID, q in pairs(rec.mats or {}) do brk.mats[matID] = (brk.mats[matID] or 0) + q end
			for matID in pairs(rec.hits or {}) do
				local lo, hi = QtyRange(rec, matID)
				if lo then Widen(brk, matID, lo, hi) end
			end
			brk.first = math.min(brk.first or rec.first or time(), rec.first or time())
			brk.last = math.max(brk.last or 0, rec.last or 0)
			total = total + rec.n
		end
	end
	db.brackets = brackets
	return total
end

-- An item whose metadata was not cached at the rebuild joins its bracket once the client knows it.
CS:On("ITEM_LOADED", function(itemID)
	local rec = itemID and CS.db and CS.db.disenchant and CS.db.disenchant[itemID]
	if rec and not rec.bracket then Tracker:RebuildBrackets() end
end)

function Tracker:GetObserved(itemID)
	return CS.db and CS.db.disenchant[itemID] or nil
end

function Tracker:GetBracketObserved(key)
	return key and CS.db and CS.db.brackets[key] or nil
end

-- Remove one item's observations (also from its bracket aggregate).
function Tracker:Forget(itemID)
	local rec = CS.db.disenchant[itemID]
	if not rec then return end
	CS.db.disenchant[itemID] = nil
	self:RebuildBrackets() -- brackets are sums of the item records; a per-cast range cannot be subtracted
	CS:Fire("DE_RECORDED", itemID)
end

---------------------------------------------------------------------------
-- Expected yields = estimate blended with observations
---------------------------------------------------------------------------

-- Pseudo-count blend. Each material is a pair (casts it appeared in, total quantity); the built-in
-- estimate is treated as `priorWeight` virtual casts. Bracket observations (minus this item's own, which
-- are also in the bracket) are folded in first, then the item's own casts.
--
-- Returns list of { itemID, chance, avgGiven, expected, min, max, estimated = bool }, nil,
--   info = { n, bracketN, estimateOnly, summary, bracketKey, meta }
-- or nil, reason ("loading" | "not-disenchantable" | "unknown"), meta
function Tracker:GetExpectedYields(itemID)
	local est, why, meta, key = CS.DEData:GetEstimate(itemID)
	local item = self:GetObserved(itemID)
	if not est and why == "loading" then return nil, why end
	if not est and why == "not-disenchantable" and not item then return nil, why, meta end
	if not est and not item then
		-- unknown bracket with no observations: nothing to say yet
		return nil, "unknown", meta
	end

	local W = (CS.settings and CS.settings.priorWeight) or 10
	local acc = {}      -- matID -> { hits, qty }
	local n0 = 0

	local n = item and item.n or 0
	local brk = self:GetBracketObserved(key or (item and item.bracket))
	local inBracket = item and item.bracket == (key or item.bracket)
	local bracketN = 0
	if brk and (brk.n or 0) > 0 then
		bracketN = math.max(0, (brk.n or 0) - (inBracket and n or 0))
	end
	-- similar items' share of a material: the bracket minus this item's own casts (already in the bracket)
	local function SimilarOf(field, matID)
		local own = inBracket and item[field] and item[field][matID] or 0
		return math.max(0, (brk and brk[field] and brk[field][matID] or 0) - own)
	end

	-- The table is wrong for this item when real casts (its own plus similar items') never produced a
	-- material it predicts and that is very unlikely by chance (Forever changed some essences). The whole
	-- table is dropped then: a missing line means the band does not apply, and its other lines would still
	-- skew the mix (10 casts of Greater Magic Essence against a table worth 10 casts of Greater Astral
	-- Essence showed both at ~40%, a mix no disenchant ever gives).
	local overruled = false
	if est then
		local evidence = n + bracketN
		if evidence >= OVERRULE_MIN_CASTS then
			for _, y in ipairs(est) do
				local seen = (item and item.hits and item.hits[y.itemID] or 0) + SimilarOf("hits", y.itemID)
				if seen == 0 and (1 - y.chance) ^ evidence < OVERRULE_P then
					overruled = true
					break
				end
			end
		end
	end

	if est and not overruled then
		n0 = W
		for _, y in ipairs(est) do
			acc[y.itemID] = { hits = W * y.chance, qty = W * y.chance * y.avgGiven, min = y.min, max = y.max }
		end
	end

	if bracketN > 0 then
		-- similar items count as at most BRACKET_CAP casts (their proportions kept), so a big bracket
		-- never drowns the estimate and the item's own casts
		local scale = math.min(1, BRACKET_CAP / bracketN)
		n0 = n0 + bracketN * scale
		for matID in pairs(brk.mats or {}) do
			local a = acc[matID] or { hits = 0, qty = 0 }
			a.hits = a.hits + SimilarOf("hits", matID) * scale
			a.qty = a.qty + SimilarOf("mats", matID) * scale
			acc[matID] = a
		end
	end

	-- per-cast range ("1-2x"): the table's (while it is in the mix) widened by every amount actually seen
	local function WidenAcc(rec)
		for matID, a in pairs(acc) do
			local lo, hi = QtyRange(rec, matID)
			if lo then
				a.min = math.min(a.min or lo, lo)
				a.max = math.max(a.max or hi, hi)
			end
		end
	end
	if bracketN > 0 then WidenAcc(brk) end

	if n > 0 then
		for matID, qty in pairs(item.mats or {}) do
			local a = acc[matID] or { hits = 0, qty = 0 }
			a.hits = a.hits + (item.hits and item.hits[matID] or 0)
			a.qty = a.qty + qty
			acc[matID] = a
		end
		WidenAcc(item)
	end

	local total = n0 + n
	if total <= 0 then return nil, "unknown", meta end

	local list = {}
	for matID, a in pairs(acc) do
		local chance = a.hits / total
		if chance > 0.001 then
			table.insert(list, {
				itemID = matID,
				chance = chance,
				avgGiven = a.hits > 0 and (a.qty / a.hits) or 0,
				expected = a.qty / total,
				min = a.min, max = a.max,
			})
		end
	end
	table.sort(list, function(x, y)
		if x.expected ~= y.expected then return x.expected > y.expected end
		return x.itemID < y.itemID
	end)

	-- the label says what the numbers rest on: "+ table" while the built-in table is still part of the mix
	local usesTable = est ~= nil and not overruled
	local summary
	if n == 0 and bracketN == 0 then
		summary = est and "estimate" or "no data"
	elseif n == 0 then
		summary = usesTable and string.format("estimate + %s similar", CS:ShortCount(bracketN))
			or string.format("%s similar", CS:ShortCount(bracketN))
	else
		summary = string.format("%s recorded", CS:ShortCount(n))
		if bracketN > 0 then summary = summary .. string.format(" + %s similar", CS:ShortCount(bracketN)) end
		if usesTable then summary = summary .. " + table" end
	end

	return list, nil, {
		n = n, bracketN = bracketN, estimateOnly = (n == 0 and bracketN == 0), hasEstimate = usesTable,
		overruled = overruled, summary = summary, bracketKey = key or (item and item.bracket), meta = meta,
	}
end

---------------------------------------------------------------------------
-- Detection
---------------------------------------------------------------------------

local function Now()
	return GetTime and GetTime() or 0
end

local function SetCandidate(itemID, link)
	if not itemID then return end
	Tracker.candidate = { itemID = itemID, link = link, t = Now() }
	CS:Debug("DE candidate %s", tostring(link or itemID))
end

local function FindBagItemByName(name)
	if not name or not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemLink) then return nil end
	local lname = name:lower()
	local last = (NUM_BAG_SLOTS or 4)
	for bag = 0, last do
		local ok, slots = pcall(C_Container.GetContainerNumSlots, bag)
		if ok and slots then
			for slot = 1, slots do
				local ok2, link = pcall(C_Container.GetContainerItemLink, bag, slot)
				if ok2 and type(link) == "string" then
					local itemName = link:match("%[(.-)%]")
					if itemName and itemName:lower() == lname then
						return CS:ItemIDFromLink(link), link
					end
				end
			end
		end
	end
	return nil
end

local function ResolveName(name)
	local id, link = FindBagItemByName(name)
	if id then return id, link end
	if C_Item and C_Item.GetItemInfoInstant and name and name ~= "" then
		local ok, itemID = pcall(C_Item.GetItemInfoInstant, name)
		if ok and type(itemID) == "number" then return itemID, nil end
	end
	return nil
end

local function IsTargeting()
	if SpellIsTargeting then
		local ok, targeting = pcall(SpellIsTargeting)
		return ok and targeting
	end
	return true -- cannot tell: keep the candidate anyway, SENT will validate it
end

-- No hooks on C_Container.UseContainerItem / UseItemByName: on build 70374 a hook there taints every item
-- use from the bags and macros (the hearthstone was blocked, blamed on CraftShuffle). Forever never needed
-- them anyway: SENT passes no target for item spells, so the item comes from the bag change (SnapshotBags).

-- Stage counters for /cs status, so a failing chain can be diagnosed without a debugger.
Tracker.stats.sent, Tracker.stats.succeeded, Tracker.stats.lootReady, Tracker.stats.lootOpened = 0, 0, 0, 0
Tracker.stats.lastStage = "nothing yet"

local function Stage(text, ...)
	if select("#", ...) > 0 then text = string.format(text, ...) end
	Tracker.stats.lastStage = text
	CS:Debug("DE: %s", text)
end

-- Disenchant by ID, or by name in case the beta uses another spell ID for it.
local deName
local function SpellName(spellID)
	if C_Spell and C_Spell.GetSpellName then
		local ok, name = pcall(C_Spell.GetSpellName, spellID)
		if ok and type(name) == "string" then return name end
	end
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
		if ok and type(info) == "table" then return info.name end
	end
	return nil
end

local function IsDisenchantSpell(spellID)
	if spellID == DISENCHANT then return true end
	if type(spellID) ~= "number" then return false end
	-- only cache a successful lookup: spell data may not be loaded at the first cast
	if not deName then deName = SpellName(DISENCHANT) end
	if not deName then return false end
	return SpellName(spellID) == deName
end
Tracker.IsDisenchantSpell = IsDisenchantSpell

-- Bag snapshot of disenchantable items (itemID -> count). Taken when a Disenchant is sent; the item whose
-- count dropped afterwards is the one that was disenchanted. Needs no hooks and no event arguments, so it
-- works for bag clicks, macros and other addons' buttons alike.
local function SnapshotBags()
	if not (C_Container and C_Container.GetContainerNumSlots) then return nil end
	local snap = {}
	for bag = 0, (NUM_BAG_SLOTS or 4) do
		local ok, slots = pcall(C_Container.GetContainerNumSlots, bag)
		for slot = 1, (ok and slots) or 0 do
			local itemID, count, quality
			if C_Container.GetContainerItemInfo then
				local ok2, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
				if ok2 and type(info) == "table" then itemID, count, quality = info.itemID, info.stackCount, info.quality end
			end
			if not itemID and C_Container.GetContainerItemID then
				local ok3, id = pcall(C_Container.GetContainerItemID, bag, slot)
				if ok3 then itemID = id end
			end
			if itemID then
				local meta = CS.DEData:GetItemMeta(itemID)
				local disenchantable
				if meta then
					disenchantable = CS.DEData:IsDisenchantable(meta)
				else
					disenchantable = (quality or 0) >= 2 -- metadata not cached yet: keep it as a possibility
				end
				if disenchantable then snap[itemID] = (snap[itemID] or 0) + (count or 1) end
			end
		end
	end
	return snap
end
Tracker.SnapshotBags = SnapshotBags

-- The one item from the snapshot that is now fewer in the bags. Returns itemID, or nil plus how many
-- candidates there were (0 = bags unchanged so far, 2+ = ambiguous).
local function ResolveFromSnapshot(p)
	if not p or not p.snapshot then return nil, 0 end
	local now = SnapshotBags()
	if not now then return nil, 0 end
	local found, n = nil, 0
	for id, count in pairs(p.snapshot) do
		if (now[id] or 0) < count then
			found = id
			n = n + 1
		end
	end
	if n == 1 then return found end
	return nil, n
end

-- Casts in flight. Spamming the disenchant macro can put a second cast (or a rejected press that fires
-- SENT + FAILED) on top of one whose loot or bag change has not arrived yet, so every cast keeps its own
-- entry, keyed by castGUID. Tracker.pending is the newest one (kept for /cs status and the refusal path).
Tracker.pendings = {}
local MAX_PENDING = 4
local EARLY_LOOT_TTL = 3 -- seconds a loot window seen before its cast's SUCCEEDED waits for it

local function SyncLatest()
	Tracker.pending = Tracker.pendings[#Tracker.pendings]
end

local function AddPending(p)
	table.insert(Tracker.pendings, p)
	while #Tracker.pendings > MAX_PENDING do table.remove(Tracker.pendings, 1) end
	SyncLatest()
end

local function RemovePending(p)
	for i = #Tracker.pendings, 1, -1 do
		if Tracker.pendings[i] == p then table.remove(Tracker.pendings, i) end
	end
	SyncLatest()
end

local function FindPending(castGUID)
	if not castGUID then return nil end
	for i = #Tracker.pendings, 1, -1 do
		if Tracker.pendings[i].castGUID == castGUID then return Tracker.pendings[i] end
	end
	return nil
end

-- Drop casts whose loot never came. A cast waiting for its bag change is left to OnBagUpdate.
local function ExpirePendings()
	local now = Now()
	for i = #Tracker.pendings, 1, -1 do
		local p = Tracker.pendings[i]
		local ttl = p.succeeded and LOOT_TTL or (LOOT_TTL + 10) -- an unfinished cast may still be casting
		if not p.lootMats and now - p.t > ttl then
			table.remove(Tracker.pendings, i)
			Stage("pending cast expired before its loot window")
		end
	end
	SyncLatest()
end

local function OnSent(_, unit, target, castGUID, spellID)
	if unit ~= "player" or not IsDisenchantSpell(spellID) then return end
	Tracker.stats.sent = Tracker.stats.sent + 1
	local cand = Tracker.candidate
	local itemID, link
	if cand and Now() - cand.t <= CANDIDATE_TTL then
		itemID, link = cand.itemID, cand.link
	elseif target and target ~= "" then
		itemID, link = ResolveName(target)
	end
	Tracker.candidate = nil
	ExpirePendings()
	-- the bag snapshot is taken for every cast: it identifies the item when there is no target, and it is
	-- the fallback for a SUCCEEDED whose SENT was missed
	local snap = SnapshotBags()
	Tracker.lastSnapshot = snap
	if not itemID then
		-- no usable target (Forever passes none for item spells): identify it from the bags afterwards
		AddPending({ itemID = nil, castGUID = castGUID, t = Now(), succeeded = false, snapshot = snap, sent = Now(), spellID = spellID })
		Stage("cast sent (spell %s), target '%s'; will identify the item from the bag change", tostring(spellID), tostring(target))
		return
	end
	AddPending({ itemID = itemID, link = link, castGUID = castGUID, t = Now(), succeeded = false, snapshot = snap, sent = Now(), spellID = spellID })
	Stage("cast sent for %s", tostring(link or itemID))
end

local HandleLoot -- forward

local function OnSucceeded(_, unit, castGUID, spellID)
	if unit ~= "player" or not IsDisenchantSpell(spellID) then return end
	Tracker.stats.succeeded = Tracker.stats.succeeded + 1
	local p = FindPending(castGUID)
	if not p and not castGUID then
		-- no GUID to match on: the newest unfinished cast
		for i = #Tracker.pendings, 1, -1 do
			if not Tracker.pendings[i].succeeded then p = Tracker.pendings[i] break end
		end
	end
	if not p then
		-- SENT was not seen: fall back to the last bag click, and to the last bag snapshot to identify the item
		local cand = Tracker.candidate
		local fresh = cand and Now() - cand.t <= 15
		p = { itemID = fresh and cand.itemID or nil, link = fresh and cand.link or nil,
			castGUID = castGUID, t = Now(), succeeded = true, snapshot = Tracker.lastSnapshot, done = Now(), spellID = spellID }
		AddPending(p)
		Tracker.candidate = nil
		Stage("cast succeeded without a sent event; item %s", fresh and tostring(cand.link or cand.itemID) or "unknown")
	else
		p.succeeded = true
		p.t = Now()
		p.done = Now()
		p.spellID = p.spellID or spellID
		Stage("cast succeeded for %s, waiting for loot", tostring(p.link or p.itemID or "unknown item"))
	end
	-- the loot window came first (event order is not guaranteed): use it now
	local early = Tracker.earlyLoot
	if early and Now() - early.t <= EARLY_LOOT_TTL then
		Tracker.earlyLoot = nil
		Stage("using the loot window that arrived before the cast finished")
		HandleLoot(p, early.mats, early.extras)
	end
end

local function OnFailed(_, unit, castGUID, spellID)
	if unit ~= "player" or not IsDisenchantSpell(spellID) then return end
	local p = FindPending(castGUID)
	if not p and not castGUID then p = Tracker.pending end
	-- a rejected extra press has its own GUID and never touches the cast that is really running
	if p and not p.succeeded then
		-- remembered briefly: the "cannot be disenchanted" error may arrive just after this event
		Tracker.lastFailed = { itemID = p.itemID, t = Now() }
		RemovePending(p)
		Stage("cast failed or interrupted")
	end
end

-- "Item cannot be disenchanted": the game knows a flag we cannot read. Learn it from the refusal so the
-- item drops out of shuffle values and the disenchant scan (the Lesser Magic Wand trap).
local CANT_DE_TEXT = "cannot be disenchanted"
local function IsCantDisenchant(message)
	if type(message) ~= "string" then return false end
	if SPELL_FAILED_CANT_BE_DISENCHANTED and message == SPELL_FAILED_CANT_BE_DISENCHANTED then return true end
	return message:lower():find(CANT_DE_TEXT, 1, true) ~= nil
end

local function OnUIError(_, _, message)
	if not IsCantDisenchant(message) then return end
	local p, lf, cand = Tracker.pending, Tracker.lastFailed, Tracker.candidate
	if p and p.succeeded then p = nil end -- a finished cast was not the refused one
	local itemID = (p and p.itemID)
		or (lf and Now() - lf.t <= 2 and lf.itemID)
		or (cand and Now() - cand.t <= CANDIDATE_TTL and cand.itemID)
	if p then RemovePending(p) end
	Tracker.lastFailed = nil
	if not itemID then
		Stage("disenchant refused, item unknown (no bag click or target name)")
		return
	end
	if Tracker:Block(itemID, "refused") then
		CS:Print("%s cannot be disenchanted: excluded from shuffle values and the disenchant scan from now on (/cs de unblock to undo).", CS:ItemName(itemID))
	end
	Stage("disenchant refused for %s", CS:ItemName(itemID))
end
CS:RegisterEvent("UI_ERROR_MESSAGE", OnUIError)

-- Returns mats { itemID = qty } when every slot is an enchanting material, otherwise nil plus a description.
-- While the benchmark runs (DEBench.lua) other slots do not reject the window: they come back as the third
-- value, extras { itemID or "?name" = qty }, so a bonus item from a salvager is logged instead of lost.
local function CollectLoot()
	if not (GetNumLootItems and GetLootSlotLink) then return nil, "no loot API" end
	local n = GetNumLootItems() or 0
	if n == 0 then return nil, "empty loot window" end
	local bench = CS.Bench and CS.Bench:IsOn()
	local mats, seen, extras = {}, {}, nil
	for i = 1, n do
		local link = GetLootSlotLink(i)
		local itemID = CS:ItemIDFromLink(link)
		local qty, slotName = 1, nil
		if GetLootSlotInfo then
			local ok, _, name, quantity = pcall(GetLootSlotInfo, i)
			if ok and type(quantity) == "number" and quantity > 0 then qty = quantity end
			if ok and type(name) == "string" then slotName = name end
		end
		table.insert(seen, string.format("%dx %s", qty, itemID and CS:ItemName(itemID) or tostring(link or slotName)))
		if itemID and CS.DEData:IsEnchantingMat(itemID) then
			mats[itemID] = (mats[itemID] or 0) + qty
		elseif bench then
			extras = extras or {}
			local key = itemID or ("?" .. tostring(slotName or ("slot " .. i)))
			extras[key] = (extras[key] or 0) + qty
		elseif not itemID then
			return nil, "slot " .. i .. " is not an item: " .. table.concat(seen, ", ")
		else
			return nil, "not enchanting materials: " .. table.concat(seen, ", ")
		end
	end
	return mats, nil, extras
end

local function GuidOf(p) return p.castGUID or ("t" .. tostring(p.t)) end

local function GiveUp(p, why)
	Tracker.stats.missedItem = Tracker.stats.missedItem + 1
	Tracker.recorded[GuidOf(p)] = true
	RemovePending(p)
	Stage(why)
	CS:Print("saw a disenchant result but could not tell which item was disenchanted (/cs debug for details).")
end

-- A succeeded cast and the materials of its loot window: identify the item and record.
HandleLoot = function(p, mats, extras)
	if not p.itemID then
		local id, n = ResolveFromSnapshot(p)
		if id then
			p.itemID = id
			Stage("item identified from the bag change: %s", CS:ItemName(id))
		elseif p.snapshot and n == 0 then
			-- bags not updated yet: keep the loot and finish on the next bag update
			p.lootMats = mats
			p.lootExtras = extras
			p.awaitBags = Now()
			Stage("loot captured, waiting for the bag update to identify the item")
			return
		else
			GiveUp(p, string.format("disenchant loot seen but the item is %s, not recorded",
				n and n > 1 and "ambiguous (" .. n .. " items changed)" or "unknown"))
			return
		end
	end
	Tracker:Finish(p, mats, extras)
end

-- The cast a loot window belongs to: the oldest succeeded cast that has no loot yet.
local function LootTarget()
	for _, p in ipairs(Tracker.pendings) do
		if p.succeeded and not p.lootMats and not Tracker.recorded[GuidOf(p)] then return p end
	end
	return nil
end

-- LOOT_READY(autoLoot) fires first and always has the slots; LOOT_OPENED(autoLoot, isFromItem) follows
-- (with auto-loot the slots may already be gone by then). Both run through here; the cast GUID guard
-- makes sure a disenchant is recorded once.
local function OnLoot(event, autoLoot, isFromItem)
	if event == "LOOT_READY" then Tracker.stats.lootReady = Tracker.stats.lootReady + 1
	else Tracker.stats.lootOpened = Tracker.stats.lootOpened + 1 end

	ExpirePendings()
	local p = LootTarget()
	if not p then
		local mats, _, extras = CollectLoot()
		local unfinished
		for _, q in ipairs(Tracker.pendings) do if not q.succeeded then unfinished = q end end
		if mats and unfinished then
			-- loot before the cast's SUCCEEDED: keep it, OnSucceeded uses it
			Tracker.earlyLoot = { mats = mats, extras = extras, t = Now(), event = event }
			Stage("%s before the cast finished, kept until it does", event)
			return
		end
		-- No cast seen at all: a loot window of pure enchanting materials right after a bag click is still a
		-- disenchant (the beta may not deliver the spellcast events the way retail does).
		local cand = Tracker.candidate
		if mats and next(mats) and cand and Now() - cand.t <= 15 then
			p = { itemID = cand.itemID, link = cand.link, castGUID = "cand" .. tostring(cand.t), t = Now(), succeeded = true }
			AddPending(p)
			Tracker.candidate = nil
			Stage("no spellcast events seen; using the bag click on %s", tostring(cand.link or cand.itemID))
		else
			return
		end
	end
	-- Retail flags item-sourced loot with isFromItem = true. When the client says false we do not trust it
	-- blindly (the beta may differ) but only accept a window that opened right after the cast.
	if isFromItem == false and Now() - p.t > 2 then
		Stage("loot window flagged as not item-sourced and %.1fs after the cast, ignored", Now() - p.t)
		return
	end

	local mats, why, extras = CollectLoot()
	if not mats then
		Tracker.stats.ignoredLoot = Tracker.stats.ignoredLoot + 1
		Stage("%s after Disenchant ignored: %s", event, tostring(why))
		return
	end
	HandleLoot(p, mats, extras)
end

-- Records the pending cast and announces it. extras: non-material loot, only while benchmarking.
function Tracker:Finish(p, mats, extras)
	self.recorded[GuidOf(p)] = true
	RemovePending(p)
	local rec = self:Record(p.itemID, mats)
	if CS.Bench then
		local ok, err = pcall(CS.Bench.Log, CS.Bench, p, mats, extras)
		if not ok then CS:Debug("benchmark log failed: %s", tostring(err)) end
	end
	Stage("recorded %s", tostring(p.link or CS:ItemName(p.itemID)))
	if CS.settings.announce and rec then
		local parts = {}
		for matID, qty in pairs(mats) do table.insert(parts, string.format("%dx %s", qty, CS:ItemName(matID))) end
		table.sort(parts)
		CS:Print("%s -> %s  (%d recorded)", p.link or CS:ItemName(p.itemID), table.concat(parts, ", "), rec.n)
	end
end

-- Deferred identification: the disenchanted item leaves the bags around the time the loot shows up.
local function OnBagUpdate()
	for i = 1, #Tracker.pendings do
		local p = Tracker.pendings[i]
		if p and p.lootMats then
			local id, n = ResolveFromSnapshot(p)
			if id then
				p.itemID = id
				Tracker:Finish(p, p.lootMats, p.lootExtras)
				return -- the list changed; the next bag event handles any other waiting cast
			elseif Now() - (p.awaitBags or 0) > 5 then
				GiveUp(p, string.format("gave up identifying the item (%d candidates in the bag change)", n or 0))
				return
			end
		end
	end
end
CS:RegisterEvent("BAG_UPDATE_DELAYED", OnBagUpdate)
CS:RegisterEvent("BAG_UPDATE", OnBagUpdate)

CS:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player", OnSent)
CS:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", OnSucceeded)
CS:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player", OnFailed)
CS:RegisterUnitEvent("UNIT_SPELLCAST_FAILED_QUIET", "player", OnFailed)
CS:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player", OnFailed)
CS:RegisterEvent("LOOT_READY", OnLoot)
CS:RegisterEvent("LOOT_OPENED", OnLoot)

function Tracker:StatusLine()
	local s = self.stats
	return string.format("events this session: sent %d, succeeded %d, loot ready %d / opened %d, recorded %d, item unknown %d, loot ignored %d. Last: %s",
		s.sent, s.succeeded, s.lootReady, s.lootOpened, s.casts, s.missedItem, s.ignoredLoot, s.lastStage)
end

---------------------------------------------------------------------------
-- Item tooltips: expected disenchant value
---------------------------------------------------------------------------

local function TooltipValue(itemID)
	local yields, _, info = Tracker:GetExpectedYields(itemID)
	if not yields then return nil end
	local total, missing = 0, 0
	for _, y in ipairs(yields) do
		local unit = CS.CP:GetSalePrice(y.itemID)
		if unit then total = total + unit * y.expected else missing = missing + 1 end
	end
	return total, missing, yields, info
end

local function AddTooltipLines(tooltip, itemID)
	if not (CS.settings and CS.settings.tooltip) or not itemID then return end
	local meta = CS.DEData:GetItemMeta(itemID)
	if not meta or not CS.DEData:LooksDisenchantable(meta) then return end
	local blocked, why = CS.DEData:IsBlocked(itemID)
	if blocked then
		tooltip:AddDoubleLine(CS:Color(CS.COLORS.gold, "Disenchant value"),
			CS:Color(CS.COLORS.loss, "cannot be disenchanted") .. CS:Color(CS.COLORS.muted, " (" .. why .. ")"), 1, 1, 1, 1, 1, 1)
		return
	end
	local total, missing, yields, info = TooltipValue(itemID)
	if not yields then return end
	-- compact: one line, disenchant value against the vendor price; Shift shows the full breakdown
	if CS.settings.tooltipCompact and not (IsShiftKeyDown and IsShiftKeyDown()) then
		local right = total > 0 and CS:Money(total) or "no mat prices"
		if missing > 0 and total > 0 then right = right .. CS:Color(CS.COLORS.muted, "*") end
		if total > 0 and meta.sell then
			local diff = total - meta.sell
			right = right .. " " .. CS:Color(diff >= 0 and CS.COLORS.profit or CS.COLORS.loss,
				"(" .. CS:Money(diff, { sign = true }) .. " vs vendor)")
		end
		tooltip:AddDoubleLine(CS:Color(CS.COLORS.gold, "Disenchant value"), right, 1, 1, 1, 1, 1, 1)
		return
	end
	local right = total > 0 and CS:Money(total) or "no mat prices"
	if missing > 0 and total > 0 then right = right .. " +" .. missing .. " unpriced" end
	-- what the numbers rest on ("10 recorded + 5 similar + table") only with Shift: it widens the tooltip
	local label = CS:Color(CS.COLORS.gold, "Disenchant value")
	if IsShiftKeyDown and IsShiftKeyDown() then label = label .. CS:Color(CS.COLORS.muted, " (" .. info.summary .. ")") end
	tooltip:AddDoubleLine(label, right, 1, 1, 1, 1, 1, 1)
	for i, y in ipairs(yields) do
		if i > 3 then break end
		tooltip:AddDoubleLine("  " .. CS:ItemName(y.itemID),
			string.format("%s  %d%%", CS:FormatYieldQty(y), math.floor(y.chance * 100 + 0.5)), 0.7, 0.7, 0.7, 0.55, 0.55, 0.55)
	end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
	pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Item, function(tooltip, data)
		if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
		local itemID = data and data.id
		if not itemID and type(tooltip.GetItem) == "function" then
			local _, link = tooltip:GetItem()
			itemID = CS:ItemIDFromLink(link)
		end
		if itemID then
			local ok, err = pcall(AddTooltipLines, tooltip, itemID)
			if not ok then CS:Debug("tooltip failed: %s", tostring(err)) end
		end
	end)
end
Tracker.AddTooltipLines = AddTooltipLines
