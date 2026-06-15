local RepS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptS = game:GetService("ServerScriptService")

local shared = RepS.Shared
local events = RepS.Events

local Validation = require(shared.Modules.Validation)

-- Locate and initialize our database and server modules
local serverModules = ServerScriptS:WaitForChild("Modules")
local DatabaseService = require(serverModules:WaitForChild("DatabaseService"))
local ShopService = require(serverModules:WaitForChild("ShopService"))
local StockingService = require(serverModules:WaitForChild("StockingService"))

-- Create Restore remote dynamically if it doesn't exist
if not events.Remotes:FindFirstChild("Restore") then
	local restoreRemote = Instance.new("RemoteEvent")
	restoreRemote.Name = "Restore"
	restoreRemote.Parent = events.Remotes
end

local deletedObjectsCache = {}

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

--[[
	Authoritatively spawns a player's saved boutique layout upon plot claim and binds
	every spawned instance directly to their master session Trove for automated, zero-leak cleanup.
]]
local function SpawnPlayerSavedLayout(player: Player, plotModel: Instance)
	local plotBase = plotModel:FindFirstChild("Base") or plotModel:FindFirstChildOfClass("Part")
	if not plotBase or not plotBase:IsA("BasePart") then
		warn(`[Server]: Failed to locate valid plot base part for {plotModel.Name}. Cannot spawn saved layout.`)
		return
	end

	local sessionTrove = DatabaseService.GetTrove(player)
	if not sessionTrove then
		warn(`[Server]: Master session Trove for {player.Name} was unresolved. Aborting save restoration.`)
		return
	end

	-- Retrieve only fully validated, non-glitched coordinate layouts from database
	local savedLayout = DatabaseService.GetAndValidatePlacedObjects(player, plotBase)
	local assetsFolder = shared:FindFirstChild("Assets")

	if not assetsFolder then return end

	print(`[Server]: Restoring {player.Name}'s validated layout ({#savedLayout} items) onto {plotModel.Name}...`)

	for placementId, objectData in pairs(savedLayout) do
		local assetTemplate = assetsFolder:FindFirstChild(objectData.ObjectName)
		if assetTemplate then
			local spawnedClone = assetTemplate:Clone()
			spawnedClone:PivotTo(objectData.CF)

			-- Stencil authoritative identity tags
			spawnedClone:SetAttribute("PlacementId", placementId)
			spawnedClone:SetAttribute("PlacedBy", player.UserId)

			if spawnedClone:GetAttribute("OccupiedSlots") == nil then
				spawnedClone:SetAttribute("OccupiedSlots", 0)
			end

			spawnedClone.Parent = workspace.Objects

			-- Zero-Leak Magic: Add instance directly to the player's session Trove!
			-- When they disconnect, this model vanishes instantly without needing manual scanning loops.
			sessionTrove:Add(spawnedClone)
		end
	end
	print(`[Server]: Layout successfully restored for {player.Name}.`)
end

-- Secure plot claiming handler
events.Remotes.ClaimPlot.OnServerEvent:Connect(function(player: Player, arguments: { [string]: any })
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

	-- Lock ownership attributes onto physical plot
	plot:SetAttribute("Owner", player.UserId)
	plot:SetAttribute("OwnerName", player.Name)
	player:SetAttribute("ClaimedPlot", plotName)

	-- Seamlessly spawn their persistent database layout onto their freshly claimed plot
	SpawnPlayerSavedLayout(player, plot)

	local spawnLocation: Instance? = plot:FindFirstChild("SpawnLocation")
	if spawnLocation and spawnLocation:IsA("BasePart") then
		local char = player.Character
		if char and char:FindFirstChild("HumanoidRootPart") then
			char.HumanoidRootPart.CFrame = spawnLocation.CFrame * CFrame.new(0, 3, 0)
		end
	end
end)

