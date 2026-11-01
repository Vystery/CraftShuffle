-- CraftShuffle :: DEScan
-- AH scans over CraftProfit's last full browse scan (lowest buyout of every item listed), no extra AH traffic:
--   DE     every armor / weapon whose expected disenchant value (after the AH cut) beats its lowest buyout by
--          at least a configurable margin, priced with the same yield blend and material prices the planner uses;
--   Vendor every item listed below what a vendor pays for it (price ladders, when CraftProfit has them, say
--          how many units are really under the vendor price).
-- /cs scan [de|vendor] opens the window; the AH's Shuffle tab has a button.

local _, CS = ...
local Scan = {}
CS.DEScan = Scan

local C = CS.UI_COLORS -- the default UI's font colours (Core.lua)
local DASH = "\226\128\148"
local DOT = " \194\183 "

local function Muted(text) return CS:Color(C.muted, text) end
local function Body(text) return CS:Color(C.body, text) end
local function Gray(text) return CS:Color(C.gray, text) end
local function Label(text) return CS:Color(C.label, text) end
local function Gold(text) return CS:Color(C.gold, text) end

local QUALITY_HEX = { [2] = "1eff00", [3] = "0070dd", [4] = "a335ee" }
local function QualityColor(quality, text)
	local hex = QUALITY_HEX[quality]
	if ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality] and ITEM_QUALITY_COLORS[quality].hex then
		hex = ITEM_QUALITY_COLORS[quality].hex:sub(5) -- "|cffRRGGBB" -> "RRGGBB"
	end
	return hex and CS:Color(hex, text) or Body(text)
end

-- Threshold presets for the dropdown (copper).
Scan.PRESETS = { 100, 500, 1000, 5000, 10000, 50000, 100000 }
Scan.VENDOR_PRESETS = { 10, 25, 50, 100, 500, 1000, 5000 }

-- Two scans share the window: "de" (disenchant) and "vendor" (below vendor price).
Scan.mode = "de"
local MODE_KEY = { de = "scanMinProfit", vendor = "scanVendorMinProfit" }

function Scan:SetMode(mode)
	mode = mode == "vendor" and "vendor" or "de"
	if mode ~= self.mode then
		self.mode = mode
		self.offset = 0
	end
	self:Refresh()
end

---------------------------------------------------------------------------
-- Money parsing: "1g", "50s", "1g 50s", "1g50s20c", "150" (copper)
---------------------------------------------------------------------------

function Scan.ParseMoney(text)
	if type(text) == "number" then return math.floor(text) end
	if type(text) ~= "string" then return nil end
	local s = text:lower():gsub("%s+", "")
	if s == "" then return nil end
	if s:match("^%d+$") then return tonumber(s) end
	local total, matched = 0, false
	for amount, unit in s:gmatch("(%d+%.?%d*)([gsc])") do
		local n = tonumber(amount)
		if not n then return nil end
		if unit == "g" then total = total + n * 10000
		elseif unit == "s" then total = total + n * 100
		else total = total + n end
		matched = true
	end
	if not matched then return nil end
	-- reject leftovers such as "1x"
	if s:gsub("%d+%.?%d*[gsc]", "") ~= "" then return nil end
	return math.floor(total + 0.5)
end

function Scan:GetMinProfit(mode)
	local key = MODE_KEY[mode or self.mode] or "scanMinProfit"
	local v = CS.settings[key]
	if type(v) ~= "number" or v < 0 then v = CS.defaults[key] or 100 end
	return v
end

function Scan:SetMinProfit(copper, mode)
	copper = math.max(0, math.floor(tonumber(copper) or 0))
	CS:SetSetting(MODE_KEY[mode or self.mode] or "scanMinProfit", copper)
end

function Scan:Presets()
	return self.mode == "vendor" and self.VENDOR_PRESETS or self.PRESETS
end

---------------------------------------------------------------------------
-- Model
---------------------------------------------------------------------------

-- Expected material value of one disenchant at current sale prices. nil when a material that matters
-- has no price (the row would be a guess).
local function DEValue(itemID)
	local CP = CS.CP
	local yields, why, info = CS.Tracker:GetExpectedYields(itemID)
	if not yields then return nil, why end
	local value, missing = 0, 0
	for _, y in ipairs(yields) do
		local unit = CP:GetSalePrice(y.itemID)
		if unit then
			value = value + unit * y.expected
		elseif y.expected >= 0.02 then
			missing = missing + 1
		end
	end
	if missing > 0 or value <= 0 then return nil, "no-mat-prices", info end
	return value, nil, info, yields
end

function Scan:Compute()
	if self.mode == "vendor" then return self:ComputeVendor() end
	return self:ComputeDE()
end

