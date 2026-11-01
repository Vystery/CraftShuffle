-- CraftShuffle :: ProfessionUI
-- "Shuffle" mode inside the default profession window, built on CraftProfit's hooks:
--   * Sell / Shuffle toggle pills next to the Filter button above the recipe list
--   * in Shuffle mode CraftProfit's row tags and sort use the shuffle net (via CraftProfit.UI:SetOverride)
--   * the "Profit - Auction House" panel is replaced by "Shuffle - Disenchant Value"
--   * Filter dropdown gets a CraftShuffle section (mode checkbox, open planner)

local _, CS = ...
local UI = {}
CS.UI = UI

local C = CS.COLORS

local function Muted(text) return CS:Color(C.muted, text) end
local function Body(text) return CS:Color(C.body, text) end
local function Gray(text) return CS:Color(C.gray, text) end
local function Label(text) return CS:Color(C.label, text) end
local DASH = "\226\128\148"

---------------------------------------------------------------------------
-- Mode
---------------------------------------------------------------------------

UI.override = {
	key = "shuffle",
	GetEco = function(recipeID) return CS.Calc:Get(recipeID) end,
	ReagentCost = function(itemID) return CS.Calc:ReagentCost(itemID) end,
	UpdateDetail = function(form, recipeInfo) UI:UpdatePanel(form, recipeInfo) end,
}

function UI:GetMode()
	return CS.settings.mode == "shuffle" and "shuffle" or "sell"
end

-- Applies the saved mode to CraftProfit (called at setup and whenever the mode changes).
function UI:ApplyMode()
	local CP = CS.CP
	if not (CP and CP.UI and CP.UI.SetOverride) then return end
	local mode = self:GetMode()
	if mode == "shuffle" and not CS:ShuffleAllowed() then
		mode = "sell"
	end
	CP.UI:SetOverride(mode == "shuffle" and self.override or nil)
	self:UpdateToggle()
end

function UI:SetMode(mode, verbose)
	mode = mode == "shuffle" and "shuffle" or "sell"
	if mode == "shuffle" and not CS:ShuffleAllowed() then
		CS:Print("Shuffle mode needs Enchanting on this character (or /cs enchanting off to plan for an alt).")
		mode = "sell"
	end
	if CS.settings.mode ~= mode then
		CS.settings.mode = mode
		CS:Fire("MODE_CHANGED", mode)
	end
	self:ApplyMode()
	if verbose then CS:Print("profession window shows %s %s", mode, mode == "shuffle" and "(disenchant value)" or "(sale value)") end
end

---------------------------------------------------------------------------
-- Sell / Shuffle toggle
---------------------------------------------------------------------------

local PILL_H = 18
local PILL_GAP = 2

local function StylePill(pill, active, disabled)
	if pill.SetBackdropColor then
		if active then
			pill:SetBackdropColor(0.25, 0.19, 0.10, 1)
			pill:SetBackdropBorderColor(1, 0.82, 0, 1)
		else
			pill:SetBackdropColor(0.03, 0.02, 0.02, 1)
			pill:SetBackdropBorderColor(0.29, 0.23, 0.15, 1)
		end
	end
	local hex = active and C.gold or (disabled and C.gray or C.muted)
	pill.Text:SetText(CS:Color(hex, pill.label))
end

local function CreatePill(parent, label, width, onClick)
	local template = BackdropTemplateMixin and "BackdropTemplate" or nil
	local pill = CreateFrame("Button", nil, parent, template)
	pill:SetSize(width, PILL_H)
	pill.label = label
	if pill.SetBackdrop then
		pill:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8x8",
			edgeFile = "Interface\\Buttons\\WHITE8x8",
			edgeSize = 1,
		})
	end
	pill.Text = pill:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	pill.Text:SetPoint("CENTER", 0, 0)
	pill:SetScript("OnClick", onClick)
	pill:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("CraftShuffle")
		if self.tooltip then GameTooltip:AddLine(self.tooltip, 1, 1, 1, true) end
		if self.disabledReason then GameTooltip:AddLine(self.disabledReason, 1, 0.4, 0.4, true) end
		GameTooltip:Show()
	end)
	pill:SetScript("OnLeave", GameTooltip_Hide)
	return pill
end

