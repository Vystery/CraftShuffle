-- CraftShuffle :: Calculator
-- Shuffle economics per recipe: craft cost (from CraftProfit, so vendor prices and crafted intermediates
-- are honoured) versus the expected value of the enchanting materials the output disenchants into.
--
--   craftCost        = CraftProfit's cost per craft
--   expectedMatValue = output quantity x sum over yields (expected qty per disenchant x mat sale price)
--   ahCut            = CraftProfit's AH cut setting x expectedMatValue
--   net              = expectedMatValue - ahCut - craftCost, margin = net / craftCost

local _, CS = ...
local Calc = {}
CS.Calc = Calc

local cache = {}

-- recipeID -> { name, prof } for learned recipes seen this session (planner dropdown, /cs top)
CS.recipes = {}

function Calc:Invalidate()
	wipe(cache)
end

-- Returns the economics table for a recipe. Fields:
--   recipeID, base (CraftProfit eco), outputItemID, quantity, cost, costComplete, reagents,
--   yields = { {itemID, chance, avgGiven, expected, unit, value} }, matValue, matValueComplete, missingPrices,
--   cut, net, margin, age, de = tracker info (n, bracketN, summary), status = "ok" | "no-output" | "loading" |
--   "not-disenchantable" | "unknown" | "no-mat-prices" | "no-cost"
function Calc:Get(recipeID)
	if not recipeID then return nil end
	local eco = cache[recipeID]
	if eco then return eco end
	local ok, result = pcall(self.Compute, self, recipeID)
	if not ok then
		CS:Debug("shuffle compute %s failed: %s", tostring(recipeID), tostring(result))
		result = { recipeID = recipeID, yields = {}, reagents = {}, cost = 0, quantity = 1, status = "error", error = tostring(result) }
	end
	cache[recipeID] = result
	return result
end

function Calc:GetNet(recipeID)
	local eco = self:Get(recipeID)
	return eco and eco.net or nil
end

-- CraftProfit economics with self-crafted intermediates considered whenever that is cheaper than buying
-- (a shuffler is a crafter: Bolt of Linen Cloth gets made from Linen Cloth when that saves money).
function Calc:Base(recipeID)
	local CP = CS.CP
	if CP.Calc.GetCrafted then
		local eco = CP.Calc:GetCrafted(recipeID)
		if eco then return eco end
	end
	return CP.Calc:Get(recipeID)
end

function Calc:ReagentCost(itemID)
	local CP = CS.CP
	if CP.Calc.ReagentCostCrafted then return CP.Calc:ReagentCostCrafted(itemID) end
	return CP.Calc:ReagentCost(itemID)
end

function Calc:Compute(recipeID)
	local CP = CS.CP
	local base = self:Base(recipeID)
	local eco = {
		recipeID = recipeID, base = base, yields = {}, status = "ok",
		outputItemID = base and base.outputItemID, quantity = (base and base.quantity) or 1,
		cost = (base and base.cost) or 0, costComplete = base and base.costComplete or false,
		reagents = (base and base.reagents) or {},
	}
	if not base or not eco.outputItemID then
		eco.status = "no-output"
		return eco
	end

	local yields, why, info = CS.Tracker:GetExpectedYields(eco.outputItemID)
	if not yields then
		eco.status = why or "unknown"
		eco.meta = info
		return eco
	end
	eco.de = info
	eco.meta = info.meta

	local perDE, missing, age = 0, 0, nil
	for _, y in ipairs(yields) do
		local unit = CP:GetSalePrice(y.itemID)
		local entry = { itemID = y.itemID, chance = y.chance, avgGiven = y.avgGiven, expected = y.expected, min = y.min, max = y.max, unit = unit }
		if unit then
			entry.value = unit * y.expected
			perDE = perDE + entry.value
			local a = CP:GetPriceAge(y.itemID)
			if a and (not age or a > age) then age = a end
		elseif y.expected >= 0.02 then
			missing = missing + 1
		end
		table.insert(eco.yields, entry)
	end
	eco.matValuePerDE = perDE
	eco.matValue = perDE * eco.quantity
	eco.missingPrices = missing
	eco.matValueComplete = (missing == 0) and perDE > 0
	eco.age = age
	eco.cut = eco.matValue * (CP.settings.ahCut or 0)

	if not eco.matValueComplete then
		eco.status = "no-mat-prices"
	elseif not eco.costComplete or #eco.reagents == 0 then
		eco.status = "no-cost"
	else
		eco.net = eco.matValue - eco.cut - eco.cost
		if eco.cost > 0 then eco.margin = eco.net / eco.cost end
	end
	return eco
