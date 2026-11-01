-- CraftShuffle :: Options
-- Settings panel (Options > AddOns > CraftShuffle) built on the retail Settings API.

local _, CS = ...
local Options = {}
CS.Options = Options

local function Proxy(category, key, varType, label, default, onSet)
	return Settings.RegisterProxySetting(category, "CraftShuffle_" .. key, varType, label, default,
		function() return CS.settings[key] end,
		function(value)
			CS.settings[key] = value
			CS.touched[key] = true
			if onSet then onSet(value) end
			CS:Fire("SETTINGS_CHANGED", key, value)
		end)
end

function Options:Setup()
	if self.category then return end
	if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterProxySetting) then
		CS:Debug("Settings API not available; options panel disabled")
		return
	end

	local ok, err = pcall(function()
		local category = Settings.RegisterVerticalLayoutCategory("CraftShuffle")
		self.category = category

		local mode = Proxy(category, "mode", Settings.VarType.String, "Profession window shows", CS.defaults.mode,
			function(value) if CS.UI then CS.UI:ApplyMode() end end)
		Settings.CreateDropdown(category, mode, function()
			local container = Settings.CreateControlTextContainer()
			container:Add("sell", "Sale value (CraftProfit)")
			container:Add("shuffle", "Shuffle value (disenchant materials)")
			return container:GetData()
		end, "Also switchable with the Sell / Shuffle pills above the recipe list.")

		local toggle = Proxy(category, "showToggle", Settings.VarType.Boolean, "Sell / Shuffle pills in the profession window", CS.defaults.showToggle)
		Settings.CreateCheckbox(category, toggle, "Show the mode toggle next to the Filter button. The Filter dropdown has the same switch.")

		local bar = Proxy(category, "sessionBar", Settings.VarType.Boolean, "Floating session bar", CS.defaults.sessionBar)
		Settings.CreateCheckbox(category, bar, "While a shuffle runs and the planner is closed, a small movable bar shows the progress; click it to reopen the Session View. Right-click hides it until you close the planner again (or /cs bar).")

		local scanMin = Proxy(category, "scanMinProfit", Settings.VarType.Number, "Disenchant scan: minimum profit", CS.defaults.scanMinProfit)
		Settings.CreateDropdown(category, scanMin, function()
			local container = Settings.CreateControlTextContainer()
			for _, v in ipairs(CS.DEScan.PRESETS) do container:Add(v, CS:Money(v)) end
			return container:GetData()
		end, "Items whose expected disenchant profit is below this stay out of the scan list (/cs scan). Any amount from chat: /cs scan min 1g50s")

		local vendorMin = Proxy(category, "scanVendorMinProfit", Settings.VarType.Number, "Vendor scan: minimum profit per unit", CS.defaults.scanVendorMinProfit)
		Settings.CreateDropdown(category, vendorMin, function()
			local container = Settings.CreateControlTextContainer()
			container:Add(10, CS:Money(10))
			container:Add(50, CS:Money(50))
			for _, v in ipairs(CS.DEScan.PRESETS) do container:Add(v, CS:Money(v)) end
			return container:GetData()
		end, "Items listed below what a vendor pays, by at least this much per unit (/cs scan vendor). Any amount: /cs scan vendor min 25c")

		local ench = Proxy(category, "requireEnchanting", Settings.VarType.Boolean, "Require Enchanting for Shuffle mode", CS.defaults.requireEnchanting)
		Settings.CreateCheckbox(category, ench, "Turn off to plan shuffles on a crafter whose materials an alt disenchants.")

		local weight = Settings.RegisterProxySetting(category, "CraftShuffle_priorWeight", Settings.VarType.Number,
			"Estimate weight (observations)", CS.defaults.priorWeight,
			function() return CS.settings.priorWeight or CS.defaults.priorWeight end,
			function(value)
				CS.settings.priorWeight = math.max(1, math.floor(tonumber(value) or CS.defaults.priorWeight))
				CS:Fire("SETTINGS_CHANGED", "priorWeight", CS.settings.priorWeight)
			end)
		local sliderOptions = Settings.CreateSliderOptions(1, 50, 1)
		sliderOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
			return string.format("%d", value)
		end)
		Settings.CreateSlider(category, weight, sliderOptions,
			"How many recorded disenchants it takes to count as much as the built-in yield table. Lower trusts your own results sooner.")

		local qty = Settings.RegisterProxySetting(category, "CraftShuffle_qty", Settings.VarType.Number,
			"Planner batch size", CS.defaults.qty,
			function() return CS.settings.qty or CS.defaults.qty end,
			function(value)
				CS.settings.qty = math.max(1, math.floor(tonumber(value) or CS.defaults.qty))
				CS:Fire("SETTINGS_CHANGED", "qty", CS.settings.qty)
			end)
		local qtyOptions = Settings.CreateSliderOptions(1, 200, 1)
		qtyOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
			return string.format("%d", value)
		end)
		Settings.CreateSlider(category, qty, qtyOptions, "Default number of crafts the planner starts with.")

		local tooltip = Proxy(category, "tooltip", Settings.VarType.Boolean, "Disenchant value in item tooltips", CS.defaults.tooltip)
		Settings.CreateCheckbox(category, tooltip, "Add the expected disenchant value (and top materials) to tooltips of green, blue and purple gear.")

		local tooltipCompact = Proxy(category, "tooltipCompact", Settings.VarType.Boolean, "Compact disenchant tooltip", CS.defaults.tooltipCompact)
		Settings.CreateCheckbox(category, tooltipCompact, "One line: the disenchant value and how much more (green) or less (red) it is worth than selling the item to a vendor. Hold Shift to see the materials and chances.")

		local macroBought = Proxy(category, "macroBought", Settings.VarType.Boolean, "DE macro works through gear bought to disenchant", CS.defaults.macroBought,
			function() if CS.Planner then CS.Planner:UpdateMacro(true) end end)
		Settings.CreateCheckbox(category, macroBought, "On (default): after the shuffle item, the macro disenchants gear you bought from the AH Scans' Disenchant list, as many as you bought. It targets exact bag slots and never touches soulbound items, equipment-set items or equipped gear.")

		local macroBags = Proxy(category, "macroBags", Settings.VarType.Boolean, "DE macro works through all greens in the bags", CS.defaults.macroBags,
			function() if CS.Planner then CS.Planner:UpdateMacro(true) end end)
		Settings.CreateCheckbox(category, macroBags, "Off (default). On: also every other unbound disenchantable green in your bags, whether you bought it to disenchant or not.")

		local macroRares = Proxy(category, "macroRares", Settings.VarType.Boolean, "DE macro includes blue and purple items", CS.defaults.macroRares,
			function() if CS.Planner then CS.Planner:UpdateMacro(true) end end)
		Settings.CreateCheckbox(category, macroRares, "Off by default so a rare you meant to keep is never queued. /cs macro list shows what is queued.")

		local deWindow = Proxy(category, "deWindow", Settings.VarType.Boolean, "Disenchanting tally window", CS.defaults.deWindow)
		Settings.CreateCheckbox(category, deWindow, "Open the tally (casts, materials, value, cost, net) on the first disenchant outside a shuffle session. /cs de stats opens it any time.")

		local announce = Proxy(category, "announce", Settings.VarType.Boolean, "Chat line per recorded disenchant", CS.defaults.announce)
		Settings.CreateCheckbox(category, announce, "Print what each disenchant produced and how many are recorded for that item.")

		local debug = Proxy(category, "debug", Settings.VarType.Boolean, "Debug output", CS.defaults.debug)
		Settings.CreateCheckbox(category, debug, "Print diagnostic messages to chat.")

		Settings.RegisterAddOnCategory(category)
	end)

	if not ok then
		self.category = nil
		CS:Debug("options panel failed: %s", tostring(err))
	end
end

function Options:Open()
	if not self.category then self:Setup() end
	if self.category and Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(self.category:GetID())
	else
		CS:Print("options panel unavailable on this client; use /cs commands instead.")
	end
end

CS:RegisterEvent("PLAYER_LOGIN", function() Options:Setup() end)