local function FilterButton(list)
	return list and (list.FilterDropdown or list.FilterButton or list.FilterDropDown) or nil
end

-- Blizzard sizes the search box to fill the header; give some of it to the pills.
local function ShrinkSearchBox(toggle)
	local list = toggle:GetParent()
	local search = list and list.SearchBox
	local filter = FilterButton(list)
	if not (search and filter and type(search.GetLeft) == "function") then return end
	local searchLeft, filterLeft = search:GetLeft(), filter:GetLeft()
	if not searchLeft or not filterLeft then return end
	local wanted = filterLeft - toggle:GetWidth() - 12 - searchLeft
	if wanted < 70 then wanted = 70 end
	if not toggle.origSearchWidth then toggle.origSearchWidth = search:GetWidth() end
	if toggle:IsShown() then
		if (search:GetWidth() or 0) > wanted + 0.5 then search:SetWidth(wanted) end
	elseif toggle.origSearchWidth and math.abs((search:GetWidth() or 0) - toggle.origSearchWidth) > 0.5 then
		search:SetWidth(toggle.origSearchWidth)
	end
end

local function CreateToggle(list)
	local filter = FilterButton(list)
	local toggle = CreateFrame("Frame", "CraftShuffleModeToggle", list)
	toggle:SetSize(34 + PILL_GAP + 48, PILL_H)
	if filter then
		toggle:SetPoint("RIGHT", filter, "LEFT", -6, 0)
	else
		toggle:SetPoint("TOPRIGHT", list, "TOPRIGHT", -8, -8)
	end
	toggle:SetFrameLevel((list:GetFrameLevel() or 1) + 10)

	toggle.Sell = CreatePill(toggle, "Sell", 34, function() UI:SetMode("sell") end)
	toggle.Sell:SetPoint("LEFT", toggle, "LEFT", 0, 0)
	toggle.Sell.tooltip = "Sale value: what CraftProfit shows. Craft cost versus the auction price of the crafted item."

	toggle.Shuffle = CreatePill(toggle, "Shuffle", 48, function() UI:SetMode("shuffle") end)
	toggle.Shuffle:SetPoint("LEFT", toggle.Sell, "RIGHT", PILL_GAP, 0)
	toggle.Shuffle.tooltip = "Shuffle value: craft cost versus the expected value of the enchanting materials the item disenchants into (minus the AH cut)."

	if type(list.HookScript) == "function" then
		list:HookScript("OnShow", function() ShrinkSearchBox(toggle) end)
		list:HookScript("OnSizeChanged", function() ShrinkSearchBox(toggle) end)
	end
	return toggle
end

function UI:UpdateToggle()
	local t = self.toggle
	if not t then return end
	if not CS.settings.showToggle then
		t:Hide()
		ShrinkSearchBox(t)
		return
	end
	t:Show()
	local mode = self:GetMode()
	local allowed = CS:ShuffleAllowed()
	StylePill(t.Sell, mode == "sell", false)
	StylePill(t.Shuffle, mode == "shuffle", not allowed)
	t.Shuffle.disabledReason = (not allowed) and "This character does not know Enchanting. /cs enchanting off plans for a disenchanting alt." or nil
	if C_Timer and C_Timer.After then
		C_Timer.After(0, function() ShrinkSearchBox(t) end)
	else
		ShrinkSearchBox(t)
	end
end

---------------------------------------------------------------------------
-- "Shuffle - Disenchant Value" panel in the recipe details
---------------------------------------------------------------------------

-- Same geometry as CraftProfit's panel so the two modes swap in place.
local PANEL_MAX_WIDTH = 340
local PANEL_HEIGHT = 164
local PANEL_INSET = 28
local PANEL_BOTTOM = 48
local PANEL_GAP = 10
local ROW_H = 15
local REAGENT_STRIDE = 4
local MAX_ROWS = 7

local function BasicSlots(form)
	local CP = CS.CP
	if CP.UI and CP.UI.BasicSlots then return CP.UI.BasicSlots(form) end
	local basic = (Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic) or 0
	local slots = form.reagentSlots and form.reagentSlots[basic]
	local list = {}
	if type(slots) == "table" then
		for _, s in ipairs(slots) do table.insert(list, s) end
	end
	return list
end

