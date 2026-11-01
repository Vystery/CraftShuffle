-- CraftShuffle :: Core
-- Namespace, saved variables, event dispatch, pub/sub, helpers shared with CraftProfit, slash commands.
--
-- CraftShuffle is a companion to CraftProfit (a hard dependency): prices, craft costs, money formatting and
-- the profession-window hooks come from CraftProfit; this addon adds the disenchant side of the shuffle
-- (buy reagents -> craft -> disenchant -> sell the materials).

local ADDON_NAME, CS = ...
_G.CraftShuffle = CS

CS.name = ADDON_NAME
CS.CALLER_ID = ADDON_NAME
-- Filled in at PLAYER_LOGIN (end of this file): on build 69977 asking the client for our own TOC metadata
-- while the addon is still loading keeps it from handing back our SavedVariables.
CS.version = "dev"
CS.DB_VERSION = 1
CS.DISENCHANT_SPELL = 13262      -- Disenchant
CS.ENCHANTING_SKILL_LINE = 333   -- skillLine reported by GetProfessionInfo for Enchanting

CS.defaults = {
	mode = "sell",             -- what the profession window shows: sell (CraftProfit) | shuffle
	requireEnchanting = true,  -- Shuffle mode only when this character knows Enchanting
	priorWeight = 10,          -- observed disenchants needed to outweigh the built-in estimate
	qty = 20,                  -- planner batch size
	showToggle = true,         -- Sell / Shuffle pills above the recipe list
	sessionBar = true,         -- floating session bar while a shuffle runs and the planner is closed
	scanMinProfit = 100,       -- disenchant scan: minimum expected profit per item, in copper (1s)
	scanVendorMinProfit = 100, -- vendor scan: minimum profit per unit (vendor price - buyout), in copper
	macroBags = false,         -- on: DE macro works through every disenchantable item in the bags, planned item first; off: shuffle item only
	macroRares = false,        -- ...including blue and purple items (off: greens only)
	macroBought = true,        -- DE macro also works through gear bought from the AH Scans' Disenchant list (as many as bought)
	deWindow = true,           -- open the disenchanting tally on the first cast outside a shuffle session
	tooltip = true,            -- disenchant value line in item tooltips
	tooltipCompact = false,    -- tooltip: one line (value vs vendor price) instead of the material breakdown; Shift shows it
	announce = true,           -- chat line for every recorded disenchant
	debug = false,
}

-- CraftProfit is loaded before us (## Dependencies). Everything price related goes through it.
CS.CP = _G.CraftProfit
CS.COLORS = (CS.CP and CS.CP.COLORS) or {
	gold = "ffd100", body = "e8dcc8", label = "c8b78a", muted = "8a7d64", gray = "9d9d9d",
	profit = "4cd137", loss = "ff5b4b",
}

-- CraftShuffle's own windows use the default UI's font colours (gold labels, white values, grey secondary
-- text, green / red money) instead of CraftProfit's palette.
local function BlizzHex(color, fallback)
	if color and type(color.GenerateHexColorNoAlpha) == "function" then
		local ok, hex = pcall(color.GenerateHexColorNoAlpha, color)
		if ok and type(hex) == "string" and #hex == 6 then return hex end
	end
	return fallback
end
CS.UI_COLORS = {
	gold = BlizzHex(NORMAL_FONT_COLOR, "ffd100"),
	label = BlizzHex(NORMAL_FONT_COLOR, "ffd100"),
	body = BlizzHex(HIGHLIGHT_FONT_COLOR, "ffffff"),
	muted = BlizzHex(GRAY_FONT_COLOR, "808080"),
	gray = BlizzHex(DISABLED_FONT_COLOR, "808080"),
	profit = BlizzHex(GREEN_FONT_COLOR, "19ff19"),
	loss = BlizzHex(RED_FONT_COLOR, "ff2020"),
}

---------------------------------------------------------------------------
-- Output helpers
---------------------------------------------------------------------------

function CS:Print(msg, ...)
	if select("#", ...) > 0 then msg = string.format(msg, ...) end
	(DEFAULT_CHAT_FRAME or ChatFrame1):AddMessage("|cffffd100CraftShuffle:|r " .. tostring(msg))
end

function CS:Debug(msg, ...)
	if self.settings and self.settings.debug then
		if select("#", ...) > 0 then msg = string.format(msg, ...) end
		(DEFAULT_CHAT_FRAME or ChatFrame1):AddMessage("|cff8a7d64CraftShuffle[dbg]:|r " .. tostring(msg))
	end
end

function CS:Color(hex, text)
	return "|cff" .. hex .. tostring(text) .. "|r"
end

-- Formatting is delegated to CraftProfit so both addons look identical.
function CS:Money(copper, opts) return self.CP:FormatMoney(copper, opts) end
function CS:MoneyShort(copper, opts) return self.CP:FormatMoneyShort(copper, opts) end
function CS:Margin(margin, sign) return self.CP:FormatMargin(margin, sign) end
function CS:Age(seconds) return self.CP:FormatAge(seconds) end
function CS:ItemIDFromLink(link) return self.CP:ItemIDFromLink(link) end

function CS:ItemName(itemID)
	if not itemID then return "?" end
	if C_Item and C_Item.GetItemNameByID then
		local ok, name = pcall(C_Item.GetItemNameByID, itemID)
		if ok and name then return name end
	end
	local known = self.DEData and self.DEData.MATS[itemID]
	if known then return known end
	return "item " .. tostring(itemID)
end

---------------------------------------------------------------------------
-- Dropdown-style context menus: a second click on the owner closes the menu.
-- The menu manager closes an open menu on the global mouse-down, so by OnClick the
-- menu is already gone and a plain CreateContextMenu would reopen it at the cursor.
-- The owner's OnMouseDown records whether the menu was open (still shown, or closed
-- by that same mouse-down this frame) and OnClick then only closes.
-- Returns true when the click was handled (menu opened or closed), false when
-- MenuUtil is unavailable so the caller can run its fallback.
---------------------------------------------------------------------------

