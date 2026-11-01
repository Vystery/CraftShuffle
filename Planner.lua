-- CraftShuffle :: Planner
-- Standalone "Shuffle Planner" window: plans a bulk run as Buy -> Craft -> Disenchant -> Sell with totals
-- and a reagent shopping list, then tracks a live session (crafts and disenchants) against the plan.

local _, CS = ...
local Planner = {}
CS.Planner = Planner

local C = CS.UI_COLORS -- the default UI's font colours (Core.lua)
local DASH = "\226\128\148"
local PORTRAIT_ICON = "Interface\\Icons\\INV_Enchant_Disenchant"

local WIDTH, HEIGHT = 940, 380
local HISTORY_LINES = 3
local PAD, GAP = 12, 8
local TOOLBAR_Y = -30                             -- toolbar row, right of the portrait
local CARD_TOP = -64
local BOARD_BOTTOM = 36                           -- the board ends above the bottom button row
local CARD_ROWS = 8
local ROW_H = 14
local CARD_HEIGHT = 32 + CARD_ROWS * ROW_H + 46   -- title, rows, divider + footer
local MACRO_NAME = "CraftShuffle"                 -- the reusable disenchant macro (see UpdateMacro)
local MACRO_ICON = "INV_Misc_QuestionMark"       -- with #showtooltip <item> the button shows the item about to be disenchanted

local function Muted(text) return CS:Color(C.muted, text) end
local function Body(text) return CS:Color(C.body, text) end
local function Gray(text) return CS:Color(C.gray, text) end
local function Label(text) return CS:Color(C.label, text) end
local function Gold(text) return CS:Color(C.gold, text) end

Planner.recipeID = nil
Planner.session = nil

---------------------------------------------------------------------------
-- Model
---------------------------------------------------------------------------

local SKILLUP_CHANCE = { [0] = 1.0, [1] = 0.6, [2] = 0.25, [3] = 0 } -- Optimal, Medium, Easy, Trivial

local function RecipeName(recipeID)
	local rec = CS.recipes[recipeID] or (CS.db and CS.db.recipes[recipeID])
	if rec and rec.name then return rec.name end
	if C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
		local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
		if ok and info and info.name then return info.name end
	end
	return "recipe " .. tostring(recipeID)
end
Planner.RecipeName = RecipeName

local function CastTimeSeconds(recipeID)
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, recipeID)
		if ok and type(info) == "table" and type(info.castTime) == "number" and info.castTime > 0 then
			return info.castTime / 1000
		end
	end
	return nil
end

-- Recipe colour, as the profession window shows it: orange (optimal), yellow (medium), green (easy), gray (trivial).
local DIFFICULTY_COLOR = { [0] = "ff8040", [1] = "ffff00", [2] = "40c040", [3] = "808080" }

-- Expected skill-ups per craft and the recipe's relative difficulty (0-3), or nil when unknown.
local function SkillUpChance(recipeID)
	if not (C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo) then return nil end
	local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
	if not ok or not info then return nil end
	local diff = info.relativeDifficulty
	if type(diff) ~= "number" then return nil end
	local chance = SKILLUP_CHANCE[diff]
	if not chance then return nil end
	return chance * ((info.numSkillUps and info.numSkillUps > 0) and info.numSkillUps or 1), diff
end

-- Expected skill-ups for `qty` crafts, coloured by recipe difficulty, for the recipe picker. "—" when unknown.
local function SkillUpsText(recipeID, qty)
	local chance, diff = SkillUpChance(recipeID)
	if not chance then return Gray(DASH) end
	if chance <= 0 then return Gray("0 sk") end
	return CS:Color(DIFFICULTY_COLOR[diff] or C.muted, CS:FormatQty(chance * qty) .. " sk")
end
Planner.SkillUpsText = SkillUpsText

local MAX_CRAFT_DEPTH = 3

-- Last bag to look in: the reagent bag when the client has one (reagents bought or looted land there).
local function LastBag()
	local reagent = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag
	return type(reagent) == "number" and reagent or ((NUM_BAG_SLOTS or 4) + 1)
end

-- Units of an item in the bags. The game's count is checked against a count over every bag including the
-- reagent bag (a client may leave that bag out of GetItemCount); the larger one wins.
local function ItemCount(itemID)
	local n
	if C_Item and C_Item.GetItemCount then
		local ok, c = pcall(C_Item.GetItemCount, itemID)
		if ok and type(c) == "number" then n = c end
	end
	if C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo then
		local sum = 0
		for bag = 0, LastBag() do
			local ok, slots = pcall(C_Container.GetContainerNumSlots, bag)
			for slot = 1, (ok and slots) or 0 do
				local ok2, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
				if ok2 and type(info) == "table" and info.itemID == itemID then sum = sum + (info.stackCount or 1) end
			end
		end
		if not n or sum > n then n = sum end
	end
	return n
end

---------------------------------------------------------------------------
-- Purchases in transit
---------------------------------------------------------------------------
-- Auction purchases are delivered by mail, so a bought reagent is neither "to buy" nor "in bags" for a
-- while. Confirmed commodity purchases (CraftProfit's PURCHASE_RECORDED) are kept as in transit and reduced
-- as the item count in the bags rises (the mail being collected). Stored in the saved variables so a
-- /reload between buying and collecting keeps the picture right; entries expire after two days.

local TRANSIT_TTL = 2 * 86400

local function TransitDB()
	CS.db.planner.transit = CS.db.planner.transit or {}
	return CS.db.planner.transit
end

function Planner:InTransit(itemID)
	local t = CS.db and CS.db.planner and CS.db.planner.transit and CS.db.planner.transit[itemID]
	if not t then return 0 end
	if time() - (t.t or 0) > TRANSIT_TTL then return 0 end
	return t.qty or 0
end

function Planner:AddTransit(itemID, qty)
	if not itemID or not qty or qty <= 0 then return end
	local db = TransitDB()
	local t = db[itemID]
	if not t or time() - (t.t or 0) > TRANSIT_TTL then
		t = { qty = 0, base = ItemCount(itemID) or 0 }
		db[itemID] = t
	end
	t.qty = t.qty + qty
	t.t = time()
end

-- Bags changed: whatever arrived of an item in transit is no longer in transit.
function Planner:ReconcileTransit()
	local db = CS.db and CS.db.planner and CS.db.planner.transit
	if not db then return end
	for itemID, t in pairs(db) do
		local now = ItemCount(itemID)
		if time() - (t.t or 0) > TRANSIT_TTL then
			db[itemID] = nil
		elseif now then
			local base = t.base or 0
			if now > base then
				t.qty = math.max(0, (t.qty or 0) - (now - base))
			end
			t.base = now -- crafting consumes items too; only rises count as deliveries
			if t.qty <= 0 then db[itemID] = nil end
		end
	end
end

-- Adds one buy entry per reagent of a recipe crafted `crafts` times (the plan) and `craftsNow` times (what is
-- still to do given what the bags hold). Crafted intermediates get entry.crafts / craftsNow, a m.crafts
-- record and their own reagents indented one level deeper. Leaves (things actually bought) also go to
-- m.shopping with entry.buyNow = what still has to be bought.
-- Returns the real outlay for the list (sum of leaf purchases at market depth), or nil when a leaf is unpriced.
local function ExpandReagents(m, reagents, crafts, craftsNow, depth)
	local CP = CS.CP
	local sum, complete = 0, true
	for _, r in ipairs(reagents) do
		local need = r.qty * crafts
		local needNow = r.qty * craftsNow
		local have = ItemCount(r.itemID) or 0
		local entry = { itemID = r.itemID, qty = need, needNow = needNow, have = have, unit = r.unit,
			total = r.unit and (r.unit * need) or nil, kind = r.kind, depth = depth }
		table.insert(m.buy, entry)
		local sub = (r.kind == "craft" and r.craftRecipeID and depth < MAX_CRAFT_DEPTH) and CS.Calc:Base(r.craftRecipeID) or nil
		if sub and #(sub.reagents or {}) > 0 then
			local per = (sub.quantity and sub.quantity > 0) and sub.quantity or 1
			local casts = math.ceil(need / per - 1e-9)
			local castsNow = math.ceil(math.max(0, needNow - have) / per - 1e-9)
			entry.crafts = casts
			entry.craftsNow = castsNow
			entry.recipeID = r.craftRecipeID
			entry.buyUnit = r.buyUnit
			table.insert(m.crafts, { recipeID = r.craftRecipeID, itemID = r.itemID, count = casts, countNow = castsNow, need = need,
				needNow = needNow, outputQty = per, name = RecipeName(r.craftRecipeID), depth = depth })
			local children = ExpandReagents(m, sub.reagents, casts, castsNow, depth + 1)
			entry.realTotal = children
			-- what buying the intermediate itself would cost at market depth
			local buyTotal = CP:GetReagentCostFor(r.itemID, need)
			if not buyTotal and r.buyUnit then buyTotal = r.buyUnit * need end
			entry.buyTotal = buyTotal
			entry.saving = (buyTotal and children) and (buyTotal - children) or nil
			if entry.saving and entry.saving > 0 then m.savings = m.savings + entry.saving end
		else
			table.insert(m.shopping, entry)
			local total, avg, kind, info = CP:GetReagentCostFor(r.itemID, need)
			entry.realTotal, entry.avgUnit, entry.buyKind, entry.buyInfo = total, avg, kind, info
			entry.transit = Planner:InTransit(r.itemID)
			entry.buyNow = math.max(0, needNow - have - entry.transit)
			if entry.buyNow > 0 then
				entry.buyNowTotal, entry.buyNowAvg = CP:GetReagentCostFor(r.itemID, entry.buyNow)
			end
			if info then
				if info.source == "ladder" then
					m.depth.ladders = m.depth.ladders + 1
					if not m.depth.oldest or info.age > m.depth.oldest then m.depth.oldest = info.age end
				elseif kind ~= "vendor" then
					m.depth.missing = m.depth.missing + 1
				end
				if (info.short or 0) > 0 then
					table.insert(info.full and m.depth.short or m.depth.beyond, entry)
				end
			end
		end
		if entry.realTotal then sum = sum + entry.realTotal else complete = false end
	end
	return complete and sum or nil
end

-- Everything the four cards and the footer show, for `qty` crafts of `recipeID`.
function Planner:BuildModel(recipeID, qty)
	qty = math.max(1, math.floor(tonumber(qty) or 1))
	local eco = CS.Calc:Get(recipeID)
	if not eco then return nil end
	local m = { recipeID = recipeID, qty = qty, eco = eco, name = RecipeName(recipeID), outputItemID = eco.outputItemID }

	-- Buy: reagents for `qty` crafts. A reagent priced at its own craft cost (kind "craft", cheaper than
	-- buying) is expanded into the intermediate craft plus its own reagents, recursively.
	m.buy, m.crafts, m.shopping, m.savings = {}, {}, {}, 0
	m.depth = { ladders = 0, missing = 0, short = {}, beyond = {}, oldest = nil }
	-- A running session for this recipe has already turned part of the plan into items (and used up their
	-- reagents): the "now" numbers (what to buy, what to craft next) are for the crafts still to do.
	local s = self.session
	m.done = (s and s.recipeID == recipeID and math.min(qty, s.crafted or 0)) or 0
	m.remaining = qty - m.done
	local realCost = ExpandReagents(m, eco.reagents or {}, qty, m.remaining, 0)
	-- Total cost is what the shopping list really costs at market depth; per-craft numbers (rows, panel)
	-- stay at unit prices. Falls back to unit price x qty when a leaf has no price at all.
	m.unitCost = (eco.cost or 0) * qty
	m.totalCost = realCost or m.unitCost
	m.costComplete = eco.costComplete and #(eco.reagents or {}) > 0
	m.costReal = realCost ~= nil
	table.sort(m.crafts, function(a, b) return a.depth > b.depth end) -- deepest first = crafting order

	-- Craft
	local cast = CastTimeSeconds(recipeID)
	local timeSec = cast and (cast * qty) or nil
	for _, c in ipairs(m.crafts) do
		local t = CastTimeSeconds(c.recipeID)
		if t and timeSec then timeSec = timeSec + t * c.count end
	end
	m.craft = {
		count = qty,
		outputQty = (eco.quantity or 1) * qty,
		timeSec = timeSec,
		skillUps = (function() local c = SkillUpChance(recipeID) return c and c * qty or nil end)(),
		costBasis = eco.cost,
	}
	local deCast = CastTimeSeconds(CS.DISENCHANT_SPELL) or 3
	m.time = { craft = timeSec, de = deCast * m.craft.outputQty }
	m.time.total = (timeSec or 0) + m.time.de

	-- Disenchant
	m.de = {}
	local casts = (eco.quantity or 1) * qty
	for _, y in ipairs(eco.yields or {}) do
		table.insert(m.de, { itemID = y.itemID, expectedQty = y.expected * casts, chance = y.chance, unit = y.unit,
			value = y.value and (y.value * casts) or nil })
	end
	m.matValue = (eco.matValue or 0) * qty
	m.matValueComplete = eco.matValueComplete

	-- Sell (net uses the depth-aware total cost)
	m.cut = (eco.cut or 0) * qty
	if eco.matValueComplete and m.costComplete then
		m.net = m.matValue - m.cut - m.totalCost
		m.perCraft = m.net / qty
		m.margin = m.totalCost > 0 and (m.net / m.totalCost) or nil
	end
	m.status = eco.status
	m.deInfo = eco.de
	return m
end

---------------------------------------------------------------------------
-- Recipes available to the dropdown
---------------------------------------------------------------------------

function Planner:RecipeChoices()
	local list = CS.Calc:TopShuffles(40)
	local seen = {}
	for _, e in ipairs(list) do seen[e.recipeID] = true end
	-- recipes without a computable net still appear (at the end) so the user can pick them
	local rest = {}
	for recipeID, rec in pairs(CS.recipes) do
		if not seen[recipeID] then table.insert(rest, { recipeID = recipeID, name = rec.name, prof = rec.prof }) end
	end
	table.sort(rest, function(a, b) return (a.name or "") < (b.name or "") end)
	for i = 1, math.min(#rest, 20) do table.insert(list, rest[i]) end
	return list
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

-- A step column on the board (no box of its own, like the sections of the profession recipe form): gold
-- title, label / value rows in the small game fonts, a divider and a footer total.
local function CreateCard(parent, index, title)
	local card = CreateFrame("Frame", nil, parent)
	card:SetHeight(CARD_HEIGHT)
	card.Title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	card.Title:SetPoint("TOPLEFT", 10, -9)
	card.Title:SetText(string.format("%d. %s", index, title))

	card.Rows = {}
	for i = 1, CARD_ROWS do
		local l = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		l:SetPoint("TOPLEFT", 10, -30 - (i - 1) * ROW_H)
		l:SetJustifyH("LEFT")
		if l.SetWordWrap then l:SetWordWrap(false) end
		local v = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		v:SetPoint("TOPRIGHT", -10, -30 - (i - 1) * ROW_H)
		v:SetJustifyH("RIGHT")
		l:SetPoint("RIGHT", v, "LEFT", -6, 0)
		card.Rows[i] = { label = l, value = v }
	end

	card.Divider = card:CreateTexture(nil, "ARTWORK")
	if not (card.Divider.SetAtlas and pcall(card.Divider.SetAtlas, card.Divider, "Options_HorizontalDivider")) then
		card.Divider:SetColorTexture(1, 1, 1, 0.12)
	end
	card.Divider:SetHeight(1)
	card.Divider:SetPoint("BOTTOMLEFT", 8, 30)
	card.Divider:SetPoint("BOTTOMRIGHT", -8, 30)

	card.FootLabel = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	card.FootLabel:SetPoint("BOTTOMLEFT", 10, 11)
	card.FootValue = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	card.FootValue:SetPoint("BOTTOMRIGHT", -10, 10)
	card.FootValue:SetJustifyH("RIGHT")
	return card
end

local function SetRows(card, rows)
	for i, pair in ipairs(card.Rows) do
		local r = rows[i]
		if r then
			pair.label:SetText(r[1])
			pair.value:SetText(r[2] or "")
			pair.label:Show()
			pair.value:Show()
		else
			pair.label:Hide()
			pair.value:Hide()
		end
	end
	if #rows > CARD_ROWS then
		local last = card.Rows[CARD_ROWS]
		last.label:SetText(Muted(string.format("+%d more (see tooltip)", #rows - CARD_ROWS + 1)))
		last.value:SetText("")
	end
end

local function Tip(owner, title, text, extra)
	owner:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(title)
		GameTooltip:AddLine(text, 1, 1, 1, true)
		if extra then GameTooltip:AddLine(extra, 0.6, 0.6, 0.6, true) end
		GameTooltip:Show()
	end)
	owner:SetScript("OnLeave", GameTooltip_Hide)
end

-- Recipe picker: the default UI's dropdown (WowStyle1DropdownTemplate, it opens and closes itself);
-- a panel button that opens the same menu on clients without it.
local function CreateRecipePicker(f)
	local ok, dd = pcall(CreateFrame, "DropdownButton", nil, f, "WowStyle1DropdownTemplate")
	if ok and dd and dd.SetupMenu then
		dd:SetSize(280, 22)
		if dd.SetSelectionTranslator then
			pcall(dd.SetSelectionTranslator, dd, function() return Planner:RecipeLabel() end)
		end
		dd:SetupMenu(function(_, root) Planner:BuildRecipeMenu(root) end)
		dd.csDropdown = true
		return dd
	end
	local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	b:SetSize(280, 22)
	b:SetScript("OnClick", function(self) Planner:OpenRecipeMenu(self) end)
	return b
end

-- Quantity: the profession window's numeric spinner (NumericInputSpinnerTemplate); minus / box / plus
-- built from panel buttons and InputBoxTemplate when the client lacks it.
local function CreateQtyInput(f)
	local ok, sp = pcall(CreateFrame, "EditBox", nil, f, "NumericInputSpinnerTemplate")
	if ok and sp and sp.SetMinMaxValues and sp.SetValue and sp.SetOnValueChangedCallback then
		sp:SetSize(46, 20)
		sp:SetMinMaxValues(1, 1000)
		sp:SetValue(Planner:GetQty())
		sp:SetOnValueChangedCallback(function(_, value) Planner:SetQty(value) end)
		f.QtySpinner = sp
		return sp, sp.DecrementButton or sp
	end
	f.QtyMinus = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.QtyMinus:SetSize(20, 22)
	f.QtyMinus:SetText("-")
	f.QtyMinus:SetScript("OnClick", function() Planner:SetQty(Planner:GetQty() - (IsShiftKeyDown and IsShiftKeyDown() and 10 or 1)) end)
	f.Qty = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
	f.Qty:SetSize(46, 20)
	f.Qty:SetPoint("LEFT", f.QtyMinus, "RIGHT", 8, 0)
	f.Qty:SetAutoFocus(false)
	f.Qty:SetNumeric(true)
	f.Qty:SetMaxLetters(4)
	f.Qty:SetJustifyH("CENTER")
	f.Qty:SetScript("OnEnterPressed", function(self) Planner:SetQty(tonumber(self:GetText())) self:ClearFocus() end)
	f.Qty:SetScript("OnEditFocusLost", function(self) Planner:SetQty(tonumber(self:GetText())) end)
	f.Qty:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	f.QtyPlus = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.QtyPlus:SetSize(20, 22)
	f.QtyPlus:SetPoint("LEFT", f.Qty, "RIGHT", 4, 0)
	f.QtyPlus:SetText("+")
	f.QtyPlus:SetScript("OnClick", function() Planner:SetQty(Planner:GetQty() + (IsShiftKeyDown and IsShiftKeyDown() and 10 or 1)) end)
	return f.Qty, f.QtyMinus
end

local function CreateWindow()
	local name = "CraftShufflePlanner"
	-- the AH's and the profession window's base (portrait frame); older templates as fallbacks
	local f
	for _, template in ipairs({ "PortraitFrameTemplate", "ButtonFrameTemplate", "BasicFrameTemplateWithInset" }) do
		local ok, frame = pcall(CreateFrame, "Frame", name, UIParent, template)
		if ok and frame then f = frame break end
	end
	if not f then
		f = CreateFrame("Frame", name, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
		if f.SetBackdrop then
			f:SetBackdrop({
				bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
				edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
				tile = true, tileSize = 32, edgeSize = 32,
				insets = { left = 11, right = 12, top = 12, bottom = 11 },
			})
		end
		f.TitleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		f.TitleText:SetPoint("TOP", 0, -14)
		f.CloseButton = CreateFrame("Button", nil, f, "UIPanelCloseButton")
		f.CloseButton:SetPoint("TOPRIGHT", -4, -4)
	end
	if f.Inset and f.Inset.Hide then f.Inset:Hide() end -- ButtonFrameTemplate: the step boxes are the insets
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
		CS.db.planner.pos = { point, relPoint, x, y }
	end)
	f:SetFrameStrata("HIGH")
	f:Hide()
	f:SetScript("OnHide", function() Planner.barHidden = nil Planner:UpdateSessionBar() end)
	f:SetScript("OnShow", function() Planner:UpdateSessionBar() end)
	local title = "Shuffle Planner"
	if f.SetTitle then pcall(f.SetTitle, f, title) elseif f.TitleText then f.TitleText:SetText(title) end
	local portrait = (f.PortraitContainer and f.PortraitContainer.portrait) or f.portrait
	if f.SetPortraitToAsset then
		pcall(f.SetPortraitToAsset, f, PORTRAIT_ICON)
	elseif portrait and SetPortraitToTexture then
		pcall(SetPortraitToTexture, portrait, PORTRAIT_ICON)
	end
	local x0 = portrait and 64 or PAD
	if UISpecialFrames then table.insert(UISpecialFrames, name) end

	-- Toolbar, right of the portrait: recipe dropdown, quantity spinner; scan age + Scan AH on the right
	f.RecipeButton = CreateRecipePicker(f)
	f.RecipeButton:SetPoint("TOPLEFT", f, "TOPLEFT", x0, TOOLBAR_Y)
	f.QtyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.QtyLabel:SetPoint("LEFT", f.RecipeButton, "RIGHT", 16, 0)
	f.QtyLabel:SetText("Quantity")
	local qty, qtyLeft = CreateQtyInput(f)
	if f.QtySpinner then
		-- the spinner's arrow buttons sit outside its box
		qty:SetPoint("LEFT", f.QtyLabel, "RIGHT", 8 + ((qtyLeft ~= qty and qtyLeft.GetWidth and qtyLeft:GetWidth()) or 0), 0)
	else
		qtyLeft:SetPoint("LEFT", f.QtyLabel, "RIGHT", 8, 0)
	end
	f.ScanButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.ScanButton:SetSize(90, 22)
	f.ScanButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, TOOLBAR_Y)
	f.ScanButton:SetText("Scan AH")
	-- disabled while scanning; the tooltip still explains it
	if f.ScanButton.SetMotionScriptsWhileDisabled then f.ScanButton:SetMotionScriptsWhileDisabled(true) end
	f.ScanButton:SetScript("OnClick", function() Planner:ScanAH() end)
	Tip(f.ScanButton, "Scan AH",
		"Click: check the real listings (price ladder) for this plan's reagents and materials. Shift-click: full Auction House browse scan (all items, lowest buyout only).",
		"Ladders are also captured whenever you look at an item in the AH.")
	f.ScanAge = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.ScanAge:SetPoint("RIGHT", f.ScanButton, "LEFT", -8, 0)

	-- The board: one inset with the profession window's Enchanting recipe background (UpdateBoardArt crops it
	-- to the board's shape). The step columns, the history lines and the summary sit on it.
	local okB, board = pcall(CreateFrame, "Frame", nil, f, "InsetFrameTemplate")
	if not okB or not board then board = CreateFrame("Frame", nil, f) end
	board:SetPoint("TOPLEFT", f, "TOPLEFT", PAD - 4, CARD_TOP + 4)
	board:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD + 4, BOARD_BOTTOM)
	board:SetFrameLevel(f:GetFrameLevel() + 1)
	board.Art = board:CreateTexture(nil, "BACKGROUND", nil, 2)
	board.Art:SetPoint("TOPLEFT", board, "TOPLEFT", 3, -3)
	board.Art:SetPoint("BOTTOMRIGHT", board, "BOTTOMRIGHT", -3, 3)
	board.Art:Hide()
	board:SetScript("OnSizeChanged", function() Planner:UpdateBoardArt() end)
	f.Board = board
	-- thin separators between the step columns
	f.Separators = {}
	local cardW0 = (WIDTH - 2 * PAD - 3 * GAP) / 4
	for i = 1, 3 do
		local sep = board:CreateTexture(nil, "ARTWORK")
		sep:SetColorTexture(1, 1, 1, 0.10)
		sep:SetWidth(1)
		local x = PAD + i * cardW0 + (i - 0.5) * GAP
		sep:SetPoint("TOPLEFT", f, "TOPLEFT", x, CARD_TOP - 8)
		sep:SetPoint("BOTTOMLEFT", f, "TOPLEFT", x, CARD_TOP - CARD_HEIGHT + 8)
		f.Separators[i] = sep
	end

	-- Plan view: four step columns, Buy -> Craft -> Disenchant -> Sell
	f.Cards = {}
	local titles = { "Buy", "Craft", "Disenchant", "Sell" }
	local cardW = (WIDTH - 2 * PAD - 3 * GAP) / 4
	for i = 1, 4 do
		local card = CreateCard(board, i, titles[i])
		card:SetWidth(cardW)
		card:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + (i - 1) * (cardW + GAP), CARD_TOP)
		f.Cards[i] = card
		card:EnableMouse(true)
		card:SetScript("OnEnter", function(self) Planner:ShowCardTooltip(self, i) end)
		card:SetScript("OnLeave", GameTooltip_Hide)
	end

	-- Session view: four cards comparing actual against plan, plus recent sessions
	f.SessionCards = {}
	local sessionTitles = { "Buy", "Craft", "Disenchant", "Result" }
	for i = 1, 4 do
		local card = CreateCard(f.Board, i, sessionTitles[i])
		card:SetWidth(cardW)
		card:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + (i - 1) * (cardW + GAP), CARD_TOP)
		card:Hide()
		card:EnableMouse(true)
		card:SetScript("OnEnter", function(self) Planner:ShowSessionCardTooltip(self, i) end)
		card:SetScript("OnLeave", GameTooltip_Hide)
		f.SessionCards[i] = card
	end
	f.History = {}
	for i = 1, HISTORY_LINES do
		local line = f.Board:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		line:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 4, CARD_TOP - CARD_HEIGHT - 8 - (i - 1) * 13)
		line:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
		line:SetJustifyH("LEFT")
		if line.SetWordWrap then line:SetWordWrap(false) end
		line:Hide()
		f.History[i] = line
	end

	-- Footer
	f.Summary = f.Board:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.Summary:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD + 4, BOARD_BOTTOM + 8)
	f.Summary:SetJustifyH("LEFT")
	f.Session = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.Session:SetPoint("BOTTOMLEFT", PAD + 110, 16)
	f.Session:SetJustifyH("LEFT")
	if f.Session.SetWordWrap then f.Session:SetWordWrap(false) end
	-- the status line stays a few words; hovering it shows the full explanation
	f.SessionHover = CreateFrame("Frame", nil, f)
	f.SessionHover:SetPoint("TOPLEFT", f.Session, "TOPLEFT", 0, 4)
	f.SessionHover:SetPoint("BOTTOMRIGHT", f.Session, "BOTTOMRIGHT", 0, -4)
	f.SessionHover:SetScript("OnEnter", function(self)
		if not self.detail then return end
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(self.title or "")
		GameTooltip:AddLine(self.detail, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	f.SessionHover:SetScript("OnLeave", GameTooltip_Hide)

	f.ViewButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.ViewButton:SetSize(100, 22)
	f.ViewButton:SetPoint("BOTTOMLEFT", PAD, 12)
	f.ViewButton:SetText("Session View")
	f.ViewButton:SetScript("OnClick", function() Planner:SetView(Planner.view == "session" and "plan" or "session") end)
	f.ViewButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(Planner.view == "session" and "Plan View" or "Session View")
		GameTooltip:AddLine(Planner.view == "session" and "Back to the Buy / Craft / Disenchant / Sell plan."
			or "How the running (or last) shuffle is going against the plan: spend, crafts, disenchants, materials, realized and projected net.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	f.ViewButton:SetScript("OnLeave", GameTooltip_Hide)

	f.StartButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.StartButton:SetSize(110, 22)
	f.StartButton:SetPoint("BOTTOMRIGHT", -PAD, 12)
	f.StartButton:SetScript("OnClick", function() Planner:ToggleSession() end)

	f.BuyButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.BuyButton:SetSize(110, 22)
	f.BuyButton:SetPoint("RIGHT", f.StartButton, "LEFT", -6, 0)
	f.BuyButton:SetText("Buy Reagents")
	if f.BuyButton.SetMotionScriptsWhileDisabled then f.BuyButton:SetMotionScriptsWhileDisabled(true) end
	f.BuyButton:SetScript("OnClick", function() Planner:BuyReagents() end)
	f.BuyButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Buy Reagents")
		GameTooltip:AddLine("With the Auction House open: a shopping panel next to the AH with everything still missing from your bags. Click a row to open that item's buy page with the quantity filled in.", 1, 1, 1, true)
		GameTooltip:AddLine("The AH cannot search several items at once, so it is one click per reagent.", 0.6, 0.6, 0.6, true)
		if not Planner.session then GameTooltip:AddLine("Start the shuffle first (Start Shuffle): the shopping list follows the running shuffle.", 1, 0.4, 0.4, true) end
		GameTooltip:Show()
	end)
	f.BuyButton:SetScript("OnLeave", GameTooltip_Hide)

	f.CraftButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.CraftButton:SetSize(90, 22)
	-- a disabled button gets no OnEnter by default; the tooltip says why it is disabled
	if f.CraftButton.SetMotionScriptsWhileDisabled then f.CraftButton:SetMotionScriptsWhileDisabled(true) end
	f.CraftButton:SetPoint("RIGHT", f.BuyButton, "LEFT", -6, 0)

	f.MacroButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.MacroButton:SetSize(80, 22)
	f.MacroButton:SetPoint("RIGHT", f.CraftButton, "LEFT", -6, 0)
	f.MacroButton:SetText("DE Macro")
	f.MacroButton:SetScript("OnClick", function() Planner:UpdateMacro(false) end)
	f.MacroButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Disenchant macro")
		local body = Planner:MacroBody()
		GameTooltip:AddLine(string.format("Creates or retargets the '%s' macro:", MACRO_NAME), 1, 1, 1, true)
		if body then GameTooltip:AddLine(body:gsub("\n", " | "), 0.8, 0.8, 0.8, true) end
		local _, _, queue = Planner:MacroTarget()
		if #queue > 0 then
			local labels = { shuffle = "shuffle", bought = "bought to disenchant", bags = "from the bags" }
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Queue:", 1, 0.82, 0)
			for i, g in ipairs(Planner.GroupQueue(queue)) do
				if i > 8 then GameTooltip:AddLine("  ...", 0.6, 0.6, 0.6) break end
				GameTooltip:AddDoubleLine(string.format("  %dx %s", g.count, g.name), labels[g.source] or g.source, 0.8, 0.8, 0.8, 0.6, 0.6, 0.6)
			end
		end
		GameTooltip:AddLine("Drag it to a bar once (/macro). It targets one exact bag slot and retargets itself after every cast: the shuffle item, then gear you bought from the AH Scans' Disenchant list. Never soulbound items, equipment-set items or equipped gear; inert in combat.", 0.6, 0.6, 0.6, true)
		if CS.settings.macroBags == true then
			GameTooltip:AddLine("'DE macro works through the bags' is on: other unbound greens in the bags are queued too.", 1, 0.4, 0.4, true)
		end
		GameTooltip:Show()
	end)
	f.MacroButton:SetScript("OnLeave", GameTooltip_Hide)

	-- mail the shuffle items to an alt that has Enchanting
	f.MailButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.MailButton:SetSize(110, 22)
	f.MailButton:SetPoint("RIGHT", f.MacroButton, "LEFT", -6, 0)
	f.MailButton:SetScript("OnClick", function() Planner:AskMailTo() end)
	f.MailButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Mail to an alt")
		local to = Planner:GetMailTo()
		GameTooltip:AddLine(to and ("Shuffle items go to " .. to .. ". Click to change.")
			or "Enchanting on another character? Set who gets the shuffle items.", 1, 1, 1, true)
		GameTooltip:AddLine("At a mailbox during a shuffle, a mail window next to the mailbox sends the crafted items, one click per mail of up to 12.", 0.6, 0.6, 0.6, true)
		GameTooltip:Show()
	end)
	f.MailButton:SetScript("OnLeave", GameTooltip_Hide)
	-- the status line (and its hover area) ends before the button row, so its tooltip never covers a button
	f.Session:SetPoint("RIGHT", f.MailButton, "LEFT", -10, 0)
	f.CraftButton:SetScript("OnClick", function() Planner:CraftAll() end)
	f.CraftButton:SetScript("OnEnter", function(self)
		-- computed live: bag contents change while the player crafts
		Planner:Refresh()
		local nc = Planner:NextCraft()
		if not nc then return end
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Craft")
		if nc.allDone then
			GameTooltip:AddLine(string.format("All %d %s of this shuffle are crafted. Next: disenchant them with the DE Macro.", Planner.model.qty, nc.name), 1, 1, 1, true)
			GameTooltip:Show()
			return
		end
		if nc.have then
			GameTooltip:AddLine(string.format("%dx %s first: you have %d of the %d needed.", nc.count, nc.name, nc.have, nc.need), 1, 1, 1, true)
		else
			GameTooltip:AddLine(string.format("%dx %s", nc.count, nc.name), 1, 1, 1)
		end
		local craftable, missing = Planner:Craftable(nc.recipeID, nc.count)
		if craftable < nc.count then
			GameTooltip:AddLine(string.format("Reagents in bags allow %d. Missing: %s", craftable, Planner:MissingText(missing)), 1, 0.4, 0.4, true)
		end
		local can, why = Planner:CanCraft(nc.recipeID)
		if not can then GameTooltip:AddLine(Planner:CraftBlockedText(nc.recipeID, why), 1, 0.4, 0.4, true) end
		GameTooltip:Show()
	end)
	f.CraftButton:SetScript("OnLeave", GameTooltip_Hide)

	f:SetScript("OnShow", function() Planner:Refresh() end)
	return f