end

---------------------------------------------------------------------------
-- Recipe registry (for the planner and /cs top)
---------------------------------------------------------------------------

local signature

function Calc:RefreshRecipes()
	if not (C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs and C_TradeSkillUI.GetRecipeInfo) then return false end
	if C_TradeSkillUI.IsTradeSkillLinked and C_TradeSkillUI.IsTradeSkillLinked() then return false end
	if C_TradeSkillUI.IsTradeSkillGuild and C_TradeSkillUI.IsTradeSkillGuild() then return false end
	if C_TradeSkillUI.IsNPCCrafting and C_TradeSkillUI.IsNPCCrafting() then return false end

	local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
	if not ok or type(ids) ~= "table" then return false end

	local prof
	for _, fn in ipairs({ "GetChildProfessionInfo", "GetBaseProfessionInfo" }) do
		if not prof and C_TradeSkillUI[fn] then
			local ok2, info = pcall(C_TradeSkillUI[fn])
			if ok2 and type(info) == "table" then prof = info.professionName or info.parentProfessionName end
		end
	end

	local learned = {}
	for _, id in ipairs(ids) do
		local ok2, info = pcall(C_TradeSkillUI.GetRecipeInfo, id)
		if ok2 and info and info.learned then
			learned[#learned + 1] = id
			CS.recipes[id] = { name = info.name or ("recipe " .. id), prof = prof }
			if CS.db then CS.db.recipes[id] = { name = info.name, prof = prof } end
		end
	end
	if #learned == 0 then return false end
	table.sort(learned)
	local sig = table.concat(learned, ",")
	if sig == signature then return false end
	signature = sig
	self:Invalidate()
	CS:Fire("RECIPES_UPDATED")
	return true
end

-- At login: this character's learned recipes (as CraftProfit saved them) with the names we saved, so the
-- planner has its list and can compute plans before any profession window is opened.
function Calc:SeedRecipes()
	local CP = CS.CP
	if not (CP and CP.GetLearnedRecipes and CS.db) then return 0 end
	local n = 0
	for recipeID in pairs(CP:GetLearnedRecipes()) do
		local saved = CS.db.recipes[recipeID]
		if saved and not CS.recipes[recipeID] then
			CS.recipes[recipeID] = { name = saved.name or ("recipe " .. recipeID), prof = saved.prof }
			n = n + 1
		end
	end
	if n > 0 then
		self:Invalidate()
		CS:Fire("RECIPES_UPDATED")
	end
	CS:Debug("seeded %d recipes from the saved data", n)
	return n
end

CS:On("READY", function() Calc:SeedRecipes() end)

-- Best shuffles among recipes seen this session. Each entry: recipeID, name, net, margin, deSummary.
function Calc:TopShuffles(limit)
	local list = {}
	for recipeID, rec in pairs(CS.recipes) do
		local eco = self:Get(recipeID)
		if eco and eco.net then
			table.insert(list, {
				recipeID = recipeID, name = rec.name, prof = rec.prof, net = eco.net, margin = eco.margin,
				deSummary = eco.de and eco.de.summary or nil,
			})
		end
	end
	table.sort(list, function(a, b)
		if a.net ~= b.net then return a.net > b.net end
		return (a.name or "") < (b.name or "")
	end)
	if limit and #list > limit then
		for i = #list, limit + 1, -1 do list[i] = nil end
	end
	return list
end

---------------------------------------------------------------------------
-- Invalidation
---------------------------------------------------------------------------

local function Setup()
	local CP = CS.CP
	if not CP then return end
	CP:On("PRICES_UPDATED", function() Calc:Invalidate() end)
	CP:On("VENDOR_UPDATED", function() Calc:Invalidate() end)
	CP:On("SETTINGS_CHANGED", function() Calc:Invalidate() end)
	CP:On("CRAFTS_UPDATED", function() Calc:Invalidate() end)
end
Setup()

CS:On("DE_RECORDED", function() Calc:Invalidate() end)
CS:On("ITEM_LOADED", function() Calc:Invalidate() end)
CS:On("SETTINGS_CHANGED", function() Calc:Invalidate() end)

CS:RegisterEvent("TRADE_SKILL_LIST_UPDATE", function() Calc:RefreshRecipes() end)
CS:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED", function() Calc:RefreshRecipes() end)
CS:RegisterEvent("TRADE_SKILL_SHOW", function() Calc:RefreshRecipes() end)
