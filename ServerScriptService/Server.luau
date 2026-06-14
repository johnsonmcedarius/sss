local RepS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local shared = RepS.Shared
local events = RepS.Events

local Validation = require(shared.Modules.Validation)

-- Create Restore remote dynamically if it doesn't exist
if not events.Remotes:FindFirstChild("Restore") then
	local restoreRemote = Instance.new("RemoteEvent")
	restoreRemote.Name = "Restore"
	restoreRemote.Parent = events.Remotes
end

local deletedObjectsCache = {}

-- Locate and initialize our newly built Shop Service module
local serverScriptService = game:GetService("ServerScriptService")
local serverModules = serverScriptService:WaitForChild("Modules")
local ShopService = require(serverModules:WaitForChild("ShopService"))
local StockingService = require(serverModules:WaitForChild("StockingService"))

-- Secure retrieval of the exact floor/boundary of the player's plot
local function GetPlayerPlotBase(player: Player): BasePart?
	local claimedPlotName: string? = player:GetAttribute("ClaimedPlot")
	if not claimedPlotName then return nil end

	local plotModel: Instance? = workspace:FindFirstChild(claimedPlotName)
	if plotModel then
		local base: Instance? = plotModel:FindFirstChild("Base") or plotModel:FindFirstChildOfClass("Part")
		if base and base:IsA("BasePart") then
			return base
		end
	end
	return nil
end

-- Secure plot claiming handler
events.Remotes.ClaimPlot.OnServerEvent:Connect(function(player: Player, arguments: {[string]: any})
	local plotName: string = arguments.PlotName
	assert(typeof(plotName) == "string", `"PlotName" was not specified`)

	local plot: Instance? = workspace:FindFirstChild(plotName)
	assert(plot, `{plotName} does not exist in workspace`)

	local existingOwner = plot:GetAttribute("Owner")
	if existingOwner then
		error(`{plotName} is already claimed by Owner ID: {existingOwner}`)
		return
	end

	for _, p in workspace:GetChildren() do
		if string.find(p.Name, "^Plot%d+$") and p:GetAttribute("Owner") == player.UserId then
			error(`${player.Name} already owns {p.Name}`)
			return
		end
	end

	plot:SetAttribute("Owner", player.UserId)
	plot:SetAttribute("OwnerName", player.Name)
	player:SetAttribute("ClaimedPlot", plotName)

	local spawnLocation: Instance? = plot:FindFirstChild("SpawnLocation")
	if spawnLocation and spawnLocation:IsA("BasePart") then
		local char = player.Character
		if char and char:FindFirstChild("HumanoidRootPart") then
			char.HumanoidRootPart.CFrame = spawnLocation.CFrame * CFrame.new(0, 3, 0)
		end
	end
end)

-- Secure placement handler
events.Remotes.Place.OnServerEvent:Connect(function(player: Player, arguments: {[string]: any})
	local objectName: string = arguments.ObjectName
	local CF: CFrame = arguments.CF
	local placementId: string? = arguments.PlacementId

	assert(typeof(objectName) == "string", `"ObjectName" was not specified`)
	assert(typeof(CF) == "CFrame", `"CF" was not specified`)

	local claimedPlot = player:GetAttribute("ClaimedPlot")
	if not claimedPlot then
		error(`{player.Name} attempted to place an item without claiming a plot.`)
		return
	end

	local object: Instance? = shared.Assets:FindFirstChild(objectName)
	assert(object, `{objectName} couldn't be found in {shared.Assets}`)

	local newObject: Instance = object:Clone()
	newObject:PivotTo(CF)

	local plotBase: BasePart? = GetPlayerPlotBase(player)
	local hasValidPlacement: boolean = Validation.HasValidPlacement(newObject, plotBase)

	if not hasValidPlacement then
		newObject:Destroy()
		error(`{objectName} has invalid placement or boundaries violated`)
		return
	end

	if placementId then
		newObject:SetAttribute("PlacementId", placementId)
	end

	newObject:SetAttribute("PlacedBy", player.UserId)

	-- FIX: Preserve pre-existing slots if it's an asset moving, only set to 0 if totally blank!
	if newObject:GetAttribute("OccupiedSlots") == nil then
		newObject:SetAttribute("OccupiedSlots", 0)
	end

	newObject.Parent = workspace.Objects
end)