end

function Planner:GetFrame()
	if not self.frame then
		self.frame = CreateWindow()
		local pos = CS.db.planner.pos
		if pos then
			self.frame:ClearAllPoints()
			self.frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
		end
	end
	return self.frame
end

function Planner:Open(recipeID)
	local f = self:GetFrame()
	if recipeID then
		self.recipeID = recipeID
		CS.db.planner.recipeID = recipeID
		-- planning another recipe while a shuffle runs: show its plan, not the running session
		if self.session and recipeID ~= self.session.recipeID then self.view = "plan" end
	elseif self.session then
		-- no recipe asked for while a shuffle runs: that shuffle is where the action is
		self.recipeID = self.session.recipeID
		CS.db.planner.recipeID = self.recipeID
		self.view = "session"
	elseif not self.recipeID then
		self.recipeID = CS.db.planner.recipeID
		local choices = self:RecipeChoices()
		if (not self.recipeID or not CS.recipes[self.recipeID]) and choices[1] then
			self.recipeID = choices[1].recipeID
		end
	end
	f:Show()
	self:Refresh()
end

-- Session View of the running shuffle (or of the last finished one when nothing runs).
function Planner:OpenSession()
	if self.session then
		self.recipeID = self.session.recipeID
		CS.db.planner.recipeID = self.recipeID
	elseif #(CS.db.sessions or {}) > 0 then
		CS:Print("no shuffle running; showing the last finished session.")
	else
		CS:Print("no shuffle running and no finished sessions yet. Pick a recipe and press Start Shuffle.")
	end
	self.view = "session"
	self:Open(self.recipeID)
end

function Planner:GetQty()
	return CS.settings.qty or 20
end

function Planner:SetQty(qty)
	qty = math.floor(tonumber(qty) or self:GetQty())
	if qty < 1 then qty = 1 end
	if qty > 1000 then qty = 1000 end
	if qty ~= CS.settings.qty then
		CS.settings.qty = qty
	end
	self:Refresh()
end

function Planner:SelectRecipe(recipeID)
	self.recipeID = recipeID
	CS.db.planner.recipeID = recipeID
	self:Refresh()
end

-- The recipe currently planned, as the picker shows it.
function Planner:RecipeLabel()
	local m = self.model
	if m and m.name then return m.name end
	if self.recipeID then return RecipeName(self.recipeID) or ("recipe " .. self.recipeID) end
	return "Choose a recipe"
end

-- Menu entries: recipes by shuffle profit with their skill-ups for the planned quantity.
function Planner:BuildRecipeMenu(root)
	local choices = self:RecipeChoices()
	local qty = self:GetQty()
	if #choices == 0 then
		root:CreateTitle("No recipes known yet. Open a profession window first.")
		return
	end
	root:CreateTitle(string.format("Recipes by shuffle profit  %s", Muted(string.format("(skill-ups for %d crafts)", qty))))
	for i, e in ipairs(choices) do
		if i > 30 then break end
		local text = e.name or ("recipe " .. e.recipeID)
		if e.net then
			local hex = e.net >= 0 and C.profit or C.loss
			text = text .. "  " .. CS:Color(hex, CS:MoneyShort(e.net, { sign = true }))
		else
			text = text .. "  " .. Gray(DASH)
		end
		text = text .. "  " .. SkillUpsText(e.recipeID, qty)
		root:CreateRadio(text, function() return Planner.recipeID == e.recipeID end,
			function() Planner:SelectRecipe(e.recipeID) end)
	end
end

-- Fallback picker (no dropdown template): the same menu as a context menu on the button.
function Planner:OpenRecipeMenu(owner)
	local choices = self:RecipeChoices()
	if #choices == 0 then
		CS:Print("no recipes known yet. Open a profession window first so the recipes register.")
		return
	end
	if CS:ToggleContextMenu(owner, function(_, root) Planner:BuildRecipeMenu(root) end) then return end
	-- no menus at all: cycle through the list
	local idx = 1
	for i, e in ipairs(choices) do
		if e.recipeID == self.recipeID then idx = i % #choices + 1 break end
	end
	self:SelectRecipe(choices[idx].recipeID)
end

---------------------------------------------------------------------------
-- Floating session bar: the running shuffle stays on screen when the planner is closed.
-- Left-click opens the Session View, right-click hides the bar until the next session, drag moves it.
---------------------------------------------------------------------------

local function CreateSessionBar()
	local template = BackdropTemplateMixin and "BackdropTemplate" or nil
	local bar = CreateFrame("Button", "CraftShuffleSessionBar", UIParent, template)
	bar:SetSize(260, 24)
	bar:SetPoint("TOP", UIParent, "TOP", 0, -120)
	if bar.SetBackdrop then
		bar:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8x8",
			edgeFile = "Interface\\Buttons\\WHITE8x8",
			edgeSize = 1,
		})
		bar:SetBackdropColor(0.03, 0.02, 0.02, 0.9)
		bar:SetBackdropBorderColor(0.45, 0.36, 0.20, 1)
	end
	bar:SetFrameStrata("MEDIUM")
	bar:SetMovable(true)
	bar:EnableMouse(true)
	bar:SetClampedToScreen(true)
	bar:RegisterForDrag("LeftButton")
	if bar.RegisterForClicks then bar:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
	bar:SetScript("OnDragStart", function(self) self:StartMoving() end)
	bar:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		CS.db.planner.barPos = { point, relPoint, x, y }
	end)
	bar:SetScript("OnClick", function(_, button)
		if button == "RightButton" then
			Planner.barHidden = true
			Planner:UpdateSessionBar()
			CS:Print("session bar hidden. It comes back when you close the planner again; /cs bar shows it right away, /cs session opens the Session View.")
		else
			Planner:OpenSession()
		end
	end)
	bar:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:AddLine("CraftShuffle " .. DASH .. " running shuffle")
		local s = Planner.session
		if s then
			local st = Planner:SessionStats(s)
			GameTooltip:AddDoubleLine("Crafted", string.format("%d / %d", st.crafted, st.qty), 0.8, 0.8, 0.8, 1, 1, 1)
			GameTooltip:AddDoubleLine("Disenchanted", string.format("%d / %d", st.de, st.qty), 0.8, 0.8, 0.8, 1, 1, 1)
			GameTooltip:AddDoubleLine("Mats so far", CS:Money(st.matValue), 0.8, 0.8, 0.8, 1, 1, 1)
			GameTooltip:AddDoubleLine("Net so far", CS:Money(st.netSoFar, { sign = true }), 0.8, 0.8, 0.8, 1, 1, 1)
		end
		GameTooltip:AddLine("Click: Session View. Right-click: hide. Drag: move.", 0.6, 0.6, 0.6, true)
		GameTooltip:Show()
	end)
	bar:SetScript("OnLeave", GameTooltip_Hide)

	bar.Icon = bar:CreateTexture(nil, "ARTWORK")
	bar.Icon:SetSize(16, 16)
	bar.Icon:SetPoint("LEFT", 5, 0)
	bar.Icon:SetTexture("Interface\\Icons\\INV_Enchant_Disenchant")
	bar.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	bar.Text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	bar.Text:SetPoint("LEFT", bar.Icon, "RIGHT", 6, 0)
	bar.Text:SetPoint("RIGHT", -6, 0)
	bar.Text:SetJustifyH("LEFT")
	if bar.Text.SetWordWrap then bar.Text:SetWordWrap(false) end
	bar:Hide()
	return bar
