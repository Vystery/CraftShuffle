-- CraftShuffle :: DESession
-- Stats for plain disenchanting (no shuffle session): every Disenchant the tracker records outside a running
-- shuffle goes into one running tally: casts, items, materials gained and their value at current prices,
-- what the items cost (the price paid at the AH for that unit when known, the market price otherwise), net and
-- per cast.
-- The window opens by itself on the first such cast (unless a shuffle session is running: its Session View
-- already keeps score), /cs de stats opens it, Reset starts a fresh tally. The tally survives /reload.

local _, CS = ...
local DES = {}
CS.DESession = DES

local C = CS.UI_COLORS -- the default UI's font colours (Core.lua)
local DASH = "\226\128\148"
local DOT = " \194\183 "

local function Muted(text) return CS:Color(C.muted, text) end
local function Body(text) return CS:Color(C.body, text) end
local function Gray(text) return CS:Color(C.gray, text) end
local function Label(text) return CS:Color(C.label, text) end
local function Gold(text) return CS:Color(C.gold, text) end
local function Signed(v)
	if not v then return Gray(DASH) end
	return CS:Color(v >= 0 and C.profit or C.loss, CS:Money(v, { sign = true }))
end

---------------------------------------------------------------------------
-- Tally
---------------------------------------------------------------------------

local function NewRun()
	return { started = time(), last = time(), casts = 0, items = {}, mats = {} }
end

function DES:GetRun(create)
	local db = CS.db
	if not db then return nil end
	if not db.derun and create then db.derun = NewRun() end
	return db.derun
end

-- Bought, not yet disenchanted: every AH purchase CraftProfit confirms (PURCHASE_RECORDED) goes into
-- db.deStock[itemID] = { { t, qty, unit }, ... }, oldest first; each cast uses up one unit of the oldest lot.
-- Lots older than STOCK_TTL are dropped (sold or kept rather than disenchanted); CS:PruneStock (Core.lua)
-- applies the same limits to the saved copy at load, adoption and logout.
local STOCK_TTL = CS.STOCK_TTL
local STOCK_MAX = CS.STOCK_MAX

function DES:AddStock(itemID, qty, unit)
	local db = CS.db
	if not (db and itemID and qty and qty > 0 and unit) then return end
	db.deStock = db.deStock or {}
	local list = db.deStock[itemID] or {}
	db.deStock[itemID] = list
	table.insert(list, { time(), qty, unit })
	while #list > STOCK_MAX do table.remove(list, 1) end
end

-- Takes one unit out of the oldest lot: its price, or nil when none is left.
function DES:TakeStock(itemID)
	local stock = CS.db and CS.db.deStock
	local list = stock and stock[itemID]
	if not list then return nil end
	while list[1] and (list[1][2] <= 0 or time() - list[1][1] > STOCK_TTL) do table.remove(list, 1) end
	local lot = list[1]
	if not lot then
		stock[itemID] = nil
		return nil
	end
	lot[2] = lot[2] - 1
	if lot[2] <= 0 then table.remove(list, 1) end
	if not list[1] then stock[itemID] = nil end
	return lot[3]
end

-- What one of this item cost us: the price paid for the oldest unit still in stock, else the market price.
local function UnitCost(itemID)
	local paid = DES:TakeStock(itemID)
	if paid then return paid, true end
	local CP = CS.CP
	if CP and CP.GetReagentCost then
		local ok, unit = pcall(CP.GetReagentCost, CP, itemID)
		if ok and unit and unit > 0 then return unit, false end
	end
	return nil, false
end