local function PanelRightInset(form)
	local formWidth = form:GetWidth() or 0
	if formWidth > 200 then
		return math.max(PANEL_INSET, formWidth - PANEL_INSET - PANEL_MAX_WIDTH)
	end
	return PANEL_INSET
end

local function AnchorPanel(p, form)
	local slots = BasicSlots(form)
	local anchor
	if #slots > 0 then
		anchor = slots[math.min(#slots, REAGENT_STRIDE)]
		if anchor and type(anchor.IsShown) == "function" and not anchor:IsShown() then anchor = nil end
	end
	p:ClearAllPoints()
	local rightInset = PanelRightInset(form)
	p.csAnchor = anchor
	if anchor then
		p.csStretch = true
		p:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -PANEL_GAP)
		p:SetPoint("BOTTOMRIGHT", form, "BOTTOMRIGHT", -rightInset, PANEL_BOTTOM)
	else
		p.csStretch = false
		p:SetPoint("BOTTOMLEFT", form, "BOTTOMLEFT", PANEL_INSET, PANEL_BOTTOM)
		p:SetPoint("BOTTOMRIGHT", form, "BOTTOMRIGHT", -rightInset, PANEL_BOTTOM)
		p:SetHeight(PANEL_HEIGHT)
	end
end

local function CapPanelHeight(p)
	if not p.csStretch or not p.csAnchor then return false end
	local h = p:GetHeight() or 0
	if h <= PANEL_HEIGHT + 0.5 then return false end
	local width = p:GetWidth() or PANEL_MAX_WIDTH
	p.csStretch = false
	p:ClearAllPoints()
	p:SetPoint("TOPLEFT", p.csAnchor, "BOTTOMLEFT", 0, -PANEL_GAP)
	p:SetSize(width, PANEL_HEIGHT)
	return true
end

-- Decide which rows fit. Rows are built in UpdatePanel as { label, value, kind }; the panel keeps
-- cost / mat value / cut first and adds disenchant lines as room allows.
local function LayoutPanel(p)
	if CapPanelHeight(p) then return end
	local h = p:GetHeight() or PANEL_HEIGHT
	local fixed = 30 + 8 + 18 + 6          -- title, divider gap, net row, bottom pad
	local avail = h - fixed
	-- The footer (yield source + Plan button) needs 20px; keep two stat rows ahead of it.
	local showFooter = avail >= 2 * ROW_H + 20
	local nRows = math.floor((avail - (showFooter and 20 or 0)) / ROW_H)
	if nRows < 0 then nRows = 0 end

	local rows = p.csRows or {}
	local core, yields = {}, {}
	for _, r in ipairs(rows) do
		if r.kind == "yield" then table.insert(yields, r) else table.insert(core, r) end
	end
	local nCore = math.min(#core, nRows)
	local nYield = math.max(0, math.min(#yields, nRows - nCore))

	-- Display order: cost, yields, mat value, cut (the handoff order) - within what fits.
	local shown = {}
	for i, r in ipairs(core) do
		if i <= nCore then
			table.insert(shown, r)
			if r.kind == "cost" then
				for j = 1, nYield do table.insert(shown, yields[j]) end
			end
		end
	end
	if nCore == 0 then
		for j = 1, nYield do table.insert(shown, yields[j]) end
	end

	for i, pair in ipairs(p.Rows) do
		local r = shown[i]
		local y = -30 - (i - 1) * ROW_H
		pair.label:ClearAllPoints()
		pair.label:SetPoint("TOPLEFT", r and r.kind == "yield" and 20 or 10, y)
		pair.value:ClearAllPoints()
		pair.value:SetPoint("TOPRIGHT", -10, y)
		if r then
			pair.label:SetText(r.label)
			pair.value:SetText(r.value)
			pair.label:Show()
			pair.value:Show()
		else
			pair.label:Hide()
			pair.value:Hide()
		end
	end

	local y = -30 - #shown * ROW_H + 3
	p.Divider:ClearAllPoints()
	p.Divider:SetPoint("TOPLEFT", 10, y)
	p.Divider:SetPoint("TOPRIGHT", -10, y)
	p.Divider:SetShown(#shown > 0)
	p.NetLabel:ClearAllPoints()
	p.NetLabel:SetPoint("TOPLEFT", 10, y - 7)
	p.Net:ClearAllPoints()
	p.Net:SetPoint("TOPRIGHT", -10, y - 5)

	p.Foot:SetShown(showFooter)
	p.PlanButton:SetShown(showFooter)
	p.csRowsShown = #shown
end

local function CreatePanel(form)
	local template = BackdropTemplateMixin and "BackdropTemplate" or nil
	local p = CreateFrame("Frame", "CraftShufflePanel", form, template)
	p:SetSize(PANEL_MAX_WIDTH, PANEL_HEIGHT)
	p:SetFrameLevel(form:GetFrameLevel() + 5)
	if type(form.HookScript) == "function" then
		form:HookScript("OnSizeChanged", function(f)
			if f.csPanel and f.csPanel:IsShown() then AnchorPanel(f.csPanel, f) end
		end)
	end
	p:SetScript("OnSizeChanged", function(self) LayoutPanel(self) end)

	if p.SetBackdrop then
		p:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		p:SetBackdropColor(0.07, 0.05, 0.03, 0.92)
		p:SetBackdropBorderColor(0.42, 0.35, 0.24, 1)
	end

	p.Title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	p.Title:SetPoint("TOPLEFT", 10, -9)
	p.Title:SetText("Shuffle " .. DASH .. " Disenchant Value")

	p.Age = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	p.Age:SetPoint("LEFT", p.Title, "RIGHT", 8, -1)
	p.Age:SetPoint("RIGHT", p, "RIGHT", -10, 0)
	p.Age:SetJustifyH("RIGHT")
	if p.Age.SetWordWrap then p.Age:SetWordWrap(false) end
	if p.Age.SetMaxLines then p.Age:SetMaxLines(1) end

	p.Rows = {}
	for i = 1, MAX_ROWS do
		local l = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		l:SetJustifyH("LEFT")
		if l.SetWordWrap then l:SetWordWrap(false) end
		local v = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		v:SetJustifyH("RIGHT")
		p.Rows[i] = { label = l, value = v }
	end

	p.Divider = p:CreateTexture(nil, "ARTWORK")
	p.Divider:SetColorTexture(0.23, 0.18, 0.12, 1)
	p.Divider:SetHeight(1)

	p.NetLabel = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	p.NetLabel:SetText(Label("Net shuffle profit"))
	p.Net = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightMedium")
	p.Net:SetJustifyH("RIGHT")

	p.Foot = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	p.Foot:SetPoint("BOTTOMLEFT", 10, 6)
	p.Foot:SetJustifyH("LEFT")
	if p.Foot.SetWordWrap then p.Foot:SetWordWrap(false) end

	p.PlanButton = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
	p.PlanButton:SetSize(64, 18)
	p.PlanButton:SetPoint("BOTTOMRIGHT", -6, 4)
	p.PlanButton:SetText("Plan...")
	p.PlanButton:SetScript("OnClick", function()
		local eco = p.csEco
		local session = CS.Planner.session
		if session and eco and eco.recipeID == session.recipeID then
			CS.Planner:OpenSession() -- this recipe is the one being shuffled
		else
			CS.Planner:Open(eco and eco.recipeID or nil)
		end
	end)
	p.Foot:SetPoint("RIGHT", p.PlanButton, "LEFT", -4, 0)

	p:EnableMouse(true)
	p:SetScript("OnEnter", function(self) UI:ShowPanelTooltip(self) end)
	p:SetScript("OnLeave", GameTooltip_Hide)

	LayoutPanel(p)
	return p
end

local STATUS_TEXT = {
	["no-output"] = "no item output",
	["loading"] = "item data loading...",
	["not-disenchantable"] = "cannot be disenchanted",
	["unknown"] = "no yield data for this item level",
	["no-mat-prices"] = "no prices for the materials",
	["no-cost"] = "reagents unpriced",
	["error"] = "error",
}
UI.STATUS_TEXT = STATUS_TEXT

function UI:UpdatePanel(form, recipeInfo)
	if not form.csPanel then form.csPanel = CreatePanel(form) end
	local p = form.csPanel
	if not recipeInfo or not recipeInfo.recipeID then
		p:Hide()
		return
	end
	local eco = CS.Calc:Get(recipeInfo.recipeID)
	p.csEco = eco
	AnchorPanel(p, form)
	p:Show()
	local session = CS.Planner and CS.Planner.session
	p.PlanButton:SetText((session and eco.recipeID == session.recipeID) and "Session" or "Plan...")

	local rows = {}
	local costText
	if eco.costComplete and #eco.reagents > 0 then
		costText = Body(CS:Money(eco.cost))
	elseif (eco.cost or 0) > 0 then
		costText = Body(CS:Money(eco.cost)) .. Muted(string.format(" +%d unpriced", eco.base and eco.base.missing or 0))
	else
		costText = Gray(DASH)
	end
	local crafted = eco.base and eco.base.crafted or 0
	table.insert(rows, { kind = "cost", label = Label(crafted > 0 and string.format("Craft cost (%d crafted)", crafted) or "Craft cost"), value = costText })

	for _, y in ipairs(eco.yields or {}) do
		local qty = CS:FormatYieldQty(y, DASH)
		local label = Body(qty .. " " .. CS:ItemName(y.itemID)) .. Muted(string.format(" %d%%", math.floor(y.chance * 100 + 0.5)))
		local value = y.value and Body(CS:Money(y.value * (eco.quantity or 1), { compact = true })) or Gray("no price")
		table.insert(rows, { kind = "yield", label = label, value = value })
	end

	local matText = eco.matValue and eco.matValue > 0 and Body(CS:Money(eco.matValue)) or Gray(DASH)
	if (eco.missingPrices or 0) > 0 and eco.matValue and eco.matValue > 0 then
		matText = matText .. Muted(string.format(" +%d unpriced", eco.missingPrices))
	end
	table.insert(rows, { kind = "mat", label = Label("Expected mat value"), value = matText })
	table.insert(rows, { kind = "cut", label = Label(string.format("AH cut (%d%%)", math.floor((CS.CP.settings.ahCut or 0) * 100 + 0.5))),
		value = eco.cut and eco.cut > 0 and Label("-" .. CS:Money(eco.cut)) or Gray(DASH) })
	p.csRows = rows

	if eco.net then
		local hex = eco.net >= 0 and C.profit or C.loss
		local margin = CS:Margin(eco.margin)
		p.Net:SetText(CS:Color(hex, CS:Money(eco.net, { sign = true }) .. (margin and ("  (" .. margin .. ")") or "")))
	else
		p.Net:SetText(Gray(STATUS_TEXT[eco.status] or DASH))
	end

	local ageText = eco.age and ("scanned " .. CS:Age(eco.age)) or "no price data"
	local source = CS.CP.Sources:Resolve()
	if source and source.key ~= "craftprofit" then
		ageText = source.name .. " \194\183 " .. (eco.age and CS:Age(eco.age) or "no data")
	end
	p.Age:SetText(ageText)

	local foot
	if eco.de then
		if eco.de.estimateOnly then
			foot = "Estimated yields"
		else
			foot = "Yields from " .. eco.de.summary
		end
	else
		foot = STATUS_TEXT[eco.status] or ""
	end
	if CS:HasEnchanting() == false then foot = foot .. " \194\183 no Enchanting here" end
	p.Foot:SetText(foot)

	LayoutPanel(p)
end

function UI:ShowPanelTooltip(p)
	local eco = p.csEco
	if not eco then return end
	GameTooltip:SetOwner(p, "ANCHOR_RIGHT")
	GameTooltip:AddLine("CraftShuffle")
	GameTooltip:AddLine("Buy reagents, craft, disenchant, sell the materials.", 0.8, 0.8, 0.8, true)
	GameTooltip:AddLine("Source: " .. CS.CP:GetSourceName(), 1, 1, 1)
	if eco.quantity and eco.quantity ~= 1 then
		GameTooltip:AddLine(string.format("Output per craft: %g", eco.quantity), 1, 1, 1)
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Reagents", 1, 0.82, 0)
	for _, r in ipairs(eco.reagents or {}) do
		local right
		if not r.unit then
			right = "no price"
		elseif r.kind == "craft" then
			right = CS:Color(C.gold, CS:Money(r.unit) .. " crafted") .. (r.buyUnit and (" (buy " .. CS:Money(r.buyUnit) .. ")") or "")
		else
			right = CS:Money(r.unit) .. (r.kind == "vendor" and " (vendor)" or "")
		end
		GameTooltip:AddDoubleLine(string.format("%dx %s", r.qty or 1, CS:ItemName(r.itemID)), right, 0.8, 0.8, 0.8, 1, 1, 1)
	end
	GameTooltip:AddLine(" ")
	if eco.de then
		GameTooltip:AddLine("Disenchants into (" .. eco.de.summary .. ")", 1, 0.82, 0)
		for _, y in ipairs(eco.yields or {}) do
			GameTooltip:AddDoubleLine(string.format("%s %s  %d%%", CS:FormatYieldQty(y), CS:ItemName(y.itemID),
				math.floor(y.chance * 100 + 0.5)),
				y.unit and (CS:Money(y.unit) .. " ea") or "no price", 0.8, 0.8, 0.8, 1, 1, 1)
		end
		if eco.de.bracketKey then
			GameTooltip:AddLine("Band: " .. CS.DEData:BracketLabel(eco.de.bracketKey), 0.6, 0.6, 0.6)
		end
		if eco.de.estimateOnly then
			GameTooltip:AddLine("Built-in estimate. Disenchant a few and the numbers switch to your real yields.", 0.6, 0.6, 0.6, true)
		end
	else
		GameTooltip:AddLine(STATUS_TEXT[eco.status] or eco.status or "", 1, 0.4, 0.4)
	end
	GameTooltip:Show()
end

---------------------------------------------------------------------------
-- Refresh + setup
---------------------------------------------------------------------------

function UI:Refresh()
	local CP = CS.CP
	if CP and CP.UI and CP.UI.override == self.override and CP.UI.RefreshAll then
		CP.UI:RefreshAll()
	end
end

function UI:Setup(page)
	if self.ready then return end
	local CP = CS.CP
	if not (CP and CP.UI and CP.UI.SetOverride) then
		if not self.warned then
			self.warned = true
			CS:Print("this CraftProfit version has no extension hooks; update CraftProfit.")
		end
		return
	end
	page = page or (ProfessionsFrame and ProfessionsFrame.CraftingPage)
	if not page or not page.RecipeList then return end
	self.ready = true

	self.toggle = CreateToggle(page.RecipeList)
	self:ApplyMode()

	if Menu and type(Menu.ModifyMenu) == "function" then
		pcall(Menu.ModifyMenu, "MENU_PROFESSIONS_FILTER", function(_, rootDescription)
			rootDescription:CreateDivider()
			rootDescription:CreateTitle("CraftShuffle")
			rootDescription:CreateCheckbox("Shuffle mode (disenchant value)",
				function() return UI:GetMode() == "shuffle" end,
				function() UI:SetMode(UI:GetMode() == "shuffle" and "sell" or "shuffle") end)
			rootDescription:CreateButton("Open shuffle planner", function() CS.Planner:Open() end)
			rootDescription:CreateButton("Open recipe browser (all professions)", function() CS.Recipes:Open() end)
		end)
	end
	CS:Debug("profession UI ready")
end

local function TrySetup()
	local CP = CS.CP
	if CP and CP.UI and CP.UI.ready then UI:Setup() end
end

if CS.CP then
	CS.CP:On("UI_READY", function(page) UI:Setup(page) end)
	-- Back in Sell mode CraftProfit redraws its own panel; ours has to get out of the way.
	CS.CP:On("OVERRIDE_CHANGED", function(key)
		if key ~= "shuffle" then
			local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
			local form = page and page.SchematicForm
			if form and form.csPanel then form.csPanel:Hide() end
		end
	end)
end
CS:On("READY", TrySetup)
CS:RegisterEvent("TRADE_SKILL_SHOW", TrySetup)

CS:On("SETTINGS_CHANGED", function(key)
	if key == "showToggle" or key == "requireEnchanting" then
		UI:ApplyMode()
	end
	UI:Refresh()
end)
CS:On("DE_RECORDED", function() UI:Refresh() end)
-- the panel's Plan... button reads Session on the recipe being shuffled
CS:On("SESSION_CHANGED", function()
	local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
	local form = page and page.SchematicForm
	local p = form and form.csPanel
	if p and p.csEco then
		local session = CS.Planner.session
		p.PlanButton:SetText((session and p.csEco.recipeID == session.recipeID) and "Session" or "Plan...")
	end
end)
CS:On("ITEM_LOADED", function() UI:Refresh() end)