-- Secure placement handler
events.Remotes.Place.OnServerEvent:Connect(function(player: Player, arguments: { [string]: any })
	local objectName: string = arguments.ObjectName
	local CF: CFrame = arguments.CF
	local placementId: string? = arguments.PlacementId

	assert(typeof(objectName) == "string", `"ObjectName" was not specified`)
	assert(typeof(CF) == "CFrame", `"CF" was not specified`)
	assert(typeof(placementId) == "string", `"PlacementId" was not specified`)

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

	-- 1. Authoritatively bind the placement configuration to the persistent database save
	local dbSuccess = DatabaseService.AddPlacedObject(player, placementId :: string, objectName, CF)
	if not dbSuccess then
		newObject:Destroy()
		error(`[Server Database Error]: Failed to save placement for {player.Name}.`)
		return
	end

	newObject:SetAttribute("PlacementId", placementId)
	newObject:SetAttribute("PlacedBy", player.UserId)

	if newObject:GetAttribute("OccupiedSlots") == nil then
		newObject:SetAttribute("OccupiedSlots", 0)
	end

	newObject.Parent = workspace.Objects

	-- 2. Bind the newly spawned model to their master session Trove
	local sessionTrove = DatabaseService.GetTrove(player)
	if sessionTrove then
		sessionTrove:Add(newObject)
	end
end)

-- Secure trash handler
events.Remotes.Delete.OnServerEvent:Connect(function(player: Player, arguments: { [string]: any })
	local object: Instance? = arguments.Object
	assert(object, `"Object" was not specified to be deleted`)

	if object and object.Parent == workspace.Objects then
		local placementId = object:GetAttribute("PlacementId")
		if placementId then
			-- 1. Scrub from authoritative database save profile instantly
			DatabaseService.RemovePlacedObject(player, placementId)
			deletedObjectsCache[placementId] = object
		end

		-- 2. Safely untrack from session Trove since we're destroying/removing it
		local sessionTrove = DatabaseService.GetTrove(player)
		if sessionTrove then
			sessionTrove:Remove(object)
		end

		object.Parent = nil
	else
		error(`Unauthorized deletion call attempt by {player.Name}`)
	end
end)

-- Secure restore handler (for Undo/Redo operations)
events.Remotes.Restore.OnServerEvent:Connect(function(player: Player, arguments: { [string]: any })
	local placementId: string = arguments.PlacementId
	local cf: CFrame = arguments.CF
	local objectName: string = arguments.ObjectName

	local object = deletedObjectsCache[placementId]
	local plotBase = GetPlayerPlotBase(player)

	if object then
		if object:GetAttribute("PlacedBy") ~= player.UserId then
			error(`Unauthorized restore attempt`)
			return
		end

		object:PivotTo(cf)
		local hasValidPlacement = Validation.HasValidPlacement(object, plotBase)

		if not hasValidPlacement then
			error(`{objectName} has invalid placement or boundaries violated`)
			return
		end

		-- Authoritatively write layout change back to player profile
		DatabaseService.AddPlacedObject(player, placementId, objectName, cf)

		object.Parent = workspace.Objects
		deletedObjectsCache[placementId] = nil

		local sessionTrove = DatabaseService.GetTrove(player)
		if sessionTrove then
			sessionTrove:Add(object)
		end
	else
		local asset = shared.Assets:FindFirstChild(objectName)
		if not asset then return end
		local newObject = asset:Clone()
		newObject:PivotTo(cf)

		if not Validation.HasValidPlacement(newObject, plotBase) then
			newObject:Destroy()
			return
		end

		DatabaseService.AddPlacedObject(player, placementId, objectName, cf)

		newObject:SetAttribute("PlacementId", placementId)
		newObject:SetAttribute("PlacedBy", player.UserId)
		newObject:SetAttribute("OccupiedSlots", 0)
		newObject.Parent = workspace.Objects

		local sessionTrove = DatabaseService.GetTrove(player)
		if sessionTrove then
			sessionTrove:Add(newObject)
		end
	end
end)

-- Secure movement handler
events.Remotes.Move.OnServerEvent:Connect(function(player: Player, arguments: { [string]: any })
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

	local placementId = object:GetAttribute("PlacementId")
	if not placementId then
		error("Object does not possess a valid tracking PlacementId!")
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

	-- Authoritatively write position updates back to the persistent database profile
	DatabaseService.UpdatePlacedObjectCFrame(player, placementId, CF)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	for placementId, obj in pairs(deletedObjectsCache) do
		if obj:GetAttribute("PlacedBy") == player.UserId then
			obj:Destroy()
			deletedObjectsCache[placementId] = nil
		end
	end

	-- Clear standard plot locks on exit instantly
	for _, p in workspace:GetChildren() do
		if string.find(p.Name, "^Plot%d+$") and p:GetAttribute("Owner") == player.UserId then
			p:SetAttribute("Owner", nil)
			p:SetAttribute("OwnerName", nil)
		end
	end
end)

-- Load and boot core background systems
DatabaseService.Initialize()
ShopService.Initialize()
StockingService.Initialize()