-- Vendor scan: items whose lowest buyout is under the vendor sell price by at least the threshold.
--   row = { itemID, name, quality, price, qty, sell, net, margin, units, total, ladderAge }
--   units/total: how many listed units are really below vendor and the profit on all of them (price ladder),
--   nil when only the lowest buyout is known.
function Scan:ComputeVendor()
	local CP = CS.CP
	local rows = {}
	local stats = { mode = "vendor", scanned = 0, seen = 0, vendorable = 0, loading = 0, listed = 0,
		minProfit = self:GetMinProfit("vendor"), lastScan = 0 }
	if not (CP and CP.GetRealmDB and CS.DEData) then return rows, stats end
	local realm = CP:GetRealmDB()
	local prices = realm and realm.prices or {}
	local lastScan = realm and realm.lastScan or 0
	stats.lastScan = lastScan
	if lastScan <= 0 then return rows, stats end
	local Scanner = CP.Scanner

	for itemID, rec in pairs(prices) do
		local price, qty, t = rec[1], rec[2], rec[3]
		stats.seen = stats.seen + 1
		if price and price > 0 and t and t >= lastScan - 60 then
			stats.scanned = stats.scanned + 1
			local meta, why = CS.DEData:GetItemMeta(itemID)
			if not meta then
				if why == "loading" then stats.loading = stats.loading + 1 end
			elseif meta.sell and meta.sell > 0 then
				stats.vendorable = stats.vendorable + 1
				local net = meta.sell - price
				if net >= stats.minProfit then
					local row = { itemID = itemID, name = meta.name, quality = meta.quality, price = price, qty = qty or 0,
						sell = meta.sell, net = net, margin = net / price }
					local ladder = Scanner and Scanner.GetLadder and Scanner:GetLadder(itemID)
					if ladder and ladder.tiers then
						local units, total = 0, 0
						for _, tier in ipairs(ladder.tiers) do
							if tier[1] < meta.sell then
								units = units + tier[2]
								total = total + (meta.sell - tier[1]) * tier[2]
							end
						end
						row.units, row.total, row.ladderFull = units, total, ladder.full
						row.ladderAge = time() - (ladder.t or 0)
					end
					table.insert(rows, row)
				end
			end
		end
	end
	table.sort(rows, function(a, b)
		local ta, tb = a.total or a.net, b.total or b.net
		if ta ~= tb then return ta > tb end
		return (a.name or "") < (b.name or "")
	end)
	stats.listed = #rows
	return rows, stats
end

-- Rows above the threshold, best net first, plus counts for the header.
--   row = { itemID, name, quality, ilvl, price, qty, value, cut, net, margin, summary, estimateOnly }
--   stats = { scanned, seen, disenchantable, loading, priced, listed, minProfit, lastScan }
function Scan:ComputeDE()
	local CP = CS.CP
	local rows = {}
	local stats = { mode = "de", scanned = 0, seen = 0, disenchantable = 0, loading = 0, priced = 0, listed = 0,
		minProfit = self:GetMinProfit("de"), lastScan = 0 }
	if not (CP and CP.GetRealmDB and CS.Tracker and CS.DEData) then return rows, stats end
	local realm = CP:GetRealmDB()
	local prices = realm and realm.prices or {}
	local lastScan = realm and realm.lastScan or 0
	stats.lastScan = lastScan
	if lastScan <= 0 then return rows, stats end
	local cutRate = (CP.settings and CP.settings.ahCut) or 0

	for itemID, rec in pairs(prices) do
		local price, qty, t = rec[1], rec[2], rec[3]
		stats.seen = stats.seen + 1
		-- only what the latest scan actually saw; older records are items that have since sold out
		if price and price > 0 and t and t >= lastScan - 60 then
			stats.scanned = stats.scanned + 1
			local meta, why = CS.DEData:GetItemMeta(itemID)
			if not meta then
				if why == "loading" then stats.loading = stats.loading + 1 end
			elseif CS.DEData:IsDisenchantable(meta) then
				stats.disenchantable = stats.disenchantable + 1
				local value, _, info = DEValue(itemID)
				if value then
					stats.priced = stats.priced + 1
					local cut = value * cutRate
					local net = value - cut - price
					if net >= stats.minProfit then
						table.insert(rows, {
							itemID = itemID, name = meta.name, quality = meta.quality, ilvl = meta.ilvl,
							weapon = meta.classID == 2,
							price = price, qty = qty or 0, value = value, cut = cut, net = net,
							margin = price > 0 and (net / price) or nil,
							summary = info and info.summary or "estimate",
							estimateOnly = info and info.estimateOnly,
						})
					end
				end
			end
		end
	end
	table.sort(rows, function(a, b)
		if a.net ~= b.net then return a.net > b.net end
		return (a.name or "") < (b.name or "")
	end)
	stats.listed = #rows
	return rows, stats
end

---------------------------------------------------------------------------
-- Window: built like the Auction House's own lists. Portrait window, toolbar right of the portrait (status,
-- minimum-profit dropdown, Scan AH), AH column headers (AuctionHouseTableHeaderStringTemplate) over an
-- InsetFrameTemplate with the Buy tab's background art, AH row highlight, and Disenchant / Vendor as tabs
-- under the window like the AH's Buy / Sell tabs. Default UI templates, font objects and colours only.
---------------------------------------------------------------------------