end

-- One line: "12/20 crafted  8 DE  +40s 82c".
function Planner:SessionLine(s)
	s = s or self.session
	if not s then return nil end
	local st = self:SessionStats(s)
	return string.format("%s  %s  %s", Body(string.format("%d/%d crafted", st.crafted, st.qty)),
		Muted(string.format("%d DE", st.de)), CS:Color(st.netSoFar >= 0 and C.profit or C.loss, CS:MoneyShort(st.netSoFar, { sign = true })))
end

-- /cs bar: bring a right-click-hidden bar back, or toggle the setting when it is already visible / off.
function Planner:ToggleSessionBar()
	if not self.session then
		CS:Print("no shuffle running; the session bar only shows during a shuffle.")
		return
	end
	if CS.settings.sessionBar == false then
		CS:SetSetting("sessionBar", true)
		self.barHidden = nil
		CS:Print("session bar on.")
	elseif self.barHidden then
		self.barHidden = nil
		CS:Print("session bar shown.")
	else
		CS:SetSetting("sessionBar", false)
		CS:Print("session bar off (/cs bar turns it back on).")
	end
	self:UpdateSessionBar()
	if self.frame and self.frame:IsShown() and self.session and CS.settings.sessionBar ~= false then
		CS:Print("it appears once the planner is closed.")
	end
end

function Planner:UpdateSessionBar()
	local s = self.session
	local wanted = s ~= nil and CS.settings.sessionBar ~= false and not self.barHidden
		and not (self.frame and self.frame:IsShown())
	if not wanted then
		if self.bar then self.bar:Hide() end
		return
	end
	if not self.bar then
		self.bar = CreateSessionBar()
		local pos = CS.db.planner.barPos
		if pos then
			self.bar:ClearAllPoints()
			self.bar:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
		end
	end
	self.bar.Text:SetText(Gold(s.name or "Shuffle") .. "  " .. (self:SessionLine(s) or ""))
	self.bar:Show()
end

CS:On("SETTINGS_CHANGED", function(key) if key == "sessionBar" then Planner:UpdateSessionBar() end end)

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local function Money(v, opts)
	if not v then return Gray(DASH) end
	return Body(CS:Money(v, opts))
end

local function Seconds(sec)
	if not sec then return Muted("?") end
	if sec < 90 then return Muted(string.format("~%d sec", math.floor(sec + 0.5))) end
	return Muted(string.format("~%d min", math.floor(sec / 60 + 0.5)))
end

-- "Tailoring" for a recipe, when the client can tell.
local function ProfessionName(recipeID)
	if C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillLineForRecipe then
		local ok, _, name = pcall(C_TradeSkillUI.GetTradeSkillLineForRecipe, recipeID)
		if ok and type(name) == "string" and name ~= "" then return name end
	end
	return nil
end

-- The board's background: the Enchanting recipe background from the profession window (the shuffle ends
-- at the disenchant), the generic recipe background when that atlas is missing. The art is cropped to the
-- board's shape (centre crop through the atlas texture coordinates) instead of being stretched.
function Planner:UpdateBoardArt()
	local board = self.frame and self.frame.Board
	if board then CS:UpdateBoardArt(board) end
end

-- The picker shows the planned recipe: the dropdown rebuilds its selection text, the fallback button sets it.
function Planner:UpdateRecipePicker()
	local b = self.frame and self.frame.RecipeButton
	if not b then return end
	local label = self:RecipeLabel()
	if b.csDropdown then
		if b.csLast == label then return end
		b.csLast = label
		if b.GenerateMenu then pcall(b.GenerateMenu, b) end
		if not b.SetSelectionTranslator and b.OverrideText then pcall(b.OverrideText, b, label) end
	else
		b:SetText(self.model and ("Recipe: " .. label) or "Recipe: choose...")
	end
end

function Planner:Refresh()
	self:UpdateSessionBar()
	local f = self.frame
	if not f or not f:IsShown() then return end
	local qty = self:GetQty()
	if f.QtySpinner then
		if f.QtySpinner:GetValue() ~= qty then f.QtySpinner:SetValue(qty) end
	elseif f.Qty:GetText() ~= tostring(qty) then
		f.Qty:SetText(tostring(qty))
	end

	local m = self.recipeID and self:BuildModel(self.recipeID, qty) or nil
	self.model = m
	self:UpdateScanStatus()
	self:UpdateBoardArt()
	self:ApplyView()
	if not m then
		self:UpdateRecipePicker()
		for _, card in ipairs(f.Cards) do SetRows(card, {}) card.FootLabel:SetText("") card.FootValue:SetText("") end
		f.Summary:SetText(Muted("Open a profession window so recipes register, then pick one."))
		f.CraftButton:SetText("Craft")
		f.CraftButton:Disable()
		f.BuyButton:Disable()
		f.StartButton:SetText(self.session and "Stop Shuffle" or "Start Shuffle")
		if self.session then f.StartButton:Enable() else f.StartButton:Disable() end
		f.Session:SetText("")
		f.SessionHover.title, f.SessionHover.detail = nil, nil
		if self.view == "session" then self:UpdateSessionView() end
		return
	end

	self:UpdateRecipePicker()

	-- Buy card: crafted intermediates in gold, their reagents indented under them. Values are what the
	-- quantity really costs at market depth; "?" = only the lowest buyout is known, red = not enough listed.
	local rows = {}
	local function HaveSuffix(b)
		if not b.have or b.have <= 0 then return "" end
		if b.have >= (b.needNow or b.qty) then return CS:Color(C.profit, string.format(" have %d", b.have)) end
		return Muted(string.format(" have %d", b.have))
	end
	for _, b in ipairs(m.buy) do
		local indent = string.rep("    ", b.depth or 0)
		local name = string.format("%dx %s", b.qty, CS:ItemName(b.itemID))
		if b.crafts then
			table.insert(rows, { indent .. Gold(name) .. Muted(" craft") .. HaveSuffix(b), b.realTotal and Gold(CS:Money(b.realTotal, { compact = true })) or Gray("no price") })
		else
			local label = (b.depth or 0) > 0 and Muted(indent .. name) or Body(name)
			local info = b.buyInfo
			local value
			if not b.realTotal then
				value = Gray("no price")
			elseif b.buyKind == "vendor" then
				label = label .. Muted("*")
				value = Money(b.realTotal, { compact = true })
			elseif info and info.source == "ladder" then
				if (info.short or 0) > 0 and info.full then
					label = label .. CS:Color(C.loss, string.format(" only %d listed", info.covered or 0))
					value = CS:Color(C.loss, CS:Money(b.realTotal, { compact = true }))
				else
					if b.avgUnit and info.minPrice and b.avgUnit > info.minPrice + 0.5 then
						label = label .. Muted(" ~" .. CS:Money(b.avgUnit, { compact = true }) .. " ea")
					end
					value = Money(b.realTotal, { compact = true })
				end
			else
				value = Muted(CS:Money(b.realTotal, { compact = true }) .. "?")
			end
			table.insert(rows, { label .. HaveSuffix(b), value })
		end
	end
	if m.savings > 0 then
		table.insert(rows, { Gold("Crafting yourself saves"), CS:Color(C.profit, CS:Money(m.savings, { compact = true })) })
	end
	SetRows(f.Cards[1], rows)
	f.Cards[1].FootLabel:SetText(Label(m.depth.missing > 0 and "Total cost (depth?)" or "Total cost"))
	f.Cards[1].FootValue:SetText(m.costComplete and Money(m.totalCost) or Gray(DASH))

	-- Craft card: intermediates first (crafting order), then the shuffle item
	rows = {}
	for _, c in ipairs(m.crafts) do
		table.insert(rows, { Gold(string.format("%dx %s", c.count, CS:ItemName(c.itemID))), Muted("first") })
	end
	table.insert(rows, { Body(string.format("%dx %s", m.craft.count, CS:ItemName(m.outputItemID) or m.name)), Seconds(m.craft.timeSec) })
	if (m.eco.quantity or 1) ~= 1 then
		table.insert(rows, { Muted("Items made"), Muted(string.format("%g", m.craft.outputQty)) })
	end
	table.insert(rows, { Muted("Skill-ups"), Muted(m.craft.skillUps and CS:FormatQty(m.craft.skillUps) or "?") })
	SetRows(f.Cards[2], rows)
	f.Cards[2].FootLabel:SetText(Label("Cost basis"))
	f.Cards[2].FootValue:SetText(m.costComplete and Money(m.craft.costBasis) or Gray(DASH))

	-- Disenchant card
	rows = {}
	for _, d in ipairs(m.de) do
		table.insert(rows, { Body(string.format("%sx %s", CS:FormatQty(d.expectedQty), CS:ItemName(d.itemID))),
			Muted(string.format("%d%%", math.floor(d.chance * 100 + 0.5))) })
	end
	if #rows == 0 then
		table.insert(rows, { Gray(CS.UI.STATUS_TEXT[m.status] or m.status or "no data"), "" })
	elseif m.deInfo then
		table.insert(rows, { Muted(m.deInfo.estimateOnly and "estimate" or m.deInfo.summary), "" })
	end
	table.insert(rows, { Muted(string.format("%d casts", m.craft.outputQty)), Seconds(m.time.de) })
	SetRows(f.Cards[3], rows)
	f.Cards[3].FootLabel:SetText(Label("Mat value"))
	f.Cards[3].FootValue:SetText(m.matValueComplete and Money(m.matValue) or Gray(DASH))

	-- Sell card
	rows = {}
	for _, d in ipairs(m.de) do
		local label = Body(string.format("%sx %s", CS:FormatQty(d.expectedQty), CS:ItemName(d.itemID)))
		table.insert(rows, { label, d.unit and Money(d.value, { compact = true }) or Gray("no price") })
	end
	table.insert(rows, { Label(string.format("AH cut (%d%%)", math.floor((CS.CP.settings.ahCut or 0) * 100 + 0.5))),
		m.cut > 0 and Label("-" .. CS:Money(m.cut, { compact = true })) or Gray(DASH) })
	SetRows(f.Cards[4], rows)
	f.Cards[4].FootLabel:SetText(Label("Net"))
	if m.net then
		f.Cards[4].FootValue:SetText(CS:Color(m.net >= 0 and C.profit or C.loss, CS:Money(m.net, { sign = true })))
	else
		f.Cards[4].FootValue:SetText(Gray(DASH))
	end

	-- Footer
	if m.net then
		local hex = m.net >= 0 and C.profit or C.loss
		f.Summary:SetText(string.format("Expected net: %s %s \194\183 per craft %s \194\183 total time %s",
			CS:Color(hex, CS:Money(m.net, { sign = true })),
			m.margin and Muted("(" .. (CS:Margin(m.margin, true) or "") .. ")") or "",
			CS:Color(hex, CS:Money(m.perCraft, { sign = true })),
			Seconds(m.time.total)))
	else
		f.Summary:SetText(Muted("Expected net: " .. (CS.UI.STATUS_TEXT[m.status] or "no data")) .. " \194\183 total time " .. Seconds(m.time.total))
	end
	self:EnsureLadders(m)

	if self.session then f.BuyButton:Enable() else f.BuyButton:Disable() end
	local nextCraft = self:NextCraft()
	f.CraftButton.csNext = nextCraft
	if nextCraft.allDone then
		f.CraftButton:SetText("All crafted")
		f.CraftButton:Disable()
	else
		f.CraftButton:SetText(string.format("Craft %d", nextCraft.count))
		if self:CanCraft(nextCraft.recipeID) then f.CraftButton:Enable() else f.CraftButton:Disable() end
	end
	f.StartButton:Enable()
	f.StartButton:SetText(self.session and "Stop Shuffle" or "Start Shuffle")
	local mailTo = self:GetMailTo()
	f.MailButton:SetText(mailTo and ("Mail: " .. (mailTo:match("^(%S+)") or mailTo)) or "Mail to...")
	local short, title, detail = self:DepthText(m)
	f.Session:SetText(short)
	f.SessionHover.title, f.SessionHover.detail = title, detail
	if self.view == "session" then self:UpdateSessionView() end
end

---------------------------------------------------------------------------
-- Plan / Session view switch
---------------------------------------------------------------------------

Planner.view = "plan"

function Planner:SetView(view)
	self.view = view == "session" and "session" or "plan"
	self:Refresh()
end

function Planner:ApplyView()
	local f = self.frame
	if not f then return end
	local session = self.view == "session"
	for _, card in ipairs(f.Cards) do card:SetShown(not session) end
	for _, card in ipairs(f.SessionCards) do card:SetShown(session) end
	for _, line in ipairs(f.History) do line:SetShown(session) end
	f.Session:SetShown(not session)
	f.SessionHover:SetShown(not session)
	f.ViewButton:SetText(session and "Plan View" or "Session View")
end

local ClampSessionPurchases

-- How many of an item the session counts as bought for the plan: what it still had to buy at the start
-- (plan.toBuy), or for sessions from before that the plan's whole need (plan.leaves). nil = no cap known.
local function SessionBuyCap(s, itemID)
	local plan = s.plan or {}
	if plan.toBuy then return plan.toBuy[itemID] or 0 end
	local leaf = plan.leaves and plan.leaves[itemID]
	return leaf and leaf.qty or nil
end

-- Counts a purchase toward the running session, only up to what the plan needs; the rest (extra stock,
-- other items) is the player's own business. The counted share of the cost is pro rata.
function Planner:RecordSessionPurchase(itemID, qty, total)
	local s = self.session
	if not (s and s.planItems and s.planItems[itemID] and total and (qty or 0) > 0) then return 0 end
	s.bought = s.bought or {}
	s.boughtCost = s.boughtCost or {}
	local cap = SessionBuyCap(s, itemID)
	local take = qty
	if cap then take = math.max(0, math.min(qty, cap - (s.bought[itemID] or 0))) end
	if take <= 0 then return 0 end
	local cost = total * take / qty
	s.spent = (s.spent or 0) + cost
	s.bought[itemID] = (s.bought[itemID] or 0) + take
	s.boughtCost[itemID] = (s.boughtCost[itemID] or 0) + cost
	return take
end

-- Sessions that counted extra purchases before the cap existed: trim them back to the cap (idempotent).
ClampSessionPurchases = function(s)
	for itemID, n in pairs(s.bought or {}) do
		local cap = SessionBuyCap(s, itemID)
		if cap and n > cap then
			local cost = s.boughtCost and s.boughtCost[itemID] or 0
			local keep = n > 0 and cost * cap / n or 0
			s.spent = math.max(0, (s.spent or 0) - (cost - keep))
			s.bought[itemID] = cap
			if s.boughtCost then s.boughtCost[itemID] = keep end
		end
	end
end

