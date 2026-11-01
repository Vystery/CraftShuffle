-- CraftShuffle :: Recipes
-- Recipe Browser (/cs recipes): every recipe of every profession, learned or not, priced with CraftProfit's AH
-- data and CraftShuffle's disenchant values. Two views: Professions (one row per profession: how many recipes
-- turn a profit and the best of them, to decide what is worth levelling) and Recipes (the full list).
--
-- The client has no recipe catalog for professions the character does not have (C_CraftingOrders
-- .GetCustomerOptions returns nothing on Forever), but two calls answer for any recipe spell ID (probed in
-- game 2026-09-24):
--   C_TradeSkillUI.GetTradeSkillLineForRecipe(id) -> skillLineID, name, parentSkillLineID; nil for most spells,
--                                                    but also answers for languages, weapon skills, class schools
--   C_TradeSkillUI.GetRecipeSchematic(id, false)  -> name, outputItemID, reagents; answers for EVERY spell ID
-- So the catalog is built by walking spell IDs once per session in time-sliced chunks, keeping IDs on a
-- profession skill line that make an item or take reagents. IDs 1..50,000 took 18 ms in one frame and held
-- every Classic-era recipe. Not available for unlearned recipes: the skill needed and where it is learned
-- (GetRecipeInfo reports difficulty 0, GetRecipeSourceText is empty), so the item level stands in for
-- "how far into the profession".
--
-- Not saved: the scan takes about a second and the saved variables are unreliable on this client.

local _, CS = ...
local Rec = {}
CS.Recipes = Rec

local unpack = unpack or table.unpack
local DASH = "\226\128\148"
local DOT = " \194\183 "

Rec.SCAN_MAX = 1500000   -- highest spell ID looked at
Rec.BUDGET_MS = 8        -- scan time per frame
Rec.view = "profs"       -- "profs" | "recipes" | "uses" (material uses)
Rec.prof = nil           -- profession filter for the Recipes view (skill line ID), nil = all
Rec.show = "all"         -- "all" | "mine" (known + learnable) | "known" | "learnable" | "other"
Rec.search = ""
Rec.sort = { recipes = { key = "profit", desc = true }, profs = { key = "best", desc = true },
	uses = { key = "perMat", desc = true } } -- the uses view has this one fixed order

-- Base profession skill lines. The client's own list (GetAllProfessionTradeSkillLines) is added at scan time;
-- the secondary professions are not on it on Forever.
local PROFESSION_LINES = {
	[129] = true, [164] = true, [165] = true, [171] = true, [182] = true, [185] = true, [186] = true,
	[197] = true, [202] = true, [333] = true, [356] = true, [393] = true, [755] = true, [773] = true,
}

-- Test and retired spells that sit on real profession lines.
local EXCLUDED_NAMES = { "%[DNT%]", "^Test ", "^TEST ", "DEPRECATED", "Deprecated", "UNUSED", "%(OLD%)", "^OLD ", "^QA " }

local function Excluded(name)
	for _, pattern in ipairs(EXCLUDED_NAMES) do
		if name:find(pattern) then return true end
	end
	return false
end

local function Now()
	if debugprofilestop then return debugprofilestop() end
	return (GetTime and GetTime() or 0) * 1000
end

local function After(seconds, fn)
	if C_Timer and C_Timer.After then C_Timer.After(seconds, fn) else fn() end
end

local function BasicReagentType()
	return (Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic) or 0
end

local function ProfessionName(lineID, fallback)
	local T = C_TradeSkillUI
	if T and T.GetProfessionInfoBySkillLineID then
		local ok, info = pcall(T.GetProfessionInfoBySkillLineID, lineID)
		if ok and type(info) == "table" and info.professionName and info.professionName ~= "" then return info.professionName end
	end
	return fallback or ("profession " .. tostring(lineID))
end

function Rec:Available()
	local T = C_TradeSkillUI
	return T ~= nil and type(T.GetTradeSkillLineForRecipe) == "function" and type(T.GetRecipeSchematic) == "function"
end

local function IsLearned(recipeID)
	local T = C_TradeSkillUI
	if not (T and T.GetRecipeInfo) then return false end
	local ok, info = pcall(T.GetRecipeInfo, recipeID)
	return ok and type(info) == "table" and info.learned == true
end

---------------------------------------------------------------------------
-- Catalog scan
---------------------------------------------------------------------------
-- Rec.catalog = { list = { entry... }, byID = { [recipeID] = entry }, profs = { [lineID] = { id, name, n } },
--                 highestID, elapsed }
-- entry = { recipeID, name, prof, outputItemID, qmin, qmax, reagents = n }

local function AllowedLines()
	local allowed = {}
	for id in pairs(PROFESSION_LINES) do allowed[id] = true end
	local T = C_TradeSkillUI
	if T and T.GetAllProfessionTradeSkillLines then
		local ok, lines = pcall(T.GetAllProfessionTradeSkillLines)
		if ok and type(lines) == "table" then
			for _, id in ipairs(lines) do
				local name = ProfessionName(id, "")
				if not Excluded(name) then allowed[id] = true end
			end
		end
	end
	return allowed
end