local WIDTH, PAD = 700, 8
local ROWS, ROW_H = 14, 20
local TOOLBAR_Y = -30
local LIST_TOP, HEADER_H = -60, 19
local FOOTER_H = 30
local HEIGHT = -LIST_TOP + HEADER_H + 6 + ROWS * ROW_H + FOOTER_H
local PORTRAIT_ICON = "Interface\\Icons\\INV_Enchant_Disenchant"
-- columns: header, width (0 = takes what is left), justify. The last one (vendor mode's "Below vendor") is
-- only shown in vendor mode; in the disenchant view the item column takes its width.
local COLS = {
	{ "Item", 0, "LEFT" },
	{ "Buyout", 82, "RIGHT" },
	{ "DE value", 82, "RIGHT" },
	{ "Net", 82, "RIGHT" },
	{ "%", 48, "RIGHT" },
	{ "Qty", 48, "RIGHT" },
	{ "Below vendor", 120, "RIGHT" },
}
local DE_COLS, VENDOR_COLS = #COLS - 1, #COLS

local function Try(obj, method, ...)
	if obj and type(obj[method]) == "function" then return pcall(obj[method], obj, ...) end
end

-- x / width of the first n columns across the row; the item column flexes.
local function Layout(n)
	local rowW = WIDTH - 2 * PAD - 8
	local fixed = 0
	for i = 1, n do fixed = fixed + COLS[i][2] end
	local x, w = {}, {}
	local cx = 0
	for i = 1, n do
		w[i] = COLS[i][2] > 0 and COLS[i][2] or (rowW - fixed)
		x[i] = cx
		cx = cx + w[i]
	end
	return x, w
end

local function CreateHeader(area, i)
	local c = COLS[i]
	local ok, h = pcall(CreateFrame, "Button", nil, area, "AuctionHouseTableHeaderStringTemplate")
	if not ok or not h then
		h = CreateFrame("Button", nil, area)
		local fs = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("LEFT", h, "LEFT", 8, 0)
		h.Text = fs
	end
	if h.Arrow then h.Arrow:Hide() end
	h:SetScript("OnClick", nil) -- the template's click sorts an AH table; this list has its own order
	function h:SetLabel(text)
		if self.SetText then self:SetText(text) end
		if self.Text and self.Text ~= self and self.Text.SetText then self.Text:SetText(text) end
	end
	h:SetLabel(c[1])
	return h
end

local function CreateRow(area, i)
	local row = CreateFrame("Button", nil, area)
	row:SetHeight(ROW_H)
	local y = -HEADER_H - 3 - (i - 1) * ROW_H
	row:SetPoint("TOPLEFT", area, "TOPLEFT", 4, y)
	row:SetPoint("TOPRIGHT", area, "TOPRIGHT", -4, y)
	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	Try(hl, "SetAllPoints", row)
	if not (hl.SetAtlas and pcall(hl.SetAtlas, hl, "auctionhouse-ui-row-highlight")) then hl:SetColorTexture(1, 1, 1, 0.08) end
	Try(hl, "SetBlendMode", "ADD")

	row.Icon = row:CreateTexture(nil, "ARTWORK")
	row.Icon:SetSize(16, 16)
	row.Icon:SetPoint("LEFT", row, "LEFT", 6, 0)
	Try(row.Icon, "SetTexCoord", 0.07, 0.93, 0.07, 0.93)

	local function Cell(col, font)
		local l = row:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
		l:SetJustifyH(COLS[col][3])
		Try(l, "SetWordWrap", false)
		return l
	end
	row.Name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.Name:SetPoint("LEFT", row.Icon, "RIGHT", 6, 0)
	row.Name:SetJustifyH("LEFT")
	Try(row.Name, "SetWordWrap", false)
	row.Price = Cell(2)
	row.Value = Cell(3)
	row.Net = Cell(4)
	row.Margin = Cell(5)
	row.Qty = Cell(6)
	row.Data = Cell(7)
	row.Cells = { false, row.Price, row.Value, row.Net, row.Margin, row.Qty, row.Data }

	row:SetScript("OnEnter", function(self)
		local r = self.csRow
		if not r then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		local shown = false
		if GameTooltip.SetItemByID then shown = pcall(GameTooltip.SetItemByID, GameTooltip, r.itemID) end
		if not shown then GameTooltip:AddLine(r.name or ("item " .. r.itemID)) end
		GameTooltip:AddLine(" ")
		if r.sell then
			GameTooltip:AddLine("CraftShuffle " .. DASH .. " vendor", 1, 0.82, 0)
			GameTooltip:AddDoubleLine("Vendor pays", CS:Money(r.sell), 1, 0.82, 0, 1, 1, 1)
			GameTooltip:AddDoubleLine("Lowest buyout", "-" .. CS:Money(r.price), 1, 0.82, 0, 1, 1, 1)
			GameTooltip:AddDoubleLine("Net per unit", CS:Money(r.net, { sign = true }), 1, 0.82, 0, 1, 1, 1)
			if r.units then
				GameTooltip:AddDoubleLine(string.format("%d units below vendor%s", r.units, r.ladderFull and "" or " (scanned depth)"), CS:Money(r.total, { sign = true }) .. " total", 1, 0.82, 0, 1, 1, 1)
				GameTooltip:AddLine(string.format("Listings checked %s.", CS:Age(r.ladderAge or 0)), 0.6, 0.6, 0.6, true)
			else
				GameTooltip:AddLine(string.format("%d listed in total; only the lowest buyout is known. Open the item (click) to see how many are under vendor price.", r.qty or 0), 0.6, 0.6, 0.6, true)
			end
			GameTooltip:AddLine("Click: open in the Auction House. Shift-click: link in chat.", 0.6, 0.6, 0.6, true)
			GameTooltip:Show()
			return
		end
		GameTooltip:AddLine("CraftShuffle " .. DASH .. " disenchant", 1, 0.82, 0)
		local yields = CS.Tracker:GetExpectedYields(r.itemID)
		for _, y in ipairs(yields or {}) do
			local unit = CS.CP:GetSalePrice(y.itemID)
			GameTooltip:AddDoubleLine(string.format("%s %s  %d%%", CS:FormatYieldQty(y), CS:ItemName(y.itemID), math.floor(y.chance * 100 + 0.5)),
				unit and CS:Money(unit * y.expected) or "?", 1, 1, 1, 1, 1, 1)
		end
		GameTooltip:AddDoubleLine("Mats per cast", CS:Money(r.value), 1, 0.82, 0, 1, 1, 1)
		GameTooltip:AddDoubleLine("AH cut", "-" .. CS:Money(r.cut), 1, 0.82, 0, 1, 1, 1)
		GameTooltip:AddDoubleLine("Lowest buyout", "-" .. CS:Money(r.price), 1, 0.82, 0, 1, 1, 1)
		GameTooltip:AddDoubleLine("Net per item", CS:Money(r.net, { sign = true }), 1, 0.82, 0, 1, 1, 1)
		GameTooltip:AddLine(string.format("Yields: %s. %d listed at this price or above.", r.summary or "estimate", r.qty or 0), 0.6, 0.6, 0.6, true)
		GameTooltip:AddLine("Click: open in the Auction House. Shift-click: link in chat.", 0.6, 0.6, 0.6, true)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
	row:SetScript("OnClick", function(self)
		if self.csRow then Scan:OpenItem(self.csRow.itemID) end
	end)
	row:Hide()
	return row
end

local function Tip(owner, title, text)
	owner:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(type(title) == "function" and title() or title)
		GameTooltip:AddLine(type(text) == "function" and text() or text, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	owner:SetScript("OnLeave", GameTooltip_Hide)
end

-- Minimum profit: the default UI's dropdown with the presets (a panel button with the same menu otherwise).
local function CreateMinPicker(f)
	local ok, dd = pcall(CreateFrame, "DropdownButton", nil, f, "WowStyle1DropdownTemplate")
	if ok and dd and dd.SetupMenu then
		dd:SetSize(150, 22)
		if dd.SetSelectionTranslator then
			pcall(dd.SetSelectionTranslator, dd, function() return "Min profit: " .. CS:MoneyShort(Scan:GetMinProfit()) end)
		end
		dd:SetupMenu(function(_, root) Scan:BuildMinMenu(root) end)
		dd.csDropdown = true
		return dd
	end
	local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	b:SetSize(150, 22)
	b:SetScript("OnClick", function(self) Scan:OpenMinMenu(self) end)
	return b
end

-- Disenchant / Vendor: tabs under the window like the AH's Buy / Sell (panel buttons when the template is missing).
local function CreateModeTabs(f, name)
	local ok = PanelTemplates_SetNumTabs and PanelTemplates_SetTab
	local tabs = {}
	for i, spec in ipairs({ { "de", "Disenchant" }, { "vendor", "Vendor" } }) do
		local tab
		if ok then
			local made, t = pcall(CreateFrame, "Button", name .. "Tab" .. i, f, "PanelTabButtonTemplate")
			if made and t then tab = t end
		end
		if not tab then
			tab = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
			tab:SetSize(90, 22)
			ok = false
		end
		tab:SetID(i)
		tab:SetText(spec[2])
		tab.csMode = spec[1]
		tab:SetScript("OnClick", function(self) Scan:SetMode(self.csMode) end)
		if i == 1 then
			tab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 12, ok and 2 or -2)
		else
			tab:SetPoint("LEFT", tabs[i - 1], "RIGHT", ok and -15 or 4, 0)
		end
		if ok and PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 0) end
		Tip(tab, spec[1] == "de" and "Disenchant scan" or "Vendor scan", spec[1] == "de"
			and "Armor and weapons worth more as enchanting materials than their buyout."
			or "Items listed below what a vendor pays for them: buy, sell to any vendor.")
		tabs[i] = tab
	end
	if ok then
		f.numTabs = #tabs
		pcall(PanelTemplates_SetNumTabs, f, #tabs)
	end
	f.csPanelTabs = ok and true or false
	return tabs
end

-- Positions the headers and row cells for n columns (DE_COLS or VENDOR_COLS); the rest are hidden.
local function ApplyColumns(f, n)
	if f.csCols == n then return end
	f.csCols = n
	local x, w = Layout(n)
	for i, h in ipairs(f.Columns) do
		if i <= n then
			local overlap = i > 1 and 2 or 0
			h:ClearAllPoints()
			h:SetPoint("TOPLEFT", f.ListArea, "TOPLEFT", 4 + x[i] - overlap, -1)
			h:SetSize(w[i] + overlap, HEADER_H)
			h:Show()
		else
			h:Hide()
		end
	end
	for _, row in ipairs(f.Rows) do
		row.Name:SetWidth(math.max(40, w[1] - 34))
		for i = 2, #COLS do
			local cell = row.Cells[i]
			if i <= n then
				cell:ClearAllPoints()
				cell:SetPoint("LEFT", row, "LEFT", x[i] + 6, 0)
				cell:SetWidth(math.max(8, w[i] - 12))
				cell:Show()
			else
				cell:Hide()
			end
		end
	end
end

local function CreateWindow()
	local name = "CraftShuffleDEScan"
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
		CS.db.planner.scanPos = { point, relPoint, x, y }
	end)
	f:SetFrameStrata("HIGH")
	f:Hide()
	local title = "AH Scans"
	if f.SetTitle then pcall(f.SetTitle, f, title) elseif f.TitleText then f.TitleText:SetText(title) end
	local portrait = (f.PortraitContainer and f.PortraitContainer.portrait) or f.portrait
	if f.SetPortraitToAsset then
		pcall(f.SetPortraitToAsset, f, PORTRAIT_ICON)
	elseif portrait and SetPortraitToTexture then
		pcall(SetPortraitToTexture, portrait, PORTRAIT_ICON)
	end
	local x0 = portrait and 64 or 12
	if UISpecialFrames then table.insert(UISpecialFrames, name) end

	-- toolbar: status on the left, minimum profit + Scan AH on the right
	f.ScanButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.ScanButton:SetSize(90, 22)
	f.ScanButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, TOOLBAR_Y)
	f.ScanButton:SetText("Scan AH")
	if f.ScanButton.SetMotionScriptsWhileDisabled then f.ScanButton:SetMotionScriptsWhileDisabled(true) end
	f.ScanButton:SetScript("OnClick", function() Scan:ScanAH() end)
	Tip(f.ScanButton, "Scan AH", "Full browse scan through CraftProfit: the lowest buyout of every item listed. The Auction House must be open. Takes a while on a busy AH.")
	f.MinButton = CreateMinPicker(f)
	f.MinButton:SetPoint("RIGHT", f.ScanButton, "LEFT", -8, 0)
	if f.MinButton.HookScript then
		f.MinButton:HookScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine(Scan.mode == "vendor" and "Minimum profit per unit" or "Minimum profit per item")
			GameTooltip:AddLine(Scan.mode == "vendor" and "Only items whose vendor price beats the lowest buyout by at least this much. Any amount: /cs scan vendor min 25c"
				or "Only items whose expected material value, after the AH cut, beats the lowest buyout by at least this much. Any amount: /cs scan min 1g50s", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		f.MinButton:HookScript("OnLeave", GameTooltip_Hide)
	end
	f.Status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.Status:SetPoint("TOPLEFT", f, "TOPLEFT", x0, TOOLBAR_Y - 6)
	f.Status:SetPoint("RIGHT", f.MinButton, "LEFT", -10, 0)
	f.Status:SetJustifyH("LEFT")
	Try(f.Status, "SetWordWrap", false)

	-- the list: AH column headers on the window background, the inset with the Buy tab's art under them
	local area = CreateFrame("Frame", nil, f)
	area:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, LIST_TOP)
	area:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, FOOTER_H)
	f.ListArea = area
	local ok, box = pcall(CreateFrame, "Frame", nil, area, "InsetFrameTemplate")
	if ok and box then
		box:SetPoint("TOPLEFT", area, "TOPLEFT", 0, -HEADER_H)
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
	f.Columns = {}
	for i = 1, #COLS do f.Columns[i] = CreateHeader(area, i) end
	f.Rows = {}
	for i = 1, ROWS do f.Rows[i] = CreateRow(area, i) end
	f.Empty = area:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	f.Empty:SetPoint("TOPLEFT", area, "TOPLEFT", 14, -HEADER_H - 12)
	f.Empty:SetPoint("TOPRIGHT", area, "TOPRIGHT", -14, -HEADER_H - 12)
	f.Empty:SetJustifyH("LEFT")
	Try(f.Empty, "SetWordWrap", true)
	if f.EnableMouseWheel then f:EnableMouseWheel(true) end
	f:SetScript("OnMouseWheel", function(_, delta) Scan:Scroll(-delta * 3) end)

	-- old scan overlay: a scan from an earlier session has prices but no listing keys (they live only for
	-- the session), so rows cannot open their listings. A dimmed cover over the list says so and rescans.
	local stale = CreateFrame("Frame", nil, area)
	stale:SetPoint("TOPLEFT", area, "TOPLEFT", 3, -HEADER_H - 3)
	stale:SetPoint("BOTTOMRIGHT", area, "BOTTOMRIGHT", -3, 3)
	stale:SetFrameLevel(area:GetFrameLevel() + 10)
	stale:EnableMouse(true) -- rows under it cannot be clicked
	if stale.EnableMouseWheel then stale:EnableMouseWheel(true) end
	stale:SetScript("OnMouseWheel", function(_, delta) Scan:Scroll(-delta * 3) end)
	stale.Dim = stale:CreateTexture(nil, "BACKGROUND")
	stale.Dim:SetColorTexture(0, 0, 0, 0.65)
	Try(stale.Dim, "SetAllPoints", stale)
	stale.Title = stale:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	stale.Title:SetPoint("CENTER", stale, "CENTER", 0, 30)
	stale.Title:SetText("Scan is old, please scan again")
	stale.Text = stale:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	stale.Text:SetPoint("TOP", stale.Title, "BOTTOM", 0, -8)
	stale.Text:SetWidth(420)
	stale.Text:SetJustifyH("CENTER")
	Try(stale.Text, "SetWordWrap", true)
	stale.Button = CreateFrame("Button", nil, stale, "UIPanelButtonTemplate")
	stale.Button:SetSize(120, 24)
	stale.Button:SetPoint("TOP", stale.Text, "BOTTOM", 0, -12)
	stale.Button:SetText("Scan AH")
	stale.Button:SetScript("OnClick", function() Scan:ScanAH() end)
	stale:Hide()
	f.Stale = stale

	-- footer: what the numbers mean, and the page
	f.Foot = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.Foot:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 10)
	f.Foot:SetJustifyH("LEFT")
	Try(f.Foot, "SetWordWrap", false)
	f.Page = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.Page:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 10)
	f.Page:SetJustifyH("RIGHT")
	f.Foot:SetPoint("RIGHT", f.Page, "LEFT", -8, 0)

	-- Disenchant / Vendor tabs under the window
	local tabs = CreateModeTabs(f, name)
	f.ModeDE, f.ModeVendor = tabs[1], tabs[2]
	return f