-- One recorded cast. Skipped when a shuffle session is running for this very item (its Session View keeps
-- that score); anything else disenchanted during a shuffle still counts here.
function DES:Record(itemID, mats)
	if not itemID or type(mats) ~= "table" then return false end
	local session = CS.Planner and CS.Planner.session
	if session and session.outputItemID == itemID then return false end
	local run = self:GetRun(true)
	if not run then return false end
	run.casts = run.casts + 1
	run.last = time()
	local it = run.items[itemID]
	if not it then
		it = { n = 0, mats = {}, cost = 0, costEstimated = false, costMissing = 0 }
		run.items[itemID] = it
	end
	it.n = it.n + 1
	local unit, known = UnitCost(itemID)
	if unit then
		it.cost = it.cost + unit
		if not known then it.costEstimated = true end
	else
		it.costMissing = it.costMissing + 1
	end
	for matID, qty in pairs(mats) do
		it.mats[matID] = (it.mats[matID] or 0) + qty
		run.mats[matID] = (run.mats[matID] or 0) + qty
	end
	self:Refresh()
	if CS.settings.deWindow ~= false and not session and not self.dismissed then self:Open() end
	return true
end

function DES:Reset()
	if CS.db then CS.db.derun = NewRun() end
	self.dismissed = nil
	self:Refresh()
end

-- Numbers for the window and chat, at current material prices.
function DES:Stats(run)
	run = run or self:GetRun(false)
	local CP = CS.CP
	local st = { casts = 0, matValue = 0, cost = 0, mats = {}, items = {}, unpriced = 0, costEstimated = false, costMissing = 0 }
	if not run then return st end
	st.casts = run.casts or 0
	st.started, st.last = run.started, run.last
	st.elapsed = (run.last or run.started or time()) - (run.started or time())
	st.cutRate = (CP and CP.settings and CP.settings.ahCut) or 0
	local unitPrice = {}
	for matID, qty in pairs(run.mats or {}) do
		local unit = CP and CP:GetSalePrice(matID)
		unitPrice[matID] = unit
		local value = unit and unit * qty or nil
		if value then st.matValue = st.matValue + value else st.unpriced = st.unpriced + 1 end
		table.insert(st.mats, { itemID = matID, qty = qty, unit = unit, value = value })
	end
	table.sort(st.mats, function(a, b)
		if (a.value or -1) ~= (b.value or -1) then return (a.value or -1) > (b.value or -1) end
		return a.qty > b.qty
	end)
	for itemID, it in pairs(run.items or {}) do
		local value = 0
		for matID, qty in pairs(it.mats or {}) do
			local unit = unitPrice[matID] or (CP and CP:GetSalePrice(matID))
			if unit then value = value + unit * qty end
		end
		local cut = value * st.cutRate
		local e = { itemID = itemID, n = it.n or 0, value = value, cut = cut, cost = it.cost or 0,
			costEstimated = it.costEstimated, costMissing = it.costMissing or 0 }
		e.net = value - cut - e.cost
		e.perCast = e.n > 0 and e.net / e.n or nil
		st.cost = st.cost + e.cost
		if it.costEstimated then st.costEstimated = true end
		st.costMissing = st.costMissing + (it.costMissing or 0)
		table.insert(st.items, e)
	end
	table.sort(st.items, function(a, b)
		if a.net ~= b.net then return a.net > b.net end
		return a.n > b.n
	end)
	st.cut = st.matValue * st.cutRate
	st.net = st.matValue - st.cut - st.cost
	st.perCast = st.casts > 0 and st.net / st.casts or nil
	st.valuePerCast = st.casts > 0 and (st.matValue - st.cut) / st.casts or nil
	return st
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

-- Window, built like the Shuffle Planner: portrait window with the Disenchant icon, the tally line and Reset
-- right of the portrait, and the materials, items and totals on one board with the profession window's
-- Enchanting background (CS:UpdateBoardArt). Default UI templates, font objects and colours only.
local WIDTH, PAD = 460, 12
local ROW_H = 14
local MAT_ROWS, ITEM_ROWS = 8, 8
local PORTRAIT_ICON = "Interface\\Icons\\INV_Enchant_Disenchant"
local BOARD_TOP = 60                                      -- board starts under the toolbar row
local Y_MATS = BOARD_TOP + 10
local Y_ITEMS = Y_MATS + 20 + MAT_ROWS * ROW_H + 14
local Y_FOOT = Y_ITEMS + 20 + ITEM_ROWS * ROW_H + 14
local BOARD_BOTTOM = 30                                   -- hint line under the board
local HEIGHT = Y_FOOT + 3 * ROW_H + 10 + BOARD_BOTTOM

