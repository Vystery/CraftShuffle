-- CraftShuffle :: DEData
-- Built-in disenchant yield estimates (vanilla 1.12 tables as documented by Enchantrix / Wowhead) plus the
-- item metadata lookups needed to pick a bracket. These are the starting point only: DETracker.lua blends
-- them with the disenchants the player actually performs, so if WoW Forever's tables differ, the numbers
-- converge on reality after a handful of casts.

local _, CS = ...
local DE = {}
CS.DEData = DE

-- Enchanting materials: itemID -> name (used before the item cache has the name).
DE.MATS = {
	[10940] = "Strange Dust", [11083] = "Soul Dust", [11137] = "Vision Dust", [11176] = "Dream Dust", [16204] = "Illusion Dust",
	[10938] = "Lesser Magic Essence", [10939] = "Greater Magic Essence",
	[10998] = "Lesser Astral Essence", [11082] = "Greater Astral Essence",
	[11134] = "Lesser Mystic Essence", [11135] = "Greater Mystic Essence",
	[11174] = "Lesser Nether Essence", [11175] = "Greater Nether Essence",
	[16202] = "Lesser Eternal Essence", [16203] = "Greater Eternal Essence",
	[10978] = "Small Glimmering Shard", [11084] = "Large Glimmering Shard",
	[11138] = "Small Glowing Shard", [11139] = "Large Glowing Shard",
	[11177] = "Small Radiant Shard", [11178] = "Large Radiant Shard",
	[14343] = "Small Brilliant Shard", [14344] = "Large Brilliant Shard",
	[20725] = "Nexus Crystal",
}

-- Uncommon (green) items by item level. Armor: dust 75% / essence 20% / shard 5% (first band 80/20,
-- ilvl 21-25 75/15/10: warcraft.wiki, matched by 71 casts on Forever). Weapons swap dust and essence chances.
local UNCOMMON = {
	{ max = 15, dust = { 10940, 1, 2 }, essence = { 10938, 1, 2 } },
	{ max = 20, dust = { 10940, 2, 3 }, essence = { 10939, 1, 2 }, shard = { 10978, 1, 1 } },
	{ max = 25, dust = { 10940, 4, 6 }, essence = { 10998, 1, 2 }, shard = { 10978, 1, 1 }, chances = { 0.75, 0.15, 0.10 } },
	{ max = 30, dust = { 11083, 1, 2 }, essence = { 11082, 1, 2 }, shard = { 11084, 1, 1 } },
	{ max = 35, dust = { 11083, 2, 5 }, essence = { 11134, 1, 2 }, shard = { 11138, 1, 1 } },
	{ max = 40, dust = { 11137, 1, 2 }, essence = { 11135, 1, 2 }, shard = { 11139, 1, 1 } },
	{ max = 45, dust = { 11137, 2, 5 }, essence = { 11174, 1, 2 }, shard = { 11177, 1, 1 } },
	{ max = 50, dust = { 11176, 1, 2 }, essence = { 11175, 1, 2 }, shard = { 11178, 1, 1 } },
	{ max = 55, dust = { 11176, 2, 5 }, essence = { 16202, 1, 2 }, shard = { 14343, 1, 1 } },
	{ max = 60, dust = { 16204, 1, 2 }, essence = { 16203, 1, 2 }, shard = { 14344, 1, 1 } },
	{ max = 65, dust = { 16204, 2, 5 }, essence = { 16203, 2, 3 }, shard = { 14344, 1, 1 } },
}