-- One recipe candidate: keep it when it makes an item or takes reagents and is not a test spell. Two spell IDs
-- that make the same item from the same reagents are one recipe (the learned one wins).
local function Consider(s, recipeID, prof)
	local ok, sch = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
	if not ok or type(sch) ~= "table" then return end
	local name = sch.name
	if type(name) ~= "string" or name == "" or Excluded(name) then return end
	local out = sch.outputItemID
	if type(out) ~= "number" or out <= 0 then out = nil end
	local basic, parts, mats = BasicReagentType(), {}, {}
	for _, slot in ipairs(sch.reagentSlotSchematics or {}) do
		if slot.reagentType == basic and slot.required ~= false then
			local first = slot.reagents and slot.reagents[1] and slot.reagents[1].itemID
			parts[#parts + 1] = tostring(first or "?") .. "x" .. tostring(slot.quantityRequired or 1)
			if first then mats[first] = (mats[first] or 0) + (slot.quantityRequired or 1) end
		end
	end
	if not out and #parts == 0 then return end -- rank spells, gathering, ...
	table.sort(parts)
	local sig = prof .. ":" .. tostring(out or name) .. ":" .. table.concat(parts, ",")
	local entry = { recipeID = recipeID, name = name, prof = prof, outputItemID = out,
		qmin = sch.quantityMin or 1, qmax = sch.quantityMax or sch.quantityMin or 1, reagents = #parts, mats = mats }
	local twin = s.bySig[sig]
	if twin then
		if not twin.learned and IsLearned(recipeID) then
			entry.learned = true
			s.byID[twin.recipeID] = nil
			s.byID[recipeID] = entry
			s.bySig[sig] = entry
		end
		s.dupes = s.dupes + 1
		return
	end
	entry.learned = IsLearned(recipeID) or nil
	s.bySig[sig] = entry
	s.byID[recipeID] = entry
	s.hits = s.hits + 1
end

local function ScanChunk()
	local s = Rec.scanning
	if not s then return end
	local T = C_TradeSkillUI
	local deadline = Now() + Rec.BUDGET_MS
	local id, last = s.next, Rec.SCAN_MAX
	while id <= last do
		local ok, line, lineName, parent = pcall(T.GetTradeSkillLineForRecipe, id)
		if ok and type(line) == "number" then
			local prof = (type(parent) == "number" and parent > 0) and parent or line
			if s.allowed[prof] or s.allowed[line] then
				if not s.names[prof] and type(lineName) == "string" then s.names[prof] = lineName end
				Consider(s, id, prof)
			end
		end
		id = id + 1
		if id % 1000 == 0 and Now() >= deadline then break end
	end
	s.next = id
	if id <= last then
		Rec.progress = (id - 1) / last
		Rec:RenderSoon()
		After(0, ScanChunk)
		return
	end
	Rec:FinishScan(s)
end

function Rec:StartScan()
	if self.scanning then return true end
	if not self:Available() then
		self.unavailable = true
		return false
	end
	self.scanning = { next = 1, allowed = AllowedLines(), names = {}, byID = {}, bySig = {}, hits = 0, dupes = 0, started = Now() }
	self.progress = 0
	CS:Debug("recipe scan started (1..%d)", self.SCAN_MAX)
	After(0, ScanChunk)
	self:RenderSoon()
	return true
end

function Rec:FinishScan(s)
	local catalog = { list = {}, byID = s.byID, profs = {}, highestID = 0, elapsed = (Now() - s.started) / 1000, dupes = s.dupes,
		usedIn = {} }
	for id, entry in pairs(s.byID) do
		table.insert(catalog.list, entry)
		for itemID in pairs(entry.mats or {}) do
			local list = catalog.usedIn[itemID]
			if not list then list = {}; catalog.usedIn[itemID] = list end
			list[#list + 1] = entry
		end
		if id > catalog.highestID then catalog.highestID = id end
		local p = catalog.profs[entry.prof]
		if not p then
			p = { id = entry.prof, name = ProfessionName(entry.prof, s.names[entry.prof]), n = 0 }
			catalog.profs[entry.prof] = p
		end
		p.n = p.n + 1
	end
	table.sort(catalog.list, function(a, b) return a.recipeID < b.recipeID end)
	self.catalog = catalog
	self.scanning = nil
	self.progress = nil
	local nProfs = 0
	for _ in pairs(catalog.profs) do nProfs = nProfs + 1 end
	CS:Debug("recipe scan: %d recipes in %d professions, %d duplicates, highest ID %d, %.2f s",
		#catalog.list, nProfs, catalog.dupes, catalog.highestID, catalog.elapsed)
	CS:Fire("CATALOG_READY", catalog)
	self:Refresh()
end

function Rec:GetCatalog()
	if not self.catalog and not self.scanning then self:StartScan() end
	return self.catalog
end

---------------------------------------------------------------------------
-- Model
---------------------------------------------------------------------------

-- Player professions: skillLine -> { name, rank, max }.
local function PlayerProfessions()
	local out = {}
	if not (GetProfessions and GetProfessionInfo) then return out end
	local packed = (function(...) return { n = select("#", ...), ... } end)(pcall(GetProfessions))
	if not packed[1] then return out end
	for i = 2, packed.n do
		local idx = packed[i]
		if idx then
			local ok, name, _, rank, maxRank, _, _, skillLine = pcall(GetProfessionInfo, idx)
			if ok and skillLine then out[skillLine] = { name = name, rank = rank, max = maxRank } end
		end
	end
	return out
end
Rec.PlayerProfessions = PlayerProfessions

-- A recipe row: the catalog entry plus status and economics.
--   status  "known" | "learnable" (your profession, not learned) | "other" (a profession you do not have)
--   cost, costComplete, sale, profit (sell: sale - AH cut - cost), shuffle (disenchant net), shuffleStatus
local function BuildRow(entry, mine)
	local learned = IsLearned(entry.recipeID)
	local CP = CS.CP
	-- recipes nobody here has learned must not end up in CraftProfit's saved schematic cache
	CP.Calc.skipSchematicCache = not learned
	local ok, eco = pcall(CS.Calc.Get, CS.Calc, entry.recipeID)
	CP.Calc.skipSchematicCache = false
	if not ok then eco = nil end
	local base = eco and eco.base
	local row = {
		entry = entry, recipeID = entry.recipeID, name = entry.name, prof = entry.prof, outputItemID = entry.outputItemID,
		status = learned and "known" or (mine[entry.prof] and "learnable" or "other"),
		eco = eco, base = base,
	}
	if base then
		row.costComplete = base.costComplete and #(base.reagents or {}) > 0
		row.cost = row.costComplete and base.cost or nil
		row.sale = base.sale
		row.profit = base.net
		row.margin = base.margin
	end
	if eco then
		row.shuffle = eco.net
		row.shuffleStatus = eco.status
	end
	if entry.outputItemID and CS.DEData then
		local meta = CS.DEData:GetItemMeta(entry.outputItemID)
		if meta then
			row.quality = meta.quality
			row.ilvl = (meta.ilvl or 0) > 0 and meta.ilvl or nil
		end
	end
	return row
end

-- Every catalog recipe as a row. Economics come from CraftShuffle's calculator cache, so this is cheap
-- until prices change.
function Rec:BuildRows()
	local catalog = self.catalog
	if not catalog then return {} end
	local mine = PlayerProfessions()
	self.mine = mine
	local rows = {}
	for _, entry in ipairs(catalog.list) do
		rows[#rows + 1] = BuildRow(entry, mine)
	end
	return rows
end

local SHOW_MATCH = {
	all = function() return true end,
	mine = function(r) return r.status ~= "other" end,
	known = function(r) return r.status == "known" end,
	learnable = function(r) return r.status == "learnable" end,
	other = function(r) return r.status == "other" end,
}
Rec.SHOW_LABELS = {
	{ "all", "All recipes" }, { "mine", "My professions" }, { "known", "Known" },
	{ "learnable", "Not learned yet" }, { "other", "Other professions" },
}

local STATUS_ORDER = { known = 1, learnable = 2, other = 3 }

-- Sort values; nil sorts last whatever the direction.
local RECIPE_SORT = {
	name = function(r) return r.name end,
	prof = function(r) return Rec:ProfName(r.prof) end,
	ilvl = function(r) return r.ilvl end,
	cost = function(r) return r.cost end,
	sale = function(r) return r.sale end,
	profit = function(r) return r.profit end,
	shuffle = function(r) return r.shuffle end,
	status = function(r) return STATUS_ORDER[r.status] end,
}

local PROF_SORT = {
	name = function(p) return p.name end,
	yours = function(p) return p.rank end,
	n = function(p) return p.n end,
	priced = function(p) return p.priced end,
	profitable = function(p) return p.profitable end,
	best = function(p) return p.best and p.best.profit end,
	bestShuffle = function(p) return p.bestShuffle and p.bestShuffle.shuffle end,
}

local function SortBy(list, getters, spec, tiebreak)
	local get = getters[spec.key] or getters.name
	table.sort(list, function(a, b)
		local va, vb = get(a), get(b)
		if va == nil or vb == nil then
			if va ~= nil then return true end
			if vb ~= nil then return false end
		elseif va ~= vb then
			if spec.desc then return va > vb end
			return va < vb
		end
		return tiebreak(a) < tiebreak(b)
	end)
end

function Rec:ProfName(lineID)
	local p = self.catalog and self.catalog.profs[lineID]
	return p and p.name or ProfessionName(lineID)
end

-- Recipes view rows after the profession / show / search filters.
function Rec:FilterRecipes(rows)
	local out = {}
	local match = SHOW_MATCH[self.show] or SHOW_MATCH.all
	local needle = (self.search or ""):lower()
	for _, r in ipairs(rows) do
		if (not self.prof or r.prof == self.prof) and match(r)
			and (needle == "" or r.name:lower():find(needle, 1, true)) then
			out[#out + 1] = r
		end
	end
	SortBy(out, RECIPE_SORT, self.sort.recipes, function(r) return r.name end)
	return out
end

-- Professions view: one summary per profession over all its recipes (the show filter does not apply).
--   { id, name, n, known, priced, profitable, best (row), bestShuffle (row), top (5 best rows), rank, max, mine }
function Rec:Summaries(rows)
	local byProf = {}
	local mine = self.mine or {}
	for _, r in ipairs(rows) do
		local s = byProf[r.prof]
		if not s then
			local you = mine[r.prof]
			s = { id = r.prof, name = self:ProfName(r.prof), n = 0, known = 0, priced = 0, profitable = 0, sellers = {},
				mine = you ~= nil, rank = you and you.rank, max = you and you.max }
			byProf[r.prof] = s
		end
		s.n = s.n + 1
		if r.status == "known" then s.known = s.known + 1 end
		if r.profit then
			s.priced = s.priced + 1
			if r.profit > 0 then
				s.profitable = s.profitable + 1
				s.sellers[#s.sellers + 1] = r
			end
		end
		if r.shuffle and r.shuffle > 0 and (not s.bestShuffle or r.shuffle > s.bestShuffle.shuffle) then s.bestShuffle = r end
	end
	local list = {}
	for _, s in pairs(byProf) do
		table.sort(s.sellers, function(a, b) return a.profit > b.profit end)
		s.best = s.sellers[1]
		s.top = { unpack(s.sellers, 1, math.min(5, #s.sellers)) }
		s.sellers = nil
		list[#list + 1] = s
	end
	SortBy(list, PROF_SORT, self.sort.profs, function(s) return s.name end)
	return list
end

---------------------------------------------------------------------------
-- Material uses: what a material is good for besides selling it
---------------------------------------------------------------------------
-- For one material, every recipe that consumes it, valued per unit of the material:
--   perMat = (sale - AH cut - the recipe's other reagents) / units of the material used
--   gain   = perMat - what one unit of the material nets when sold (price - AH cut)
-- Enchants make no item (they cannot be sold on the AH), so they only count as demand. Essences also convert
-- 3 lesser <-> 1 greater by right-clicking them, which is its own row.

local ESSENCE_PAIRS = { { 10938, 10939 }, { 10998, 11082 }, { 11134, 11135 }, { 11174, 11175 }, { 16202, 16203 } }
local ESSENCE = {}
for _, p in ipairs(ESSENCE_PAIRS) do
	ESSENCE[p[1]] = { lesser = p[1], greater = p[2], isLesser = true }
	ESSENCE[p[2]] = { lesser = p[1], greater = p[2], isLesser = false }
end
Rec.ESSENCE = ESSENCE
Rec.mat = 10940 -- Strange Dust

local function CutRate()
	local CP = CS.CP
	return (CP and CP.settings and CP.settings.ahCut) or 0.05
end

-- What one unit of the material nets when sold on the AH.
function Rec:MatSellNet(itemID)
	local unit = CS.CP and CS.CP:GetSalePrice(itemID)
	if not unit then return nil end
	return unit * (1 - CutRate()), unit
end

-- One "uses" row per recipe consuming `mat`, from the priced recipe rows.
local function UsesRow(r, mat, sellNet)
	local qty = r.entry.mats and r.entry.mats[mat] or 1
	local u = { entry = r.entry, recipeID = r.recipeID, name = r.name, prof = r.prof, outputItemID = r.outputItemID,
		status = r.status, eco = r.eco, base = r.base, quality = r.quality, ilvl = r.ilvl, shuffle = r.shuffle,
		shuffleStatus = r.shuffleStatus, sale = r.sale, qty = qty, kind = r.outputItemID and "item" or "enchant" }
	local base = r.base
	if base then
		local other, complete = 0, true
		for _, g in ipairs(base.reagents or {}) do
			if g.itemID ~= mat then
				if g.total then other = other + g.total else complete = false end
			end
		end
		u.other, u.otherComplete = other, complete
		if r.sale and complete then
			u.craftNet = r.sale - (base.cut or r.sale * CutRate()) - other
			u.perMat = u.craftNet / qty
			if sellNet then u.gain = u.perMat - sellNet end
		end
	end
	return u
end

-- The right-click conversion of an essence, valued like a recipe.
local function ConversionRow(mat, sellNet)
	local pair = ESSENCE[mat]
	if not pair then return nil end
	local cut = CutRate()
	local target = pair.isLesser and pair.greater or pair.lesser
	local unit = CS.CP and CS.CP:GetSalePrice(target)
	local u = { conversion = true, outputItemID = target, kind = "conversion", status = "anyone", prof = nil,
		qty = pair.isLesser and 3 or 1, other = 0, otherComplete = true }
	if pair.isLesser then
		u.name = "Combine 3 into 1 " .. CS:ItemName(target)
		if unit then u.sale = unit; u.craftNet = unit * (1 - cut); u.perMat = u.craftNet / 3 end
	else
		u.name = "Split into 3 " .. CS:ItemName(target)
		if unit then u.sale = unit * 3; u.craftNet = unit * 3 * (1 - cut); u.perMat = u.craftNet end
	end
	if u.perMat and sellNet then u.gain = u.perMat - sellNet end
	return u
end

local KIND_ORDER = { conversion = 1, item = 2, enchant = 3 }

-- Rows for the Material uses view: priced uses first (best value per unit on top), then unpriced items,
-- then enchants. The profession / show / search filters apply.
function Rec:UsesRows(rows, mat)
	mat = mat or self.mat
	local out, stats = {}, { items = 0, enchants = 0, better = 0 }
	local catalog = self.catalog
	if not (catalog and mat) then return out, stats end
	local sellNet = self:MatSellNet(mat)
	local users = {}
	for _, e in ipairs(catalog.usedIn and catalog.usedIn[mat] or {}) do users[e.recipeID] = true end
	local match = SHOW_MATCH[self.show] or SHOW_MATCH.all
	local needle = (self.search or ""):lower()
	for _, r in ipairs(rows or {}) do
		if users[r.recipeID] then
			local u = UsesRow(r, mat, sellNet)
			if u.kind == "enchant" then stats.enchants = stats.enchants + 1 else stats.items = stats.items + 1 end
			if u.gain and u.gain > 0 then stats.better = stats.better + 1 end
			if (not self.prof or r.prof == self.prof) and match(r)
				and (needle == "" or r.name:lower():find(needle, 1, true)) then
				out[#out + 1] = u
			end
		end
	end
	local conv = ConversionRow(mat, sellNet)
	if conv then
		stats.conversion = conv
		if conv.gain and conv.gain > 0 then stats.better = stats.better + 1 end
		if needle == "" then out[#out + 1] = conv end
	end
	table.sort(out, function(a, b)
		local pa, pb = a.perMat, b.perMat
		if (pa ~= nil) ~= (pb ~= nil) then return pa ~= nil end
		if pa and pb and pa ~= pb then return pa > pb end
		local ka, kb = KIND_ORDER[a.kind] or 9, KIND_ORDER[b.kind] or 9
		if ka ~= kb then return ka < kb end
		return a.name < b.name
	end)
	stats.sellNet = sellNet
	return out, stats
end

-- Materials the picker offers: every enchanting material some recipe uses, plus the current one.
function Rec:MatChoices()
	local list, seen = {}, {}
	local usedIn = self.catalog and self.catalog.usedIn or {}
	local function add(id)
		if seen[id] then return end
		seen[id] = true
		list[#list + 1] = { id = id, name = CS:ItemName(id), n = usedIn[id] and #usedIn[id] or 0 }
	end
	for id in pairs(CS.DEData and CS.DEData.MATS or {}) do
		if usedIn[id] then add(id) end
	end
	if self.mat then add(self.mat) end
	table.sort(list, function(a, b) return a.name < b.name end)
	return list
end

function Rec:SetMat(itemID)
	if not itemID then return end
	self.mat = itemID
	self.view = "uses"
	self.offset = 0
	self:Refresh()
end

-- "Strange Dust", an item link or an item ID -> itemID
function Rec:ResolveItem(text)
	text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then return nil end
	local id = CS:ItemIDFromLink(text) or tonumber(text)
	if id then return id end
	local needle = text:lower()
	for mid, name in pairs(CS.DEData and CS.DEData.MATS or {}) do
		if name:lower() == needle then return mid end
	end
	if C_Item and C_Item.GetItemInfoInstant then
		local ok, found = pcall(C_Item.GetItemInfoInstant, text)
		if ok and type(found) == "number" then return found end
	end
	for mid, name in pairs(CS.DEData and CS.DEData.MATS or {}) do
		if name:lower():find(needle, 1, true) then return mid end
	end
	return nil
end

-- Market of the material from CraftProfit: listed count, cheapest tiers of the ladder, sold per day.
function Rec:MatMarketText(itemID, maxTiers)
	local CP = CS.CP
	local Scanner = CP and CP.Scanner
	local parts = {}
	local ladder = Scanner and Scanner:GetLadder(itemID)
	if ladder and ladder.tiers and #ladder.tiers > 0 then
		local tiers = {}
		for i = 1, math.min(maxTiers or 3, #ladder.tiers) do
			local t = ladder.tiers[i]
			tiers[#tiers + 1] = CS:MoneyShort(t[1]) .. " x" .. tostring(t[2])
		end
		parts[#parts + 1] = string.format("%s listed, cheapest %s", tostring(ladder.total or "?"), table.concat(tiers, ", "))
	else
		local listed = Scanner and Scanner:GetQuantity(itemID)
		if listed then parts[#parts + 1] = tostring(listed) .. " listed" end
	end
	local spd = CP and CP:GetSoldPerDay(itemID)
	if spd then parts[#parts + 1] = string.format("~%s sold/day", CS:FormatQty(spd)) end
	return #parts > 0 and table.concat(parts, DOT) or nil
end

-- How the item binds: "BoP" | "BoE" | "BoU" | "quest" | "no bind" | nil (not cached yet). An unpriced output that
-- is not soulbound may simply be missing from the AH (nobody makes it yet).
local BIND_NAMES = { [0] = "no bind", [1] = "BoP", [2] = "BoE", [3] = "BoU", [4] = "quest", [5] = "quest" }
function Rec:BindText(itemID)
	if not (itemID and C_Item and C_Item.GetItemInfo) then return nil end
	local ok, name, _, _, _, _, _, _, _, _, _, _, _, _, bindType = pcall(C_Item.GetItemInfo, itemID)
	if not ok or not name then return nil end
	return BIND_NAMES[bindType or 0] or ("bind " .. tostring(bindType))
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local WIDTH, PAD = 780, 8
local ROWS, ROW_H = 16, 20
local FOOTER_H = 30
local HEIGHT = 76 + 19 + 6 + ROWS * ROW_H + FOOTER_H -- toolbar + status, headers, rows, footer
local ROW_W = WIDTH - 24 -- list area (PAD each side) minus 4 px row inset each side

-- Column layouts (x from the row's left edge). `head` = false: no header of its own (the money half of a
-- "best recipe" cell sits under the name column's header).
local COLUMNS = {
	recipes = {
		{ key = "name", title = "Recipe", x = 24, w = 218 },
		{ key = "prof", title = "Profession", x = 246, w = 86 },
		{ key = "ilvl", title = "ilvl", x = 334, w = 28, justify = "RIGHT" },
		{ key = "cost", title = "Cost", x = 368, w = 68, justify = "RIGHT" },
		{ key = "sale", title = "Sells for", x = 440, w = 68, justify = "RIGHT" },
		{ key = "profit", title = "Profit", x = 512, w = 68, justify = "RIGHT" },
		{ key = "shuffle", title = "Shuffle", x = 584, w = 68, justify = "RIGHT" },
		{ key = "status", title = "Status", x = 664, w = ROW_W - 668 },
	},
	profs = {
		{ key = "name", title = "Profession", x = 6, w = 140 },
		{ key = "yours", title = "Your skill", x = 150, w = 64, justify = "RIGHT" },
		{ key = "n", title = "Recipes", x = 218, w = 52, justify = "RIGHT" },
		{ key = "priced", title = "Priced", x = 274, w = 46, justify = "RIGHT" },
		{ key = "profitable", title = "Profitable", x = 324, w = 62, justify = "RIGHT" },
		{ key = "best", title = "Best to sell", x = 400, w = 150, span = 204 },
		{ key = "bestMoney", head = false, x = 552, w = 52, justify = "RIGHT" },
		{ key = "bestShuffle", title = "Best shuffle", x = 614, w = 90, span = 142 },
		{ key = "bestShuffleMoney", head = false, x = 706, w = ROW_W - 710, justify = "RIGHT" },
	},
	uses = {
		{ key = "name", title = "Use", x = 24, w = 210 },
		{ key = "prof", title = "Profession", x = 238, w = 82 },
		{ key = "qty", title = "Needs", x = 322, w = 36, justify = "RIGHT" },
		{ key = "other", title = "Other mats", x = 364, w = 66, justify = "RIGHT" },
		{ key = "sale", title = "Sells for", x = 434, w = 66, justify = "RIGHT" },
		{ key = "perMat", title = "Per mat", x = 504, w = 62, justify = "RIGHT" },
		{ key = "gain", title = "vs selling", x = 570, w = 66, justify = "RIGHT" },
		{ key = "status", title = "Status", x = 648, w = ROW_W - 652 },
	},
}

local function TrySetFont(fs, fontName)
	if fs and _G[fontName] then pcall(fs.SetFontObject, fs, fontName) end
end

local function NewText(parent, font, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
	fs:SetJustifyH(justify or "LEFT")
	if fs.SetWordWrap then fs:SetWordWrap(false) end
	return fs
end

local function QualityHex(q)
	local colors = _G.ITEM_QUALITY_COLORS
	if colors and q and colors[q] then
		local col = colors[q]
		if col.hex then return (col.hex:gsub("^|c%x%x", "")) end
		if col.color and col.color.GenerateHexColor then return (col.color:GenerateHexColor():gsub("^%x%x", "")) end
	end
	return nil
end

local function QualityName(quality, text)
	local hex = QualityHex(quality)
	if not hex then return text end
	return "|cff" .. hex .. text .. "|r"
end

-- Money in a cell, coloured through Blizzard font objects: green profit, red loss, white otherwise.
local function SetMoney(fs, value, signed)
	if value == nil then
		TrySetFont(fs, "GameFontDisableSmall")
		fs:SetText(DASH)
		return
	end
	if signed then
		TrySetFont(fs, value >= 0 and "GameFontGreenSmall" or "GameFontRedSmall")
	else
		TrySetFont(fs, "GameFontHighlightSmall")
	end
	fs:SetText(CS:MoneyShort(value, signed and { sign = true } or nil))
end

local function SetPlain(fs, text, font)
	TrySetFont(fs, font or "GameFontHighlightSmall")
	fs:SetText(text or "")
end

local STATUS_TEXT = {
	known = { "Known", "GameFontGreenSmall" },
	learnable = { "Not learned", "GameFontNormalSmall" },
	other = { "Other profession", "GameFontDisableSmall" },
}

local SHUFFLE_REASON = {
	["not-disenchantable"] = "cannot be disenchanted",
	["no-output"] = "makes no item",
	["loading"] = "item data loading",
	["no-mat-prices"] = "no prices for the enchanting materials yet",
	["no-cost"] = "reagent prices missing",
	["unknown-bracket"] = "no disenchant table for this item level",
}

local ShowLabel -- defined with the menus below

-- Window, built like the Auction House's lists (same parts as the AH Scans window): portrait window, toolbar
-- right of the portrait (Material / Profession / Show dropdowns, search box, Scan AH), a status line, the AH
-- column headers (AuctionHouseTableHeaderStringTemplate, with their own sort arrow) over an InsetFrameTemplate
-- with the Buy tab's background art and the AH row highlight, and Professions / Recipes / Mat uses as tabs
-- under the window. Default UI templates, font objects and colours only.
local PORTRAIT_ICON = "Interface\\Icons\\INV_Misc_Book_09"
local TOOLBAR_Y, STATUS_Y = -30, -58
local LIST_TOP, LIST_HEADER_H = -76, 19

local function Try(obj, method, ...)
	if obj and type(obj[method]) == "function" then return pcall(obj[method], obj, ...) end
end

local function CreateRow(area, i)
	local row = CreateFrame("Button", nil, area)
	row:SetSize(ROW_W, ROW_H)
	row:SetPoint("TOPLEFT", area, "TOPLEFT", 4, -LIST_HEADER_H - 3 - (i - 1) * ROW_H)
	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	Try(hl, "SetAllPoints", row)
	if not (hl.SetAtlas and pcall(hl.SetAtlas, hl, "auctionhouse-ui-row-highlight")) then hl:SetColorTexture(1, 1, 1, 0.08) end
	Try(hl, "SetBlendMode", "ADD")
	if row.RegisterForClicks then row:RegisterForClicks("LeftButtonUp") end
	row.Icon = row:CreateTexture(nil, "ARTWORK")
	row.Icon:SetSize(16, 16)
	row.Icon:SetPoint("LEFT", 4, 0)
	Try(row.Icon, "SetTexCoord", 0.07, 0.93, 0.07, 0.93)
	row.cells = {}
	for view, cols in pairs(COLUMNS) do
		row.cells[view] = {}
		for _, col in ipairs(cols) do
			local fs = NewText(row, "GameFontHighlightSmall", col.justify)
			fs:SetPoint("LEFT", col.x, 0)
			fs:SetWidth(col.w)
			row.cells[view][col.key] = fs
		end
	end
	row:SetScript("OnEnter", function(self) Rec:ShowRowTooltip(self) end)
	row:SetScript("OnLeave", function() if GameTooltip_Hide then GameTooltip_Hide() elseif GameTooltip then GameTooltip:Hide() end end)
	row:SetScript("OnClick", function(self) Rec:ClickRow(self) end)
	row:Hide()
	return row
end

-- The AH column header for one column. Headers of a view sit edge to edge (each runs to the next one's x;
-- the first also covers the icon), overlapping by 2 px as the AH's own table builder lays them out.
local function CreateHeader(area, view, col, x0, x1, first)
	local ok, h = pcall(CreateFrame, "Button", nil, area, "AuctionHouseTableHeaderStringTemplate")
	if not ok or not h then
		h = CreateFrame("Button", nil, area)
		h.Text = NewText(h, "GameFontHighlightSmall", "LEFT")
		h.Text:SetPoint("LEFT", h, "LEFT", 8, 0)
	end
	local overlap = first and 0 or 2
	h:SetPoint("TOPLEFT", area, "TOPLEFT", 4 + x0 - overlap, -1)
	h:SetSize(x1 - x0 + overlap, LIST_HEADER_H)
	h.col, h.view = col, view
	if h.Arrow then h.Arrow:Hide() end
	if view == "uses" then
		h:SetScript("OnClick", nil) -- fixed order: best value per unit first
	else
		h:SetScript("OnClick", function(self) Rec:SetSort(self.view, self.col.key) end)
	end
	h:SetScript("OnEnter", function(self)
		if self.view == "uses" then return end
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(self.col.title)
		GameTooltip:AddLine("Click to sort; again to reverse.", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	h:SetScript("OnLeave", function() if GameTooltip_Hide then GameTooltip_Hide() else GameTooltip:Hide() end end)
	h:Hide()
	return h
end

-- Header text plus the sort direction: the template's arrow (flipped for ascending), text arrows otherwise.
local function SetHeaderLabel(h, sorted, desc)
	local title = h.col.title
	if h.Arrow then
		h.Arrow:SetShown(sorted)
		if sorted and h.Arrow.SetTexCoord then
			if desc then h.Arrow:SetTexCoord(0, 1, 0, 1) else h.Arrow:SetTexCoord(0, 1, 1, 0) end
		end
	elseif sorted then
		title = title .. (desc and " v" or " ^")
	end
	if h.SetText then h:SetText(title) end
	if h.Text and h.Text ~= h and h.Text.SetText then h.Text:SetText(title) end
end

local function Tip(b, title, body)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(title)
		if body then GameTooltip:AddLine(type(body) == "function" and body() or body, 1, 1, 1, true) end
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() if GameTooltip_Hide then GameTooltip_Hide() else GameTooltip:Hide() end end)
end

-- A filter picker: the default UI's dropdown (it opens and closes itself) showing labelFn(); a panel button
-- that opens the same menu (or cycles) on clients without it.
local function CreatePicker(f, width, build, labelFn, fallbackClick)
	local ok, dd = pcall(CreateFrame, "DropdownButton", nil, f, "WowStyle1DropdownTemplate")
	if ok and dd and dd.SetupMenu then
		dd:SetSize(width, 22)
		if dd.SetSelectionTranslator then pcall(dd.SetSelectionTranslator, dd, function() return labelFn() end) end
		dd:SetupMenu(function(_, root) build(root) end)
		dd.csDropdown = true
		dd.csLabel = labelFn
		return dd
	end
	local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetScript("OnClick", fallbackClick)
	b.csLabel = labelFn
	return b
end

-- Shows the picker's current label (dropdowns rebuild their selection text, buttons set it).
local function RefreshPicker(p)
	local label = p.csLabel()
	if p.csDropdown then
		if p.csLast == label then return end
		p.csLast = label
		if p.GenerateMenu then pcall(p.GenerateMenu, p) end
		if not p.SetSelectionTranslator and p.OverrideText then pcall(p.OverrideText, p, label) end
	else
		p:SetText(label)
	end
end

-- Professions / Recipes / Mat uses: tabs under the window like the AH's Buy / Sell (panel buttons as fallback).
local function CreateViewTabs(f, name)
	local panelTabs = PanelTemplates_SetNumTabs and PanelTemplates_SetTab and true or false
	local specs = {
		{ "profs", "Professions", "One row per profession: how many of its recipes sell for more than their reagents cost, and the best of them. Click a profession to see its recipes." },
		{ "recipes", "Recipes", "Every recipe, learned or not. Click a column header to sort." },
		{ "uses", "Mat uses", "Everything a material goes into: every recipe that uses it, valued per unit of the material against simply selling it. Pick the material in the dropdown, or type /cs uses <item>." },
	}
	local tabs = {}
	for i, spec in ipairs(specs) do
		local tab
		if panelTabs then
			local made, t = pcall(CreateFrame, "Button", name .. "Tab" .. i, f, "PanelTabButtonTemplate")
			if made and t then tab = t end
		end
		if not tab then
			tab = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
			tab:SetSize(90, 22)
			panelTabs = false
		end
		tab:SetID(i)
		tab:SetText(spec[2])
		tab.csView = spec[1]
		tab:SetScript("OnClick", function(self) Rec:SetView(self.csView) end)
		if i == 1 then
			tab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 12, panelTabs and 2 or -2)
		else
			tab:SetPoint("LEFT", tabs[i - 1], "RIGHT", panelTabs and -15 or 4, 0)
		end
		if panelTabs and PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 0) end
		Tip(tab, spec[2], spec[3])
		tabs[i] = tab
	end
	if panelTabs then
		f.numTabs = #tabs
		pcall(PanelTemplates_SetNumTabs, f, #tabs)
	end
	f.csPanelTabs = panelTabs
	return tabs
end

local function CreateWindow()
	local name = "CraftShuffleRecipes"
	local f
	for _, template in ipairs({ "PortraitFrameTemplate", "ButtonFrameTemplate", "BasicFrameTemplateWithInset" }) do
		local ok, frame = pcall(CreateFrame, "Frame", name, UIParent, template)
		if ok and frame then f = frame break end
	end
	if not f then
		f = CreateFrame("Frame", name, UIParent)
		f.TitleText = NewText(f, "GameFontNormal", "CENTER")
		f.TitleText:SetPoint("TOP", 0, -8)
		f.CloseButton = CreateFrame("Button", nil, f, "UIPanelCloseButton")
		f.CloseButton:SetPoint("TOPRIGHT", -4, -4)
	end
	if f.Inset and f.Inset.Hide then f.Inset:Hide() end
	f:SetSize(WIDTH, HEIGHT)
	f:SetPoint("CENTER")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) self:StartMoving() end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		CS.db.planner.recipesPos = { point, relPoint, x, y }
	end)
	f:SetFrameStrata("HIGH")
	f:Hide()
	local title = "Recipe Browser"
	if f.SetTitle then pcall(f.SetTitle, f, title) elseif f.TitleText then f.TitleText:SetText(title) end
	local portrait = (f.PortraitContainer and f.PortraitContainer.portrait) or f.portrait
	if f.SetPortraitToAsset then
		pcall(f.SetPortraitToAsset, f, PORTRAIT_ICON)
	elseif portrait and SetPortraitToTexture then
		pcall(SetPortraitToTexture, portrait, PORTRAIT_ICON)
	end
	local x0 = portrait and 64 or PAD
	if UISpecialFrames then table.insert(UISpecialFrames, name) end

	-- toolbar, right of the portrait: [Material] Profession, Show, search; Scan AH on the right
	f.MatButton = CreatePicker(f, 160, function(root) Rec:BuildMatMenu(root) end,
		function() return Rec.mat and CS:ItemName(Rec.mat) or "Material" end,
		function(self) Rec:OpenMatMenu(self) end)
	f.MatButton:SetPoint("TOPLEFT", f, "TOPLEFT", x0, TOOLBAR_Y)
	f.ProfButton = CreatePicker(f, 150, function(root) Rec:BuildProfMenu(root) end,
		function() return Rec.prof and Rec:ProfName(Rec.prof) or "All professions" end,
		function(self) Rec:OpenProfMenu(self) end)
	f.ShowButton = CreatePicker(f, 130, function(root) Rec:BuildShowMenu(root) end,
		function() return ShowLabel(Rec.show) end,
		function(self) Rec:OpenShowMenu(self) end)
	f.ShowButton:SetPoint("LEFT", f.ProfButton, "RIGHT", 6, 0)
	f.csToolbarX = x0

	local okSearch, search = pcall(CreateFrame, "EditBox", nil, f, "SearchBoxTemplate")
	if not okSearch or not search then search = CreateFrame("EditBox", nil, f, "InputBoxTemplate") end
	search:SetSize(150, 20)
	search:SetPoint("LEFT", f.ShowButton, "RIGHT", 14, 0)
	if search.SetAutoFocus then search:SetAutoFocus(false) end
	search:HookScript("OnTextChanged", function(self)
		local text = self:GetText() or ""
		if text == Rec.search then return end
		Rec.search = text
		Rec.offset = 0
		if text ~= "" and Rec.view == "profs" then Rec.view = "recipes" end
		Rec:Refresh()
	end)
	search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	f.Search = search

	f.ScanButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.ScanButton:SetSize(90, 22)
	f.ScanButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, TOOLBAR_Y)
	f.ScanButton:SetText("Scan AH")
	f.ScanButton:SetScript("OnClick", function() Rec:ScanAH() end)
	if f.ScanButton.SetMotionScriptsWhileDisabled then f.ScanButton:SetMotionScriptsWhileDisabled(true) end
	Tip(f.ScanButton, "Scan AH", "Full browse scan through CraftProfit: the lowest buyout of every item listed, so reagents and crafted items get prices. The Auction House must be open.")

	f.Status = NewText(f, "GameFontHighlightSmall", "LEFT")
	f.Status:SetPoint("TOPLEFT", f, "TOPLEFT", 14, STATUS_Y)
	f.Status:SetPoint("RIGHT", f, "RIGHT", -14, 0)

	-- the list: AH column headers on the window background, the inset with the Buy tab's art under them
	local area = CreateFrame("Frame", nil, f)
	area:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, LIST_TOP)
	area:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, FOOTER_H)
	f.ListArea = area
	local okBox, box = pcall(CreateFrame, "Frame", nil, area, "InsetFrameTemplate")
	if okBox and box then
		box:SetPoint("TOPLEFT", area, "TOPLEFT", 0, -LIST_HEADER_H)
		box:SetPoint("BOTTOMRIGHT", area, "BOTTOMRIGHT", 0, 0)
		box:SetFrameLevel(area:GetFrameLevel())
		local art = box:CreateTexture(nil, "BACKGROUND", nil, 2)
		if art.SetAtlas and pcall(art.SetAtlas, art, "auctionhouse-background-index") then
			art:SetPoint("TOPLEFT", box, "TOPLEFT", 3, -3)
			art:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -3, 3)
		else
			art:Hide()
		end
		f.ListBox = box
	end

	f.Headers = {}
	for view, cols in pairs(COLUMNS) do
		f.Headers[view] = {}
		local heads = {}
		for _, col in ipairs(cols) do
			if col.head ~= false then heads[#heads + 1] = col end
		end
		for i, col in ipairs(heads) do
			local x0h = i == 1 and 0 or (col.x - 2)
			local x1h = heads[i + 1] and (heads[i + 1].x - 2) or ROW_W
			table.insert(f.Headers[view], CreateHeader(area, view, col, x0h, x1h, i == 1))
		end
	end

	f.Rows = {}
	for i = 1, ROWS do f.Rows[i] = CreateRow(area, i) end
	f.Empty = NewText(area, "GameFontDisable", "LEFT")
	f.Empty:SetPoint("TOPLEFT", area, "TOPLEFT", 14, -LIST_HEADER_H - 12)
	f.Empty:SetPoint("RIGHT", area, "RIGHT", -14, 0)
	if f.Empty.SetWordWrap then f.Empty:SetWordWrap(true) end
	if f.EnableMouseWheel then f:EnableMouseWheel(true) end
	f:SetScript("OnMouseWheel", function(_, delta) Rec:Scroll(-delta * 3) end)

	f.Foot = NewText(f, "GameFontDisableSmall", "LEFT")
	f.Foot:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 10)
	f.Page = NewText(f, "GameFontDisableSmall", "RIGHT")
	f.Page:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 10)
	f.Foot:SetPoint("RIGHT", f.Page, "LEFT", -8, 0)

	local tabs = CreateViewTabs(f, name)
	f.ViewProfs, f.ViewRecipes, f.ViewUses = tabs[1], tabs[2], tabs[3]
	return f
end

function Rec:GetFrame()
	if not self.frame then
		self.frame = CreateWindow()
		local pos = CS.db and CS.db.planner and CS.db.planner.recipesPos
		if pos then
			self.frame:ClearAllPoints()
			self.frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
		end
	end
	return self.frame
end

function Rec:Open(view)
	local f = self:GetFrame()
	if view then self.view = view end
	f:Show()
	self.offset = 0
	self:GetCatalog()
	self:Refresh()
end

function Rec:Toggle()
	if self.frame and self.frame:IsShown() then self.frame:Hide() else self:Open() end
end

function Rec:SetView(view)
	if view ~= "recipes" and view ~= "uses" then view = "profs" end
	if view ~= self.view then
		self.view = view
		self.offset = 0
	end
	self:Refresh()
end

function Rec:SetProf(lineID)
	self.prof = lineID
	self.offset = 0
	if self.view ~= "uses" then self.view = "recipes" end
	self:Refresh()
end

function Rec:SetShow(show)
	self.show = SHOW_MATCH[show] and show or "all"
	self.offset = 0
	if self.view ~= "uses" then self.view = "recipes" end
	self:Refresh()
end

-- Same column again flips the direction; a new column starts with the natural direction (names A-Z,
-- numbers high to low).
function Rec:SetSort(view, key)
	local spec = self.sort[view]
	if spec.key == key then
		spec.desc = not spec.desc
	else
		spec.key = key
		spec.desc = not (key == "name" or key == "prof" or key == "status")
	end
	self.offset = 0
	self:Refresh()
end

function Rec:Scroll(step)
	local n = #(self.list or {})
	local offset = math.max(0, math.min(math.max(0, n - ROWS), (self.offset or 0) + step))
	if offset ~= self.offset then
		self.offset = offset
		self:Render()
	end
end

function Rec:ScanAH()
	local Scanner = CS.CP and CS.CP.Scanner
	if not Scanner then return end
	if not Scanner.ahOpen then
		CS:Print("open the Auction House first.")
		return
	end
	Scanner:Start()
	self:Render()
end

local function SortedProfs()
	local list = {}
	for _, p in pairs(Rec.catalog and Rec.catalog.profs or {}) do list[#list + 1] = p end
	table.sort(list, function(a, b) return a.name < b.name end)
	return list
end

function Rec:BuildProfMenu(root)
	root:CreateTitle("Profession")
	root:CreateRadio("All professions", function() return Rec.prof == nil end, function() Rec:SetProf(nil) end)
	for _, p in ipairs(SortedProfs()) do
		local you = Rec.mine and Rec.mine[p.id]
		local text = p.name .. (you and "  (yours)" or "")
		root:CreateRadio(text, function() return Rec.prof == p.id end, function() Rec:SetProf(p.id) end)
	end
end

function Rec:BuildShowMenu(root)
	root:CreateTitle("Show")
	for _, s in ipairs(Rec.SHOW_LABELS) do
		root:CreateRadio(s[2], function() return Rec.show == s[1] end, function() Rec:SetShow(s[1]) end)
	end
end

function Rec:BuildMatMenu(root)
	root:CreateTitle("Material")
	for _, m in ipairs(self:MatChoices()) do
		root:CreateRadio(string.format("%s  (%d)", m.name, m.n), function() return Rec.mat == m.id end, function() Rec:SetMat(m.id) end)
	end
end

-- Fallback pickers (no dropdown template): the same menus as context menus on the buttons, else cycling.
function Rec:OpenProfMenu(owner)
	local profs = SortedProfs()
	if CS:ToggleContextMenu(owner, function(_, root) Rec:BuildProfMenu(root) end) then return end
	-- fallback: cycle
	local idx = 0
	for i, p in ipairs(profs) do if p.id == self.prof then idx = i end end
	local nextP = profs[idx + 1]
	self:SetProf(nextP and nextP.id or nil)
end

function Rec:OpenShowMenu(owner)
	if CS:ToggleContextMenu(owner, function(_, root) Rec:BuildShowMenu(root) end) then return end
	local idx = 0
	for i, s in ipairs(self.SHOW_LABELS) do if s[1] == self.show then idx = i end end
	local nextS = self.SHOW_LABELS[idx % #self.SHOW_LABELS + 1]
	self:SetShow(nextS[1])
end

function Rec:OpenMatMenu(owner)
	local mats = self:MatChoices()
	if CS:ToggleContextMenu(owner, function(_, root) Rec:BuildMatMenu(root) end) then return end
	local idx = 0
	for i, m in ipairs(mats) do if m.id == self.mat then idx = i end end
	local nextM = mats[idx % math.max(1, #mats) + 1]
	if nextM then self:SetMat(nextM.id) end
end

ShowLabel = function(show)
	for _, s in ipairs(Rec.SHOW_LABELS) do if s[1] == show then return s[2] end end
	return show
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

function Rec:Refresh()
	local f = self.frame
	if not f or not f:IsShown() then return end
	self.rows = self:BuildRows()
	if self.view == "recipes" then
		self.list = self:FilterRecipes(self.rows)
	elseif self.view == "uses" then
		self.list, self.usesStats = self:UsesRows(self.rows, self.mat)
	else
		self.list = self:Summaries(self.rows)
	end
	self.offset = math.max(0, math.min(self.offset or 0, math.max(0, #self.list - ROWS)))
	self:Render()
end

local renderPending = false
function Rec:RenderSoon()
	if renderPending or not (self.frame and self.frame:IsShown()) then return end
	renderPending = true
	After(0.2, function()
		renderPending = false
		Rec:Render()
	end)
end

local function ItemIcon(itemID)
	if itemID and C_Item and C_Item.GetItemIconByID then
		local ok, icon = pcall(C_Item.GetItemIconByID, itemID)
		if ok and (type(icon) == "number" or type(icon) == "string") then return icon end
	end
	return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function PriceAgeText()
	local CP = CS.CP
	local realm = CP and CP.GetRealmDB and CP:GetRealmDB()
	local last = realm and realm.lastScan or 0
	if last <= 0 then return nil end
	return CS:Age(time() - last)
end

function Rec:RenderStatus(f)
	local Scanner = CS.CP and CS.CP.Scanner
	if Scanner and Scanner.running then
		f.ScanButton:SetText("Scanning...")
		f.ScanButton:Disable()
	else
		f.ScanButton:SetText("Scan AH")
		if Scanner and Scanner.ahOpen then f.ScanButton:Enable() else f.ScanButton:Disable() end
	end
	if self.unavailable then
		SetPlain(f.Status, "This client does not offer the recipe lookup the browser needs (C_TradeSkillUI.GetTradeSkillLineForRecipe).", "GameFontRedSmall")
		return
	end
	if self.scanning then
		SetPlain(f.Status, string.format("Reading every profession's recipes... %d%%", math.floor((self.progress or 0) * 100)), "GameFontNormalSmall")
		return
	end
	local c = self.catalog
	if not c then
		SetPlain(f.Status, "", nil)
		return
	end
	local nProfs = 0
	for _ in pairs(c.profs) do nProfs = nProfs + 1 end
	local age = PriceAgeText()
	local parts = { string.format("%d recipes in %d professions", #c.list, nProfs) }
	if age then
		parts[#parts + 1] = "prices from the AH scan " .. age
	else
		parts[#parts + 1] = "no AH scan yet: open the Auction House and press Scan AH for prices"
	end
	if self.view == "uses" then
		SetPlain(f.Status, self:UsesStatusText(), "GameFontHighlightSmall")
		return
	end
	if self.view == "recipes" then
		parts[#parts + 1] = string.format("%d shown", #(self.list or {}))
	end
	SetPlain(f.Status, table.concat(parts, DOT), age and "GameFontHighlightSmall" or "GameFontNormalSmall")
end

function Rec:Render()
	local f = self.frame
	if not f or not f:IsShown() then return end
	local view = (self.view == "recipes" or self.view == "uses") and self.view or "profs"
	local list = self.list or {}

	-- the view's tab is highlighted the AH way; panel-button fallback: the current one is disabled
	local tabIndex = { profs = 1, recipes = 2, uses = 3 }
	if f.csPanelTabs and PanelTemplates_SetTab then
		pcall(PanelTemplates_SetTab, f, tabIndex[view])
	else
		for v, b in pairs({ profs = f.ViewProfs, recipes = f.ViewRecipes, uses = f.ViewUses }) do
			if v == view then b:Disable() else b:Enable() end
		end
	end
	f.MatButton:SetShown(view == "uses")
	f.ProfButton:ClearAllPoints()
	if view == "uses" then
		f.ProfButton:SetPoint("LEFT", f.MatButton, "RIGHT", 6, 0)
	else
		f.ProfButton:SetPoint("TOPLEFT", f, "TOPLEFT", f.csToolbarX, -30)
	end
	RefreshPicker(f.MatButton)
	RefreshPicker(f.ProfButton)
	RefreshPicker(f.ShowButton)
	self:RenderStatus(f)

	local spec = self.sort[view]
	for v, headers in pairs(f.Headers) do
		for _, h in ipairs(headers) do
			if v == view then
				SetHeaderLabel(h, v ~= "uses" and h.col.key == spec.key, spec.desc)
				h:Show()
			else
				h:Hide()
			end
		end
	end

	local offset = self.offset or 0
	for i, row in ipairs(f.Rows) do
		local item = list[offset + i]
		row.item, row.view = item, view
		for v, cells in pairs(row.cells) do
			for _, fs in pairs(cells) do fs:SetShown(v == view and item ~= nil) end
		end
		if item then
			if view == "recipes" then self:RenderRecipeRow(row, item)
			elseif view == "uses" then self:RenderUsesRow(row, item)
			else self:RenderProfRow(row, item) end
			row:Show()
		else
			row:Hide()
		end
	end

	if self.scanning or self.unavailable or not self.catalog then
		f.Empty:SetText(self.scanning and "Reading the recipe list, once per session (about a second)." or "")
		f.Empty:Show()
	elseif #list == 0 then
		f.Empty:SetText(view == "profs" and "No professions found." or (view == "uses"
			and "No recipe uses this material (or none matches the profession, show filter and search)."
			or "No recipe matches the profession, show filter and search."))
		f.Empty:Show()
	else
		f.Empty:Hide()
	end

	if view == "uses" then
		f.Foot:SetText("Per mat = (sale " .. DASH .. " AH cut " .. DASH .. " other reagents) / units used. vs selling = per mat " .. DASH .. " what one unit nets on the AH. Enchants cannot be sold: they are demand only.")
	elseif view == "profs" then
		f.Foot:SetText("Profitable = sells for more than its reagents cost after the AH cut. Skill needed and where a recipe is learned are not available for recipes you do not know.")
	else
		f.Foot:SetText("Profit = sale " .. DASH .. " AH cut " .. DASH .. " reagents. Shuffle = disenchant materials " .. DASH .. " cut " .. DASH .. " reagents. Click: shuffle planner. Shift-click: link.")
	end
	if #list > ROWS then
		f.Page:SetText(string.format("%d-%d of %d", offset + 1, math.min(#list, offset + ROWS), #list))
	else
		f.Page:SetText("")
	end
end

function Rec:RenderRecipeRow(row, r)
	local cells = row.cells.recipes
	row.Icon:SetTexture(ItemIcon(r.outputItemID))
	row.Icon:Show()
	SetPlain(cells.name, QualityName(r.quality, r.name))
	SetPlain(cells.prof, self:ProfName(r.prof), "GameFontDisableSmall")
	SetPlain(cells.ilvl, r.ilvl and tostring(r.ilvl) or "", "GameFontDisableSmall")
	SetMoney(cells.cost, r.cost)
	SetMoney(cells.sale, r.sale)
	SetMoney(cells.profit, r.profit, true)
	SetMoney(cells.shuffle, r.shuffle, true)
	local st = STATUS_TEXT[r.status] or STATUS_TEXT.other
	SetPlain(cells.status, st[1], st[2])
end

local USES_STATUS = {
	anyone = { "Right-click, anyone", "GameFontGreenSmall" },
}

function Rec:RenderUsesRow(row, u)
	local cells = row.cells.uses
	row.Icon:SetTexture(u.conversion and ItemIcon(u.outputItemID) or ItemIcon(u.outputItemID or self.mat))
	row.Icon:Show()
	SetPlain(cells.name, u.kind == "enchant" and u.name or QualityName(u.quality, u.name), u.kind == "enchant" and "GameFontDisableSmall" or nil)
	SetPlain(cells.prof, u.conversion and DASH or self:ProfName(u.prof), "GameFontDisableSmall")
	SetPlain(cells.qty, tostring(u.qty or 1))
	if u.otherComplete == false then SetPlain(cells.other, "?", "GameFontDisableSmall") else SetMoney(cells.other, u.other) end
	if u.kind == "enchant" then
		SetPlain(cells.sale, "enchant", "GameFontDisableSmall")
	else
		SetMoney(cells.sale, u.sale)
	end
	SetMoney(cells.perMat, u.perMat)
	SetMoney(cells.gain, u.gain, true)
	local st = USES_STATUS[u.status] or STATUS_TEXT[u.status] or STATUS_TEXT.other
	SetPlain(cells.status, st[1], st[2])
end

function Rec:UsesStatusText()
	local mat = self.mat
	if not mat then return "Pick a material." end
	local st = self.usesStats or {}
	local parts = { CS:ItemName(mat) }
	local sellNet, unit = self:MatSellNet(mat)
	if unit then
		parts[#parts + 1] = string.format("sells for %s (%s after cut)", CS:MoneyShort(unit), CS:MoneyShort(sellNet))
	else
		parts[#parts + 1] = "no AH price yet"
	end
	parts[#parts + 1] = string.format("used by %d items + %d enchants", st.items or 0, st.enchants or 0)
	parts[#parts + 1] = string.format("%d beat selling", st.better or 0)
	local market = self:MatMarketText(mat, 2)
	if market then parts[#parts + 1] = market end
	return table.concat(parts, DOT)
end

function Rec:RenderProfRow(row, p)
	local cells = row.cells.profs
	row.Icon:Hide()
	SetPlain(cells.name, p.name, p.mine and "GameFontNormalSmall" or "GameFontHighlightSmall")
	if p.mine and p.rank then
		SetPlain(cells.yours, string.format("%d/%d", p.rank, p.max or 0), "GameFontGreenSmall")
	else
		SetPlain(cells.yours, DASH, "GameFontDisableSmall")
	end
	SetPlain(cells.n, tostring(p.n))
	SetPlain(cells.priced, tostring(p.priced), "GameFontDisableSmall")
	SetPlain(cells.profitable, tostring(p.profitable), p.profitable > 0 and "GameFontGreenSmall" or "GameFontDisableSmall")
	if p.best then
		SetPlain(cells.best, QualityName(p.best.quality, p.best.name))
		SetMoney(cells.bestMoney, p.best.profit, true)
	else
		SetPlain(cells.best, p.priced > 0 and "none profitable" or "no prices yet", "GameFontDisableSmall")
		SetPlain(cells.bestMoney, "")
	end
	if p.bestShuffle then
		SetPlain(cells.bestShuffle, QualityName(p.bestShuffle.quality, p.bestShuffle.name))
		SetMoney(cells.bestShuffleMoney, p.bestShuffle.shuffle, true)
	else
		SetPlain(cells.bestShuffle, DASH, "GameFontDisableSmall")
		SetPlain(cells.bestShuffleMoney, "")
	end
end

---------------------------------------------------------------------------
-- Tooltips and clicks
---------------------------------------------------------------------------

local function Line(left, right, r, g, b)
	GameTooltip:AddDoubleLine(left, right, r or 0.8, g or 0.8, b or 0.8, 1, 1, 1)
end

function Rec:ShowRowTooltip(row)
	local item = row.item
	if not item then return end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	if row.view == "profs" then
		GameTooltip:AddLine(item.name)
		if item.mine then GameTooltip:AddLine(string.format("Yours: skill %d/%d, %d of %d recipes known", item.rank or 0, item.max or 0, item.known, item.n), 0.25, 1, 0.25) end
		GameTooltip:AddLine(string.format("%d recipes, %d with complete prices, %d profitable", item.n, item.priced, item.profitable), 1, 1, 1, true)
		if #(item.top or {}) > 0 then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Best to sell", 1, 0.82, 0)
			for _, r in ipairs(item.top) do Line(QualityName(r.quality, r.name), CS:Money(r.profit, { sign = true })) end
		end
		if item.bestShuffle then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Best shuffle", 1, 0.82, 0)
			Line(QualityName(item.bestShuffle.quality, item.bestShuffle.name), CS:Money(item.bestShuffle.shuffle, { sign = true }))
		end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Click: show this profession's recipes.", 0.6, 0.6, 0.6, true)
		GameTooltip:Show()
		return
	end

	if row.view == "uses" and item.conversion then
		if item.outputItemID and GameTooltip.SetItemByID then pcall(GameTooltip.SetItemByID, GameTooltip, item.outputItemID) end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(item.name, 1, 0.82, 0)
		GameTooltip:AddLine("Right-click the essence in your bags. No profession needed in Classic (check that Forever agrees).", 1, 1, 1, true)
		if item.sale then Line("Sells for", CS:Money(item.sale)) end
		if item.perMat then Line("Per " .. CS:ItemName(self.mat), CS:Money(item.perMat)) end
		if item.gain then Line("vs selling it as is", CS:Money(item.gain, { sign = true }), 1, 0.82, 0) end
		local market = self:MatMarketText(item.outputItemID, 3)
		if market then GameTooltip:AddLine(CS:ItemName(item.outputItemID) .. ": " .. market, 0.6, 0.6, 0.6, true) end
		GameTooltip:Show()
		return
	end

	local r = item
	local shown = false
	if r.outputItemID and GameTooltip.SetItemByID then shown = pcall(GameTooltip.SetItemByID, GameTooltip, r.outputItemID) end
	if not shown then GameTooltip:AddLine(r.name) end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("CraftShuffle " .. DASH .. " " .. r.name, 1, 0.82, 0)
	local st = STATUS_TEXT[r.status] or STATUS_TEXT.other
	GameTooltip:AddLine(self:ProfName(r.prof) .. DOT .. st[1], 0.6, 0.6, 0.6)
	local base = r.base
	if base then
		for _, g in ipairs(base.reagents or {}) do
			local label = string.format("%dx %s", g.qty or 1, CS:ItemName(g.itemID))
			if g.kind == "craft" then label = label .. "  (crafted)" elseif g.kind == "vendor" then label = label .. "  (vendor)" end
			Line(label, g.total and CS:Money(g.total) or "?")
		end
		Line("Reagents", r.cost and CS:Money(r.cost) or "incomplete", 1, 0.82, 0)
		if r.sale then
			Line(string.format("Sells for%s", (base.quantity or 1) ~= 1 and string.format(" (x%s)", tostring(base.quantity)) or ""), CS:Money(r.sale))
			Line("AH cut", "-" .. CS:Money(base.cut or 0))
		elseif r.outputItemID then
			Line("Sells for", "no price yet")
		end
		if r.profit then Line("Profit", CS:Money(r.profit, { sign = true }), 1, 0.82, 0) end
	end
	if row.view == "uses" then
		local matName = CS:ItemName(self.mat)
		if r.kind == "enchant" then
			GameTooltip:AddLine("Enchant: goes straight onto gear, so it cannot be sold on the AH. Enchanters buy " .. matName .. " for these.", 1, 1, 1, true)
		end
		if r.perMat then Line(string.format("Per %s (uses %d)", matName, r.qty or 1), CS:Money(r.perMat), 1, 0.82, 0) end
		if r.gain then Line("vs selling " .. matName, CS:Money(r.gain, { sign = true }), 1, 0.82, 0) end
		if r.outputItemID then
			local market = self:MatMarketText(r.outputItemID, 3)
			if market then GameTooltip:AddLine("Output: " .. market, 0.6, 0.6, 0.6, true) end
			local bind = self:BindText(r.outputItemID)
			if bind then GameTooltip:AddLine("Output binds: " .. bind, 0.6, 0.6, 0.6) end
		end
	end
	if r.shuffle then
		Line("Shuffle net" .. (r.eco.de and r.eco.de.summary and (" (" .. r.eco.de.summary .. ")") or ""), CS:Money(r.shuffle, { sign = true }), 1, 0.82, 0)
	elseif r.shuffleStatus and SHUFFLE_REASON[r.shuffleStatus] then
		Line("Shuffle", SHUFFLE_REASON[r.shuffleStatus])
	end
	if r.status ~= "known" then
		GameTooltip:AddLine("Skill needed and where it is learned: not available from the game for recipes you do not know.", 0.6, 0.6, 0.6, true)
	end
	GameTooltip:AddLine(self:CanPlan(r) and "Click: open in the shuffle planner. Shift-click: link the item." or "Shift-click: link the item.", 0.6, 0.6, 0.6, true)
	GameTooltip:Show()
end

-- The planner is about disenchanting, so only recipes whose item can be disenchanted go there.
function Rec:CanPlan(r)
	local st = r.shuffleStatus
	return r.outputItemID ~= nil and st ~= "not-disenchantable" and st ~= "no-output" and st ~= "error"
end

function Rec:ClickRow(row)
	local item = row.item
	if not item then return end
	if row.view == "profs" then
		self:SetProf(item.id)
		return
	end
	if item.conversion then return end
	if IsShiftKeyDown and IsShiftKeyDown() then
		local link
		if item.outputItemID and C_Item and C_Item.GetItemInfo then
			local ok, _, l = pcall(C_Item.GetItemInfo, item.outputItemID)
			if ok then link = l end
		end
		if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
		return
	end
	if self:CanPlan(item) and CS.Planner then CS.Planner:Open(item.recipeID) end
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

local refreshPending = false
local function RefreshSoon(delay)
	if not (Rec.frame and Rec.frame:IsShown()) or not Rec.catalog then return end
	if refreshPending then return end
	refreshPending = true
	After(type(delay) == "number" and delay or 0.3, function()
		refreshPending = false
		Rec:Refresh()
	end)
end
Rec.RefreshSoon = RefreshSoon

-- item data arrives one item at a time while the list first loads: gather those into one refresh per second
CS:On("ITEM_LOADED", function() RefreshSoon(1) end)
CS:On("DE_RECORDED", RefreshSoon)
CS:On("SETTINGS_CHANGED", RefreshSoon)
if CS.CP then
	CS.CP:On("PRICES_UPDATED", RefreshSoon)
	CS.CP:On("VENDOR_UPDATED", RefreshSoon)
	CS.CP:On("CRAFTS_UPDATED", RefreshSoon)
	CS.CP:On("SETTINGS_CHANGED", RefreshSoon)
	CS.CP:On("SCAN_STARTED", function() Rec:RenderSoon() end)
	CS.CP:On("SCAN_FINISHED", RefreshSoon)
end
CS:RegisterEvent("AUCTION_HOUSE_SHOW", function() Rec:RenderSoon() end)
CS:RegisterEvent("AUCTION_HOUSE_CLOSED", function() Rec:RenderSoon() end)
CS:RegisterEvent("NEW_RECIPE_LEARNED", function() RefreshSoon() end)
CS:RegisterEvent("SKILL_LINES_CHANGED", function() RefreshSoon(1) end)

-- /cs uses <item> [n]: opens the Material uses view and prints the report to chat (for copying out of the game).
function Rec:SlashUses(rest)
	rest = rest or ""
	local n = tonumber(rest:match("%s(%d+)%s*$") or "")
	local text = n and rest:gsub("%s%d+%s*$", "") or rest
	local itemID = text:match("%S") and self:ResolveItem(text) or self.mat
	if not itemID then
		CS:Print("unknown item %q: use an item link, an item ID or a material name (Strange Dust, Greater Magic Essence, ...).", text)
		return
	end
	self.mat = itemID
	self:Open("uses")
	if not self.catalog then
		self.pendingUsesReport = n or 20
		CS:Print("reading every profession's recipes (about a second); the report follows.")
		return
	end
	self:PrintUses(itemID, n or 20)
end

function Rec:PrintUses(itemID, n)
	local rows = self:BuildRows()
	local saved = { prof = self.prof, show = self.show, search = self.search }
	self.prof, self.show, self.search = nil, "all", ""
	local list, st = self:UsesRows(rows, itemID)
	self.prof, self.show, self.search = saved.prof, saved.show, saved.search
	local windowStats = self.usesStats
	self.usesStats = st
	CS:Print(self:UsesStatusText())
	self.usesStats = windowStats
	local shown, enchants = 0, {}
	for _, u in ipairs(list) do
		if u.kind == "enchant" then
			enchants[#enchants + 1] = string.format("%s x%d", (u.name:gsub("^Enchant ", "")), u.qty or 1)
		elseif shown < n then
			shown = shown + 1
			local where = u.conversion and "anyone" or string.format("%s, %s", self:ProfName(u.prof), (STATUS_TEXT[u.status] or STATUS_TEXT.other)[1])
			local money
			if u.perMat then
				money = string.format("per mat %s, vs selling %s", CS:Money(u.perMat), u.gain and CS:Money(u.gain, { sign = true }) or "?")
			elseif u.otherComplete == false then
				money = "other reagents unpriced"
			else
				local bind = self:BindText(u.outputItemID)
				if bind == "BoP" or bind == "quest" then
					money = "output has no AH price (" .. bind .. ", cannot be sold)"
				elseif bind then
					money = "output has no AH price (" .. bind .. ": tradeable, nobody lists it)"
				else
					money = "output has no AH price"
				end
			end
			CS:Print("%2d. %s (%s) needs %d: %s", shown, u.name, where, u.qty or 1, money)
		end
	end
	if #enchants > 0 then
		CS:Print("enchants using it (%d, not sellable): %s", #enchants, table.concat(enchants, "; "))
	end
end

CS:On("CATALOG_READY", function()
	local n = Rec.pendingUsesReport
	if n and Rec.mat then
		Rec.pendingUsesReport = nil
		After(0.5, function() Rec:PrintUses(Rec.mat, n) end)
	end
end)

---------------------------------------------------------------------------
-- Market watch (/cs watch <item> [seconds]): who buys a material, and what happens after
---------------------------------------------------------------------------
-- While the AH is open, searches the item every `interval` seconds through CraftProfit's depth scan and
-- compares the price ladder with the last one: units gone from a price tier were bought (or cancelled /
-- expired), units added are new listings. A buyout followed within minutes by a similar amount listed higher
-- is what a reseller looks like. Blizzard's own searches of the item feed the same comparison.

local Watch = { interval = 60, log = {} }
Rec.Watch = Watch
local RELIST_WINDOW = 900 -- seconds between a buyout and a higher listing that counts as a relist

local function TierMap(ladder)
	local map, maxPrice = {}, 0
	for _, t in ipairs(ladder and ladder.tiers or {}) do
		map[t[1]] = (map[t[1]] or 0) + t[2]
		if t[1] > maxPrice then maxPrice = t[1] end
	end
	return map, maxPrice
end

local function Clock(t)
	if date then return date("%H:%M", t) end
	return tostring(t)
end

local function TierList(list)
	local out = {}
	for i = 1, math.min(4, #list) do out[#out + 1] = string.format("%d at %s", list[i][2], CS:MoneyShort(list[i][1])) end
	if #list > 4 then out[#out + 1] = string.format("+%d more tiers", #list - 4) end
	return table.concat(out, ", ")
end

-- Compare the new ladder with the previous one; returns gone, added as ascending { price, qty }.
function Watch.Diff(prevLadder, newLadder)
	local a, amax = TierMap(prevLadder)
	local b, bmax = TierMap(newLadder)
	-- a ladder cut off at the tier/quantity cap says nothing about prices above its top
	local limit = math.huge
	if prevLadder and not prevLadder.full then limit = math.min(limit, amax) end
	if newLadder and not newLadder.full then limit = math.min(limit, bmax) end
	local gone, added, seen = {}, {}, {}
	local function visit(price)
		if seen[price] or price > limit then return end
		seen[price] = true
		local d = (b[price] or 0) - (a[price] or 0)
		if d < 0 then gone[#gone + 1] = { price, -d } elseif d > 0 then added[#added + 1] = { price, d } end
	end
	for price in pairs(a) do visit(price) end
	for price in pairs(b) do visit(price) end
	table.sort(gone, function(x, y) return x[1] < y[1] end)
	table.sort(added, function(x, y) return x[1] < y[1] end)
	return gone, added
end

function Watch:Start(itemID, interval)
	local Scanner = CS.CP and CS.CP.Scanner
	if not (Scanner and Scanner.ScanItems) then CS:Print("CraftProfit's scanner is missing.") return end
	if not Scanner.ahOpen then CS:Print("open the Auction House first; the watch runs while it stays open.") return end
	self:Stop(true)
	self.itemID, self.interval = itemID, math.max(20, interval or 60)
	self.gen = (self.gen or 0) + 1
	self.started = time()
	local l = Scanner:GetLadder(itemID)
	self.prev = l and { tiers = l.tiers, full = l.full, t = l.t } or nil
	self.log, self.recentGone = {}, {}
	self.bought, self.boughtValue, self.listed, self.relists = 0, 0, 0, 0
	CS:Print("watching %s every %d s while the Auction House is open (/cs watch stop to end, /cs watch to summarise).",
		CS:ItemName(itemID), self.interval)
	self:PrintHistory(itemID)
	local gen = self.gen
	local function tick()
		if Watch.gen ~= gen or not Watch.itemID then return end
		if not Scanner.ahOpen then
			Watch:Stop()
			return
		end
		Scanner:ScanItems({ Watch.itemID })
		After(Watch.interval, tick)
	end
	tick()
end

function Watch:Stop(quiet)
	if not self.itemID then return end
	if not quiet then self:Summary("watch ended") end
	self.itemID = nil
	self.gen = (self.gen or 0) + 1
end

-- Own full-scan history of the item (lowest buyout and listed count per scan).
function Watch:PrintHistory(itemID)
	local realm = CS.CP and CS.CP.GetRealmDB and CS.CP:GetRealmDB()
	local h = realm and realm.history and realm.history[itemID]
	if not h or #h == 0 then return end
	local parts = {}
	for i = math.max(1, #h - 7), #h do
		local sm = h[i]
		parts[#parts + 1] = string.format("%s %s x%d", date and date("%m-%d %H:%M", sm[1]) or tostring(sm[1]),
			CS:MoneyShort(sm[2] or 0), sm[3] or 0)
	end
	CS:Print("earlier AH scans (lowest price x listed): %s", table.concat(parts, DOT))
end

function Watch:OnLadder(itemID)
	if not self.itemID or itemID ~= self.itemID then return end
	local ladder = CS.CP.Scanner:GetLadder(itemID)
	if not ladder then return end
	local prev = self.prev
	self.prev = { tiers = ladder.tiers, full = ladder.full, t = ladder.t }
	if not prev then
		CS:Print("%s now: %s", CS:ItemName(itemID), Rec:MatMarketText(itemID, 4) or "?")
		return
	end
	local gone, added = Watch.Diff(prev, ladder)
	if #gone == 0 and #added == 0 then return end
	local now = time()
	local parts = {}
	local goneQty, goneTop = 0, 0
	for _, g in ipairs(gone) do
		goneQty = goneQty + g[2]
		if g[1] > goneTop then goneTop = g[1] end
		self.bought = self.bought + g[2]
		self.boughtValue = self.boughtValue + g[1] * g[2]
	end
	if goneQty > 0 then
		parts[#parts + 1] = "gone " .. TierList(gone)
		table.insert(self.recentGone, { t = now, qty = goneQty, top = goneTop })
	end
	local relist = false
	if #added > 0 then
		local addQty, addLow = 0, math.huge
		for _, a in ipairs(added) do
			addQty = addQty + a[2]
			if a[1] < addLow then addLow = a[1] end
			self.listed = self.listed + a[2]
		end
		parts[#parts + 1] = "new " .. TierList(added)
		for _, g in ipairs(self.recentGone) do
			if now - g.t <= RELIST_WINDOW and addLow > g.top and addQty >= g.qty * 0.5 then relist = true end
		end
		if relist then self.relists = self.relists + 1 end
	end
	while self.recentGone[1] and now - self.recentGone[1].t > RELIST_WINDOW do table.remove(self.recentGone, 1) end
	local line = string.format("[%s] %s: %s%s  (now %s)", Clock(now), CS:ItemName(itemID), table.concat(parts, "; "),
		relist and "  <- listed higher soon after a buyout: looks like a reseller" or "",
		Rec:MatMarketText(itemID, 1) or "?")
	table.insert(self.log, line)
	while #self.log > 50 do table.remove(self.log, 1) end
	CS:Print(line)
end

function Watch:Summary(title)
	if not self.itemID then
		CS:Print("no watch running: /cs watch <item> [seconds] with the Auction House open.")
		return
	end
	local mins = math.max(1, math.floor((time() - (self.started or time())) / 60 + 0.5))
	local avg = self.bought > 0 and CS:MoneyShort(self.boughtValue / self.bought) or DASH
	CS:Print("%s: %s over %d min: %d gone (bought, cancelled or expired; avg %s), %d newly listed, %d reseller-like relists.",
		title or "watch", CS:ItemName(self.itemID), mins, self.bought, avg, self.listed, self.relists)
end

if CS.CP then CS.CP:On("LADDER_UPDATED", function(itemID) Watch:OnLadder(itemID) end) end
CS:RegisterEvent("AUCTION_HOUSE_CLOSED", function() if Watch.itemID then Watch:Stop() end end)

-- /cs watch <item> [seconds] | stop | (nothing: summary)
function Rec:SlashWatch(rest)
	rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if rest == "" then Watch:Summary() return end
	if rest:lower() == "stop" then
		if Watch.itemID then Watch:Stop() else CS:Print("no watch running.") end
		return
	end
	local secs = tonumber(rest:match("%s(%d+)$") or "")
	local text = secs and rest:gsub("%s%d+$", "") or rest
	local itemID = self:ResolveItem(text)
	if not itemID then
		CS:Print("unknown item %q: use an item link, an item ID or a material name.", text)
		return
	end
	Watch:Start(itemID, secs)
end

-- /cs recipes [rescan | list [n]]
function Rec:Slash(rest)
	local sub, arg = (rest or ""):match("^(%S*)%s*(.*)$")
	sub = (sub or ""):lower()
	if sub == "" then
		self:Open()
	elseif sub == "rescan" then
		self.catalog = nil
		self:Open()
	elseif sub == "list" or sub == "top" then
		if not self.catalog then
			CS:Print("the recipe list is not read yet: /cs recipes opens the browser and reads it (about a second).")
			self:GetCatalog()
			return
		end
		local rows = self:BuildRows()
		local list = {}
		for _, r in ipairs(rows) do if r.profit then list[#list + 1] = r end end
		table.sort(list, function(a, b) return a.profit > b.profit end)
		local n = math.max(1, math.min(tonumber(arg) or 10, #list))
		CS:Print("most profitable recipes to sell, all professions (%d priced of %d):", #list, #rows)
		for i = 1, math.min(n, #list) do
			local r = list[i]
			CS:Print("%2d. %s (%s, %s)  %s", i, QualityName(r.quality, r.name), self:ProfName(r.prof),
				(STATUS_TEXT[r.status] or STATUS_TEXT.other)[1], CS:Money(r.profit, { sign = true }))
		end
	else
		CS:Print("usage: /cs recipes  |  /cs recipes rescan  |  /cs recipes list [n]")
	end
end
