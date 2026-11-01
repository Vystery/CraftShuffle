-- CraftShuffle :: DEBench
-- Disenchant benchmark: a per-cast log for comparing yields under different conditions (first use: the
-- Arcane Salvager, a camp object said to make disenchanting "more efficient"). The tracker's item records
-- only keep running totals; an A/B test needs every cast on its own with the conditions it ran under.
--
-- While the benchmark is on, every Disenchant the tracker finishes adds one entry to db.bench.log:
--   { t, g = castGUID, id = itemID, q = quality, il = ilvl, sk = Enchanting skill, sp = spellID,
--     ct = seconds from sent to succeeded, m = { matID = qty }, x = { other loot = qty } or nil,
--     au = "spellID,spellID" (the player's buffs), cp = "Enchanted Lute,Camp Chair" (camp objects read from
--     the Camp Benefits tooltip), sv = the Salvager was active (camp object or buff name), lb = manual label }
-- The tracker also keeps loot it would normally reject (anything that is not an enchanting material) in x,
-- so a new bonus item shows up instead of throwing the cast away. Other spells the player casts while the
-- benchmark runs are counted in db.bench.spells (finds a separate "salvage" spell, if there is one).
-- The log is capped (LOG_MAX, newest kept) and merged by cast key, so a merge of a copy into itself adds
-- nothing. Analysis is done offline from the SavedVariables file; /cs de bench prints a quick summary.

local _, CS = ...
local Bench = {}
CS.Bench = Bench

local LOG_MAX = 3000
local SPELLS_MAX = 100
Bench.LOG_MAX = LOG_MAX

-- buff / camp object names that are the Salvager (lower case, plain find). Not "lute": the Enchanted Lute is
-- a separate camp object (armor, stats, resistances) that the Salvager replaces.
local SALVAGER_WORDS = { "salvag" }

local function Now() return GetTime and GetTime() or 0 end

function Bench:Data(create)
	local db = CS.db
	if not db then return nil end
	if not db.bench and create then db.bench = { on = false, log = {}, spells = {}, auras = {} } end
	local b = db.bench
	if b then
		b.log = b.log or {}
		b.spells = b.spells or {}
		b.auras = b.auras or {}
	end
	return b
end

function Bench:IsOn()
	local b = CS.db and CS.db.bench
	return b and b.on or false
end

---------------------------------------------------------------------------
-- Conditions
---------------------------------------------------------------------------