local function MenuShown(owner)
	local menu = owner.csMenu
	return menu and menu.IsShown and menu:IsShown() and true or false
end

function CS:ToggleContextMenu(owner, generator)
	if not (MenuUtil and MenuUtil.CreateContextMenu) then return false end
	if owner and not owner.csMenuHooked and owner.HookScript then
		owner.csMenuHooked = true
		owner:HookScript("OnMouseDown", function(o)
			o.csMenuWasOpen = MenuShown(o) or o.csMenuClosedAt == GetTime()
			o.csMenuClosedAt = nil
		end)
	end
	if owner and (owner.csMenuWasOpen or MenuShown(owner)) then
		owner.csMenuWasOpen = nil
		local menu = owner.csMenu
		if MenuShown(owner) and menu.Close then pcall(menu.Close, menu) end
		return true
	end
	local ok, menu = pcall(MenuUtil.CreateContextMenu, owner, function(desc, root)
		if owner and root.AddMenuReleasedCallback then
			root:AddMenuReleasedCallback(function()
				owner.csMenu = nil
				owner.csMenuClosedAt = GetTime()
			end)
		end
		generator(desc, root)
	end)
	if not ok then
		self:Debug("context menu failed: %s", tostring(menu))
		return false
	end
	if owner then owner.csMenu = menu end
	return true
end

-- Counts for labels: 950, 1.2k, 11k, 1.2M.
function CS:ShortCount(n)
	n = math.floor((n or 0) + 0.5)
	if n < 1000 then return tostring(n) end
	if n < 10000 then return (string.format("%.1fk", n / 1000):gsub("%.0k$", "k")) end
	if n < 1000000 then return string.format("%dk", math.floor(n / 1000)) end
	return (string.format("%.1fM", n / 1000000):gsub("%.0M$", "M"))
end

-- Opens an item's buy page through the AH's own SelectBrowseResult. When a buy page is already showing,
-- Blizzard only swaps the item key (SetDisplayMode returns early, so the list never re-shows and never
-- searches): the page would show the new name over the old item's listings. So an open buy page is first
-- switched back to the Buy list; the item's page then opens exactly like a first click and runs its search.
-- Errors when the AH lacks SelectBrowseResult.
function CS:SelectAuctionItem(key, minPrice, quantity)
	local ah = AuctionHouseFrame
	if not ah or type(ah.SelectBrowseResult) ~= "function" then error("no SelectBrowseResult") end
	local modes = AuctionHouseFrameDisplayMode
	if modes and ah.displayMode ~= nil and modes.Buy and type(ah.SetDisplayMode) == "function"
		and (ah.displayMode == modes.ItemBuy or ah.displayMode == modes.CommoditiesBuy) then
		ah:SetDisplayMode(modes.Buy)
	end
	ah:SelectBrowseResult({ itemKey = key, minPrice = minPrice or 0, totalQuantity = quantity or 1 })
end

local BOARD_ATLASES = { "Professions-Recipe-Background-Enchanting", "Professions-Recipe-Background" }

local function AtlasInfo(atlas)
	if not (C_Texture and C_Texture.GetAtlasInfo) then return nil end
	local ok, info = pcall(C_Texture.GetAtlasInfo, atlas)
	return ok and type(info) == "table" and info or nil
end

-- Puts the profession window's Enchanting recipe background on a board frame (board.Art), centre-cropped to
-- the board's shape. Used by the planner and the disenchanting tally.
function CS:UpdateBoardArt(board)
	if not (board and board.Art) then return end
	local w, h = board:GetWidth() or 0, board:GetHeight() or 0
	if w <= 6 or h <= 6 then return end
	local key = string.format("%dx%d", w, h)
	if board.csArtKey == key then return end
	board.csArtKey = key
	local art = board.Art
	for _, atlas in ipairs(BOARD_ATLASES) do
		local info = AtlasInfo(atlas)
		if info and info.file and (info.width or 0) > 0 and (info.height or 0) > 0 then
			local l, r, t, b = info.leftTexCoord or 0, info.rightTexCoord or 1, info.topTexCoord or 0, info.bottomTexCoord or 1
			local areaAspect = (w - 6) / (h - 6)
			local artAspect = info.width / info.height
			if areaAspect > artAspect then
				-- board wider than the art: full width, keep the middle band of its height
				local half = (b - t) * (artAspect / areaAspect) / 2
				local mid = (t + b) / 2
				t, b = mid - half, mid + half
			else
				local half = (r - l) * (areaAspect / artAspect) / 2
				local mid = (l + r) / 2
				l, r = mid - half, mid + half
			end
			art:SetTexture(info.file)
			art:SetTexCoord(l, r, t, b)
			art:Show()
			return
		end
	end
	-- no atlas info on this client: the plain atlas (stretched) or nothing
	local ok = art.SetAtlas and pcall(art.SetAtlas, art, BOARD_ATLASES[1], false)
	art:SetShown(ok and true or false)
end

-- "~42x" style quantity for expected yields.
function CS:FormatQty(n)
	if not n then return "?" end
	if n >= 10 then return string.format("~%d", math.floor(n + 0.5)) end
	return string.format("~%.1f", n):gsub("%.0$", "")
end