local function Elapsed(sec)
	sec = math.max(0, math.floor(sec or 0))
	if sec < 60 then return string.format("%d sec", sec) end
	if sec < 3600 then return string.format("%d min", math.floor(sec / 60)) end
	return string.format("%dh %02dm", math.floor(sec / 3600), math.floor((sec % 3600) / 60))
end

-- Label / value rows on the board, positioned from the window's top.
local function MakeRows(board, f, y, n)
	local rows = {}
	for i = 1, n do
		local l = board:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		l:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 6, -(y + (i - 1) * ROW_H))
		l:SetJustifyH("LEFT")
		if l.SetWordWrap then l:SetWordWrap(false) end
		local v = board:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		v:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD - 6, -(y + (i - 1) * ROW_H))
		v:SetJustifyH("RIGHT")
		l:SetPoint("RIGHT", v, "LEFT", -6, 0)
		rows[i] = { label = l, value = v }
	end
	return rows
end

local function SectionTitle(board, f, text, y)
	local t = board:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	t:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 4, -y)
	t:SetText(text)
	local right = board:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	right:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD - 4, -(y + 2))
	right:SetJustifyH("RIGHT")
	return t, right
end

local function Divider(board, f, y)
	local d = board:CreateTexture(nil, "ARTWORK")
	if not (d.SetAtlas and pcall(d.SetAtlas, d, "Options_HorizontalDivider")) then d:SetColorTexture(1, 1, 1, 0.12) end
	d:SetHeight(1)
	d:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 4, -y)
	d:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD - 4, -y)
	return d
end