-- Numbers for the session view, for a running or finished session.
function Planner:SessionStats(s)
	local CP = CS.CP
	-- a running session started before plan.leaves existed: rebuild the per-material plan once from the
	-- recipe (today's prices for what was not bought) so its cost basis uses real spend too
	if not s.ended and s.recipeID and type(s.plan) == "table" and not s.plan.leaves then
		local ok, m = pcall(self.BuildModel, self, s.recipeID, s.qty or 1)
		if ok and m then
			s.plan.leaves = {}
			for _, e in ipairs(m.shopping) do s.plan.leaves[e.itemID] = { qty = e.qty, total = e.realTotal } end
			s.plan.casts = m.craft.outputQty
		end
	end
	ClampSessionPurchases(s)
	local st = { s = s }
	st.elapsed = (s.ended or time()) - (s.started or time())
	st.crafted, st.qty, st.de = s.crafted or 0, s.qty or 1, s.disenchanted or 0
	st.spent = s.spent or 0
	st.plan = s.plan or {}
	st.planCost = s.expectedCost or 0
	st.planNet = s.expectedNet
	st.planMatValue = s.expectedMatValue or 0
	st.cutRate = CP.settings.ahCut or 0

	-- materials at current prices
	st.matValue, st.mats = 0, {}
	local seen = {}
	for _, y in ipairs(st.plan.yields or {}) do
		local unit = CP:GetSalePrice(y.itemID) or y.unit
		local gained = s.mats and s.mats[y.itemID] or 0
		table.insert(st.mats, { itemID = y.itemID, gained = gained, expectedSoFar = y.perDE * st.de, expectedTotal = y.perDE * st.qty, unit = unit })
		if unit then st.matValue = st.matValue + unit * gained end
		seen[y.itemID] = true
	end
	for matID, gained in pairs(s.mats or {}) do
		if not seen[matID] then
			local unit = CP:GetSalePrice(matID)
			table.insert(st.mats, { itemID = matID, gained = gained, expectedSoFar = 0, expectedTotal = 0, unit = unit, unplanned = true })
			if unit then st.matValue = st.matValue + unit * gained end
		end
	end
	st.expectedSoFar = 0
	for _, x in ipairs(st.mats) do
		if x.unit then st.expectedSoFar = st.expectedSoFar + x.unit * x.expectedSoFar end
	end
	-- Batch cost: what was paid for bought materials plus the planned cost of the rest (from the bags or
	-- not bought yet). Sessions from before plan.leaves existed fall back to the frozen per-craft cost.
	local casts = st.plan.casts or st.qty
	-- the plan's materials for the whole batch at today's prices
	st.expectedFull = 0
	for _, x in ipairs(st.mats) do
		if x.unit then st.expectedFull = st.expectedFull + x.unit * x.expectedTotal end
	end
	st.paidPlanned = 0 -- what the purchased quantities were planned to cost
	if st.plan.leaves then
		local batch = 0
		for itemID, L in pairs(st.plan.leaves) do
			local unit = (L.total and L.qty and L.qty > 0) and (L.total / L.qty) or 0
			local bq = s.bought and s.bought[itemID] or 0
			local bc = s.boughtCost and s.boughtCost[itemID] or 0
			local used = math.min(bq, L.qty or 0)
			local paid = bq > 0 and (bc * used / bq) or 0
			st.paidPlanned = st.paidPlanned + unit * used
			batch = batch + paid + unit * ((L.qty or 0) - used)
		end
		st.batchCost = batch
	else
		st.batchCost = (s.costPerCraft or 0) * casts
		st.paidPlanned = st.planCost
	end
	st.costPerCast = casts > 0 and st.batchCost / casts or 0
	st.costBasisDE = st.costPerCast * st.de
	st.netSoFar = st.matValue - st.matValue * st.cutRate - st.costBasisDE
	if st.de > 0 then
		st.perDEValue = st.matValue / st.de
		st.projectedMatValue = st.perDEValue * casts
	else
		-- nothing disenchanted yet: the plan's yields at today's prices
		st.perDEValue = nil
		st.projectedMatValue = st.expectedFull
	end
	st.projectedNet = st.projectedMatValue - st.projectedMatValue * st.cutRate - st.batchCost
	st.casts = casts
	st.complete = st.de >= casts
	-- result (or projection) vs plan, split into parts that add up to it:
	--   luck   = materials got vs the plan's average yields, at today's prices, after the AH cut
	--   prices = the plan's materials at today's prices vs at the start
	--   cost   = the plan's cost vs the batch cost (real purchases)
	if st.planNet then
		local keep = 1 - st.cutRate
		st.vsPlan = st.projectedNet - st.planNet
		st.vsLuck = (st.projectedMatValue - st.expectedFull) * keep
		st.vsPrices = (st.expectedFull - st.planMatValue) * keep
		st.vsCost = st.planCost - st.batchCost
	end
	return st
end

local function Signed(v)
	if not v then return Gray(DASH) end
	return CS:Color(v >= 0 and C.profit or C.loss, CS:Money(v, { sign = true }))
end

local function Elapsed(sec)
	sec = math.max(0, math.floor(sec or 0))
	if sec < 60 then return string.format("%d sec", sec) end
	if sec < 3600 then return string.format("%d min", math.floor(sec / 60)) end
	return string.format("%dh %02dm", math.floor(sec / 3600), math.floor((sec % 3600) / 60))
end

function Planner:UpdateSessionView()
	local f = self.frame
	if not f then return end
	local s = self.session
	local last = not s and CS.db.sessions[#CS.db.sessions] or nil
	local sess = s or last
	local cards = f.SessionCards

	if not sess then
		for _, card in ipairs(cards) do SetRows(card, {}) card.FootLabel:SetText("") card.FootValue:SetText("") end
		f.Summary:SetText(Muted("No shuffle session yet. Pick a recipe in the Plan View and press Start Shuffle."))
		for _, line in ipairs(f.History) do line:SetText("") end
		return
	end

	local st = self:SessionStats(sess)
	local running = s ~= nil
	f.Summary:SetText(string.format("%s %s \194\183 started %s \194\183 %s %s",
		running and Gold("Session:") or Label("Last session:"),
		Body(string.format("%dx %s", st.qty, sess.name or "?")),
		date("%H:%M", sess.started or 0),
		running and "running" or "took", Body(Elapsed(st.elapsed))))

	-- Buy: what the plan cost and what was spent
	local rows = {
		{ Label("Planned cost"), Money(st.planCost) },
		{ Label("Spent (purchases)"), st.spent > 0 and CS:Color(st.spent <= st.paidPlanned + 0.5 and C.profit or C.loss, CS:Money(st.spent)) or Muted("none recorded") },
		{ Label("Batch cost"), Money(st.batchCost) },
	}
	local bought = {}
	for itemID, qty in pairs(sess.bought or {}) do table.insert(bought, { itemID = itemID, qty = qty, cost = sess.boughtCost and sess.boughtCost[itemID] }) end
	table.sort(bought, function(a, b) return (a.cost or 0) > (b.cost or 0) end)
	for i, b in ipairs(bought) do
		if i > 5 then break end
		table.insert(rows, { Muted(string.format("    %dx %s", b.qty, CS:ItemName(b.itemID))), b.cost and Money(b.cost, { compact = true }) or "" })
	end
	SetRows(cards[1], rows)
	cards[1].FootLabel:SetText(Label("Paid vs plan"))
	cards[1].FootValue:SetText(st.spent > 0 and Signed(st.paidPlanned - st.spent) or Gray(DASH))

	-- Craft: progress and pace
	rows = {}
	for _, c in ipairs(st.plan.crafts or {}) do
		local i = sess.intermediates and sess.intermediates[c.recipeID]
		local count = i and i.count or 0
		table.insert(rows, { Gold(c.name), Gold(string.format("%d/%d", count, c.count)) })
	end
	table.insert(rows, { Body(sess.name or "?"), Body(string.format("%d/%d", st.crafted, st.qty)) })
	table.insert(rows, { Muted("Elapsed"), Muted(Elapsed(st.elapsed)) })
	if st.crafted > 0 and st.elapsed > 0 then
		table.insert(rows, { Muted("Pace"), Muted(string.format("%.1f crafts/min", st.crafted / (st.elapsed / 60))) })
	end
	if st.plan.time then table.insert(rows, { Muted("Plan time"), Muted(Elapsed(st.plan.time)) }) end
	SetRows(cards[2], rows)
	cards[2].FootLabel:SetText(Label("Progress"))
	cards[2].FootValue:SetText(Body(string.format("%d%%", math.floor(st.crafted / st.qty * 100 + 0.5))))

	-- Disenchant: materials gained against what the plan expected by now
	rows = { { Label("Disenchanted"), Body(string.format("%d/%d", st.de, st.qty)) } }
	if (sess.mailed or 0) > 0 then
		table.insert(rows, { Label("Mailed to " .. (sess.mailedTo or "?")), Body(tostring(sess.mailed)) })
	end
	for _, x in ipairs(st.mats) do
		local name = (x.unplanned and Muted or Body)(CS:ItemName(x.itemID))
		local right
		if x.unplanned then
			right = Body(tostring(x.gained)) .. Muted(" unplanned")
		else
			local hex = x.gained >= x.expectedSoFar - 0.5 and C.profit or C.label
			right = CS:Color(hex, tostring(x.gained)) .. Muted(string.format(" (~%s)", CS:FormatQty(x.expectedSoFar):gsub("^~", "")))
		end
		table.insert(rows, { name, right })
	end
	if st.de > 0 then
		table.insert(rows, { Muted("Value per cast"), Muted(CS:Money(st.perDEValue, { compact = true })) })
	end
	table.insert(rows, { Muted("Cost per cast"), Muted(CS:Money(st.costPerCast, { compact = true })) })
	SetRows(cards[3], rows)
	cards[3].FootLabel:SetText(Label("Mats so far"))
	cards[3].FootValue:SetText(Money(st.matValue))

	-- Result: realized, and (while casts are left) projected to the whole batch. Once every cast is done the
	-- projection is the result itself, so it is left out and the footer compares the result with the plan.
	rows = {
		{ Label("Mats value"), Money(st.matValue) },
		{ Label(st.complete and "Plan expected" or "Plan expected by now"), Money(st.expectedSoFar) },
		{ Label("AH cut"), Money(st.matValue * st.cutRate) },
		{ Label(string.format("Cost of %d disenchanted", st.de)), Money(st.costBasisDE) },
		{ Label(st.complete and "Net" or "Net so far"), Signed(st.netSoFar) },
	}
	if not st.complete then
		table.insert(rows, { Label(string.format("Projected net (%d)", st.casts)), Signed(st.projectedNet) })
	end
	table.insert(rows, { Label("Plan net"), Signed(st.planNet) })
	SetRows(cards[4], rows)
	cards[4].FootLabel:SetText(Label(st.complete and "Net vs plan" or "Projected vs plan"))
	cards[4].FootValue:SetText(st.planNet and Signed(st.vsPlan) or Gray(DASH))

	-- Recent finished sessions
	local hist = CS.db.sessions
	for i = 1, HISTORY_LINES do
		local h = hist[#hist - i + 1]
		local line = f.History[i]
		if h and not (running and false) then
			line:SetText(string.format("%s  %s  \194\183 crafted %d/%d \194\183 disenchanted %d \194\183 mats %s \194\183 spent %s \194\183 net %s",
				Muted(date("%m-%d %H:%M", h.started or 0)), Body(string.format("%dx %s", h.qty or 0, h.name or "?")),
				h.crafted or 0, h.qty or 0, h.disenchanted or 0, CS:Money(h.matValue or 0), CS:Money(h.spent or 0), Signed(h.net)))
		else
			line:SetText(i == 1 and Muted("No finished sessions yet.") or "")
		end
	end
end

-- Session View tooltips: where the materials and the result stand against the plan.
function Planner:ShowSessionCardTooltip(card, index)
	if index ~= 3 and index ~= 4 then return end
	local sess = self.session or CS.db.sessions[#CS.db.sessions]
	if not sess then return end
	local st = self:SessionStats(sess)
	GameTooltip:SetOwner(card, "ANCHOR_RIGHT")
	if index == 3 then
		GameTooltip:AddLine("Materials vs the plan")
		GameTooltip:AddLine(string.format("After %d of %d casts. The plan is the average yield per cast; every material is a chance per cast, so a few casts can swing a lot either way.", st.de, st.casts), 1, 1, 1, true)
		GameTooltip:AddLine(" ")
		for _, x in ipairs(st.mats) do
			local left = string.format("%s: %d (plan ~%s)", CS:ItemName(x.itemID), x.gained, (CS:FormatQty(x.expectedSoFar):gsub("^~", "")))
			local right = x.unit and Signed((x.gained - x.expectedSoFar) * x.unit) or Gray("no price")
			GameTooltip:AddDoubleLine(left, right, 1, 1, 1)
		end
	else
		GameTooltip:AddLine(st.complete and "Result vs plan" or "Projection vs plan")
		if not st.planNet then
			GameTooltip:AddLine("This session has no plan net to compare with.", 1, 1, 1, true)
		else
			GameTooltip:AddDoubleLine("Plan net (prices at the start)", Signed(st.planNet), 1, 1, 1)
			GameTooltip:AddDoubleLine("Disenchant luck", Signed(st.vsLuck), 1, 1, 1)
			GameTooltip:AddDoubleLine("Mat prices since the start", Signed(st.vsPrices), 1, 1, 1)
			GameTooltip:AddDoubleLine("Cost vs plan", Signed(st.vsCost), 1, 1, 1)
			GameTooltip:AddDoubleLine(st.complete and "Net" or string.format("Projected net (%d casts)", st.casts), Signed(st.projectedNet), 1, 0.82, 0)
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Luck: the materials you got against the plan's average yields, at today's prices, after the AH cut. Prices: the plan's materials at today's AH prices against the prices when the session started. Cost: the planned cost against what the batch really cost.", 0.6, 0.6, 0.6, true)
		end
	end
	GameTooltip:Show()
end

-- Second footer line while no session runs: how good the buy-side numbers are.
-- Footer status next to Session View: a few words that fit the line, plus the full
-- explanation for its tooltip. Returns short, title, detail.
function Planner:DepthText(m)
	local d = m.depth
	local ahOpen = CS.CP.Scanner and CS.CP.Scanner.ahOpen
	local track = "Start Shuffle tracks your crafts, disenchants and spend against this plan."
	if #d.short > 0 then
		local names = {}
		for _, e in ipairs(d.short) do table.insert(names, CS:ItemName(e.itemID)) end
		local short = "Not enough listed: " .. names[1] .. (#names > 1 and string.format(" +%d more", #names - 1) or "")
		return CS:Color(C.loss, short), "Not enough listed",
			"The Auction House does not have enough of: " .. table.concat(names, ", ") .. ". Plan a smaller batch or wait for new listings."
	end
	local s = d.missing == 1 and "" or "s"
	if d.missing > 0 then
		if ahOpen then
			return Label("Checking AH depth..."), "Checking AH depth",
				string.format("Reading the listings for %d reagent%s. Until then they are priced at the lowest buyout.", d.missing, s)
		end
		return Label(string.format("AH depth unknown (%d) - Scan AH", d.missing)), "AH depth unknown",
			string.format("%d reagent%s priced at the lowest buyout only (marked ?). Open the Auction House and click Scan AH to price the real listings.", d.missing, s)
	end
	if d.ladders > 0 then
		local beyond = #d.beyond > 0
		return Muted(string.format("AH prices: %s%s", CS:Age(d.oldest or 0), beyond and Label(" - partly beyond depth") or "")),
			"AH prices",
			string.format("Buy prices walk the real AH listings, scanned %s.%s %s", CS:Age(d.oldest or 0),
				beyond and " Some quantities go beyond the scanned depth, so those units are estimated." or "", track)
	end
	return Muted("Plan only - Start Shuffle to track"), "Plan", track
end

-- With the AH open, fetch price ladders for the plan's purchases when missing or stale (once per plan).
function Planner:EnsureLadders(m)
	local Scanner = CS.CP.Scanner
	if not (Scanner and Scanner.ahOpen and Scanner.ScanItems) then return end
	local ids, sig = {}, {}
	for _, e in ipairs(m.shopping) do
		if e.buyKind ~= "vendor" and (e.buyNow or 0) > 0 then
			local age = Scanner:GetLadderAge(e.itemID)
			if not age or age > (Scanner.LADDER_STALE or 600) then
				table.insert(ids, e.itemID)
				table.insert(sig, e.itemID)
			end
		end
	end
	if #ids == 0 then return end
	table.sort(sig)
	local key = table.concat(sig, ",")
	local now = GetTime and GetTime() or 0
	if self.ladderRequest and self.ladderRequest.key == key and now - self.ladderRequest.t < 120 then return end
	self.ladderRequest = { key = key, t = now }
	Scanner:ScanItems(ids)
end

-- Scan AH button: depth scan of this plan's purchases and materials; shift-click runs the full browse scan.
local ScanRemaining -- defined after ScanAH

function Planner:ScanAH()
	local Scanner = CS.CP.Scanner
	if not Scanner then return end
	if not Scanner.ahOpen then
		CS:Print("open the Auction House first.")
		return
	end
	if IsShiftKeyDown and IsShiftKeyDown() then
		Scanner:Start()
		return
	end
	local m = self.model
	if not m then
		Scanner:Start()
		return
	end
	local ids = {}
	for _, e in ipairs(m.shopping) do if e.buyKind ~= "vendor" then table.insert(ids, e.itemID) end end
	for _, c in ipairs(m.crafts) do table.insert(ids, c.itemID) end
	for _, d in ipairs(m.de) do table.insert(ids, d.itemID) end
	self.ladderRequest = nil
	if self.scanJob then return end -- already reading this plan's listings; the button shows the progress
	local ok, err = Scanner:ScanItems(ids)
	if not ok then
		CS:Print("Scan AH did not start: %s", tostring(err))
		return
	end
	local total = ScanRemaining()
	if total == 0 then
		CS:Print("Scan AH: nothing to check for this plan.")
		return
	end
	self.scanJob = { total = total }
	if C_Timer and C_Timer.NewTicker then
		self.scanJob.ticker = C_Timer.NewTicker(0.25, function() Planner:UpdateScanStatus() end)
	end
	self:UpdateScanStatus()
end

-- Items the scanner still has to read (queued + the one in flight).
ScanRemaining = function()
	local Scanner = CS.CP.Scanner
	if not Scanner then return 0 end
	return (Scanner.itemQueue and #Scanner.itemQueue or 0) + (Scanner.itemCurrent and 1 or 0)
end

-- Ends the Scan AH job: done (all listings read) or stopped (AH closed).
function Planner:FinishScanJob(stopped)
	local job = self.scanJob
	if not job then return end
	self.scanJob = nil
	if job.ticker and job.ticker.Cancel then job.ticker:Cancel() end
	if stopped then
		CS:Print("Scan AH stopped: the Auction House was closed.")
	else
		CS:Print("Scan AH done: prices for %d item%s now come from the live AH listings.", job.total, job.total == 1 and "" or "s")
	end
	self:Refresh()
end

-- The Scan AH button and the age line next to it: progress while the plan's listings are read
-- ("Scanning 3/7"), "Scanning..." during a full browse scan, otherwise how fresh the plan's prices are.
function Planner:UpdateScanStatus()
	local f = self.frame
	local Scanner = CS.CP.Scanner
	local job = self.scanJob
	if job then
		local left = ScanRemaining()
		if left == 0 then return self:FinishScanJob(false) end
		job.total = math.max(job.total, left)
	end
	if not f then return end
	local b = f.ScanButton
	if job then
		local left = ScanRemaining()
		b:SetText(string.format("Scanning %d/%d", job.total - left + 1, job.total))
		b:Disable()
		f.ScanAge:SetText(Scanner and Scanner.itemPausedForBuy and "Paused while a buy page is open" or "Reading the AH listings...")
		return
	end
	if Scanner and Scanner.running then
		b:SetText("Scanning...")
		b:Disable()
		f.ScanAge:SetText("Full AH scan running")
		return
	end
	b:SetText("Scan AH")
	b:Enable()
	local source = CS.CP.Sources:Resolve()
	local m = self.model
	if source and source.key ~= "craftprofit" then
		f.ScanAge:SetText(source.name)
	elseif m and m.depth and m.depth.ladders > 0 and m.depth.oldest then
		f.ScanAge:SetText("Prices checked " .. CS:Age(m.depth.oldest))
	else
		local last = Scanner and Scanner:GetLastScan() or 0
		f.ScanAge:SetText(last > 0 and ("Full scan " .. CS:Age(time() - last)) or "No scan yet")
	end
end

function Planner:ShowCardTooltip(card, index)
	local m = self.model
	if not m then return end
	GameTooltip:SetOwner(card, "ANCHOR_RIGHT")
	if index == 1 then
		GameTooltip:AddLine("Shopping list")
		for _, b in ipairs(m.buy) do
			local indent = string.rep("  ", b.depth or 0)
			local name = indent .. string.format("%dx %s", b.qty, CS:ItemName(b.itemID))
			if b.crafts then
				GameTooltip:AddDoubleLine(name, string.format("craft %dx: %s vs %s to buy", b.crafts,
					b.realTotal and CS:Money(b.realTotal) or "?", b.buyTotal and CS:Money(b.buyTotal) or "?"), 1, 0.82, 0, 1, 0.82, 0)
			elseif b.buyKind == "vendor" then
				GameTooltip:AddDoubleLine(name, CS:Money(b.avgUnit or b.unit or 0) .. " ea (vendor)", 0.8, 0.8, 0.8, 1, 1, 1)
			elseif b.buyInfo and b.buyInfo.source == "ladder" then
				local parts = {}
				for _, t in ipairs(b.buyInfo.tiers or {}) do table.insert(parts, string.format("%d @ %s", t[2], CS:Money(t[1]))) end
				GameTooltip:AddDoubleLine(name, string.format("%s (avg %s)", CS:Money(b.realTotal or 0), CS:Money(b.avgUnit or 0)), 0.8, 0.8, 0.8, 1, 1, 1)
				GameTooltip:AddLine(indent .. "   " .. table.concat(parts, ", "), 0.6, 0.6, 0.6, true)
				if (b.buyInfo.short or 0) > 0 then
					GameTooltip:AddLine(indent .. "   " .. (b.buyInfo.full and string.format("only %d listed, %d short", b.buyInfo.covered or 0, b.buyInfo.short)
						or string.format("%d beyond the scanned depth, priced at the top tier seen", b.buyInfo.short)), 1, 0.4, 0.4, true)
				end
			elseif b.realTotal then
				GameTooltip:AddDoubleLine(name, CS:Money(b.avgUnit or b.unit or 0) .. " ea (lowest buyout, depth unknown)", 0.8, 0.8, 0.8, 1, 0.82, 0)
			else
				GameTooltip:AddDoubleLine(name, "no price", 0.8, 0.8, 0.8, 0.6, 0.6, 0.6)
			end
			local paid, ago, paidQty = CS.CP.Scanner and CS.CP.Scanner:GetLastPaid(b.itemID)
			if paid then
				GameTooltip:AddLine(indent .. string.format("   last bought %dx at %s ea, %s", paidQty or 0, CS:Money(paid), CS:Age(ago)), 0.5, 0.5, 0.5, true)
			end
		end
		if m.savings > 0 then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine(string.format("Crafting the gold lines yourself instead of buying them saves %s.", CS:Money(m.savings)), 0.3, 0.82, 0.22, true)
		end
		GameTooltip:AddLine("Buy prices walk the AH listings captured for each item (Scan AH, or view the item in the AH). Intermediates: only recipes you know, only when cheaper than buying.", 0.6, 0.6, 0.6, true)
	elseif index == 2 then
		GameTooltip:AddLine("Craft")
		for _, c in ipairs(m.crafts) do
			GameTooltip:AddDoubleLine(string.format("%dx %s", c.count, c.name), string.format("makes %d", c.count * c.outputQty), 1, 0.82, 0, 1, 1, 1)
		end
		GameTooltip:AddLine("The Craft button crafts intermediates you are short of first, then the shuffle item.", 0.8, 0.8, 0.8, true)
		GameTooltip:AddLine("Cast time from the spell data; skill-ups from the recipe colour (orange 100%, yellow 60%, green 25%).", 0.6, 0.6, 0.6, true)
	elseif index == 3 then
		GameTooltip:AddLine("Disenchant" .. (m.deInfo and (" (" .. m.deInfo.summary .. ")") or ""))
		for _, y in ipairs(m.eco.yields or {}) do
			GameTooltip:AddDoubleLine(string.format("%s %s", CS:FormatYieldQty(y), CS:ItemName(y.itemID)),
				string.format("%d%% chance", math.floor(y.chance * 100 + 0.5)), 0.8, 0.8, 0.8, 1, 1, 1)
		end
		if m.deInfo and m.deInfo.bracketKey then
			GameTooltip:AddLine("Band: " .. CS.DEData:BracketLabel(m.deInfo.bracketKey), 0.6, 0.6, 0.6)
		end
	else
		GameTooltip:AddLine("Sell")
		for _, d in ipairs(m.de) do
			GameTooltip:AddDoubleLine(string.format("%sx %s", CS:FormatQty(d.expectedQty), CS:ItemName(d.itemID)),
				d.unit and (CS:Money(d.unit) .. " ea") or "no price", 0.8, 0.8, 0.8, 1, 1, 1)
		end
		GameTooltip:AddLine("Materials at the current price source; the AH cut comes off the gross.", 0.8, 0.8, 0.8, true)
		GameTooltip:AddLine("Source: " .. CS.CP:GetSourceName(), 1, 1, 1)
	end
	GameTooltip:Show()
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

-- Returns true, or false plus why: "api" (no craft API), "closed" (profession window not open),
-- "other" (the open window does not have this recipe learned).
function Planner:CanCraft(recipeID)
	if not (C_TradeSkillUI and C_TradeSkillUI.CraftRecipe and C_TradeSkillUI.GetRecipeInfo) then return false, "api" end
	if not (ProfessionsFrame and ProfessionsFrame:IsShown()) then return false, "closed" end
	local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
	if ok and info ~= nil and info.learned == true then return true end
	return false, "other"
end


-- Tooltip / chat line for a Craft button that cannot craft.
function Planner:CraftBlockedText(recipeID, reason)
	local prof = ProfessionName(recipeID)
	if reason == "closed" then
		return string.format("Open your %s window to craft. The button unlocks as soon as it opens.", prof or "profession")
	elseif reason == "other" then
		return string.format("The open profession window does not have this recipe. Open %s.", prof or "the profession that teaches it")
	end
	return "Crafting is not available on this client."
end

-- How many casts of a recipe the bags allow, and what is missing for `count` casts.
-- Returns craftable, missing = { { itemID, short } }.
function Planner:Craftable(recipeID, count)
	local base = CS.Calc:Base(recipeID)
	if not base or #(base.reagents or {}) == 0 then return count, {} end
	local craftable, missing = count, {}
	for _, r in ipairs(base.reagents) do
		local have = ItemCount(r.itemID)
		if have then
			local possible = math.floor(have / math.max(1, r.qty))
			if possible < craftable then craftable = possible end
			local short = r.qty * count - have
			if short > 0 then table.insert(missing, { itemID = r.itemID, short = short }) end
		end
	end
	return math.max(0, craftable), missing
end

function Planner:MissingText(missing)
	local parts = {}
	for _, x in ipairs(missing or {}) do table.insert(parts, string.format("%dx %s", x.short, CS:ItemName(x.itemID))) end
	return #parts > 0 and table.concat(parts, ", ") or "nothing"
end

-- What the Craft button should do next: the first intermediate we are short of (deepest first),
-- otherwise the shuffle item itself. Returns { recipeID, name, count, itemID, have, need }.
function Planner:NextCraft()
	local m = self.model
	if not m then return nil end
	for _, c in ipairs(m.crafts) do
		local have = ItemCount(c.itemID)
		local need = c.needNow or c.need
		if have and have < need then
			return { recipeID = c.recipeID, name = c.name, itemID = c.itemID, have = have, need = need,
				count = math.ceil((need - have) / c.outputQty - 1e-9) }
		end
	end
	-- count 0 = the running shuffle has crafted the whole batch (the Craft button turns into "All crafted")
	local remaining = m.remaining or m.qty
	return { recipeID = m.recipeID, name = m.name, itemID = m.outputItemID, count = math.max(0, remaining), allDone = remaining <= 0 }
end

function Planner:CraftAll()
	local m = self.model
	if not m then return end
	local nc = self:NextCraft()
	if nc.allDone then
		CS:Print("all %d %s are crafted. Next: disenchant them (DE Macro).", m.qty, m.name)
		return
	end
	local can, why = self:CanCraft(nc.recipeID)
	if not can then
		CS:Print("cannot craft %s: %s", nc.name, self:CraftBlockedText(nc.recipeID, why))
		return
	end
	local craftable, missing = self:Craftable(nc.recipeID, nc.count)
	if craftable <= 0 then
		CS:Print("cannot craft %s yet: missing %s. Buy Reagents lists what is left to get.", nc.name, self:MissingText(missing))
		return
	end
	local count = math.min(nc.count, craftable)
	local ok, err = pcall(C_TradeSkillUI.CraftRecipe, nc.recipeID, count)
	if not ok then
		CS:Print("craft failed: %s", tostring(err))
		return
	end
	local note = count < nc.count and string.format(" (%d of %d; missing %s for the rest)", count, nc.count, self:MissingText(missing)) or ""
	if nc.have then
		CS:Print("crafting %dx %s first (have %d of %d)%s.", count, nc.name, nc.have, nc.need, note)
	else
		CS:Print("crafting %dx %s%s.", count, nc.name, note)
	end
end

local function AuctionatorAPI()
	local a = _G.Auctionator
	return a and a.API and a.API.v1 or nil
end

-- What still has to be bought, given the bags: { { itemID, buy, need, have, total, avg, kind } }, plus
-- the lines that are done and the vendor lines, for display.
-- The plan the shopping list follows: the running shuffle's recipe and quantity (the planner may be showing
-- another recipe meanwhile). nil while no shuffle runs: nothing is bought for a plan that was not started.
function Planner:ShopModel()
	local s = self.session
	if not s then return nil end
	-- the planner's model is only kept current while its window is open; otherwise build a fresh one, so
	-- the bags (a purchase that just arrived) are counted as they are now
	local m = self.model
	if m and m.recipeID == s.recipeID and m.qty == s.qty and self.frame and self.frame:IsShown() then return m end
	return self:BuildModel(s.recipeID, s.qty or 1)
end

function Planner:ShoppingNow(m)
	m = m or self.model
	local list = {}
	if not m then return list end
	for _, b in ipairs(m.shopping) do
		table.insert(list, {
			itemID = b.itemID, buy = b.buyNow or 0, need = b.needNow or b.qty, have = b.have or 0,
			transit = b.transit or 0,
			total = b.buyNowTotal, avg = b.buyNowAvg, kind = b.buyKind, info = b.buyInfo,
		})
	end
	table.sort(list, function(a, b)
		if (a.buy > 0) ~= (b.buy > 0) then return a.buy > 0 end
		return (a.total or 0) > (b.total or 0)
	end)
	return list
end

-- Shopping list. With the AH open: our shopping panel docked to the AH (one row per reagent still needed,
-- click = that item's buy page with the quantity filled in). Otherwise: chat, and an Auctionator list when
-- that addon is present. The Blizzard AH has no multi-item search.
function Planner:BuyReagents()
	if not self.session then
		CS:Print("start the shuffle first (Start Shuffle): the shopping list follows the running shuffle.")
		return
	end
	local m = self:ShopModel()
	if not m then return end
	local now = self:ShoppingNow(m)
	local lines, names, craftLines = {}, {}, {}
	for _, e in ipairs(now) do
		if e.buy > 0 then
			table.insert(lines, string.format("%dx %s%s", e.buy, CS:ItemName(e.itemID), e.kind == "vendor" and " (vendor)" or ""))
			if e.kind ~= "vendor" then table.insert(names, CS:ItemName(e.itemID)) end
		end
	end
	for _, c in ipairs(m.crafts) do
		if (c.countNow or c.count) > 0 then table.insert(craftLines, string.format("%dx %s", c.countNow or c.count, c.name)) end
	end
	if #lines == 0 then
		CS:Print("nothing left to buy for %dx %s.", m.qty, m.name)
	else
		CS:Print("still to buy for %dx %s: %s", m.qty, m.name, table.concat(lines, ", "))
	end
	if #craftLines > 0 then
		CS:Print("still to craft yourself (saves %s vs buying): %s", CS:Money(m.savings), table.concat(craftLines, ", "))
	end

	local ahOpen = CS.CP.Scanner and CS.CP.Scanner.ahOpen
	if ahOpen and self:ShowShop() then return end

	local api = AuctionatorAPI()
	if api and #names > 0 and type(api.CreateShoppingList) == "function" then
		local ok = pcall(api.CreateShoppingList, CS.CALLER_ID, "CraftShuffle: " .. m.name, names)
		if ok then
			CS:Print("Auctionator shopping list 'CraftShuffle: %s' created.", m.name)
			return
		end
	end
	if not ahOpen then CS:Print("open the Auction House: Buy Reagents then shows the shopping panel.") end
end

---------------------------------------------------------------------------
-- Shopping panel inside the Auction House
---------------------------------------------------------------------------

-- Shuffle tab geometry. The tab fills the Auction House like Blizzard's own Buy tab: a toolbar right of
-- the portrait, a summary line, then one AH list (AuctionHouseTableHeaderStringTemplate column headers over
-- an InsetFrameTemplate with the Buy tab's background art and the AH row highlight), and a footer with the
-- total and Buy Next above the AH's money strip. Blizzard templates, font objects and colours only.
local SHOP_TOOLBAR_X, SHOP_TOOLBAR_Y = 68, -30     -- right of the AH portrait
local SHOP_SUMMARY_Y = -58
local SHOP_INSET_TOP, SHOP_INSET_BOTTOM = -76, 58
local SHOP_HEADER_H, SHOP_HEADER_OVERLAP = 19, 2  -- AH header art is 19 px; neighbours overlap by 2 (TableBuilder)
local SHOP_ROW_H, SHOP_ROWS = 22, 15
local SHOP_FOOT_Y = 32
-- columns: key, header, width (0 = takes what is left), justify
local SHOP_COLS = {
	{ "item", "Item", 0, "LEFT" },
	{ "source", "Source", 110, "LEFT" },
	{ "have", "Have", 130, "LEFT" },
	{ "unit", "Each", 100, "RIGHT" },
	{ "cost", "To Buy", 100, "RIGHT" },
	{ "action", "", 104, "CENTER" },
}

local function Try(obj, method, ...)
	if obj and type(obj[method]) == "function" then return pcall(obj[method], obj, ...) end
end

-- Blizzard's font colours (ColorMixin) as inline colour codes; plain text when the client lacks them.
local function Wrap(color, text)
	if color and type(color.WrapTextInColorCode) == "function" then return color:WrapTextInColorCode(text) end
	return text
end

-- Money as the default UI writes it (coin icons); our formatter when GetMoneyString is missing.
local function MoneyText(copper)
	if GetMoneyString then
		local ok, s = pcall(GetMoneyString, copper, true)
		if ok and type(s) == "string" then return s end
	end
	return CS:Money(copper)
end

local function ItemIcon(itemID)
	if C_Item and C_Item.GetItemIconByID then
		local ok, icon = pcall(C_Item.GetItemIconByID, itemID)
		if ok and icon then return icon end
	end
	if C_Item and C_Item.GetItemInfoInstant then
		local ok, _, _, _, _, icon = pcall(C_Item.GetItemInfoInstant, itemID)
		if ok and icon then return icon end
	end
	return "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- Item name in its quality colour, as AH rows show it.
local function QualityName(itemID, name)
	local q
	if C_Item and C_Item.GetItemQualityByID then
		local ok, v = pcall(C_Item.GetItemQualityByID, itemID)
		if ok then q = v end
	end
	local qc = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
	return Wrap(qc and qc.color, name)
end

-- Progress bar: the client's status bar texture over a dark track, Blizzard gold.
local function CreateBar(parent, height)
	local bar = CreateFrame("StatusBar", nil, parent)
	bar:SetHeight(height)
	bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	local c = NORMAL_FONT_COLOR
	bar:SetStatusBarColor(c and c.r or 1, c and c.g or 0.82, c and c.b or 0, 1)
	local track = bar:CreateTexture(nil, "BACKGROUND")
	track:SetColorTexture(0, 0, 0, 0.5)
	Try(track, "SetAllPoints", bar)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)
	return bar
end

local function SetBar(bar, have, need)
	need = math.max(1, need or 1)
	bar:SetMinMaxValues(0, need)
	bar:SetValue(math.min(have or 0, need))
end

-- Set the quantity on Blizzard's commodities buy page THROUGH ITS OWN METHOD. SetQuantitySelected recomputes
-- the unit/total price preview from the loaded search results; the buy dialog compares the server's quote
-- against that preview and shows "This item is no longer available" when they disagree. Writing the number
-- into the input box directly leaves the preview at one unit and every purchase fails that check.
-- The page has two parts that each keep a quantity: the buy box and the price list
-- (AuctionHouseCommoditiesBuyListMixin). The list starts at 1 and re-announces its own number on every refresh
-- (results loaded, more results fetched when the cheapest listing is small), which reset a quantity set on the
-- box alone back to 1. So the quantity goes out through the Auction House frame's
-- CommoditiesQuantitySelectionChanged event, which both parts follow (Gethe wow-ui-source, live = forever branch,
-- Blizzard_AuctionHouseCommoditiesBuyFrame.lua / _CommoditiesList.lua); SetQuantitySelected is the fallback.
local function ApplyQuantity(itemID, qty)
	local ah = AuctionHouseFrame
	local frame = ah and ah.CommoditiesBuyFrame
	local display = frame and frame.BuyDisplay
	if not display then return false end
	if type(display.GetItemID) == "function" then
		local ok, current = pcall(display.GetItemID, display)
		if ok and current and current ~= itemID then return false end
	end
	local event = AuctionHouseFrameMixin and AuctionHouseFrameMixin.Event and AuctionHouseFrameMixin.Event.CommoditiesQuantitySelectionChanged
	if event and type(ah.TriggerEvent) == "function" then
		return (pcall(ah.TriggerEvent, ah, event, qty))
	end
	if type(display.SetQuantitySelected) == "function" then return (pcall(display.SetQuantitySelected, display, qty)) end
	return false
end

-- Blizzard's display marks its results as loaded in its own event handler, which may run after ours,
-- so the quantity is (re)applied on the next frame and once more shortly after.
local function ApplyPendingQuantity()
	local p = Planner.pendingBuy
	if not p then return end
	if (GetTime and GetTime() or 0) - p.t > 10 then
		Planner.pendingBuy = nil
		return
	end
	if C_Timer and C_Timer.After then
		C_Timer.After(0, function() ApplyQuantity(p.itemID, p.qty) end)
		C_Timer.After(0.3, function() ApplyQuantity(p.itemID, p.qty) end)
	else
		ApplyQuantity(p.itemID, p.qty)
	end
end

-- Open the buy page for an item with the quantity prefilled (falls back to the search bar).
function Planner:BuyItem(itemID, qty)
	local ah = AuctionHouseFrame
	if not ah or not (C_AuctionHouse and C_AuctionHouse.MakeItemKey) then return false end
	-- the price we know for the item makes the page's initial preview sane (it is recomputed from the results)
	local minPrice = (CS.CP.Scanner and CS.CP.Scanner:GetMin(itemID)) or select(1, CS.CP:GetReagentCost(itemID)) or 0
	local ok = pcall(function()
		local key = (CS.CP.Scanner and CS.CP.Scanner.GetItemKey and CS.CP.Scanner:GetItemKey(itemID)) or C_AuctionHouse.MakeItemKey(itemID)
		CS:SelectAuctionItem(key, minPrice, qty)
	end)
	if ok then
		self.pendingBuy = { itemID = itemID, qty = qty, t = GetTime and GetTime() or 0 }
		self.shopUsed = true
		self.buyFromShop = true -- the buy page's Back button returns to the Shuffle tab
		ApplyQuantity(itemID, qty) -- shows the quantity right away; the price follows when results load
		return true
	end
	local bar = ah.SearchBar
	if bar then
		local ok2 = pcall(function()
			if bar.SearchBox and bar.SearchBox.SetText then bar.SearchBox:SetText(CS:ItemName(itemID)) end
			if type(bar.StartSearch) == "function" then bar:StartSearch() end
		end)
		return ok2
	end
	return false
end

-- AH row art: the selected-row atlas marks the next item to buy, the row highlight follows the mouse.
local function RowArt(row)
	local sel = row:CreateTexture(nil, "OVERLAY")
	Try(sel, "SetAllPoints", row)
	if not (sel.SetAtlas and pcall(sel.SetAtlas, sel, "auctionhouse-ui-row-select")) then sel:SetColorTexture(1, 0.82, 0, 0.12) end
	Try(sel, "SetBlendMode", "ADD")
	sel:Hide()
	row.Sel = sel
	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	Try(hl, "SetAllPoints", row)
	if not (hl.SetAtlas and pcall(hl.SetAtlas, hl, "auctionhouse-ui-row-highlight")) then hl:SetColorTexture(1, 1, 1, 0.08) end
	Try(hl, "SetBlendMode", "ADD")
end

-- Row states: "active" (next to buy), "pending" (later / vendor / in the mail), "done".
local function StyleRow(row, state)
	row.Sel:SetShown(state == "active")
end

local function Cell(row, layout, key, font)
	local i = layout.index[key]
	local fs = row:CreateFontString(nil, "OVERLAY", font)
	fs:SetPoint("LEFT", row, "LEFT", layout.x[i] + 6, 0)
	fs:SetWidth(math.max(8, layout.w[i] - 12))
	fs:SetJustifyH(SHOP_COLS[i][4])
	Try(fs, "SetWordWrap", false)
	return fs
end

local function CreateShopRow(area, i, layout)
	local row = CreateFrame("Button", nil, area)
	row:SetHeight(SHOP_ROW_H)
	local y = -SHOP_HEADER_H - 3 - (i - 1) * SHOP_ROW_H
	row:SetPoint("TOPLEFT", area, "TOPLEFT", 4, y)
	row:SetPoint("TOPRIGHT", area, "TOPRIGHT", -4, y)
	RowArt(row)

	-- item: icon + name in quality colour
	row.Icon = row:CreateTexture(nil, "ARTWORK")
	row.Icon:SetSize(18, 18)
	row.Icon:SetPoint("LEFT", row, "LEFT", 6, 0)
	Try(row.Icon, "SetTexCoord", 0.07, 0.93, 0.07, 0.93)
	row.Name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.Name:SetPoint("LEFT", row.Icon, "RIGHT", 6, 0)
	row.Name:SetWidth(math.max(40, layout.w[1] - 36))
	row.Name:SetJustifyH("LEFT")
	Try(row.Name, "SetWordWrap", false)

	row.Source = Cell(row, layout, "source", "GameFontHighlightSmall")
	row.Have = Cell(row, layout, "have", "GameFontHighlightSmall")
	row.Unit = Cell(row, layout, "unit", "GameFontHighlightSmall")
	row.Value = Cell(row, layout, "cost", "GameFontHighlight")

	local a = layout.index.action
	row.Buy = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.Buy:SetSize(layout.w[a] - 8, 20)
	row.Buy:SetPoint("LEFT", row, "LEFT", layout.x[a] + 4, 0)
	row.Buy:SetScript("OnClick", function(self)
		local r = self:GetParent()
		if r.csItemID and (r.csBuy or 0) > 0 then Planner:BuyItem(r.csItemID, r.csBuy) end
	end)
	row.Done = row:CreateTexture(nil, "OVERLAY")
	row.Done:SetSize(16, 16)
	row.Done:SetPoint("LEFT", row, "LEFT", layout.x[a] + math.floor(layout.w[a] / 2) - 8, 0)
	row.Done:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
	row.Done:Hide()

	row:SetScript("OnClick", function(self)
		if self.csItemID and (self.csBuy or 0) > 0 and self.csKind ~= "vendor" then Planner:BuyItem(self.csItemID, self.csBuy) end
	end)
	row:SetScript("OnEnter", function(self)
		if not self.csItemID then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		-- the item's own tooltip first (as the AH shows it), our plan lines under it
		if Try(GameTooltip, "SetItemByID", self.csItemID) then
			GameTooltip:AddLine(" ")
		else
			GameTooltip:AddLine(CS:ItemName(self.csItemID))
		end
		local e = self.csEntry
		if e then
			GameTooltip:AddLine(string.format("Plan needs %d, bags hold %d, buy %d.", e.need, e.have, e.buy), 1, 1, 1, true)
			if e.info and e.info.source == "ladder" and e.buy > 0 then
				local parts = {}
				for _, t in ipairs(e.info.tiers or {}) do table.insert(parts, string.format("%d @ %s", t[2], CS:Money(t[1]))) end
				GameTooltip:AddLine(table.concat(parts, ", "), 0.8, 0.8, 0.8, true)
			end
			local paid, ago, paidQty = CS.CP.Scanner and CS.CP.Scanner:GetLastPaid(self.csItemID)
			if paid then GameTooltip:AddLine(string.format("Last bought %dx at %s ea, %s.", paidQty or 0, CS:Money(paid), CS:Age(ago)), 0.6, 0.6, 0.6, true) end
		end
		if (self.csBuy or 0) > 0 and self.csKind ~= "vendor" then GameTooltip:AddLine("Click: open the buy page with this quantity.", 0.6, 0.6, 0.6, true) end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
	return row
end

-- A "Shopping" tab next to Buy / Sell / Auctions. The retail AH switches content with
-- AuctionHouseFrame:SetDisplayMode(mode) where mode is a table of frame names; a mode it does not know
-- hides all of its own frames, and our hook shows the shopping frame for our mode. Same technique as
-- Auctionator's tabs. If any of that is missing on this client, the shopping list falls back to a side panel.
Planner.SHOP_MODE = { "CraftShuffleShopping" }

function Planner:SetupShopTab()
	if self.shopTab ~= nil then return self.shopTab end
	local ah = AuctionHouseFrame
	if not (ah and type(ah.Tabs) == "table" and #ah.Tabs > 0 and type(ah.SetDisplayMode) == "function"
		and PanelTemplates_SetNumTabs and hooksecurefunc) then
		self.shopTab = false
		return false
	end
	local mode = self.SHOP_MODE
	local function Build(template, ownClick)
		local tabs = ah.Tabs
		local id = #tabs + 1
		-- PanelTemplates falls back to the global "<Frame>Tab<n>" name, so keep that convention
		local tab = CreateFrame("Button", "AuctionHouseFrameTab" .. id, ah, template)
		-- the Blizzard template may already have appended the tab to ah.Tabs (parentArray)
		local already, previous = false, nil
		for _, t in ipairs(tabs) do
			if t == tab then already = true elseif not already then previous = t end
		end
		if not already then
			previous = tabs[#tabs]
			table.insert(tabs, tab)
		end
		for i, t in ipairs(tabs) do if t == tab then id = i end end
		if tab.SetID then tab:SetID(id) end
		tab:SetText("Shuffle")
		tab.displayMode = mode
		tab:ClearAllPoints()
		if previous and previous ~= tab then
			tab:SetPoint("LEFT", previous, "RIGHT", -15, 0)
		else
			tab:SetPoint("BOTTOMLEFT", ah, "BOTTOMLEFT", 20, -30)
		end
		if ownClick then tab:SetScript("OnClick", function() ah:SetDisplayMode(mode) end) end
		PanelTemplates_SetNumTabs(ah, #tabs)
		if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 0) end
		return tab
	end
	local ok, tab = pcall(Build, "AuctionHouseFrameDisplayModeTabTemplate", false)
	if not ok or not tab then ok, tab = pcall(Build, "PanelTabButtonTemplate", true) end
	if not ok or not tab then
		CS:Debug("shopping tab not created: %s", tostring(tab))
		self.shopTab = false
		return false
	end
	self.shopTab = tab
	-- Buy pages opened from the Shuffle tab: Blizzard's Back button goes to the Buy tab (an empty browse
	-- list), so send it back to Shuffle instead. PreClick records the origin before OnClick's
	-- SetDisplayMode(Buy) clears it; the OnClick hook runs after Blizzard's handler.
	local buyModes = {}
	local DM = AuctionHouseFrameDisplayMode
	if type(DM) == "table" then
		if DM.CommoditiesBuy then buyModes[DM.CommoditiesBuy] = true end
		if DM.ItemBuy then buyModes[DM.ItemBuy] = true end
	end
	for _, key in ipairs({ "CommoditiesBuyFrame", "ItemBuyFrame" }) do
		local back = ah[key] and ah[key].BackButton
		if back and back.HookScript then
			back:HookScript("PreClick", function(b) b.csToShop = Planner.buyFromShop end)
			back:HookScript("OnClick", function(b)
				if not b.csToShop then return end
				b.csToShop = nil
				Planner.buyFromShop = nil
				pcall(ah.SetDisplayMode, ah, mode)
			end)
		end
	end
	pcall(hooksecurefunc, ah, "SetDisplayMode", function(_, displayMode)
		local f = Planner.shop
		local active = displayMode == mode
		if f then f:SetShown(active) end
		-- leaving the buy pages any other way (tabs, closing) ends the Shuffle origin
		if not active and not buyModes[displayMode] then Planner.buyFromShop = nil end
		if active then
			-- Blizzard only highlights tabs it knew about at load; select ours by hand
			if PanelTemplates_SetTab then
				for i, t in ipairs(ah.Tabs) do
					if t == tab then pcall(PanelTemplates_SetTab, ah, i) end
				end
			end
			Planner:UpdateShop()
		end
	end)
	return tab
end

-- The tab exists from the moment the Auction House opens, plan or no plan.
local function EnsureShopTab()
	if AuctionHouseFrame and not Planner.shop then
		local ok, err = pcall(Planner.GetShopFrame, Planner)
		if not ok then CS:Debug("shopping tab setup failed: %s", tostring(err)) end
	end
end
CS:RegisterEvent("AUCTION_HOUSE_SHOW", EnsureShopTab)
CS:RegisterEvent("ADDON_LOADED", function(_, name) if name == "Blizzard_AuctionHouseUI" then EnsureShopTab() end end)

local function ToolButton(parent, text, width, title, tip)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(title)
		GameTooltip:AddLine(tip, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)
	return b
end

function Planner:GetShopFrame()
	if self.shop then return self.shop end
	local ah = AuctionHouseFrame
	if not ah then return nil end
	local tab = self:SetupShopTab()
	local f
	if tab then
		-- the tab's content fills the Auction House, like the Buy / Sell / Auctions tabs
		f = CreateFrame("Frame", "CraftShuffleShopping", ah)
		f:SetPoint("TOPLEFT", ah, "TOPLEFT", 0, 0)
		f:SetPoint("BOTTOMRIGHT", ah, "BOTTOMRIGHT", 0, 0)
		ah.CraftShuffleShopping = f
	else
		-- no tab on this client: a standard window of the AH's size next to it
		local ok, w = pcall(CreateFrame, "Frame", "CraftShuffleShopping", ah, "BasicFrameTemplateWithInset")
		f = ok and w or CreateFrame("Frame", "CraftShuffleShopping", ah)
		f:SetSize(800, 540)
		f:SetPoint("TOPLEFT", ah, "TOPRIGHT", 4, 0)
		f:SetFrameStrata("HIGH")
		if f.TitleText then f.TitleText:SetText("CraftShuffle " .. DASH .. " Shopping") end
	end
	local x0 = tab and SHOP_TOOLBAR_X or 12

	-- 1. toolbar: plan + scan age on the left, Planner / Scans / Rescan on the right
	f.Plan = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.Plan:SetPoint("TOPLEFT", f, "TOPLEFT", x0, SHOP_TOOLBAR_Y - 4)
	f.Plan:SetJustifyH("LEFT")
	Try(f.Plan, "SetWordWrap", false)
	f.Rescan = ToolButton(f, "Rescan", 90, "Rescan", "Re-prices the rows from the current AH listings. Shift-click: full browse scan.")
	f.Rescan:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, SHOP_TOOLBAR_Y)
	f.Rescan:SetScript("OnClick", function() Planner:ScanAH() end)
	f.DEScan = ToolButton(f, "Scans", 90, "AH scans",
		"Disenchant: armor and weapons worth more as enchanting materials than their buyout. Vendor: items listed below what a vendor pays (/cs scan, /cs scan vendor).")
	f.DEScan:SetPoint("RIGHT", f.Rescan, "LEFT", -4, 0)
	f.DEScan:SetScript("OnClick", function() CS.DEScan:Toggle() end)
	f.OpenPlanner = ToolButton(f, "Planner", 90, "Shuffle Planner", "Pick the recipe and quantity, then craft, disenchant and track the session (/cs plan).")
	f.OpenPlanner:SetPoint("RIGHT", f.DEScan, "LEFT", -4, 0)
	f.OpenPlanner:SetScript("OnClick", function() Planner:Open(Planner.recipeID) end)
	f.Plan:SetPoint("RIGHT", f.OpenPlanner, "LEFT", -10, 0)

	-- 2. summary: materials progress
	f.OverallLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	f.OverallLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 14, SHOP_SUMMARY_Y)
	f.OverallLabel:SetText("Materials")
	f.Overall = CreateBar(f, 10)
	f.Overall:SetPoint("LEFT", f.OverallLabel, "RIGHT", 8, 0)
	f.Overall:SetWidth(220)
	f.OverallText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.OverallText:SetPoint("LEFT", f.Overall, "RIGHT", 8, 0)
	f.OverallText:SetJustifyH("LEFT")
	f.Status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.Status:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, SHOP_SUMMARY_Y)
	f.Status:SetJustifyH("RIGHT")

	-- 3. the list: AH column headers on the window background, the inset with the Buy tab's art under them
	local area = CreateFrame("Frame", nil, f)
	area:SetPoint("TOPLEFT", f, "TOPLEFT", 8, SHOP_INSET_TOP)
	area:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, SHOP_INSET_BOTTOM)
	f.ListArea = area
	local ok, box = pcall(CreateFrame, "Frame", nil, area, "InsetFrameTemplate")
	if ok and box then
		box:SetPoint("TOPLEFT", area, "TOPLEFT", 0, -SHOP_HEADER_H)
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

	-- column layout: the item column takes what the fixed ones leave
	local rowW = 800 - 16 - 8 -- AuctionHouseFrame is 800 wide; list area insets 8 + rows 4 on each side
	local fixed = 0
	for _, c in ipairs(SHOP_COLS) do fixed = fixed + c[3] end
	local layout = { x = {}, w = {}, index = {} }
	local cx = 0
	for i, c in ipairs(SHOP_COLS) do
		local w = c[3] > 0 and c[3] or (rowW - fixed)
		layout.x[i], layout.w[i], layout.index[c[1]] = cx, w, i
		cx = cx + w
	end
	f.Headers = {}
	for i, c in ipairs(SHOP_COLS) do
		local okH, h = pcall(CreateFrame, "Button", nil, area, "AuctionHouseTableHeaderStringTemplate")
		if not okH or not h then
			h = CreateFrame("Button", nil, area)
			local fs = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			fs:SetPoint("LEFT", h, "LEFT", 8, 0)
			h.Text = fs
		end
		if h.SetText then h:SetText(c[2]) end
		if h.Text and h.Text.SetText then h.Text:SetText(c[2]) end
		if h.Arrow then h.Arrow:Hide() end
		h:SetScript("OnClick", nil) -- the template's click sorts an AH table; ours has a fixed order
		local overlap = i > 1 and SHOP_HEADER_OVERLAP or 0
		h:SetPoint("TOPLEFT", area, "TOPLEFT", 4 + layout.x[i] - overlap, -1)
		h:SetSize(layout.w[i] + overlap, SHOP_HEADER_H)
		f.Headers[i] = h
	end

	f.Rows = {}
	for i = 1, SHOP_ROWS do f.Rows[i] = CreateShopRow(area, i, layout) end
	f.Empty = area:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	f.Empty:SetPoint("TOPLEFT", area, "TOPLEFT", 14, -SHOP_HEADER_H - 10)
	f.Empty:SetJustifyH("LEFT")
	f.More = area:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.More:SetPoint("BOTTOMLEFT", area, "BOTTOMLEFT", 10, 6)
	f.More:SetJustifyH("LEFT")

	-- 4. footer: what is left to buy, and Buy Next
	f.BuyNext = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.BuyNext:SetSize(260, 22)
	f.BuyNext:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, SHOP_FOOT_Y)
	f.BuyNext:SetScript("OnClick", function(self)
		if self.csItemID and (self.csBuy or 0) > 0 then Planner:BuyItem(self.csItemID, self.csBuy) end
	end)
	f.BuyNext:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Buy Next")
		GameTooltip:AddLine("Opens the auction page of the next material with the quantity filled in. The list updates as you buy and craft, and the AH comes back here after each purchase.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	f.BuyNext:SetScript("OnLeave", GameTooltip_Hide)
	f.Total = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.Total:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, SHOP_FOOT_Y + 5)
	f.Total:SetPoint("RIGHT", f.BuyNext, "LEFT", -10, 0)
	f.Total:SetJustifyH("LEFT")
	Try(f.Total, "SetWordWrap", false)
	f:Hide()
	self.shop = f
	return f
end

-- Bring the shopping list up: our AH tab when there is one, the side panel otherwise.
function Planner:ShowShop()
	local f = self:GetShopFrame()
	if not f or not self.model then return false end
	if self.shopTab then
		local ok = pcall(AuctionHouseFrame.SetDisplayMode, AuctionHouseFrame, self.SHOP_MODE)
		if not ok then f:Show() end
	else
		f:Show()
	end
	self:UpdateShop()
	return true
end

-- After buying something for the plan, go back to the list for the next item.
function Planner:ReturnToShop()
	if not (self.shopTab and self.shopUsed and AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return end
	local function back()
		if AuctionHouseFrame and AuctionHouseFrame:IsShown() then
			pcall(AuctionHouseFrame.SetDisplayMode, AuctionHouseFrame, Planner.SHOP_MODE)
		end
	end
	if C_Timer and C_Timer.After then C_Timer.After(0.3, back) else back() end
end

-- The first unfinished AH-sourced material: what "Buy Next" and the active row point at.
local function NextToBuy(list)
	for _, e in ipairs(list) do
		if e.buy > 0 and e.kind ~= "vendor" then return e end
	end
	return nil
end

function Planner:UpdateShop()
	local f = self.shop
	if not f or not f:IsShown() then return end
	local m = self:ShopModel()
	local list = m and self:ShoppingNow(m) or {}
	local nextE = NextToBuy(list)
	local GRAY, GREEN, RED = GRAY_FONT_COLOR, GREEN_FONT_COLOR, RED_FONT_COLOR

	-- toolbar + scan age
	if m then
		local Scanner = CS.CP.Scanner
		local last = Scanner and Scanner:GetLastScan() or 0
		local oldest
		for _, e in ipairs(list) do
			if e.info and e.info.source == "ladder" and e.info.age and (not oldest or e.info.age > oldest) then oldest = e.info.age end
		end
		f.Plan:SetText(string.format("Plan: %dx %s", m.qty, m.name))
		f.Status:SetText(oldest and ("AH depth checked " .. CS:Age(oldest)) or (last > 0 and ("AH scanned " .. CS:Age(time() - last)) or "No AH scan yet"))
	else
		f.Plan:SetText("No shuffle running")
		f.Status:SetText("")
	end

	-- overall progress over everything the plan buys (bought-but-in-the-mail counts as acquired)
	local haveAll, needAll, mailAll = 0, 0, 0
	for _, e in ipairs(list) do
		haveAll = haveAll + math.min(e.have + e.transit, e.need)
		mailAll = mailAll + e.transit
		needAll = needAll + e.need
	end
	f.OverallText:SetText(string.format("%d / %d", haveAll, needAll) .. (mailAll > 0 and Wrap(GRAY, string.format(" (%d in mail)", mailAll)) or ""))
	SetBar(f.Overall, haveAll, needAll)

	-- rows
	local total, unknown, leftToBuy = 0, 0, 0
	local shown = 0
	for i, row in ipairs(f.Rows) do
		local e = list[i]
		row.csItemID, row.csBuy, row.csEntry, row.csKind = e and e.itemID or nil, e and e.buy or 0, e, e and e.kind or nil
		if e then
			shown = shown + 1
			local name = CS:ItemName(e.itemID)
			local vendor = e.kind == "vendor"
			local done = e.buy <= 0
			row.Icon:SetTexture(ItemIcon(e.itemID))
			row.Source:SetText(vendor and Wrap(GRAY, "Vendor") or "Auction House")
			local unit = e.avg or (e.info and e.info.minPrice)
			row.Unit:SetText(unit and MoneyText(unit) or "")
			row.Have:SetText(string.format("%d / %d", e.have, e.need) .. (e.transit > 0 and Wrap(GRAY, string.format("  %d in mail", e.transit)) or ""))
			if done and e.transit > 0 and e.have < e.need then
				-- bought, waiting in the mailbox
				row.csState = "pending"
				row.Name:SetText(QualityName(e.itemID, name))
				row.Value:SetText(Wrap(GRAY, "bought"))
				row.Done:Hide()
				row.Buy:Show()
				row.Buy:SetText("In mail")
				row.Buy:Disable()
			elseif done then
				row.csState = "done"
				row.Name:SetText(Wrap(GRAY, name))
				row.Value:SetText(Wrap(GREEN, "complete"))
				row.Buy:Hide()
				row.Done:Show()
			else
				leftToBuy = leftToBuy + 1
				row.Name:SetText(QualityName(e.itemID, name))
				row.Done:Hide()
				row.Buy:Show()
				if e.total then
					total = total + e.total
					if e.kind == "ladder" or vendor then
						row.Value:SetText(MoneyText(e.total))
					else
						unknown = unknown + 1
						row.Value:SetText(MoneyText(e.total) .. Wrap(GRAY, " ?"))
					end
					if e.info and (e.info.short or 0) > 0 and e.info.full then
						row.Value:SetText(Wrap(RED, CS:Money(e.total)))
						row.Have:SetText(Wrap(RED, string.format("%d / %d, only %d listed", e.have, e.need, e.info.covered or 0)))
					end
				else
					row.Value:SetText(Wrap(GRAY, "no price"))
				end
				if vendor then
					row.csState = "pending"
					row.Buy:SetText("At vendor")
					row.Buy:Disable()
				else
					row.csState = (e == nextE) and "active" or "pending"
					row.Buy:SetText(string.format("Buy %d", e.buy))
					row.Buy:Enable()
				end
			end
			StyleRow(row, row.csState)
			row:Show()
		else
			row.csState = nil
			row:Hide()
		end
	end
	local extra = #list - shown
	f.More:SetText(extra > 0 and string.format("+%d more materials in the planner", extra) or "")
	f.Empty:SetText(m and (shown == 0 and "This plan buys nothing." or "")
		or "Pick a recipe in the planner and press Start Shuffle: its shopping list appears here.")

	-- footer
	if not m then
		f.Total:SetText(Wrap(GRAY, "No shuffle running. Start one in the planner (/cs plan)."))
	elseif leftToBuy == 0 and mailAll > 0 then
		f.Total:SetText(Wrap(GREEN, "Everything is bought") .. Wrap(GRAY, string.format(" \194\183 %d item%s waiting in your mailbox.", mailAll, mailAll == 1 and "" or "s")))
	elseif leftToBuy == 0 then
		f.Total:SetText(Wrap(GREEN, "Everything for this plan is in your bags."))
	else
		f.Total:SetText("Left to buy: " .. MoneyText(total) .. (unknown > 0 and Wrap(GRAY, " (depth unknown for " .. unknown .. ")") or "")
			.. (mailAll > 0 and Wrap(GRAY, string.format(" \194\183 %d in mail", mailAll)) or ""))
	end
	if nextE then
		f.BuyNext.csItemID, f.BuyNext.csBuy = nextE.itemID, nextE.buy
		f.BuyNext:SetText(string.format("Buy Next: %dx %s", nextE.buy, CS:ItemName(nextE.itemID)))
		f.BuyNext:Enable()
		f.BuyNext:Show()
	else
		f.BuyNext.csItemID, f.BuyNext.csBuy = nil, 0
		f.BuyNext:SetText(m and "Nothing left to buy" or "Start a shuffle first")
		f.BuyNext:Disable()
	end
end

-- When the buy page's results arrive (or more are fetched), apply our quantity again: Blizzard's price list
-- re-announces its own quantity on each refresh. A finished purchase ends it.
CS:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED", function(_, itemID)
	local p = Planner.pendingBuy
	if p and p.itemID == itemID then ApplyPendingQuantity() end
end)
for _, ev in ipairs({ "COMMODITY_SEARCH_RESULTS_RECEIVED", "COMMODITY_SEARCH_RESULTS_ADDED" }) do
	CS:RegisterEvent(ev, function(_, itemID)
		local p = Planner.pendingBuy
		if p and (not itemID or p.itemID == itemID) then ApplyPendingQuantity() end
	end)
end
CS:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED", function() Planner.pendingBuy = nil end)

---------------------------------------------------------------------------
-- Live session
---------------------------------------------------------------------------

function Planner:ToggleSession()
	if self.session then
		self:StopSession()
	else
		self:StartSession()
		-- Start Shuffle: the session is what matters now, so the planner shows it
		if self.session then self:SetView("session") end
	end
end

function Planner:StartSession()
	local m = self.model
	if not m then return end
	local inter, planItems = {}, {}
	for _, c in ipairs(m.crafts) do
		inter[c.recipeID] = { count = 0, need = c.count, name = CS:ItemName(c.itemID) }
		planItems[c.itemID] = true
	end
	for _, e in ipairs(m.shopping) do planItems[e.itemID] = true end
	-- what the plan expected, frozen at start so the session view compares against it
	local plan = { yields = {}, crafts = {}, time = m.time and m.time.total or nil }
	local casts = (m.eco.quantity or 1)
	for _, y in ipairs(m.eco.yields or {}) do
		table.insert(plan.yields, { itemID = y.itemID, perDE = y.expected * casts, unit = y.unit })
	end
	for _, c in ipairs(m.crafts) do table.insert(plan.crafts, { recipeID = c.recipeID, name = CS:ItemName(c.itemID), count = c.count }) end
	-- what each bought material was planned to cost for the whole batch: the session swaps in what was
	-- really paid as purchases come in (SessionStats), so the cost basis is real money, not a stale estimate
	plan.leaves = {}
	for _, e in ipairs(m.shopping) do
		plan.leaves[e.itemID] = { qty = e.qty, total = e.realTotal }
	end
	plan.casts = m.craft.outputQty
	-- what the plan still had to buy at the start: purchases above it are the player's own stock
	plan.toBuy = {}
	for _, e in ipairs(m.shopping) do plan.toBuy[e.itemID] = e.buyNow or 0 end
	self.session = {
		recipeID = m.recipeID, name = m.name, outputItemID = m.outputItemID, qty = m.qty,
		started = time(), crafted = 0, disenchanted = 0, mats = {}, matValue = 0, intermediates = inter,
		planItems = planItems, spent = 0, bought = {}, boughtCost = {}, plan = plan,
		expectedNet = m.net, expectedMatValue = m.matValue, expectedCost = m.totalCost, costPerCraft = m.eco.cost,
	}
	CS.db.planner.session = self.session -- same table: every update is saved, survives /reload and relog
	self.barHidden = nil
	CS:Print("shuffle session started: %dx %s. Craft and disenchant; the planner keeps score (Session View, /cs session).", m.qty, m.name)
	self:UpdateMacro(true)
	self:Refresh()
	CS:Fire("SESSION_CHANGED", self.session)
end

-- A session that was running at the last logout / reload carries on.
function Planner:RestoreSession()
	local s = CS.db and CS.db.planner and CS.db.planner.session
	if not s or s.ended then
		if CS.db and CS.db.planner then CS.db.planner.session = nil end
		return false
	end
	s.planItems = s.planItems or {}
	s.bought = s.bought or {}
	s.boughtCost = s.boughtCost or {}
	s.mats = s.mats or {}
	s.intermediates = s.intermediates or {}
	self.session = s
	self.recipeID = self.recipeID or s.recipeID
	CS:Print("shuffle session resumed: %dx %s (crafted %d, disenchanted %d). Stop Shuffle ends it; /cs session opens it.",
		s.qty or 0, s.name or "?", s.crafted or 0, s.disenchanted or 0)
	self:UpdateSessionBar()
	CS:Fire("SESSION_CHANGED", s)
	return true
end

CS:On("READY", function() Planner:RestoreSession() end)

---------------------------------------------------------------------------
-- Disenchant macro: one macro, placed on a bar once, retargeted to the current plan's item
---------------------------------------------------------------------------

-- Gear bought to disenchant: purchases of items opened from the AH Scans window's Disenchant view
-- (DEScan marks them), db.deBuys[itemID] = { n = units, t = last purchase }. Each disenchant of the item
-- uses one up. Kept DEBUY_TTL at most, DEBUY_MAX items (the saved data is parsed at every login).
local DEBUY_TTL, DEBUY_MAX = 7 * 86400, 200

local function DEBuys()
	local db = CS.db
	if not db then return {} end
	db.deBuys = db.deBuys or {}
	local now, count = time(), 0
	for itemID, e in pairs(db.deBuys) do
		if type(e) ~= "table" or (e.n or 0) <= 0 or now - (e.t or 0) > DEBUY_TTL then
			db.deBuys[itemID] = nil
		else
			count = count + 1
		end
	end
	if count > DEBUY_MAX then
		local list = {}
		for itemID, e in pairs(db.deBuys) do list[#list + 1] = { itemID, e.t or 0 } end
		table.sort(list, function(a, b) return a[2] < b[2] end)
		for i = 1, count - DEBUY_MAX do db.deBuys[list[i][1]] = nil end
	end
	return db.deBuys
end

function Planner:AddDEBuy(itemID, qty)
	if not (itemID and qty and qty > 0) then return end
	local buys = DEBuys()
	local e = buys[itemID] or { n = 0 }
	e.n, e.t = e.n + qty, time()
	buys[itemID] = e
	self:RetargetMacroSoon()
end

CS:On("DE_RECORDED", function(itemID, mats)
	if not (itemID and mats) then return end
	local buys = DEBuys()
	local e = buys[itemID]
	if e then
		e.n = e.n - 1
		if e.n <= 0 then buys[itemID] = nil end
	end
end)

-- Item IDs saved in the player's equipment sets: never disenchanted.
local function EquipmentSetItems()
	local ids = {}
	local ES = C_EquipmentSet
	if not (ES and ES.GetEquipmentSetIDs and ES.GetItemIDs) then return ids end
	local ok, setIDs = pcall(ES.GetEquipmentSetIDs)
	for _, setID in ipairs(ok and type(setIDs) == "table" and setIDs or {}) do
		local ok2, items = pcall(ES.GetItemIDs, setID)
		for _, id in pairs(ok2 and type(items) == "table" and items or {}) do
			if type(id) == "number" and id > 0 then ids[id] = true end
		end
	end
	return ids
end

-- The macro's queue, one entry per bag slot, in the order the macro works through them:
--   1. the shuffle item (crafted for this; allowed even when bound while its shuffle runs),
--   2. gear bought to disenchant from the AH Scans window (as many as were bought),
--   3. with "DE macro works through the bags" on: any other disenchantable green (blue / purple too when
--      allowed) in the bags.
-- Every slot is checked on its own: soulbound items and items in an equipment set are never queued, and
-- equipped gear cannot be reached (the macro targets a bag slot). Entry: { itemID, bag, slot, name, quality, source }.
function Planner:DEQueue()
	local list = {}
	local planned = (self.session and self.session.outputItemID) or (self.model and self.model.outputItemID)
	if not (C_Container and C_Container.GetContainerNumSlots) then return list, planned end
	local includeRares = CS.settings.macroRares == true
	local bagsMode = CS.settings.macroBags == true
	local boughtOn = CS.settings.macroBought ~= false
	local buys = boughtOn and DEBuys() or {}
	local inSets = EquipmentSetItems()
	local sessionItem = self.session and self.session.outputItemID
	local left = {}
	for itemID, e in pairs(buys) do left[itemID] = e.n end
	local shuffle, bought, other = {}, {}, {}
	for bag = 0, (NUM_BAG_SLOTS or 4) do
		local ok, slots = pcall(C_Container.GetContainerNumSlots, bag)
		for slot = 1, (ok and slots) or 0 do
			local itemID, link, bound
			if C_Container.GetContainerItemInfo then
				local ok2, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
				if ok2 and type(info) == "table" then itemID, link, bound = info.itemID, info.hyperlink, info.isBound end
			end
			if not itemID and C_Container.GetContainerItemID then
				local ok3, id = pcall(C_Container.GetContainerItemID, bag, slot)
				if ok3 then itemID = id end
			end
			local meta = itemID and not inSets[itemID] and CS.DEData:GetItemMeta(itemID)
			if meta and CS.DEData:IsDisenchantable(meta) then
				if not link and C_Container.GetContainerItemLink then
					local ok4, l = pcall(C_Container.GetContainerItemLink, bag, slot)
					if ok4 then link = l end
				end
				local e = { itemID = itemID, bag = bag, slot = slot, quality = meta.quality,
					name = (type(link) == "string" and link:match("%[(.-)%]")) or meta.name or CS:ItemName(itemID) }
				if itemID == planned and (bound ~= true or itemID == sessionItem) then
					e.source = "shuffle"
					table.insert(shuffle, e)
				elseif bound ~= true and (left[itemID] or 0) > 0 then
					left[itemID] = left[itemID] - 1
					e.source = "bought"
					table.insert(bought, e)
				elseif bound ~= true and bagsMode and (includeRares or (meta.quality or 0) == 2) then
					e.source = "bags"
					table.insert(other, e)
				end
			end
		end
	end
	for _, part in ipairs({ bought, other }) do
		for _, e in ipairs(part) do table.insert(shuffle, e) end
	end
	return shuffle, planned
end

-- The queue grouped by item for display: { { itemID, name, count, source } }.
local function GroupQueue(queue)
	local groups, byKey = {}, {}
	for _, e in ipairs(queue) do
		local key = e.itemID .. ":" .. e.source
		local g = byKey[key]
		if not g then
			g = { itemID = e.itemID, name = e.name, count = 0, source = e.source }
			byKey[key] = g
			table.insert(groups, g)
		end
		g.count = g.count + 1
	end
	return groups
end
Planner.GroupQueue = GroupQueue

-- Next slot the macro should disenchant. Returns entry (or nil), planned itemID, queue.
function Planner:MacroTarget()
	local queue, planned = self:DEQueue()
	return queue[1], planned, queue
end

-- The macro targets a bag slot (/use <bag> <slot>), never an item name: a name also matches equipped and
-- soulbound copies. [nocombat] keeps it inert in combat, when the bags can change but the macro cannot be
-- edited. With nothing to disenchant it only shows the shuffle item and prints the queue.
function Planner:MacroBody()
	local e, planned = self:MacroTarget()
	if e then
		return string.format("#showtooltip item:%d\n/cast [nocombat] Disenchant\n/use [nocombat] %d %d", e.itemID, e.bag, e.slot)
	end
	if planned then
		return string.format("#showtooltip item:%d\n/cs macro list", planned)
	end
	return nil
end

function Planner:PrintDEQueue()
	local queue, planned = self:DEQueue()
	if #queue == 0 then
		CS:Print("nothing to disenchant in the bags%s.", planned and (" (the macro waits for " .. CS:ItemName(planned) .. ")") or "")
		return
	end
	local labels = { shuffle = "shuffle", bought = "bought to disenchant", bags = "from the bags" }
	local parts = {}
	for i, g in ipairs(GroupQueue(queue)) do
		if i <= 12 then table.insert(parts, string.format("%dx %s (%s)", g.count, g.name, labels[g.source] or g.source)) end
	end
	CS:Print("macro queue, %d item%s: %s", #queue, #queue == 1 and "" or "s", table.concat(parts, ", "))
end

-- Returns true when the macro exists and matches the current plan.
function Planner:UpdateMacro(silent)
	local body = self:MacroBody()
	if not body then
		if not silent then CS:Print("nothing to disenchant: no shuffle item or bought gear in the bags, and no recipe picked in the planner.") end
		return false
	end
	if MacroFrame and MacroFrame:IsShown() then
		if not silent then CS:Print("close the macro window first.") end
		self.macroDirty = true
		return false
	end
	if not (CreateMacro and EditMacro and GetMacroIndexByName) then
		if not silent then CS:Print("this client has no macro API.") end
		return false
	end
	if InCombatLockdown and InCombatLockdown() then
		if not silent then CS:Print("cannot change macros in combat.") end
		self.macroDirty = true
		return false
	end
	self.macroDirty = nil
	local ok, idx = pcall(GetMacroIndexByName, MACRO_NAME)
	idx = ok and idx or 0
	local created = false
	if idx and idx > 0 then
		if silent and self.macroBody == body then return true end
		local okE, err = pcall(EditMacro, idx, MACRO_NAME, MACRO_ICON, body)
		if not okE then
			CS:Print("could not update the %s macro: %s", MACRO_NAME, tostring(err))
			return false
		end
	else
		local okC, newIdx = pcall(CreateMacro, MACRO_NAME, MACRO_ICON, body, false)
		if not okC or not newIdx then
			-- general macro slots full: try a character macro
			okC, newIdx = pcall(CreateMacro, MACRO_NAME, MACRO_ICON, body, true)
		end
		if not okC or not newIdx then
			CS:Print("could not create the %s macro (macro slots full?).", MACRO_NAME)
			return false
		end
		created = true
	end
	self.macroBody = body
	if silent then return true end
	local e, planned, queue = self:MacroTarget()
	local what = e and string.format("%s (bag %d, slot %d)", e.name, e.bag, e.slot)
		or string.format("nothing yet (waiting for %s)", CS:ItemName(planned))
	local more = #queue > 1 and string.format(", then %d more", #queue - 1) or ""
	if created then
		CS:Print("macro '%s' created: it disenchants %s%s. Open /macro once and drag it to a bar; the button shows the next item and retargets itself after every cast.", MACRO_NAME, what, more)
	else
		CS:Print("macro '%s' now disenchants %s%s.", MACRO_NAME, what, more)
	end
	return true
end

-- Keep the macro pointed at the next item as the bags change. Only touches a macro that already exists,
-- never in combat (retried when combat ends), and only when the body would actually change.
local retargetPending = false
function Planner:RetargetMacroSoon()
	if retargetPending then return end
	if not (GetMacroIndexByName and EditMacro) then return end
	retargetPending = true
	local function go()
		retargetPending = false
		local ok, idx = pcall(GetMacroIndexByName, MACRO_NAME)
		if not ok or not idx or idx == 0 then return end
		Planner:UpdateMacro(true)
	end
	-- next frame: the macro points at a bag slot, so it must follow bag changes at once
	if C_Timer and C_Timer.After then C_Timer.After(0, go) else go() end
end
CS:On("DE_RECORDED", function() Planner:RetargetMacroSoon() end)
CS:On("SETTINGS_CHANGED", function(key)
	if key == "macroBags" or key == "macroRares" or key == "macroBought" then Planner:RetargetMacroSoon() end
end)
CS:RegisterEvent("PLAYER_REGEN_ENABLED", function() if Planner.macroDirty then Planner:RetargetMacroSoon() end end)

function Planner:StopSession()
	local s = self.session
	if not s then return end
	s.ended = time()
	local st = self:SessionStats(s)
	s.matValue = st.matValue
	s.net = st.netSoFar
	s.planItems = nil -- not needed once finished
	table.insert(CS.db.sessions, s)
	while #CS.db.sessions > 20 do table.remove(CS.db.sessions, 1) end
	self.session = nil
	CS.db.planner.session = nil
	CS:Fire("SESSION_CHANGED", nil)
	CS:Print("session done: crafted %d, disenchanted %d, materials worth %s (plan expected %s for %d); spent %s on reagents (plan %s); net so far %s. Details: Session View.",
		s.crafted, s.disenchanted, CS:Money(s.matValue), CS:Money(s.expectedMatValue or 0), s.qty,
		CS:Money(s.spent or 0), CS:Money(s.expectedCost or 0), CS:Money(s.net, { sign = true }))
	self:Refresh()
end

CS:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, unit, _, spellID)
	local s = Planner.session
	if not s or unit ~= "player" then return end
	if spellID == s.recipeID then
		s.crafted = s.crafted + 1
	elseif s.intermediates and s.intermediates[spellID] then
		s.intermediates[spellID].count = s.intermediates[spellID].count + 1
	else
		return
	end
	Planner:Refresh()
end)

CS:On("DE_RECORDED", function(itemID, mats)
	local s = Planner.session
	if not s or not mats or itemID ~= s.outputItemID then return end
	s.disenchanted = s.disenchanted + 1
	for matID, qty in pairs(mats) do
		s.mats[matID] = (s.mats[matID] or 0) + qty
		local unit = CS.CP:GetSalePrice(matID)
		if unit then s.matValue = s.matValue + unit * qty end
	end
	Planner:Refresh()
end)

local function RefreshIfShown()
	if Planner.frame and Planner.frame:IsShown() then Planner:Refresh() end
end

if CS.CP then
	CS.CP:On("PURCHASE_RECORDED", function(itemID, qty, total)
		Planner:AddTransit(itemID, qty)
		Planner:RecordSessionPurchase(itemID, qty, total)
		RefreshIfShown()
		Planner:UpdateShop()
		Planner:ReturnToShop()
	end)
	CS.CP:On("LADDER_UPDATED", RefreshIfShown)
	CS.CP:On("ITEM_SCAN_FINISHED", function()
		if Planner.scanJob then Planner:FinishScanJob(false) else RefreshIfShown() end
	end)
	CS.CP:On("SCAN_STARTED", function() Planner:UpdateScanStatus() end)
end
CS:RegisterEvent("AUCTION_HOUSE_SHOW", function()
	RefreshIfShown()
	-- during a shuffle the shopping panel is the reason to be at the AH
	if Planner.session and Planner.model then Planner:ShowShop() end
end)
CS:RegisterEvent("AUCTION_HOUSE_CLOSED", function()
	Planner.shopUsed = nil
	if Planner.scanJob then Planner:FinishScanJob(true) end
	RefreshIfShown()
end)
CS:RegisterEvent("BAG_UPDATE_DELAYED", function()
	Planner:RetargetMacroSoon()
	Planner:ReconcileTransit()
	RefreshIfShown()
	Planner:UpdateShop()
end)
-- keep the shopping panel in step with the planner model
local origRefresh = Planner.Refresh
function Planner:Refresh(...)
	origRefresh(self, ...)
	self:UpdateShop()
end
CS:On("RECIPES_UPDATED", RefreshIfShown)
CS:On("SETTINGS_CHANGED", RefreshIfShown)
CS:On("ITEM_LOADED", RefreshIfShown)
if CS.CP then
	CS.CP:On("PRICES_UPDATED", RefreshIfShown)
	CS.CP:On("SETTINGS_CHANGED", RefreshIfShown)
	CS.CP:On("SCAN_FINISHED", RefreshIfShown)
end
-- The Craft button depends on ProfessionsFrame being shown and the recipe data loaded. TRADE_SKILL_SHOW
-- fires before the frame is shown and before the recipe list arrives, so refresh again on the next frame,
-- on the list / data-source events and on the frame's own OnShow / OnHide.
local function RefreshSoon()
	RefreshIfShown()
	if C_Timer and C_Timer.After then
		C_Timer.After(0, RefreshIfShown)
		C_Timer.After(0.5, RefreshIfShown)
	end
end
local function HookProfessionsFrame()
	local pf = ProfessionsFrame
	if not pf or pf.csPlannerHooked or not pf.HookScript then return end
	pf.csPlannerHooked = true
	pf:HookScript("OnShow", RefreshSoon)
	pf:HookScript("OnHide", RefreshSoon)
end
CS:RegisterEvent("TRADE_SKILL_SHOW", function() HookProfessionsFrame() RefreshSoon() end)
CS:RegisterEvent("TRADE_SKILL_CLOSE", RefreshSoon)
-- the list updates often while crafting: only refresh when it unlocks a disabled Craft button
CS:RegisterEvent("TRADE_SKILL_LIST_UPDATE", function()
	local f = Planner.frame
	local nc = f and f:IsShown() and f.CraftButton.csNext
	if nc and not nc.allDone and not f.CraftButton:IsEnabled() and Planner:CanCraft(nc.recipeID) then Planner:Refresh() end
end)
CS:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED", RefreshSoon)
CS:RegisterEvent("ADDON_LOADED", function(_, name) if name == "Blizzard_Professions" then HookProfessionsFrame() end end)
HookProfessionsFrame()

---------------------------------------------------------------------------
-- Vendor panel: at a merchant that sells something the plan still needs, a small window docked to the
-- merchant frame lists it with the exact quantity and buys it (BuyMerchantItem, the merchant frame's own
-- call: quantity in items, a multiple of the bundle size, at most GetMerchantItemMaxStack per call).
-- Shown while a shuffle runs.
---------------------------------------------------------------------------

local VENDOR_ROWS, VENDOR_ROW_H = 6, 24

local function MerchantItemID(index)
	if GetMerchantItemID then
		local ok, id = pcall(GetMerchantItemID, index)
		if ok and id then return id end
	end
	if GetMerchantItemLink then
		local ok, link = pcall(GetMerchantItemLink, index)
		if ok then return CS:ItemIDFromLink(link) end
	end
	return nil
end

local function MerchantItemInfo(index)
	if not (C_MerchantFrame and C_MerchantFrame.GetItemInfo) then return nil end
	local ok, info = pcall(C_MerchantFrame.GetItemInfo, index)
	return ok and type(info) == "table" and info or nil
end

local function MaxStack(index, fallback)
	if GetMerchantItemMaxStack then
		local ok, n = pcall(GetMerchantItemMaxStack, index)
		if ok and type(n) == "number" and n > 0 then return n end
	end
	return fallback
end

-- itemID -> { index, unit (copper per item), stack, available (items, nil = unlimited), maxStack }
local function MerchantOffers()
	local offers = {}
	if not GetMerchantNumItems then return offers end
	local ok, n = pcall(GetMerchantNumItems)
	for i = 1, (ok and n) or 0 do
		local id = MerchantItemID(i)
		local info = id and MerchantItemInfo(i)
		if info and not info.hasExtendedCost and info.isPurchasable ~= false and (info.price or 0) > 0 then
			local stack = math.max(1, info.stackCount or 1)
			offers[id] = {
				index = i, unit = info.price / stack, stack = stack,
				available = (info.numAvailable and info.numAvailable >= 0) and info.numAvailable * stack or nil,
				maxStack = MaxStack(i, stack),
			}
		end
	end
	return offers
end

-- What to buy here: plan materials still missing that this merchant sells.
function Planner:VendorList()
	local m = self:ShopModel()
	if not m then return {} end
	local list = {}
	local offers = MerchantOffers()
	for _, e in ipairs(self:ShoppingNow(m)) do
		local o = offers[e.itemID]
		if o and e.buy > 0 then
			local qty = math.ceil(e.buy / o.stack) * o.stack
			if o.available then qty = math.min(qty, o.available) end
			if qty > 0 then
				table.insert(list, { itemID = e.itemID, need = e.buy, qty = qty, cost = o.unit * qty,
					ahTotal = e.kind ~= "vendor" and e.total or nil })
			end
		end
	end
	return list
end

-- Buys `qty` of an item from the open merchant; returns what was bought and its cost.
function Planner:BuyFromMerchant(itemID, qty)
	local o = MerchantOffers()[itemID]
	if not (o and BuyMerchantItem) then return 0, 0 end
	qty = math.ceil(qty / o.stack) * o.stack
	if o.available then qty = math.min(qty, o.available) end
	local money = GetMoney and GetMoney() or math.huge
	if o.unit * qty > money then
		qty = math.floor(money / o.unit / o.stack) * o.stack
		if qty <= 0 then
			CS:Print("not enough money for %s.", CS:ItemName(itemID))
			return 0, 0
		end
	end
	local chunk = math.max(o.stack, math.floor(o.maxStack / o.stack) * o.stack)
	local left, bought = qty, 0
	while left > 0 do
		local n = math.min(left, chunk)
		local ok, err = pcall(BuyMerchantItem, o.index, n)
		if not ok then
			CS:Print("buying %s failed: %s", CS:ItemName(itemID), tostring(err))
			break
		end
		bought, left = bought + n, left - n
	end
	local cost = o.unit * bought
	if bought > 0 then
		-- shown as bought in the vendor panel until the merchant closes
		self.vendorBought = self.vendorBought or {}
		local vb = self.vendorBought[itemID] or { qty = 0, cost = 0 }
		vb.qty, vb.cost = vb.qty + bought, vb.cost + cost
		self.vendorBought[itemID] = vb
		-- vendor purchases count toward the running shuffle's spend and batch cost like AH purchases
		self:RecordSessionPurchase(itemID, bought, cost)
		CS:Print("bought %dx %s for %s.", bought, CS:ItemName(itemID), CS:Money(cost))
	end
	return bought, cost
end

function Planner:BuyAllFromMerchant()
	for _, e in ipairs(self:VendorList()) do self:BuyFromMerchant(e.itemID, e.qty) end
end

local function CreateVendorPanel()
	local parent = MerchantFrame or UIParent
	local ok, f = pcall(CreateFrame, "Frame", "CraftShuffleVendor", parent, "BasicFrameTemplateWithInset")
	if not ok or not f then f = CreateFrame("Frame", "CraftShuffleVendor", parent) end
	f:SetSize(330, 74 + VENDOR_ROWS * VENDOR_ROW_H)
	if MerchantFrame then f:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", 4, 0) else f:SetPoint("CENTER") end
	local title = "Shuffle " .. DASH .. " buy here"
	if f.TitleText then f.TitleText:SetText(title) elseif f.SetTitle then pcall(f.SetTitle, f, title) end
	f.Rows = {}
	for i = 1, VENDOR_ROWS do
		local row = CreateFrame("Frame", nil, f)
		row:SetHeight(VENDOR_ROW_H)
		row:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -30 - (i - 1) * VENDOR_ROW_H)
		row:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -30 - (i - 1) * VENDOR_ROW_H)
		row.Icon = row:CreateTexture(nil, "ARTWORK")
		row.Icon:SetSize(18, 18)
		row.Icon:SetPoint("LEFT", row, "LEFT", 0, 0)
		Try(row.Icon, "SetTexCoord", 0.07, 0.93, 0.07, 0.93)
		row.Buy = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		row.Buy:SetSize(64, 20)
		row.Buy:SetPoint("RIGHT", row, "RIGHT", 0, 0)
		row.Buy:SetScript("OnClick", function(self)
			local r = self:GetParent()
			if r.csItemID then Planner:BuyFromMerchant(r.csItemID, r.csQty) end
		end)
		row.Cost = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.Cost:SetPoint("RIGHT", row.Buy, "LEFT", -6, 0)
		row.Cost:SetJustifyH("RIGHT")
		row.Name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.Name:SetPoint("LEFT", row.Icon, "RIGHT", 6, 0)
		row.Name:SetPoint("RIGHT", row.Cost, "LEFT", -6, 0)
		row.Name:SetJustifyH("LEFT")
		Try(row.Name, "SetWordWrap", false)
		row:EnableMouse(true)
		row:SetScript("OnEnter", function(self)
			if not self.csItemID then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if not Try(GameTooltip, "SetItemByID", self.csItemID) then GameTooltip:AddLine(CS:ItemName(self.csItemID)) end
			local e = self.csEntry
			if e then
				GameTooltip:AddLine(" ")
				GameTooltip:AddLine(string.format("The plan still needs %d; Buy gets %d for %s.", e.need, e.qty, CS:Money(e.cost)), 1, 1, 1, true)
				if e.ahTotal then
					GameTooltip:AddLine(string.format("The plan priced it on the AH at %s.", CS:Money(e.ahTotal)), 0.6, 0.6, 0.6, true)
				end
			end
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", GameTooltip_Hide)
		f.Rows[i] = row
	end
	f.Total = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.Total:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 14)
	f.BuyAll = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.BuyAll:SetSize(100, 22)
	f.BuyAll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
	f.BuyAll:SetText("Buy All")
	f.BuyAll:SetScript("OnClick", function() Planner:BuyAllFromMerchant() end)
	-- the footer text ends before the button
	f.Total:SetPoint("RIGHT", f.BuyAll, "LEFT", -8, 0)
	f.Total:SetJustifyH("LEFT")
	if f.Total.SetWordWrap then f.Total:SetWordWrap(false) end
	f:Hide()
	return f