end

function Scan:GetFrame()
	if not self.frame then
		self.frame = CreateWindow()
		local pos = CS.db.planner.scanPos
		if pos then
			self.frame:ClearAllPoints()
			self.frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
		end
	end
	return self.frame
end

function Scan:Open()
	local f = self:GetFrame()
	f:Show()
	self.offset = 0
	self:Refresh()
end

function Scan:Toggle()
	if self.frame and self.frame:IsShown() then self.frame:Hide() else self:Open() end
end

function Scan:Scroll(step)
	local rows = self.rows or {}
	local maxOffset = math.max(0, #rows - ROWS)
	local offset = math.max(0, math.min(maxOffset, (self.offset or 0) + step))
	if offset ~= self.offset then
		self.offset = offset
		self:Render()
	end
end

function Scan:ScanAH()
	local Scanner = CS.CP and CS.CP.Scanner
	if not Scanner then return end
	if not Scanner.ahOpen then
		CS:Print("open the Auction House first.")
		return
	end
	Scanner:Start()
	self:Refresh()
end

-- Item's auction page when the AH is open (same hand-off the shopping list uses), otherwise the link.
function Scan:OpenItem(itemID)
	if IsShiftKeyDown and IsShiftKeyDown() then
		local ok, _, link = pcall(C_Item.GetItemInfo, itemID)
		if ok and link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
		return
	end
	local ah = AuctionHouseFrame
	if not (ah and ah:IsShown() and C_AuctionHouse and C_AuctionHouse.MakeItemKey) then
		CS:Print("%s: open the Auction House to jump to its listings.", CS:ItemName(itemID))
		return false
	end
	local Scanner = CS.CP.Scanner
	local keys = Scanner and Scanner.keysByItem
	if not (keys and next(keys)) then
		-- the list comes from a scan of an earlier session: no listing keys to open yet
		CS:Print("press Scan AH first: this list is from an earlier scan, so its listings cannot be opened yet.")
		return false
	end
	-- the listed (suffixed) key of the cheapest row: gear is listed as "X of the Y", and the plain item
	-- key shows "No items found". No key in this session's scan = no longer listed.
	local key = Scanner:GetBrowseKey(itemID)
	local ok = key and pcall(CS.SelectAuctionItem, CS, key, Scanner:GetMin(itemID) or 0, Scanner:GetQuantity(itemID) or 1)
	if ok then
		-- opened from the Disenchant list: what gets bought now is bought to disenchant (DE macro queue)
		if self.mode == "de" then self.intent[itemID] = time() end
		return true
	end
	self:RemoveItem(itemID)
	CS:Print("%s is no longer on the Auction House; removed from the list.", CS:ItemName(itemID))
	return false
end

-- Items opened from the Disenchant list (itemID -> time). A purchase of one within INTENT_TTL counts as
-- bought to disenchant: the DE macro then works through it (Planner:AddDEBuy).
local INTENT_TTL = 30 * 60
Scan.intent = {}
if CS.CP then
	CS.CP:On("PURCHASE_RECORDED", function(itemID, qty)
		local t = itemID and Scan.intent[itemID]
		if t and time() - t <= INTENT_TTL and CS.Planner and CS.Planner.AddDEBuy then
			CS.Planner:AddDEBuy(itemID, qty or 1)
		end
	end)
end

-- Items taken off the list this scan (sold out / no listing). Cleared by the next full scan.
Scan.removed = {}
function Scan:RemoveItem(itemID)
	self.removed[itemID] = true
	self:Refresh()
end

function Scan:BuildMinMenu(root)
	root:CreateTitle(Scan.mode == "vendor" and "Minimum profit per unit" or "Minimum profit per item")
	for _, v in ipairs(self:Presets()) do
		root:CreateRadio(CS:Money(v), function() return Scan:GetMinProfit() == v end, function() Scan:SetMinProfit(v) end)
	end
	root:CreateDivider()
	root:CreateButton(Muted(Scan.mode == "vendor" and "Other: /cs scan vendor min 25c" or "Other: /cs scan min 1g50s"), function() end)
end

-- Fallback picker (no dropdown template): the same menu as a context menu on the button.
function Scan:OpenMinMenu(owner)
	local current = self:GetMinProfit()
	local presets = self:Presets()
	if CS:ToggleContextMenu(owner, function(_, root) Scan:BuildMinMenu(root) end) then return end
	-- fallback: step through the presets
	local nextV = presets[1]
	for i, v in ipairs(presets) do
		if v == current then nextV = presets[i + 1] or presets[1] break end
	end
	self:SetMinProfit(nextV)
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

function Scan:Refresh()
	local f = self.frame
	if not f or not f:IsShown() then return end
	self.rows, self.stats = self:Compute()
	if next(self.removed) then
		local kept = {}
		for _, r in ipairs(self.rows) do if not self.removed[r.itemID] then kept[#kept + 1] = r end end
		self.rows = kept
	end
	self.offset = math.max(0, math.min(self.offset or 0, math.max(0, #self.rows - ROWS)))
	self:Render()
end

function Scan:Render()
	local f = self.frame
	if not f or not f:IsShown() then return end
	local rows, st = self.rows or {}, self.stats or {}
	local Scanner = CS.CP and CS.CP.Scanner
	local vendor = self.mode == "vendor"

	-- the selected mode's tab is highlighted the AH way; panel-button fallback: the selected one is disabled
	if f.csPanelTabs and PanelTemplates_SetTab then
		pcall(PanelTemplates_SetTab, f, vendor and 2 or 1)
	else
		if vendor then f.ModeDE:Enable() f.ModeVendor:Disable() else f.ModeDE:Disable() f.ModeVendor:Enable() end
	end
	ApplyColumns(f, vendor and VENDOR_COLS or DE_COLS)
	f.Columns[3]:SetLabel(vendor and "Vendor" or "DE value")
	local minText = "Min profit: " .. CS:MoneyShort(st.minProfit or self:GetMinProfit())
	if f.MinButton.csDropdown then
		if f.MinButton.csLast ~= minText then
			f.MinButton.csLast = minText
			if f.MinButton.GenerateMenu then pcall(f.MinButton.GenerateMenu, f.MinButton) end
			if not f.MinButton.SetSelectionTranslator and f.MinButton.OverrideText then pcall(f.MinButton.OverrideText, f.MinButton, minText) end
		end
	else
		f.MinButton:SetText(minText)
	end
	if Scanner and Scanner.running then
		f.ScanButton:SetText("Scanning...")
		f.ScanButton:Disable()
	else
		f.ScanButton:SetText("Scan AH")
		if Scanner and Scanner.ahOpen then f.ScanButton:Enable() else f.ScanButton:Disable() end
	end

	if (st.lastScan or 0) <= 0 then
		f.Status:SetText(Muted("No AH scan yet"))
	else
		local parts = { Body(string.format("%d items", st.scanned or 0)),
			Body(vendor and string.format("%d with a vendor price", st.vendorable or 0) or string.format("%d disenchantable", st.disenchantable or 0)) }
		if (st.loading or 0) > 0 then table.insert(parts, Muted(string.format("%d loading", st.loading))) end
		f.Status:SetText(Muted("Scanned " .. CS:Age(time() - st.lastScan) .. DOT) .. table.concat(parts, Muted(DOT)))
	end

	local offset = self.offset or 0
	for i, row in ipairs(f.Rows) do
		local r = rows[offset + i]
		row.csRow = r
		if r then
			local icon = C_Item and C_Item.GetItemIconByID and select(2, pcall(C_Item.GetItemIconByID, r.itemID))
			if type(icon) == "number" or type(icon) == "string" then row.Icon:SetTexture(icon) else row.Icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark") end
			if vendor then
				row.Name:SetText(QualityColor(r.quality, r.name or ("item " .. r.itemID)))
				row.Price:SetText(Body(CS:MoneyShort(r.price)))
				row.Value:SetText(Body(CS:MoneyShort(r.sell)))
				row.Net:SetText(CS:Color(C.profit, CS:MoneyShort(r.net, { sign = true })))
				row.Margin:SetText(r.margin and Muted(string.format("%d%%", math.floor(r.margin * 100 + 0.5))) or Gray(DASH))
				row.Qty:SetText(Muted(tostring(r.qty or 0)))
				if r.units then
					row.Data:SetText(CS:Color(C.profit, string.format("%d%s = %s", r.units, r.ladderFull and "" or "+", CS:MoneyShort(r.total, { sign = true }))))
				else
					row.Data:SetText(Gray("lowest only"))
				end
			else
				row.Name:SetText(QualityColor(r.quality, r.name or ("item " .. r.itemID)) .. Muted(string.format("  %d %s", r.ilvl or 0, r.weapon and "wpn" or "arm")))
				row.Price:SetText(Body(CS:MoneyShort(r.price)))
				row.Value:SetText(Body(CS:MoneyShort(r.value - r.cut)))
				row.Net:SetText(CS:Color(r.net >= 0 and C.profit or C.loss, CS:MoneyShort(r.net, { sign = true })))
				row.Margin:SetText(r.margin and Muted(string.format("%d%%", math.floor(r.margin * 100 + 0.5))) or Gray(DASH))
				row.Qty:SetText(Muted(tostring(r.qty or 0)))
				-- no Yields column: an estimate-only item is marked after its name (the tooltip has the yields)
				if r.estimateOnly then row.Name:SetText(row.Name:GetText() .. Gray("  estimate")) end
			end
			row:Show()
		else
			row:Hide()
		end
	end

	-- prices from an earlier session's scan: no listing keys this session -> the overlay asks for a rescan
	local keys = Scanner and Scanner.keysByItem
	local stale = (st.lastScan or 0) > 0 and not (keys and next(keys)) and #rows > 0
	f.Stale:SetShown(stale)
	if stale then
		local scanning = Scanner and Scanner.running
		local ahOpen = Scanner and Scanner.ahOpen
		f.Stale.Text:SetText(scanning and "Scanning the Auction House..."
			or ahOpen and string.format("These prices are from a scan %s, before this session. Scan again to open the listings from here.", CS:Age(time() - st.lastScan))
			or "These prices are from an earlier session. Open the Auction House and scan again to open the listings from here.")
		if ahOpen and not scanning then f.Stale.Button:Enable() else f.Stale.Button:Disable() end
	end

	if #rows == 0 then
		if (st.lastScan or 0) <= 0 then
			f.Empty:SetText(Muted(vendor and "Open the Auction House and press Scan AH. This view keeps the items listed below what a vendor pays for them."
				or "Open the Auction House and press Scan AH. The scan lists every item; this window keeps the armor and weapons whose materials are worth more than the item."))
		elseif (vendor and (st.vendorable or 0) == 0 or (not vendor and (st.disenchantable or 0) == 0)) and (st.loading or 0) > 0 then
			f.Empty:SetText(Muted("Item data is still loading, the list fills in as it arrives."))
		elseif vendor then
			f.Empty:SetText(Muted(string.format("Nothing listed more than %s under its vendor price among %d items. Lower the minimum, or nobody is underpricing right now.",
				CS:Money(st.minProfit or 0), st.vendorable or 0)))
		else
			f.Empty:SetText(Muted(string.format("Nothing above %s profit among %d disenchantable items (%d priced). Lower the minimum, or the AH is fairly priced right now.",
				CS:Money(st.minProfit or 0), st.disenchantable or 0, st.priced or 0)))
		end
		f.Empty:Show()
	else
		f.Empty:Hide()
	end

	if vendor then
		f.Foot:SetText("Net = vendor price " .. DASH .. " lowest buyout, per unit. Below vendor: units under it (+ = beyond the scanned depth). Click: open in the AH.")
	else
		f.Foot:SetText("Net = mats " .. DASH .. " AH cut " .. DASH .. " buyout. Grey 'estimate' = table values only: disenchant one first. Click: open in the AH.")
	end
	if #rows > ROWS then
		f.Page:SetText(Muted(string.format("%d-%d of %d", offset + 1, math.min(#rows, offset + ROWS), #rows)))
	else
		f.Page:SetText(Muted(string.format("%d above %s", #rows, CS:MoneyShort(st.minProfit or 0))))
	end
end

-- Chat version: /cs scan list [n]
function Scan:PrintTop(n)
	local rows, st = self:Compute()
	if (st.lastScan or 0) <= 0 then
		CS:Print("no AH scan yet. Open the Auction House and run Scan AH (or the CraftProfit Scan button).")
		return
	end
	n = math.max(1, math.min(tonumber(n) or 10, #rows))
	if self.mode == "vendor" then
		CS:Print("vendor scan: %d of %d items listed more than %s under vendor price (scanned %s%s)", #rows, st.vendorable or 0,
			CS:Money(st.minProfit or 0), CS:Age(time() - st.lastScan), (st.loading or 0) > 0 and string.format(", %d still loading", st.loading) or "")
		for i = 1, n do
			local r = rows[i]
			CS:Print("%2d. %s  buy %s, vendor %s, %s per unit (%+d%%)  %s", i, QualityColor(r.quality, r.name or tostring(r.itemID)),
				CS:Money(r.price), CS:Money(r.sell), CS:Color(C.profit, CS:Money(r.net, { sign = true })), math.floor((r.margin or 0) * 100 + 0.5),
				r.units and string.format("%d%s units below vendor = %s", r.units, r.ladderFull and "" or "+", CS:Money(r.total, { sign = true })) or string.format("x%d listed, lowest only", r.qty or 0))
		end
		return
	end
	CS:Print("disenchant scan: %d of %d disenchantable items above %s (scanned %s%s)", #rows, st.disenchantable or 0,
		CS:Money(st.minProfit or 0), CS:Age(time() - st.lastScan), (st.loading or 0) > 0 and string.format(", %d still loading", st.loading) or "")
	for i = 1, n do
		local r = rows[i]
		CS:Print("%2d. %s  buy %s, mats %s, %s (%s)  x%d  %s", i, QualityColor(r.quality, r.name or tostring(r.itemID)),
			CS:Money(r.price), CS:Money(r.value - r.cut), CS:Color(r.net >= 0 and C.profit or C.loss, CS:Money(r.net, { sign = true })),
			r.margin and string.format("%+d%%", math.floor(r.margin * 100 + 0.5)) or "?", r.qty or 0, r.summary or "")
	end
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

local pending = false
local function RefreshSoon()
	if not (Scan.frame and Scan.frame:IsShown()) then return end
	if pending then return end
	pending = true
	local function go() pending = false Scan:Refresh() end
	if C_Timer and C_Timer.After then C_Timer.After(0.3, go) else go() end
end

CS:On("ITEM_LOADED", RefreshSoon)
CS:On("DE_RECORDED", RefreshSoon)
CS:On("SETTINGS_CHANGED", function(key)
	if key == nil or key == "scanMinProfit" or key == "scanVendorMinProfit" or key == "priorWeight" then RefreshSoon() end
end)
if CS.CP then CS.CP:On("LADDER_UPDATED", RefreshSoon) end
if CS.CP then
	CS.CP:On("PRICES_UPDATED", RefreshSoon)
	CS.CP:On("SCAN_STARTED", RefreshSoon)
	CS.CP:On("SCAN_FINISHED", function() Scan.removed = {} RefreshSoon() end)
	CS.CP:On("SETTINGS_CHANGED", RefreshSoon)
end
CS:RegisterEvent("AUCTION_HOUSE_SHOW", RefreshSoon)
CS:RegisterEvent("AUCTION_HOUSE_CLOSED", RefreshSoon)

-- Slash: /cs scan [de|vendor] [min <money> | list [n]]
function Scan:Slash(rest)
	local sub, arg = (rest or ""):match("^(%S*)%s*(.*)$")
	sub = (sub or ""):lower()
	local switched = false
	if sub == "de" or sub == "vendor" then
		self.mode = sub
		self.offset = 0
		switched = true
		sub, arg = (arg or ""):match("^(%S*)%s*(.*)$")
		sub = (sub or ""):lower()
	end
	local label = self.mode == "vendor" and "vendor scan" or "disenchant scan"
	if sub == "" then
		self:Open()
	elseif sub == "min" then
		local copper = self.ParseMoney(arg)
		if copper then
			self:SetMinProfit(copper)
			CS:Print("%s: minimum profit set to %s", label, CS:Money(copper))
		else
			CS:Print("%s: minimum profit is %s. Usage: /cs scan %smin 1g50s (or 50s, 25c, 150 = copper)", label, CS:Money(self:GetMinProfit()),
				self.mode == "vendor" and "vendor " or "")
		end
	elseif sub == "list" or sub == "top" then
		self:PrintTop(tonumber(arg) or 10)
	else
		CS:Print("usage: /cs scan [de|vendor]  |  /cs scan [de|vendor] min <money>  |  /cs scan [de|vendor] list [n]")
	end
	if switched then self:Refresh() end
end