local function CreateWindow()
	local name = "CraftShuffleDESession"
	local f
	for _, template in ipairs({ "PortraitFrameTemplate", "ButtonFrameTemplate", "BasicFrameTemplateWithInset" }) do
		local ok, frame = pcall(CreateFrame, "Frame", name, UIParent, template)
		if ok and frame then f = frame break end
	end
	if not f then
		f = CreateFrame("Frame", name, UIParent)
		f.TitleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		f.TitleText:SetPoint("TOP", 0, -8)
		f.CloseButton = CreateFrame("Button", nil, f, "UIPanelCloseButton")
		f.CloseButton:SetPoint("TOPRIGHT", -4, -4)
	end
	if f.Inset and f.Inset.Hide then f.Inset:Hide() end
	f:SetSize(WIDTH, HEIGHT)
	f:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) self:StartMoving() end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		CS.db.planner.dePos = { point, relPoint, x, y }
	end)
	-- closed by hand: stay closed for the rest of this tally (Reset or /cs de stats brings it back)
	f:SetScript("OnHide", function() DES.dismissed = true end)
	f:SetFrameStrata("HIGH")
	f:Hide()
	local title = "Disenchanting"
	if f.SetTitle then pcall(f.SetTitle, f, title) elseif f.TitleText then f.TitleText:SetText(title) end
	local portrait = (f.PortraitContainer and f.PortraitContainer.portrait) or f.portrait
	if f.SetPortraitToAsset then
		pcall(f.SetPortraitToAsset, f, PORTRAIT_ICON)
	elseif portrait and SetPortraitToTexture then
		pcall(SetPortraitToTexture, portrait, PORTRAIT_ICON)
	end
	local x0 = portrait and 64 or PAD
	if UISpecialFrames then table.insert(UISpecialFrames, name) end

	-- toolbar, right of the portrait: the tally line and Reset
	f.ResetButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.ResetButton:SetSize(70, 22)
	f.ResetButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -30)
	f.ResetButton:SetText("Reset")
	f.ResetButton:SetScript("OnClick", function() DES:Reset() end)
	f.ResetButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Reset")
		GameTooltip:AddLine("Starts a fresh tally. The recorded disenchants themselves stay in the yield data.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	f.ResetButton:SetScript("OnLeave", GameTooltip_Hide)
	f.Head = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.Head:SetPoint("TOPLEFT", f, "TOPLEFT", x0, -36)
	f.Head:SetPoint("RIGHT", f.ResetButton, "LEFT", -8, 0)
	f.Head:SetJustifyH("LEFT")
	if f.Head.SetWordWrap then f.Head:SetWordWrap(false) end

	-- the board: one inset with the Enchanting background, the two lists and the totals on it
	local okB, board = pcall(CreateFrame, "Frame", nil, f, "InsetFrameTemplate")
	if not okB or not board then board = CreateFrame("Frame", nil, f) end
	board:SetPoint("TOPLEFT", f, "TOPLEFT", PAD - 4, -BOARD_TOP)
	board:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD + 4, BOARD_BOTTOM)
	board.Art = board:CreateTexture(nil, "BACKGROUND", nil, 2)
	board.Art:SetPoint("TOPLEFT", board, "TOPLEFT", 3, -3)
	board.Art:SetPoint("BOTTOMRIGHT", board, "BOTTOMRIGHT", -3, 3)
	board.Art:Hide()
	board:SetScript("OnSizeChanged", function(self) CS:UpdateBoardArt(self) end)
	f.Board = board

	f.MatsTitle, f.MatsRight = SectionTitle(board, f, "Materials gained", Y_MATS)
	f.Mats = MakeRows(board, f, Y_MATS + 20, MAT_ROWS)
	f.Divider1 = Divider(board, f, Y_ITEMS - 7)
	f.ItemsTitle, f.ItemsRight = SectionTitle(board, f, "Items disenchanted", Y_ITEMS)
	f.Items = MakeRows(board, f, Y_ITEMS + 20, ITEM_ROWS)
	f.Divider = Divider(board, f, Y_FOOT - 7)
	f.Foot = MakeRows(board, f, Y_FOOT, 3)
	for _, pair in ipairs(f.Foot) do
		if pair.label.SetFontObject then pcall(pair.label.SetFontObject, pair.label, "GameFontNormalSmall") end
		if pair.value.SetFontObject then pcall(pair.value.SetFontObject, pair.value, "GameFontHighlight") end
	end
	f.Hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.Hint:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 10)
	f.Hint:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 10)
	f.Hint:SetJustifyH("LEFT")
	if f.Hint.SetWordWrap then f.Hint:SetWordWrap(false) end
	f:HookScript("OnShow", function() CS:UpdateBoardArt(board) end)
	return f
end

function DES:GetFrame()
	if not self.frame then
		self.frame = CreateWindow()
		local pos = CS.db.planner.dePos
		if pos then
			self.frame:ClearAllPoints()
			self.frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
		end
	end
	return self.frame
end

function DES:Open()
	local f = self:GetFrame()
	self.dismissed = nil
	f:Show()
	self:Refresh()
end

function DES:Toggle()
	if self.frame and self.frame:IsShown() then self.frame:Hide() else self:Open() end
end