end

-- MERCHANT_SHOW reaches us before Blizzard's own handler has shown MerchantFrame, so "open" is tracked
-- from the events (and the frame's OnShow / OnHide), not from MerchantFrame:IsShown() at that moment.
function Planner:UpdateVendorPanel()
	if not (self.merchantOpen or (MerchantFrame and MerchantFrame:IsShown())) then
		if self.vendor then self.vendor:Hide() end
		return
	end
	local list = self:VendorList()
	-- what was bought here this visit stays listed with a check, so the purchase is visible
	local listed = {}
	for _, e in ipairs(list) do listed[e.itemID] = true end
	for itemID, vb in pairs(self.vendorBought or {}) do
		if not listed[itemID] then table.insert(list, { itemID = itemID, qty = vb.qty, cost = vb.cost, done = true }) end
	end
	if #list == 0 then
		if self.vendor then self.vendor:Hide() end
		return
	end
	self.vendor = self.vendor or CreateVendorPanel()
	local f = self.vendor
	local total, left = 0, 0
	for i, row in ipairs(f.Rows) do
		local e = list[i]
		row.csItemID, row.csQty, row.csEntry = e and not e.done and e.itemID or nil, e and e.qty, e
		if e then
			row.Icon:SetTexture(ItemIcon(e.itemID))
			if e.done then
				row.Name:SetText(Wrap(GRAY_FONT_COLOR, string.format("%dx %s", e.qty, CS:ItemName(e.itemID))))
				row.Cost:SetText(Wrap(GREEN_FONT_COLOR, "bought"))
				row.Buy:Hide()
				row.Done = row.Done or row:CreateTexture(nil, "OVERLAY")
				row.Done:SetSize(16, 16)
				row.Done:SetPoint("RIGHT", row, "RIGHT", -24, 0)
				row.Done:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
				row.Done:Show()
			else
				total, left = total + e.cost, left + 1
				row.Name:SetText(string.format("%dx ", e.qty) .. QualityName(e.itemID, CS:ItemName(e.itemID)))
				row.Cost:SetText(MoneyText(e.cost))
				row.Buy:SetText("Buy")
				row.Buy:Show()
				if row.Done then row.Done:Hide() end
			end
			row:Show()
		else
			row:Hide()
		end
	end
	if left == 0 then
		f.Total:SetText(Wrap(GREEN_FONT_COLOR, "All done"))
		f.BuyAll:Disable()
	else
		f.Total:SetText("Total: " .. MoneyText(total))
		f.BuyAll:Enable()
	end
	f:SetHeight(74 + math.min(#list, VENDOR_ROWS) * VENDOR_ROW_H)
	f:Show()
end

local function VendorSoon()
	Planner:UpdateVendorPanel()
	-- the merchant's item list can arrive a moment after the window opens
	if C_Timer and C_Timer.After then
		C_Timer.After(0, function() Planner:UpdateVendorPanel() end)
		C_Timer.After(0.5, function() Planner:UpdateVendorPanel() end)
	end
end
CS:RegisterEvent("MERCHANT_SHOW", function() Planner.merchantOpen = true VendorSoon() end)
CS:RegisterEvent("MERCHANT_UPDATE", function() Planner:UpdateVendorPanel() end)
CS:RegisterEvent("MERCHANT_CLOSED", function()
	Planner.merchantOpen = nil
	Planner.vendorBought = nil
	if Planner.vendor then Planner.vendor:Hide() end
end)
if MerchantFrame and MerchantFrame.HookScript then
	MerchantFrame:HookScript("OnShow", function() Planner.merchantOpen = true VendorSoon() end)
	MerchantFrame:HookScript("OnHide", function()
		Planner.merchantOpen = nil
		Planner.vendorBought = nil
		if Planner.vendor then Planner.vendor:Hide() end
	end)
end
CS:RegisterEvent("BAG_UPDATE_DELAYED", function()
	if Planner.vendor and Planner.vendor:IsShown() then Planner:UpdateVendorPanel() end
end)

---------------------------------------------------------------------------
-- Mail the shuffle items to an alt (when the enchanter is another character). The planner's "Mail to..."
-- button sets the recipient (db.planner.mailTo, the name as typed in a whisper). At a mailbox, while a shuffle runs, a small
-- window docked to the mail frame offers to send the shuffle items in the bags: each click sends one mail of
-- up to ATTACHMENTS_MAX_SEND items (C_Container.PickupContainerItem + ClickSendMailItemButton + SendMail),
-- one click per mail so every send comes from a key press. Soulbound and locked items are skipped.
---------------------------------------------------------------------------

local MAIL_ROWS_H = 92

function Planner:GetMailTo()
	local to = CS.db and CS.db.planner and CS.db.planner.mailTo
	return (type(to) == "string" and to ~= "") and to or nil
end

function Planner:SetMailTo(name)
	name = type(name) == "string" and name:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ") or ""
	CS.db.planner.mailTo = name ~= "" and name or nil
	if name ~= "" then
		CS:Print("shuffle items can now be mailed to %s: open a mailbox during a shuffle.", name)
	else
		CS:Print("mail recipient cleared.")
	end
	self:Refresh()
	self:UpdateMailPanel()
end

-- Standard input popup for the recipient.
function Planner:AskMailTo()
	if not (StaticPopupDialogs and StaticPopup_Show) then
		CS:Print("type /cs mailto <character> to set the recipient.")
		return
	end
	StaticPopupDialogs.CRAFTSHUFFLE_MAILTO = StaticPopupDialogs.CRAFTSHUFFLE_MAILTO or {
		text = "Mail the shuffle items to which character?\n(leave empty to clear)",
		button1 = ACCEPT or "Accept",
		button2 = CANCEL or "Cancel",
		hasEditBox = true,
		maxLetters = 48,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		OnShow = function(self)
			local box = self.editBox or self.EditBox
			if box then box:SetText(Planner:GetMailTo() or "") box:HighlightText() end
		end,
		OnAccept = function(self)
			local box = self.editBox or self.EditBox
			Planner:SetMailTo(box and box:GetText() or "")
		end,
		EditBoxOnEnterPressed = function(self)
			Planner:SetMailTo(self:GetText())
			self:GetParent():Hide()
		end,
		EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	}
	StaticPopup_Show("CRAFTSHUFFLE_MAILTO")
end

local function MaxAttachments()
	return math.max(1, math.min(12, tonumber(ATTACHMENTS_MAX_SEND) or 12))
end

-- This character's full name. Forever characters have a first name and a surname: UnitName gives the
-- surname as its second value (all of a player's characters may share the first name).
local function PlayerFullName()
	if not UnitName then return nil end
	local name, surname = UnitName("player")
	if type(name) ~= "string" or name == "" then return nil end
	if type(surname) == "string" and surname ~= "" and name:sub(-#surname - 1) ~= " " .. surname then
		name = name .. " " .. surname
	end
	return name
end

-- True when the recipient is the character logged in now (full name, case-insensitive, realm suffix
-- ignored). A first name alone is never taken as a match: other characters can share it.
function Planner:IsMailToSelf(to)
	local me = PlayerFullName()
	if not (me and to) then return false end
	local base = to:match("^([^%-]+)") or to
	local function clean(x) return (x:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "):lower()) end
	return clean(base) == clean(me)
end

local function AttachedCount()
	if not GetSendMailItem then return 0 end
	local n = 0
	for i = 1, MaxAttachments() do
		local ok, name = pcall(GetSendMailItem, i)
		if ok and name then n = n + 1 end
	end
	return n
end

-- Bag slots holding the running shuffle's item that can be mailed (not soulbound, not locked).
function Planner:MailSlots()
	local s = self.session
	local list, bound = {}, 0
	if not (s and s.outputItemID and C_Container and C_Container.GetContainerNumSlots) then return list, bound end
	for bag = 0, (NUM_BAG_SLOTS or 4) do
		local ok, slots = pcall(C_Container.GetContainerNumSlots, bag)
		for slot = 1, (ok and slots) or 0 do
			local info
			if C_Container.GetContainerItemInfo then
				local ok2, i = pcall(C_Container.GetContainerItemInfo, bag, slot)
				if ok2 and type(i) == "table" then info = i end
			end
			if info and info.itemID == s.outputItemID then
				if info.isBound then
					bound = bound + 1
				elseif not info.isLocked then
					table.insert(list, { bag = bag, slot = slot, count = info.stackCount or 1 })
				end
			end
		end
	end
	return list, bound
end

-- Sends one mail with the next items. Returns true when SendMail was called.
function Planner:MailNext()
	local s, to = self.session, self:GetMailTo()
	if not (s and to) then return false end
	if self:IsMailToSelf(to) then
		CS:Print("you are logged in on %s, the recipient: nothing to mail.", to)
		return false
	end
	if not self.mailOpen then
		CS:Print("open a mailbox first.")
		return false
	end
	if self.mailPending then return false end
	if not (SendMail and ClickSendMailItemButton and C_Container and C_Container.PickupContainerItem) then
		CS:Print("this client has no mail-sending API.")
		return false
	end
	-- the Send Mail tab holds the attachment slots
	if MailFrameTab_OnClick and not (SendMailFrame and SendMailFrame:IsShown()) then pcall(MailFrameTab_OnClick, nil, 2) end
	if AttachedCount() > 0 then
		CS:Print("the Send Mail form already holds items; send or clear it first.")
		return false
	end
	local slots, bound = self:MailSlots()
	if bound > 0 then CS:Print("%d %s are soulbound and cannot be mailed.", bound, CS:ItemName(s.outputItemID)) end
	if #slots == 0 then
		CS:Print("no %s in your bags to mail.", CS:ItemName(s.outputItemID))
		return false
	end
	if CursorHasItem and CursorHasItem() and ClearCursor then ClearCursor() end
	local n, items = 0, 0
	for _, e in ipairs(slots) do
		if n >= MaxAttachments() then break end
		pcall(C_Container.PickupContainerItem, e.bag, e.slot)
		pcall(ClickSendMailItemButton, n + 1)
		if CursorHasItem and CursorHasItem() then
			if ClearCursor then ClearCursor() end -- the form refused it
		else
			n, items = n + 1, items + e.count
		end
	end
	if n == 0 then
		CS:Print("could not attach %s to the mail.", CS:ItemName(s.outputItemID))
		return false
	end
	if GetSendMailPrice and GetMoney then
		local ok, postage = pcall(GetSendMailPrice)
		if ok and type(postage) == "number" and postage > GetMoney() then
			if ClearSendMail then pcall(ClearSendMail) end
			CS:Print("not enough gold for the postage (%s).", CS:Money(postage))
			return false
		end
	end
	if SetSendMailCOD then pcall(SetSendMailCOD, 0) end
	if SetSendMailMoney then pcall(SetSendMailMoney, 0) end
	local subject = string.format("CraftShuffle: %dx %s", items, CS:ItemName(s.outputItemID))
	local ok, err = pcall(SendMail, to, subject, "")
	if not ok then
		if ClearSendMail then pcall(ClearSendMail) end
		CS:Print("sending failed: %s", tostring(err))
		return false
	end
	self.mailPending = { to = to, items = items, t = GetTime and GetTime() or 0 }
	self:UpdateMailPanel()
	return true
end

local function CreateMailPanel()
	local parent = MailFrame or UIParent
	local ok, f = pcall(CreateFrame, "Frame", "CraftShuffleMail", parent, "BasicFrameTemplateWithInset")
	if not ok or not f then f = CreateFrame("Frame", "CraftShuffleMail", parent) end
	f:SetSize(260, MAIL_ROWS_H)
	if MailFrame then f:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 4, 0) else f:SetPoint("CENTER") end
	local title = "Shuffle " .. DASH .. " mail"
	if f.TitleText then f.TitleText:SetText(title) elseif f.SetTitle then pcall(f.SetTitle, f, title) end
	f.Line = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.Line:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -32)
	f.Line:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -32)
	f.Line:SetJustifyH("LEFT")
	if f.Line.SetWordWrap then f.Line:SetWordWrap(false) end
	f.Note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.Note:SetPoint("TOPLEFT", f.Line, "BOTTOMLEFT", 0, -4)
	f.Note:SetPoint("TOPRIGHT", f.Line, "BOTTOMRIGHT", 0, -4)
	f.Note:SetJustifyH("LEFT")
	f.Send = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.Send:SetSize(140, 22)
	f.Send:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
	f.Send:SetScript("OnClick", function() Planner:MailNext() end)
	f.Change = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.Change:SetSize(80, 22)
	f.Change:SetPoint("RIGHT", f.Send, "LEFT", -6, 0)
	f.Change:SetText("Change")
	f.Change:SetScript("OnClick", function() Planner:AskMailTo() end)
	f:Hide()
	return f
end

function Planner:UpdateMailPanel()
	local s, to = self.session, self:GetMailTo()
	-- on the recipient itself (the enchanter collecting the mail) there is nothing to send
	if not (self.mailOpen and s and to) or self:IsMailToSelf(to) then
		if self.mailPanel then self.mailPanel:Hide() end
		return
	end
	local slots = self:MailSlots()
	local items = 0
	for _, e in ipairs(slots) do items = items + e.count end
	if items == 0 and not self.mailPending then
		if self.mailPanel then self.mailPanel:Hide() end
		return
	end
	self.mailPanel = self.mailPanel or CreateMailPanel()
	local f = self.mailPanel
	local mails = math.ceil(#slots / MaxAttachments())
	f.Line:SetText(string.format("%dx %s  " .. Muted("to") .. "  %s", items, CS:ItemName(s.outputItemID), to))
	if self.mailPending then
		f.Note:SetText("Sending...")
		f.Send:SetText("Sending...")
		f.Send:Disable()
	else
		f.Note:SetText(mails > 1 and string.format("%d mails of up to %d items: one click per mail.", mails, MaxAttachments()) or "One mail.")
		f.Send:SetText(mails > 1 and string.format("Send (%d mails left)", mails) or "Send")
		f.Send:Enable()
	end
	f:Show()
end

CS:RegisterEvent("MAIL_SHOW", function()
	Planner.mailOpen = true
	Planner:UpdateMailPanel()
end)
CS:RegisterEvent("MAIL_CLOSED", function()
	Planner.mailOpen = nil
	Planner.mailPending = nil
	if Planner.mailPanel then Planner.mailPanel:Hide() end
end)
CS:RegisterEvent("MAIL_SEND_SUCCESS", function()
	local p = Planner.mailPending
	if not p then return end
	Planner.mailPending = nil
	local s = Planner.session
	if s then
		s.mailed = (s.mailed or 0) + p.items
		s.mailedTo = p.to
	end
	CS:Print("mailed %dx %s to %s.", p.items, s and CS:ItemName(s.outputItemID) or "items", p.to)
	-- the bag slots unlock a moment after the send
	if C_Timer and C_Timer.After then
		C_Timer.After(0.5, function() Planner:UpdateMailPanel() Planner:Refresh() end)
	else
		Planner:UpdateMailPanel()
	end
end)
CS:RegisterEvent("MAIL_FAILED", function()
	local p = Planner.mailPending
	if not p then return end
	Planner.mailPending = nil
	if ClearSendMail then pcall(ClearSendMail) end
	CS:Print("the mail to %s was refused (check the character name, written as in a whisper).", p.to)
	Planner:UpdateMailPanel()
end)
CS:RegisterEvent("BAG_UPDATE_DELAYED", function()
	if Planner.mailPanel and Planner.mailPanel:IsShown() then Planner:UpdateMailPanel() end
end)