-- Secure trash handler (Modified to cache deleted items safely)
events.Remotes.Delete.OnServerEvent:Connect(function(player: Player, arguments: {[string]: any})
	local object: Instance? = arguments.Object
	assert(object, `"Object" was not specified to be deleted`)

	if object and object.Parent == workspace.Objects then
		local placementId = object:GetAttribute("PlacementId")
		if placementId then
			deletedObjectsCache[placementId] = object
		end
		object.Parent = nil
	else
		error(`Unauthorized deletion call attempt by {player.Name}`)
	end
end)

-- Secure restore handler
events.Remotes.Restore.OnServerEvent:Connect(function(player: Player, arguments: {[string]: any})
	local placementId: string = arguments.PlacementId
	local cf: CFrame = arguments.CF
	local objectName: string = arguments.ObjectName

	local object = deletedObjectsCache[placementId]

	if object then
		if object:GetAttribute("PlacedBy") ~= player.UserId then
			error(`Unauthorized restore attempt`)
			return
		end

		object:PivotTo(cf)

		local plotBase: BasePart? = GetPlayerPlotBase(player)
		local hasValidPlacement: boolean = Validation.HasValidPlacement(object, plotBase)

		if not hasValidPlacement then
			error(`{objectName} has invalid placement or boundaries violated`)
			return
		end

		object.Parent = workspace.Objects
		deletedObjectsCache[placementId] = nil
	else
		-- Fallback to Place from catalog asset directory if cache dropped
		local asset = shared.Assets:FindFirstChild(objectName)
		if not asset then return end
		local newObject = asset:Clone()
		newObject:PivotTo(cf)

		local plotBase: BasePart? = GetPlayerPlotBase(player)
		if not Validation.HasValidPlacement(newObject, plotBase) then
			newObject:Destroy()
			return
		end

		newObject:SetAttribute("PlacementId", placementId)
		newObject:SetAttribute("PlacedBy", player.UserId)
		newObject:SetAttribute("OccupiedSlots", 0)
		newObject.Parent = workspace.Objects
	end
end)

-- Secure movement handler
events.Remotes.Move.OnServerEvent:Connect(function(player: Player, arguments: {[string]: any})
	local object: Instance? = arguments.Object
	local CF: CFrame = arguments.CF

	assert(object, `"Object" was not specified to be moved`)
	assert(typeof(CF) == "CFrame", `"CF" was not specified`)

	if not (object and object.Parent == workspace.Objects) then
		error(`Unauthorized move call attempt by {player.Name}`)
		return
	end

	if object:GetAttribute("PlacedBy") ~= player.UserId then
		error(`Unauthorized move attempt: {player.Name} does not own this object`)
		return
	end

	local originalCF = object:GetPivot()
	object:PivotTo(CF)

	local plotBase: BasePart? = GetPlayerPlotBase(player)
	local hasValidPlacement: boolean = Validation.HasValidPlacement(object, plotBase)

	if not hasValidPlacement then
		object:PivotTo(originalCF)
		error(`{object.Name} has invalid movement target or boundaries violated`)
		return
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	for placementId, obj in pairs(deletedObjectsCache) do
		if obj:GetAttribute("PlacedBy") == player.UserId then
			obj:Destroy()
			deletedObjectsCache[placementId] = nil
		end
	end

	for _, p in workspace:GetChildren() do
		if string.find(p.Name, "^Plot%d+$") and p:GetAttribute("Owner") == player.UserId then
			p:SetAttribute("Owner", nil)
			p:SetAttribute("OwnerName", nil)
		end
	end
end)

ShopService.Initialize()
StockingService.Initialize()