-- WoW Forever: green weapons of ilvl 21-30 give Greater Magic Essence instead of the band's astral essence
-- (Wowhead's Forever data via Disenchantry; our own casts confirm 26-30, 21-25 is not checked yet).
-- Armor keeps the classic essences.
local FOREVER_WEAPON_ESSENCE = { min = 21, max = 30, essence = { 10939, 1, 2 } }

-- Rare (blue): one shard, always.
local RARE = {
	{ max = 25, shard = { 10978, 1, 1 } },
	{ max = 30, shard = { 11084, 1, 1 } },
	{ max = 35, shard = { 11138, 1, 1 } },
	{ max = 40, shard = { 11139, 1, 1 } },
	{ max = 45, shard = { 11177, 1, 1 } },
	{ max = 50, shard = { 11178, 1, 1 } },
	{ max = 55, shard = { 14343, 1, 1 } },
	{ max = 65, shard = { 14344, 1, 1 } },
}

-- Epic (purple).
local EPIC = {
	{ max = 45, shard = { 11177, 2, 4 } },
	{ max = 50, shard = { 11178, 2, 4 } },
	{ max = 55, shard = { 14343, 2, 4 } },
	{ max = 65, shard = { 20725, 1, 1 } },
}

local CLASS_WEAPON, CLASS_ARMOR = 2, 4

local function FindBand(list, ilvl)
	for i, band in ipairs(list) do
		if ilvl <= band.max then return band, i end
	end
	return nil
end

local function Yield(spec, chance)
	return { itemID = spec[1], min = spec[2], max = spec[3], chance = chance, avgGiven = (spec[2] + spec[3]) / 2 }
end

---------------------------------------------------------------------------
-- Item metadata
---------------------------------------------------------------------------

local metaCache = {}
local requested = {}

-- { itemID, name, quality, ilvl, classID, subclassID, equipLoc } or nil, "loading" | reason
function DE:GetItemMeta(itemID)
	if not itemID then return nil, "no item" end
	local meta = metaCache[itemID]
	if meta then return meta end
	if not (C_Item and C_Item.GetItemInfo) then return nil, "no C_Item.GetItemInfo" end
	local ok, name, _, quality, ilvl, _, _, _, _, equipLoc, _, sellPrice, classID, subclassID = pcall(C_Item.GetItemInfo, itemID)
	if not ok or not name then
		if not requested[itemID] and C_Item.RequestLoadItemDataByID then
			requested[itemID] = true
			pcall(C_Item.RequestLoadItemDataByID, itemID)
		end
		return nil, "loading"
	end
	if (not classID) and C_Item.GetItemInfoInstant then
		local ok2, _, _, _, _, _, cid, scid = pcall(C_Item.GetItemInfoInstant, itemID)
		if ok2 then classID, subclassID = cid, scid end
	end
	meta = {
		itemID = itemID, name = name, quality = quality or 0, ilvl = ilvl or 0,
		classID = classID, subclassID = subclassID, equipLoc = equipLoc,
		sell = (type(sellPrice) == "number" and sellPrice > 0) and sellPrice or nil, -- what a vendor pays per unit
	}
	metaCache[itemID] = meta
	return meta
end

-- Green-or-better weapons and armor the game refuses to disenchant anyway (vanilla NO_DISENCHANT flag).
-- The client has no API for the flag, so: the known offenders here, items the tracker saw refused in
-- CS.db.blocked ("Item cannot be disenchanted"), and /cs de block for anything else.
DE.NOT_DISENCHANTABLE = {
	[11287] = "Lesser Magic Wand", [11288] = "Greater Magic Wand",
	[11289] = "Lesser Mystic Wand", [11290] = "Greater Mystic Wand",
}

-- true, "built-in" | "refused" | "manual" when the item must not be treated as disenchantable.
function DE:IsBlocked(itemID)
	if not itemID then return false end
	if self.NOT_DISENCHANTABLE[itemID] then return true, "built-in" end
	local b = CS.db and CS.db.blocked and CS.db.blocked[itemID]
	if b then return true, b.reason or "recorded" end
	return false
end

-- Quality and class say it could be disenchanted; the block list has the final word.
function DE:LooksDisenchantable(meta)
	if not meta then return false end
	if (meta.quality or 0) < 2 or (meta.quality or 0) > 4 then return false end
	return meta.classID == CLASS_WEAPON or meta.classID == CLASS_ARMOR
end

function DE:IsDisenchantable(meta)
	if not self:LooksDisenchantable(meta) then return false end
	if self:IsBlocked(meta.itemID) then return false end
	return true
end

-- Quality + weapon/armor + 5-level band. Used to pool observations across similar items.
function DE:BracketKey(meta)
	local band = math.floor((math.max(meta.ilvl or 1, 1) - 1) / 5)
	return string.format("%d:%s:%d", meta.quality or 0, meta.classID == CLASS_WEAPON and "w" or "a", band)
end

function DE:BracketLabel(key)
	local q, kind, band = key:match("^(%d+):(%a):(%d+)$")
	if not q then return key end
	local qualities = { [2] = "uncommon", [3] = "rare", [4] = "epic" }
	return string.format("%s %s ilvl %d-%d", qualities[tonumber(q)] or ("q" .. q), kind == "w" and "weapons" or "armor",
		tonumber(band) * 5 + 1, tonumber(band) * 5 + 5)
end

---------------------------------------------------------------------------
-- Estimates
---------------------------------------------------------------------------

-- Returns a list of { itemID, min, max, chance, avgGiven }, or nil plus a reason
-- ("loading" | "not-disenchantable" | "unknown-bracket"), followed by meta and the bracket key.
function DE:GetEstimate(itemID)
	local meta, why = self:GetItemMeta(itemID)
	if not meta then return nil, why end
	if not self:IsDisenchantable(meta) then return nil, "not-disenchantable", meta end
	local key = self:BracketKey(meta)
	local isWeapon = meta.classID == CLASS_WEAPON
	local ilvl = math.max(meta.ilvl or 1, 1)
	local list

	if meta.quality == 2 then
		local band = FindBand(UNCOMMON, ilvl)
		if band then
			local dust, essence, shard = 0.75, 0.20, 0.05
			if band.chances then dust, essence, shard = band.chances[1], band.chances[2], band.chances[3] end
			if not band.shard then dust, essence, shard = 0.80, 0.20, 0 end
			if isWeapon then dust, essence = essence, dust end
			local essenceSpec = band.essence
			local fw = FOREVER_WEAPON_ESSENCE
			if isWeapon and ilvl >= fw.min and ilvl <= fw.max then essenceSpec = fw.essence end
			list = { Yield(band.dust, dust), Yield(essenceSpec, essence) }
			if band.shard then table.insert(list, Yield(band.shard, shard)) end
		end
	elseif meta.quality == 3 then
		local band = FindBand(RARE, ilvl)
		if band then list = { Yield(band.shard, 1) } end
	elseif meta.quality == 4 then
		local band = FindBand(EPIC, ilvl)
		if band then list = { Yield(band.shard, 1) } end
	end

	if not list then return nil, "unknown-bracket", meta, key end
	for _, y in ipairs(list) do y.expected = y.chance * y.avgGiven end
	return list, nil, meta, key
end

function DE:IsEnchantingMat(itemID)
	if self.MATS[itemID] then return true end
	if C_Item and C_Item.GetItemInfoInstant then
		local ok, _, _, _, _, _, classID, subclassID = pcall(C_Item.GetItemInfoInstant, itemID)
		-- Trade Goods (7) / Enchanting (12) on retail item data
		if ok and classID == 7 then return subclassID == 12 or subclassID == nil end
	end
	return false
end

CS:RegisterEvent("ITEM_DATA_LOAD_RESULT", function(_, itemID, success)
	if success and itemID and requested[itemID] and not metaCache[itemID] then
		requested[itemID] = nil
		CS:Fire("ITEM_LOADED", itemID)
	end
end)