local function Fill(rows, entries, fmt)
	for i, pair in ipairs(rows) do
		local e = entries[i]
		if e and (i < #rows or #entries <= #rows) then
			local l, v = fmt(e)
			pair.label:SetText(l)
			pair.value:SetText(v)
			pair.label:Show() pair.value:Show()
		elseif e then
			pair.label:SetText(Muted(string.format("+%d more", #entries - #rows + 1)))
			pair.value:SetText("")
			pair.label:Show() pair.value:Show()
		else
			pair.label:Hide() pair.value:Hide()
		end
	end
end

function DES:Refresh()
	local f = self.frame
	if not f or not f:IsShown() then return end
	local run = self:GetRun(false)
	local st = self:Stats(run)

	if st.casts == 0 then
		f.Head:SetText(Muted("No disenchants recorded yet. Disenchant something outside a shuffle session and it shows up here."))
	else
		f.Head:SetText(Body(string.format("%d casts", st.casts)) .. Muted(DOT .. "since " .. date("%H:%M", st.started or time()) .. DOT .. Elapsed(st.elapsed)))
	end

	f.MatsRight:SetText(st.unpriced > 0 and Muted(string.format("%d unpriced", st.unpriced)) or "")
	Fill(f.Mats, st.mats, function(m)
		local right = m.value and (Body(CS:Money(m.value)) .. Muted(string.format(" (%s ea)", CS:MoneyShort(m.unit)))) or Gray("no price")
		return Body(string.format("%dx %s", m.qty, CS:ItemName(m.itemID))), right
	end)

	f.ItemsRight:SetText(Muted("net after cut and cost"))
	Fill(f.Items, st.items, function(e)
		local costNote = ""
		if e.costMissing > 0 then costNote = Gray(" cost?") elseif e.costEstimated then costNote = Muted(" ~cost") end
		return Body(string.format("%dx %s", e.n, CS:ItemName(e.itemID))) .. costNote,
			Signed(e.net) .. Muted(e.perCast and string.format(" (%s ea)", CS:MoneyShort(e.perCast, { sign = true })) or "")
	end)

	local costLabel = "Items cost"
	if st.costMissing > 0 then costLabel = costLabel .. Gray(" (" .. st.costMissing .. " unknown)")
	elseif st.costEstimated then costLabel = costLabel .. Muted(" (market, not paid)") end
	f.Foot[1].label:SetText(Label("Mats value after cut")) f.Foot[1].value:SetText(Body(CS:Money(st.matValue - st.cut)))
	f.Foot[2].label:SetText(Label(costLabel)) f.Foot[2].value:SetText(Body(CS:Money(st.cost)))
	f.Foot[3].label:SetText(Label("Net")) f.Foot[3].value:SetText(Signed(st.net) .. Muted(st.perCast and string.format("  %s per cast", CS:MoneyShort(st.perCast, { sign = true })) or ""))
	for _, pair in ipairs(f.Foot) do pair.label:Show() pair.value:Show() end
	f.Hint:SetText("Current material prices. Cost = what you paid on the AH, else the market price.")
end

function DES:PrintStats()
	local st = self:Stats()
	if st.casts == 0 then
		CS:Print("no disenchants in the current tally.")
		return
	end
	CS:Print("disenchanting: %d casts since %s, mats %s after cut, cost %s, net %s (%s per cast)", st.casts,
		date("%H:%M", st.started or time()), CS:Money(st.matValue - st.cut), CS:Money(st.cost), CS:Money(st.net, { sign = true }),
		st.perCast and CS:Money(st.perCast, { sign = true }) or "?")
	for i, m in ipairs(st.mats) do
		if i > 8 then break end
		CS:Print("  %dx %s  %s", m.qty, CS:ItemName(m.itemID), m.value and CS:Money(m.value) or "no price")
	end
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

CS:On("DE_RECORDED", function(itemID, mats)
	if itemID and type(mats) == "table" then
		DES:Record(itemID, mats)
	else
		DES:Refresh()
	end
end)
if CS.CP then
	CS.CP:On("PURCHASE_RECORDED", function(itemID, qty, total)
		if itemID and qty and qty > 0 and total then DES:AddStock(itemID, qty, total / qty) end
	end)
	CS.CP:On("PRICES_UPDATED", function() DES:Refresh() end)
	CS.CP:On("SETTINGS_CHANGED", function() DES:Refresh() end)
end
CS:On("ITEM_LOADED", function() DES:Refresh() end)

-- /cs de stats [reset]
function DES:Slash(arg)
	arg = (arg or ""):lower()
	if arg == "reset" then
		self:Reset()
		CS:Print("disenchant tally reset.")
	elseif arg == "chat" or arg == "print" then
		self:PrintStats()
	else
		self:Open()
	end
end