-- What one disenchant gives of a material when it drops: "1-2x", "3x", or "~1.5x" when no range is known.
function CS:FormatYieldQty(y, dash)
	if y.min and y.max and y.min ~= y.max then return string.format("%d%s%dx", y.min, dash or "-", y.max) end
	if y.min then return string.format("%dx", y.min) end
	return CS:FormatQty(y.avgGiven) .. "x"
end

---------------------------------------------------------------------------
-- Pub/sub between modules
---------------------------------------------------------------------------

local listeners = {}

function CS:On(event, fn)
	listeners[event] = listeners[event] or {}
	table.insert(listeners[event], fn)
end

function CS:Fire(event, ...)
	local list = listeners[event]
	if not list then return end
	for _, fn in ipairs(list) do
		local ok, err = pcall(fn, ...)
		if not ok then CS:Debug("listener for %s failed: %s", event, tostring(err)) end
	end
end

---------------------------------------------------------------------------
-- Game events
---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local handlers = {}

function CS:RegisterEvent(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		local ok, err = pcall(eventFrame.RegisterEvent, eventFrame, event)
		if not ok then CS:Debug("cannot register event %s: %s", event, tostring(err)) end
	end
	table.insert(handlers[event], fn)
end

-- Some events only exist for specific units; ignore failures silently.
function CS:RegisterUnitEvent(event, unit, fn)
	if not handlers[event] then
		handlers[event] = {}
		local ok = pcall(eventFrame.RegisterUnitEvent, eventFrame, event, unit)
		if not ok then pcall(eventFrame.RegisterEvent, eventFrame, event) end
	end
	table.insert(handlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if not list then return end
	for _, fn in ipairs(list) do
		local ok, err = pcall(fn, event, ...)
		if not ok then geterrorhandler()(err) end
	end
end)

---------------------------------------------------------------------------
-- Saved variables
---------------------------------------------------------------------------

-- One-time setting changes for existing saves (ApplyDefaults only fills missing keys, so a changed default
-- never reaches a save that already holds the old one).
function CS:MigrateSettings(settings)
	if not settings.macroBagsOffDefault then
		-- 2026-10-13: the DE macro targets only the shuffle item unless the player turns the bags on
		if not (CS.touched and CS.touched.macroBags) then settings.macroBags = false end
		settings.macroBagsOffDefault = true
	end
end

local function ApplyDefaults(tbl, defaults)
	for k, v in pairs(defaults) do
		if tbl[k] == nil then tbl[k] = v end
	end
end

-- Bought-not-yet-disenchanted lots (db.deStock, DESession.lua): kept STOCK_TTL at most, STOCK_MAX per item.
CS.STOCK_TTL = 14 * 86400
CS.STOCK_MAX = 50

-- Drops duplicate, used-up and expired lots and keeps the newest STOCK_MAX per item. Before the self-merge
-- fix every login doubled each list, so vault copies came back with 2^17 copies of one lot (85 MB of
-- Blizzard_Console.lua); this shrinks them on the first adoption and keeps the logout copy small.
-- No string keys: a bloated copy holds millions of lots and this runs once on it at login.
function CS:PruneStock(db)
	local stock = type(db) == "table" and db.deStock
	if type(stock) ~= "table" then return 0 end
	local now, removed = time(), 0
	for itemID, list in pairs(stock) do
		local keep, seen, n = {}, {}, 0
		if type(list) == "table" then
			n = #list
			for i = 1, n do
				local lot = list[i]
				local t, qty, unit = type(lot) == "table" and lot[1], type(lot) == "table" and lot[2], type(lot) == "table" and lot[3]
				if type(t) == "number" and type(qty) == "number" and qty > 0 and unit and now - t <= self.STOCK_TTL then
					local same = seen[t]
					local dup = false
					if same then
						for _, o in ipairs(same) do if o[2] == qty and o[3] == unit then dup = true break end end
					else
						same = {}
						seen[t] = same
					end
					if not dup then
						same[#same + 1] = lot
						keep[#keep + 1] = lot
					end
				end
			end
		end
		table.sort(keep, function(a, b) return a[1] < b[1] end)
		while #keep > self.STOCK_MAX do table.remove(keep, 1) end
		removed = removed + n - #keep
		stock[itemID] = keep[1] and keep or nil
	end
	if not next(stock) then db.deStock = nil end
	return removed
end

-- What the watcher hands the client (and the console vault) at logout: the live table with its stock pruned
-- (only lots that can still be disenchanted) and the backup copy of CraftProfit's data in its compact form.
function CS.PackForSave(live)
	CS:PruneStock(live)
	if CS.Bench then CS.Bench.Prune(live) end
	if CS.CP and CS.CP.db and CS.CP.PackDB then live.cpBackup = CS.CP:PackDB(CS.CP.db) end
	return live
end

local function InitDB()
	if CraftShuffleDB == nil and CraftShuffleCharDB ~= nil then CraftShuffleDB = CraftShuffleCharDB end
	if not CS.loadInfo then
		local info = { hadDB = CraftShuffleDB ~= nil, casts = 0, items = 0, sessions = 0 }
		if type(CraftShuffleDB) == "table" then
			for _, rec in pairs(CraftShuffleDB.disenchant or {}) do
				info.items = info.items + 1
				info.casts = info.casts + (rec.n or 0)
			end
			info.sessions = #(CraftShuffleDB.sessions or {})
		end
		CS.loadInfo = info
	end
	-- see CraftProfit Core: the global is left unset until the client had its chance to load the file
	local db = CraftShuffleDB or {}
	db.version = db.version or CS.DB_VERSION
	db.settings = db.settings or {}
	db.disenchant = db.disenchant or {}   -- itemID -> { n, hits = {matID = casts}, mats = {matID = qty}, first, last }
	db.brackets = db.brackets or {}       -- bracketKey -> same shape, aggregated over items of that quality/level band
	db.sessions = db.sessions or {}       -- finished shuffle sessions (planner), newest last
	db.recipes = db.recipes or {}         -- recipeID -> { name, prof } seen on this account (planner dropdown)
	db.planner = db.planner or {}         -- window position, last recipe
	db.blocked = db.blocked or {}         -- itemID -> { reason, t }: gear the game refused to disenchant
	-- db.derun: the running disenchanting tally (DESession.lua), created on the first cast
	-- db.deStock: itemID -> AH lots bought and not yet disenchanted (DESession.lua), created on the first purchase
	-- db.bench: disenchant benchmark state + per-cast log (DEBench.lua), created by /cs de bench on
	ApplyDefaults(db.settings, CS.defaults)
	CS:MigrateSettings(db.settings)
	CS:PruneStock(db)
	local repaired = CS.Tracker and CS.Tracker.RepairRecords and CS.Tracker:RepairRecords(db) or 0
	if CS.Tracker and CS.Tracker.RebuildBrackets then CS.Tracker:RebuildBrackets(db) end
	if repaired > 0 then CS.repairedRecords = repaired end -- announced at login (chat is not ready yet)
	CS.db = db
	CS.settings = db.settings
	if CS.CP and CS.CP.WatchSavedVariable then
		CS.CP:WatchSavedVariable("CraftShuffleDB", db, function(...) return CS.AdoptDB(...) end, CS.PackForSave, "CraftShuffle")
		CS.CP:WatchSavedVariable("CraftShuffleCharDB", db, function(...) return CS.AdoptDB(...) end, CS.PackForSave, "CraftShuffle")
	else
		CraftShuffleDB = db -- no watcher available: at least make sure the client saves it
	end
end

CS.touched = {}

function CS:SetSetting(key, value)
	self.settings[key] = value
	self.touched[key] = true
	self:Fire("SETTINGS_CHANGED", key, value)
end

-- The saved table can show up after ADDON_LOADED on this client (see CraftProfit Core, "Late
-- SavedVariables"). Merge what this session recorded into it and switch over.
local function AddRecord(into, rec)
	into.n = (into.n or 0) + (rec.n or 0)
	into.hits, into.mats = into.hits or {}, into.mats or {}
	for m, c in pairs(rec.hits or {}) do into.hits[m] = (into.hits[m] or 0) + c end
	for m, q in pairs(rec.mats or {}) do into.mats[m] = (into.mats[m] or 0) + q end
	for m, lo in pairs(rec.lo or {}) do CS.Tracker.Widen(into, m, lo, rec.hi and rec.hi[m] or lo) end
	into.first = math.min(into.first or rec.first or time(), rec.first or time())
	into.last = math.max(into.last or 0, rec.last or 0)
	into.bracket = into.bracket or rec.bracket
end

local function AdoptCraftShuffleDB(loaded, provisional, reason)
	local M = CS.CP.Merge
	local pruned = CS:PruneStock(loaded) -- before the merge: a pre-fix vault copy holds millions of duplicate lots
	loaded.settings = M.Settings(loaded.settings or {}, provisional.settings, CS.touched)
	CS:MigrateSettings(loaded.settings)
	loaded.disenchant = loaded.disenchant or {}
	for itemID, rec in pairs(provisional.disenchant or {}) do
		local have = loaded.disenchant[itemID]
		if not have then
			loaded.disenchant[itemID] = rec
		elseif have ~= rec then
			if have.first and have.first == rec.first then
				-- the same record (same first cast) from two copies of the data (vault + file): one holds the
				-- other's history, so keep the fuller one. Adding them doubled every count on each login.
				if (rec.n or 0) > (have.n or 0) then loaded.disenchant[itemID] = rec end
			else
				-- a record started this session before the saved data arrived: genuinely new casts
				AddRecord(have, rec)
			end
		end
	end
	-- brackets are derived from the item records: rebuilt, never merged (a merge of a copy into itself
	-- doubled them on every login)
	local repaired = CS.Tracker and CS.Tracker.RepairRecords and CS.Tracker:RepairRecords(loaded) or 0
	if CS.Tracker and CS.Tracker.RebuildBrackets then CS.Tracker:RebuildBrackets(loaded) end
	if repaired > 0 then
		CS:Print("repaired %d disenchant records inflated by an old saved-data merge bug (doubled counts undone, yield proportions kept).", repaired)
	end
	loaded.sessions = M.Append(loaded.sessions or {}, provisional.sessions, 20)
	loaded.recipes = M.Union(loaded.recipes or {}, provisional.recipes, true)
	loaded.blocked = loaded.blocked or {}
	for itemID, b in pairs(provisional.blocked or {}) do loaded.blocked[itemID] = loaded.blocked[itemID] or b end
	loaded.planner = loaded.planner or {}
	local prov = provisional.planner or {}
	if prov.pos then loaded.planner.pos = prov.pos end
	if prov.recipeID then loaded.planner.recipeID = prov.recipeID end
	if prov.session then loaded.planner.session = prov.session end -- the session running right now wins
	if prov.dePos then loaded.planner.dePos = prov.dePos end
	if provisional.derun and (provisional.derun.casts or 0) > 0 then loaded.derun = provisional.derun end -- this login's tally wins
	for itemID, lots in pairs(provisional.deStock or {}) do -- items bought this login, not yet disenchanted
		loaded.deStock = loaded.deStock or {}
		local list = loaded.deStock[itemID] or {}
		loaded.deStock[itemID] = list
		local have = {} -- never add a lot the saved copy already holds (guards against merging a copy into itself)
		for _, lot in ipairs(list) do have[tostring(lot[1]) .. ":" .. tostring(lot[2]) .. ":" .. tostring(lot[3])] = true end
		for _, lot in ipairs(lots) do
			local key = tostring(lot[1]) .. ":" .. tostring(lot[2]) .. ":" .. tostring(lot[3])
			if lots ~= list and not have[key] then table.insert(list, lot) end
		end
		table.sort(list, function(a, b) return a[1] < b[1] end)
	end
	CS:PruneStock(loaded)
	if CS.Bench then CS.Bench.Merge(loaded, provisional) end -- keyed by cast: a self-merge adds nothing
	if pruned > 1000 then
		CS:Print("removed %d duplicate or expired bought-item entries from the saved data (left by an old merge bug).", pruned)
	end
	loaded.version = loaded.version or provisional.version
	CS.db = loaded
	CS.settings = loaded.settings
	for k, v in pairs(CS.defaults) do if CS.settings[k] == nil then CS.settings[k] = v end end
	if CS.Calc then
		CS.Calc:Invalidate()
		if CS.Calc.SeedRecipes then CS.Calc:SeedRecipes() end
	end
	if CS.Planner and not CS.Planner.session and loaded.planner.session and not loaded.planner.session.ended then
		CS.Planner:RestoreSession()
	end
	local casts = 0
	for _, rec in pairs(loaded.disenchant) do casts = casts + (rec.n or 0) end
	if reason == "console vault" then
		CS:Print("saved data loaded from the console vault: %d disenchants recorded in total.", casts)
	else
		CS:Print("saved data arrived after login (%s) and was merged with this session: %d disenchants recorded in total.", tostring(reason), casts)
	end
	if CS.UI and CS.UI.ApplyMode then CS.UI:ApplyMode() end
	CS:Fire("DE_RECORDED")
	CS:Fire("SETTINGS_CHANGED")
	CS:Fire("DB_ADOPTED")
	return loaded
end
CS.AdoptDB = AdoptCraftShuffleDB

---------------------------------------------------------------------------
-- Backup copy of CraftProfit's database
---------------------------------------------------------------------------
-- On this client CraftProfit's saved table has not been coming back at all, while CraftShuffle's does.
-- CraftShuffleDB therefore holds a reference to CraftProfit's live table (cpBackup): the client serializes
-- it into CraftShuffle's file, and when CraftProfit starts empty at the next login the copy is handed back.
-- The same table object is then CraftProfitDB and cpBackup, so both files stay complete from then on.

function CS:RestoreCraftProfitBackup()
	local CP = self.CP
	if not (CP and CP.db and self.db) then return false end
	-- the console vault supersedes this copy: when it holds CraftProfit's data (or has not loaded yet), merging
	-- the backup as well would append CraftProfit's price histories and purchases twice
	if CP.GetVault and (_G.Blizzard_Console_SavedVars == nil or CP:GroupAdopted("CraftProfit")
		or (CP:GetVault(false) and CP:GetVault(false).CraftProfit)) then
		self.db.cpBackup = CP.db
		return false
	end
	local backup = self.db.cpBackup
	if CP.IsPacked and CP:IsPacked(backup) then backup = CP:UnpackDB(backup) end
	local restored = false
	local li = CP.loadInfo
	if type(backup) == "table" and backup ~= CP.db and li and not li.hadDB and type(backup.realms) == "table" then
		local ok, err = pcall(CP.AdoptDB, backup, CP.db, "CraftShuffle backup")
		if ok then
			-- the global stays unset (the client may still load the real file; the watcher adopts it);
			-- the watcher assigns this table at logout so it gets saved
			if CP.ResetSavedVariableWatch then CP:ResetSavedVariableWatch("CraftProfitDB", backup) end
			restored = true
		else
			self:Print("could not restore CraftProfit's data from the backup copy: %s", tostring(err))
		end
	end
	self.db.cpBackup = CP.db -- keep pointing at the live table for the next save
	return restored
end

CS:On("READY", function() CS:RestoreCraftProfitBackup() end)
CS:On("DB_ADOPTED", function() if CS.CP and CS.CP.db then CS.db.cpBackup = CS.CP.db end end)
if CS.CP then
	CS.CP:On("DB_ADOPTED", function() if CS.db and CS.CP.db then CS.db.cpBackup = CS.CP.db end end)
end

---------------------------------------------------------------------------
-- Character facts
---------------------------------------------------------------------------

-- true / false, or nil when the client cannot tell us.
function CS:HasEnchanting()
	if not (GetProfessions and GetProfessionInfo) then return nil end
	local ok, p1, p2 = pcall(GetProfessions)
	if not ok then return nil end
	for _, idx in ipairs({ p1, p2 }) do
		if idx then
			local ok2, _, _, _, _, _, _, skillLine = pcall(GetProfessionInfo, idx)
			if ok2 and skillLine == self.ENCHANTING_SKILL_LINE then return true end
		end
	end
	return false
end

function CS:ShuffleAllowed()
	if not self.settings.requireEnchanting then return true end
	local has = self:HasEnchanting()
	if has == nil then return true end -- cannot tell: do not block the user
	return has
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function Count(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

local function PrintStatus()
	CS:Print("v%s (CraftProfit v%s), mode %s", CS.version, tostring(CS.CP and CS.CP.version), CS.settings.mode)
	local li = CS.loadInfo
	if li then
		CS:Print("Loaded from disk at login: %s (%d disenchants on %d items, %d sessions). Since: %s.",
			li.hadDB and "saved data found" or "NO SAVED DATA (fresh database)", li.casts, li.items, li.sessions,
			CS.CP and CS.CP.SavedVariableStatus and CS.CP:SavedVariableStatus("CraftShuffleDB") or "?")
	end
	local has = CS:HasEnchanting()
	CS:Print("Enchanting on this character: %s (requirement %s)",
		has == nil and "unknown" or (has and "yes" or "no"), CS.settings.requireEnchanting and "on" or "off")
	local items, casts = 0, 0
	for _, rec in pairs(CS.db.disenchant) do
		items = items + 1
		casts = casts + (rec.n or 0)
	end
	CS:Print("Disenchant tracker: %d casts recorded on %d items, %d level bands. Estimate weight %d.",
		casts, items, Count(CS.db.brackets), CS.settings.priorWeight)
	CS:Print("  " .. CS.Tracker:StatusLine())
	CS:Print("Recipes known for the planner: %d (%d this session). Sessions logged: %d.",
		Count(CS.db.recipes), Count(CS.recipes), #CS.db.sessions)
	CS:Print("Price source: %s", CS.CP and CS.CP:GetSourceName() or "none")
	if CS.db.cpBackup then
		CS:Print("Backup copy of CraftProfit's data carried in this file: %s.",
			CS.db.cpBackup == (CS.CP and CS.CP.db) and "live (written compact at logout)" or "present")
	end
end

local function PrintHelp()
	CS:Print("commands:")
	CS:Print("  /cs status - tracker counts, mode, settings")
	CS:Print("  /cs mode sell|shuffle - what the profession window shows")
	CS:Print("  /cs plan [qty] - open the shuffle planner")
	CS:Print("  /cs session - open the running shuffle's Session View")
	CS:Print("  /cs bar - show / hide the floating session bar")
	CS:Print("  /cs scan [de|vendor] [min <money> | list [n]] - AH scans: gear worth more disenchanted, items below vendor price")
	CS:Print("  /cs macro [list | bought on|off | bags on|off | rares on|off] - the disenchant macro: shuffle item, then gear bought to disenchant (bags: all greens)")
	CS:Print("  /cs mailto [name | clear] - alt that gets the shuffle items (mailbox window during a shuffle)")
	CS:Print("  /cs recipes [rescan | list [n]] - Recipe Browser: every recipe of every profession, known or not, with profit")
	CS:Print("  /cs uses <item> [n] - what a material goes into: every recipe using it, value per unit vs selling it")
	CS:Print("  /cs watch <item> [seconds] | stop - log who buys an item and whether it gets relisted higher (AH open)")
	CS:Print("  /cs top [n] - best shuffles among recipes seen this session")
	CS:Print("  /cs de <item link or id> - estimate vs recorded disenchant yields")
	CS:Print("  /cs de reset <item id>|all confirm - forget recorded disenchants")
	CS:Print("  /cs de block|unblock <item> - mark gear the game will not disenchant; /cs de blocked lists them")
	CS:Print("  /cs de stats [reset|chat] - disenchanting tally (casts, mats, value, cost, net) outside a shuffle")
	CS:Print("  /cs de bench [on [label] | off | label <text>|auto | auras | reset confirm] - disenchant benchmark: logs every cast with buffs and full loot (Arcane Salvager test)")
	CS:Print("  /cs history - finished shuffle sessions")
	CS:Print("  /cs enchanting on|off - require Enchanting for Shuffle mode")
	CS:Print("  /cs weight <n> - observations needed to outweigh the estimate")
	CS:Print("  /cs qty <n> - default planner batch size")
	CS:Print("  /cs tooltip [compact] | announce | debug - toggles (tooltip compact: one line, value vs vendor; Shift shows the materials)")
	CS:Print("  /cs reset confirm - wipe everything")
end

local function ParseItem(text)
	if not text or text == "" then return nil end
	local id = CS:ItemIDFromLink(text)
	if id then return id end
	return tonumber(text)
end

local function PrintDE(itemID)
	local yields, why, info = CS.Tracker:GetExpectedYields(itemID)
	local name = CS:ItemName(itemID)
	if not yields then
		CS:Print("%s: %s", name, why == "loading" and "item data still loading, try again" or tostring(why))
		return
	end
	CS:Print("%s (%s) disenchants into:", name, info.summary)
	local total = 0
	for _, y in ipairs(yields) do
		local unit = CS.CP:GetSalePrice(y.itemID)
		local value = unit and unit * y.expected or nil
		if value then total = total + value end
		CS:Print("  %s %s  %d%% chance, %.2f avg when it drops  = %.2f per cast%s", CS:FormatYieldQty(y), CS:ItemName(y.itemID),
			math.floor(y.chance * 100 + 0.5), y.avgGiven or 0, y.expected,
			value and (" -> " .. CS:Money(value)) or " (no price)")
	end
	CS:Print("  expected value per disenchant: %s", CS:Money(total))
end

local function HandleSlash(input)
	input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local cmd, rest = input:match("^(%S+)%s*(.*)$")
	cmd = cmd and cmd:lower() or ""

	if cmd == "" or cmd == "help" then
		PrintHelp()
	elseif cmd == "status" then
		PrintStatus()
	elseif cmd == "mode" then
		local mode = rest:lower()
		if mode == "sell" or mode == "shuffle" then
			CS.UI:SetMode(mode, true)
		else
			CS:Print("usage: /cs mode sell|shuffle (current: %s)", CS.settings.mode)
		end
	elseif cmd == "plan" or cmd == "planner" then
		local qty = tonumber(rest)
		if qty and qty > 0 then CS:SetSetting("qty", math.floor(qty)) end
		CS.Planner:Open()
	elseif cmd == "session" then
		CS.Planner:OpenSession()
	elseif cmd == "bar" then
		CS.Planner:ToggleSessionBar()
	elseif cmd == "recipes" or cmd == "browser" or cmd == "browse" then
		CS.Recipes:Slash(rest)
	elseif cmd == "uses" or cmd == "mat" or cmd == "mats" then
		CS.Recipes:SlashUses(rest)
	elseif cmd == "watch" then
		CS.Recipes:SlashWatch(rest)
	elseif cmd == "scan" or cmd == "descan" then
		CS.DEScan:Slash(rest)
	elseif cmd == "mailto" then
		if rest == "" then CS.Planner:AskMailTo() else CS.Planner:SetMailTo(rest == "clear" and "" or rest) end
	elseif cmd == "macro" then
		local sub, arg = rest:match("^(%S*)%s*(%S*)$")
		sub = (sub or ""):lower()
		if sub == "list" or sub == "queue" then
			CS.Planner:PrintDEQueue()
		elseif sub == "rares" or sub == "bags" or sub == "bought" then
			local key = sub == "rares" and "macroRares" or sub == "bought" and "macroBought" or "macroBags"
			local on = arg:lower()
			if on == "on" or on == "off" then
				CS:SetSetting(key, on == "on")
			else
				CS:SetSetting(key, not CS.settings[key])
			end
			CS:Print("macro %s %s", sub == "rares" and "includes blue/purple items (bags mode):" or sub == "bought" and "works through gear bought to disenchant:" or "works through all greens in the bags:", CS.settings[key] and "on" or "off")
			CS.Planner:UpdateMacro(true)
		else
			CS.Planner:UpdateMacro(false)
		end
	elseif cmd == "top" then
		local n = tonumber(rest) or 10
		local list = CS.Calc:TopShuffles(n)
		if #list == 0 then
			CS:Print("no shuffle candidates yet. Open a profession window (and scan the AH) first.")
		end
		for i, e in ipairs(list) do
			local hex = e.net >= 0 and CS.COLORS.profit or CS.COLORS.loss
			CS:Print("%2d. %s  %s (%s)  %s", i, e.name, CS:Color(hex, CS:Money(e.net, { sign = true })),
				CS:Margin(e.margin) or "?", e.deSummary or "")
		end
	elseif cmd == "de" then
		local sub, arg = rest:match("^(%S+)%s*(.*)$")
		local subl = sub and sub:lower()
		if subl == "stats" or subl == "tally" or subl == "window" then
			CS.DESession:Slash(arg)
		elseif subl == "bench" or subl == "benchmark" then
			CS.Bench:Slash(arg)
		elseif subl == "block" or subl == "unblock" then
			local id = ParseItem(arg)
			if not id then
				CS:Print("usage: /cs de %s <item link or id>", subl)
			elseif subl == "block" then
				if CS.Tracker:Block(id, "manual") then
					CS:Print("%s marked as not disenchantable: excluded from shuffle values and the disenchant scan.", CS:ItemName(id))
				else
					CS:Print("%s is already marked as not disenchantable.", CS:ItemName(id))
				end
			else
				if CS.DEData.NOT_DISENCHANTABLE[id] then
					CS:Print("%s is on the built-in list; it stays excluded.", CS:ItemName(id))
				elseif CS.Tracker:Unblock(id) then
					CS:Print("%s can be disenchanted again as far as CraftShuffle is concerned.", CS:ItemName(id))
				else
					CS:Print("%s was not marked.", CS:ItemName(id))
				end
			end
		elseif subl == "blocked" then
			local n = 0
			for id, name in pairs(CS.DEData.NOT_DISENCHANTABLE) do
				n = n + 1
				CS:Print("  %s (built-in)", CS:ItemName(id) ~= ("item " .. id) and CS:ItemName(id) or name)
			end
			for id, b in pairs(CS.db.blocked or {}) do
				n = n + 1
				CS:Print("  %s (%s%s)", CS:ItemName(id), b.reason or "recorded", b.t and (", " .. date("%m-%d", b.t)) or "")
			end
			CS:Print("%d items marked as not disenchantable.", n)
		elseif sub and sub:lower() == "reset" then
			local target, confirm = arg:match("^(%S+)%s*(%S*)$")
			if confirm ~= "confirm" then
				CS:Print("usage: /cs de reset <item id>|all confirm")
			elseif target == "all" then
				wipe(CS.db.disenchant)
				wipe(CS.db.brackets)
				CS:Fire("DE_RECORDED")
				CS:Print("all recorded disenchants forgotten.")
			else
				local id = ParseItem(target)
				if id then
					CS.Tracker:Forget(id)
					CS:Print("recorded disenchants for %s forgotten.", CS:ItemName(id))
				else
					CS:Print("unknown item '%s'", tostring(target))
				end
			end
		else
			local id = ParseItem(rest)
			if id then PrintDE(id) else CS:Print("usage: /cs de <item link or id>") end
		end
	elseif cmd == "history" then
		if #CS.db.sessions == 0 then CS:Print("no shuffle sessions yet.") end
		for i = #CS.db.sessions, math.max(1, #CS.db.sessions - 9), -1 do
			local s = CS.db.sessions[i]
			CS:Print("%s: %s x%d, crafted %d, disenchanted %d, mats %s (expected %s)",
				date("%m-%d %H:%M", s.started or 0), s.name or ("recipe " .. tostring(s.recipeID)), s.qty or 0,
				s.crafted or 0, s.disenchanted or 0, CS:Money(s.matValue or 0), CS:Money(s.expectedMatValue or 0))
		end
	elseif cmd == "enchanting" then
		local v = rest:lower()
		if v == "on" or v == "off" then
			CS:SetSetting("requireEnchanting", v == "on")
			CS:Print("Enchanting requirement %s", v)
		else
			CS:Print("usage: /cs enchanting on|off")
		end
	elseif cmd == "weight" then
		local n = tonumber(rest)
		if n and n >= 1 and n <= 100 then
			CS:SetSetting("priorWeight", math.floor(n))
			CS:Print("estimate weight set to %d observations", math.floor(n))
		else
			CS:Print("usage: /cs weight <1-100>")
		end
	elseif cmd == "qty" then
		local n = tonumber(rest)
		if n and n >= 1 and n <= 1000 then
			CS:SetSetting("qty", math.floor(n))
			CS:Print("planner batch size set to %d", math.floor(n))
		else
			CS:Print("usage: /cs qty <1-1000>")
		end
	elseif cmd == "tooltip" and rest:lower() == "compact" then
		CS:SetSetting("tooltipCompact", not CS.settings.tooltipCompact)
		CS:Print("compact tooltip %s", CS.settings.tooltipCompact and "on (one line, hold Shift for the materials)" or "off")
	elseif cmd == "tooltip" or cmd == "announce" or cmd == "debug" then
		CS:SetSetting(cmd, not CS.settings[cmd])
		CS:Print("%s %s", cmd, CS.settings[cmd] and "on" or "off")
	elseif cmd == "options" or cmd == "config" then
		CS.Options:Open()
	elseif cmd == "reset" then
		if rest:lower() == "confirm" then
			wipe(CS.db.disenchant)
			wipe(CS.db.brackets)
			wipe(CS.db.sessions)
			wipe(CS.db.recipes)
			wipe(CS.db.planner)
			wipe(CS.db.blocked)
			CS.db.derun = nil
			wipe(CS.db.settings)
			ApplyDefaults(CS.db.settings, CS.defaults)
			CS:Fire("DE_RECORDED")
			CS:Fire("SETTINGS_CHANGED")
			CS:Print("database and settings reset.")
		else
			CS:Print("this wipes recorded disenchants, sessions and settings. Type /cs reset confirm to proceed.")
		end
	else
		CS:Print("unknown command '%s'", cmd)
		PrintHelp()
	end
end

SLASH_CRAFTSHUFFLE1 = "/craftshuffle"
SLASH_CRAFTSHUFFLE2 = "/shuffle"
SLASH_CRAFTSHUFFLE3 = "/cs"
SlashCmdList["CRAFTSHUFFLE"] = HandleSlash

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

CS:RegisterEvent("ADDON_LOADED", function(_, name)
	if name ~= ADDON_NAME then return end
	InitDB()
	CS:Debug("loaded v%s", CS.version)
end)

-- Oldest CraftProfit this version works with: it uses the listing keys, depth scans and purchase events
-- CraftProfit added in 0.3.0.
CS.MIN_CRAFTPROFIT = "0.3.0"

function CS:CraftProfitVersion()
	if C_AddOns and C_AddOns.GetAddOnMetadata then
		local ok, v = pcall(C_AddOns.GetAddOnMetadata, "CraftProfit", "Version")
		if ok and type(v) == "string" and v ~= "" then return v end
	end
	return self.CP and self.CP.version or nil
end

-- "0.3.0" >= "0.3.0". A version that is not numbers (a dev copy) passes; missing APIs never do.
function CS:CraftProfitIsRecentEnough()
	local Scanner = self.CP and self.CP.Scanner
	if not (Scanner and Scanner.ScanItems and Scanner.GetBrowseKey) then return false end
	local have = self:CraftProfitVersion()
	if type(have) ~= "string" or not have:match("^%d+%.%d+") then return true end
	local function parts(v) local t = {} for n in v:gmatch("%d+") do t[#t + 1] = tonumber(n) end return t end
	local a, b = parts(have), parts(self.MIN_CRAFTPROFIT)
	for i = 1, math.max(#a, #b) do
		local x, y = a[i] or 0, b[i] or 0
		if x ~= y then return x > y end
	end
	return true
end

CS:RegisterEvent("PLAYER_LOGIN", function()
	if not CS.db then InitDB() end
	if CS.repairedRecords then
		CS:Print("repaired %d disenchant records inflated by an old saved-data merge bug (doubled counts undone, yield proportions kept).", CS.repairedRecords)
		CS.repairedRecords = nil
	end
	-- the console vault (see CraftProfit Core) can show up a little after login: only complain if nothing arrived
	local function ReportLoad()
		if CS.loadInfo and not CS.loadInfo.hadDB and not (CS.CP and CS.CP.GroupAdopted and CS.CP:GroupAdopted("CraftShuffle")) then
			CS:Print("no saved data was found; starting with an empty database (see /cs status).")
		end
	end
	if C_Timer and C_Timer.After then C_Timer.After(10, ReportLoad) else ReportLoad() end
	if not CS.CP then
		CS:Print("CraftProfit is not loaded; CraftShuffle needs it for prices and the profession window.")
		return
	end
	if not CS:CraftProfitIsRecentEnough() then
		CS:Print("this version needs CraftProfit %s or newer (you have %s). Update CraftProfit: listing pages, depth scans and purchase tracking need it.",
			CS.MIN_CRAFTPROFIT, tostring(CS:CraftProfitVersion() or "an older one"))
	end
	CS:Fire("READY")
end)

CS:RegisterEvent("PLAYER_LOGIN", function()
	if C_AddOns and C_AddOns.GetAddOnMetadata then CS.version = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or CS.version end
end)