-- Camp objects active right now. Forever has no buff per object: one "Camp Benefits" buff (1229741 on build
-- 70338) lists them in its tooltip, "Enchanted Lute: Armor increased by 114, ..." one per line. Returns the
-- object names in tooltip order (empty when the tooltip cannot be read).
local function CampObjects(aura, index)
	local objects = {}
	if not C_TooltipInfo then return objects end
	local ok, data
	if C_TooltipInfo.GetUnitBuffByAuraInstanceID and aura.auraInstanceID then
		ok, data = pcall(C_TooltipInfo.GetUnitBuffByAuraInstanceID, "player", aura.auraInstanceID)
	end
	if not (ok and type(data) == "table") and C_TooltipInfo.GetUnitAura then
		ok, data = pcall(C_TooltipInfo.GetUnitAura, "player", index, "HELPFUL")
	end
	if not (ok and type(data) == "table" and type(data.lines) == "table") then return objects end
	for _, line in ipairs(data.lines) do
		local text = type(line) == "table" and line.leftText
		if type(text) == "string" then
			for part in text:gmatch("[^\n]+") do
				local name = part:match("^%s*([^:]+):")
				-- a name has letters: "60:00 remaining" is the duration line, not an object
				if name and #name <= 40 and name:find("%a") and not name:find("^%s*%d")
					and not name:lower():find("camp benefit", 1, true) then
					objects[#objects + 1] = name
				end
			end
		end
	end
	return objects
end
Bench.CampObjects = CampObjects

-- Helpful auras on the player: sorted list of spell IDs, id -> name, and the camp objects named in a
-- camp buff's tooltip.
function Bench:PlayerAuras()
	local ids, names, camp = {}, {}, {}
	if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return ids, names, camp end
	for i = 1, 80 do
		local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
		if not ok or type(aura) ~= "table" then break end
		-- secret values (combat) fail the type checks or the pcall: skipped
		pcall(function()
			local id, name = aura.spellId, aura.name
			if type(id) == "number" then
				ids[#ids + 1] = id
				if type(name) == "string" then
					names[id] = name
					if name:lower():find("camp", 1, true) then
						for _, obj in ipairs(CampObjects(aura, i)) do camp[#camp + 1] = obj end
					end
				end
			end
		end)
	end
	table.sort(ids)
	return ids, names, camp
end

local function LooksLikeSalvager(id, name, b)
	if b and b.auraID and id == b.auraID then return true end
	if type(name) ~= "string" then return false end
	local l = name:lower()
	for _, w in ipairs(SALVAGER_WORDS) do
		if l:find(w, 1, true) then return true end
	end
	return false
end

function Bench:EnchantingSkill()
	if not (GetProfessions and GetProfessionInfo) then return nil end
	local ok, p1, p2 = pcall(GetProfessions)
	if not ok then return nil end
	for _, idx in ipairs({ p1, p2 }) do
		if idx then
			local ok2, _, _, rank, _, _, _, skillLine = pcall(GetProfessionInfo, idx)
			if ok2 and skillLine == CS.ENCHANTING_SKILL_LINE then return rank end
		end
	end
	return nil
end

---------------------------------------------------------------------------
-- Logging (called by the tracker for every finished cast)
---------------------------------------------------------------------------

local function EntryKey(e)
	return e.g and tostring(e.g) or (tostring(e.t) .. ":" .. tostring(e.id))
end
Bench.EntryKey = EntryKey

local function CopyMap(m)
	if not m or not next(m) then return nil end
	local c = {}
	for k, v in pairs(m) do c[k] = v end
	return c
end

function Bench:Log(p, mats, extras)
	if not self:IsOn() or not p or not p.itemID then return nil end
	local b = self:Data(true)
	local ids, names, camp = self:PlayerAuras()
	local sv = false
	for _, id in ipairs(ids) do
		if names[id] then b.auras[id] = names[id] end
		if LooksLikeSalvager(id, names[id], b) then sv = true end
	end
	for _, obj in ipairs(camp) do
		if LooksLikeSalvager(nil, obj, b) then sv = true end
	end
	local meta = CS.DEData:GetItemMeta(p.itemID)
	local e = {
		t = time(), g = p.castGUID, id = p.itemID,
		q = meta and meta.quality or nil, il = meta and meta.ilvl or nil,
		sk = self:EnchantingSkill(), sp = p.spellID,
		ct = (p.sent and p.done and p.done >= p.sent) and math.floor((p.done - p.sent) * 100 + 0.5) / 100 or nil,
		m = CopyMap(mats) or {}, x = CopyMap(extras),
		au = #ids > 0 and table.concat(ids, ",") or nil,
		cp = #camp > 0 and table.concat(camp, ",") or nil,
		sv = sv, lb = b.label,
	}
	table.insert(b.log, e)
	while #b.log > LOG_MAX do table.remove(b.log, 1) end
	if e.x then
		local parts = {}
		for k, v in pairs(e.x) do parts[#parts + 1] = string.format("%dx %s", v, type(k) == "number" and CS:ItemName(k) or tostring(k)) end
		table.sort(parts)
		CS:Print("benchmark: extra loot from %s: %s", CS:ItemName(p.itemID), table.concat(parts, ", "))
	end
	CS:Fire("BENCH_LOGGED", e)
	return e
end

-- Other spells cast while the benchmark runs (the salvager may come with its own).
CS:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, unit, _, spellID)
	if unit ~= "player" or not Bench:IsOn() or type(spellID) ~= "number" then return end
	if CS.Tracker.IsDisenchantSpell(spellID) then return end
	local b = Bench:Data(true)
	local s = b.spells[spellID]
	if not s then
		local n = 0
		for _ in pairs(b.spells) do n = n + 1 end
		if n >= SPELLS_MAX then return end
		local name
		if C_Spell and C_Spell.GetSpellName then
			local ok, v = pcall(C_Spell.GetSpellName, spellID)
			if ok and type(v) == "string" then name = v end
		end
		s = { n = 0, name = name }
		b.spells[spellID] = s
	end
	s.n = s.n + 1
	s.last = time()
end)

---------------------------------------------------------------------------
-- Saved data: cap + idempotent merge
---------------------------------------------------------------------------

function Bench.Prune(db)
	local b = type(db) == "table" and db.bench
	if type(b) ~= "table" then return end
	if type(b.log) ~= "table" then b.log = {} end
	while #b.log > LOG_MAX do table.remove(b.log, 1) end
end

-- loaded <- provisional: entries this session logged before the saved data arrived. Keyed by cast, so
-- merging a copy into itself (vault + file) adds nothing. The provisional on/label state wins (it is now).
function Bench.Merge(loaded, provisional)
	local pb = provisional and provisional.bench
	if type(pb) ~= "table" then Bench.Prune(loaded) return end
	local lb = loaded.bench
	if type(lb) ~= "table" or lb == pb then
		loaded.bench = pb
		Bench.Prune(loaded)
		return
	end
	lb.log = lb.log or {}
	local have = {}
	for _, e in ipairs(lb.log) do have[EntryKey(e)] = true end
	for _, e in ipairs(pb.log or {}) do
		if not have[EntryKey(e)] then
			have[EntryKey(e)] = true
			table.insert(lb.log, e)
		end
	end
	table.sort(lb.log, function(a, b) return (a.t or 0) < (b.t or 0) end)
	lb.spells = lb.spells or {}
	for id, s in pairs(pb.spells or {}) do
		local h = lb.spells[id]
		if not h or (s.n or 0) > (h.n or 0) then lb.spells[id] = s end -- the fuller count, never a sum
	end
	lb.auras = lb.auras or {}
	for id, name in pairs(pb.auras or {}) do lb.auras[id] = lb.auras[id] or name end
	if pb.on ~= nil then lb.on = pb.on end
	lb.label = pb.label
	lb.auraID = pb.auraID or lb.auraID
	Bench.Prune(loaded)
end

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------

local function GroupOf(e)
	if e.lb then return e.lb end
	return e.sv and "salvager buff" or "no salvager buff"
end
Bench.GroupOf = GroupOf

-- group -> { n, value, unpriced, mats = {id = qty}, hits = {id = casts}, extras = n, ct = sum, ctN }
function Bench:Summarize(log)
	log = log or (self:Data(false) or {}).log or {}
	local groups, order = {}, {}
	for _, e in ipairs(log) do
		local key = GroupOf(e)
		local g = groups[key]
		if not g then
			g = { n = 0, value = 0, unpriced = 0, mats = {}, hits = {}, extras = 0, ct = 0, ctN = 0 }
			groups[key] = g
			order[#order + 1] = key
		end
		g.n = g.n + 1
		for id, qty in pairs(e.m or {}) do
			g.mats[id] = (g.mats[id] or 0) + qty
			g.hits[id] = (g.hits[id] or 0) + 1
			local unit = CS.CP and CS.CP.GetSalePrice and CS.CP:GetSalePrice(id)
			if unit then g.value = g.value + unit * qty else g.unpriced = g.unpriced + 1 end
		end
		if e.x then g.extras = g.extras + 1 end
		if e.ct then g.ct = g.ct + e.ct; g.ctN = g.ctN + 1 end
	end
	table.sort(order)
	return groups, order
end

function Bench:PrintSummary()
	local b = self:Data(false)
	local n = b and #b.log or 0
	CS:Print("disenchant benchmark %s%s: %d casts logged (max %d).", self:IsOn() and "ON" or "off",
		b and b.label and (", label '" .. b.label .. "'") or "", n, LOG_MAX)
	if n == 0 then return end
	local groups, order = self:Summarize(b.log)
	for _, key in ipairs(order) do
		local g = groups[key]
		local parts = {}
		for id, qty in pairs(g.mats) do
			parts[#parts + 1] = { text = string.format("%s %s (%d%%)", CS:FormatQty(qty / g.n), CS:ItemName(id), math.floor(g.hits[id] / g.n * 100 + 0.5)), q = qty }
		end
		table.sort(parts, function(x, y) return x.q > y.q end)
		local list = {}
		for i, p in ipairs(parts) do if i <= 4 then list[#list + 1] = p.text end end
		CS:Print("  %s: %d casts, %s per cast%s%s%s", key, g.n, CS:Money(math.floor(g.value / g.n + 0.5)),
			g.unpriced > 0 and " (some mats unpriced)" or "",
			g.ctN > 0 and string.format(", cast %.2fs", g.ct / g.ctN) or "",
			g.extras > 0 and string.format(", %d with extra loot", g.extras) or "")
		if #list > 0 then CS:Print("    per cast: %s", table.concat(list, ", ")) end
	end
	CS:Print("  compare similar items only (same quality and level band); the full log is in the saved data for analysis.")
end

---------------------------------------------------------------------------
-- Slash: /cs de bench ...
---------------------------------------------------------------------------

function Bench:Slash(arg)
	local sub, rest = (arg or ""):match("^(%S*)%s*(.-)%s*$")
	sub = (sub or ""):lower()
	if sub == "on" or sub == "start" then
		local b = self:Data(true)
		b.on = true
		if rest ~= "" then b.label = rest end
		CS:Print("disenchant benchmark ON%s: every Disenchant is logged with your buffs, skill and full loot.",
			b.label and (" (label '" .. b.label .. "')") or "")
		CS:Print("  without a label, casts are grouped by whether a salvager-looking buff was up. Check with /cs de bench auras next to the Salvager.")
	elseif sub == "off" or sub == "stop" then
		local b = self:Data(false)
		if b then b.on = false end
		CS:Print("disenchant benchmark off. /cs de bench shows the summary; the log stays until /cs de bench reset confirm.")
	elseif sub == "label" then
		local b = self:Data(true)
		if rest == "" or rest:lower() == "auto" then
			b.label = nil
			CS:Print("benchmark label cleared: casts are grouped by the salvager buff.")
		else
			b.label = rest
			CS:Print("benchmark label set to '%s' for the next casts.", rest)
		end
	elseif sub == "aura" then
		local b = self:Data(true)
		local id = tonumber(rest)
		b.auraID = id
		CS:Print(id and ("buff %d now counts as the salvager."):format(id) or "salvager buff ID cleared (name match only).")
	elseif sub == "auras" or sub == "buffs" then
		local ids, names, camp = self:PlayerAuras()
		local b = self:Data(false)
		if #ids == 0 then CS:Print("no readable buffs on you right now.") end
		for _, id in ipairs(ids) do
			CS:Print("  %d %s%s", id, names[id] or "?", LooksLikeSalvager(id, names[id], b) and "  <- counts as salvager" or "")
		end
		if #camp > 0 then
			for _, obj in ipairs(camp) do
				CS:Print("  camp object: %s%s", obj, LooksLikeSalvager(nil, obj, b) and "  <- counts as salvager" or "")
			end
		elseif #ids > 0 then
			CS:Print("  no camp objects read from a Camp Benefits buff.")
		end
	elseif sub == "reset" then
		if rest ~= "confirm" then
			CS:Print("usage: /cs de bench reset confirm (forgets the benchmark log)")
		elseif CS.db then
			local on, label = self:IsOn(), CS.db.bench and CS.db.bench.label
			CS.db.bench = { on = on, label = label, log = {}, spells = {}, auras = {} }
			CS:Print("benchmark log cleared.")
		end
	elseif sub == "" or sub == "stats" or sub == "status" then
		self:PrintSummary()
	else
		CS:Print("usage: /cs de bench [on [label] | off | label <text>|auto | auras | aura <spellID> | reset confirm]")
	end
end
