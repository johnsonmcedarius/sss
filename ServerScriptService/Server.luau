local CollectionS = game:GetService("CollectionService")
local RepS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptS = game:GetService("ServerScriptService")

local shared = RepS.Shared
local events = RepS.Events
local Validation = require(shared.Modules.Validation)

-- Locate and initialize our database and server modules
local serverModules = ServerScriptS:WaitForChild("Modules")
local DatabaseService = require(serverModules:WaitForChild("DatabaseService"))
local EconomyService = require(serverModules:WaitForChild("EconomyService"))
local ShopService = require(serverModules:WaitForChild("ShopService"))
local StockingService = require(serverModules:WaitForChild("StockingService"))

if not events.Remotes:FindFirstChild("Restore") then
	local restoreRemote = Instance.new("RemoteEvent")
	restoreRemote.Name = "Restore"
	restoreRemote.Parent = events.Remotes
end

local deletedObjectsCache = {}

local function GetPlayerPlotBase(player: Player): BasePart?
	local claimedPlotName: string? = player:GetAttribute("ClaimedPlot")
	if not claimedPlotName then
		return nil
	end
	local plotModel: Instance? = workspace:FindFirstChild(claimedPlotName)
	if plotModel then
		local base: Instance? = plotModel:FindFirstChild("Base") or plotModel:FindFirstChildOfClass("Part")
		if base and base:IsA("BasePart") then
			return base
		end
	end
	return nil
end

local function SpawnPlayerSavedLayout(player: Player, plotModel: Instance)
	local plotBase = plotModel:FindFirstChild("Base") or plotModel:FindFirstChildOfClass("Part")
	if not plotBase or not plotBase:IsA("BasePart") then
		return
	end

	local sessionTrove = DatabaseService.GetTrove(player)
	if not sessionTrove then
		return
	end

	local savedLayout = DatabaseService.GetAndValidatePlacedObjects(player, plotBase)
	local assetsFolder = shared:FindFirstChild("Assets")
	if not assetsFolder then
		return
	end

	for placementId, objectData in pairs(savedLayout) do
		local assetTemplate = assetsFolder:FindFirstChild(objectData.ObjectName)
		if assetTemplate then
			local spawnedClone = assetTemplate:Clone()
			spawnedClone:PivotTo(objectData.CF)
			spawnedClone:SetAttribute("PlacementId", placementId)
			spawnedClone:SetAttribute("PlacedBy", player.UserId)
			if spawnedClone:GetAttribute("OccupiedSlots") == nil then
				spawnedClone:SetAttribute("OccupiedSlots", 0)
			end
			spawnedClone.Parent = workspace.Objects
			sessionTrove:Add(spawnedClone)
		end
	end
end

-- Rebuilds display items for restored clothing and shoe racks from historical snapshots
local function RebuildRestoredStock(rack: Model, stockData: table, player: Player)
	if not stockData or #stockData == 0 then
		return
	end

	local displayFolder = rack:FindFirstChild("DisplayItems")
	if not displayFolder then
		displayFolder = Instance.new("Folder")
		displayFolder.Name = "DisplayItems"
		displayFolder.Parent = rack
	end

	local sessionTrove = DatabaseService.GetTrove(player)
	local rackType = rack:GetAttribute("RackType") or "Shoes"

	for _, itemInfo in ipairs(stockData) do
		local attachment = rack:FindFirstChild(itemInfo.AttachmentName, true)
		if not attachment or not attachment:IsA("Attachment") then
			continue
		end

		local targetWorldCF = attachment.WorldCFrame
		local spawnedModel = nil

		if rackType == "Clothing" then
			local baseFolder = shared:FindFirstChild("BaseModels")
			local mannequinType = itemInfo.MannequinType or "HangingTorso"
			local hangerTemplate = baseFolder and baseFolder:FindFirstChild(mannequinType)
			if hangerTemplate then
				local hangerClone = hangerTemplate:Clone()
				local shirtInstance = hangerClone:FindFirstChildOfClass("Shirt")
				if shirtInstance and itemInfo.ShirtTemplate then
					shirtInstance.ShirtTemplate = itemInfo.ShirtTemplate
				end
				local pantsInstance = hangerClone:FindFirstChildOfClass("Pants")
				if pantsInstance and itemInfo.PantsTemplate then
					pantsInstance.PantsTemplate = itemInfo.PantsTemplate
				end
				local torsoPart = hangerClone:FindFirstChild("Torso") or hangerClone:FindFirstChildOfClass("MeshPart")
				if torsoPart and torsoPart:IsA("MeshPart") and not shirtInstance and itemInfo.TextureId then
					torsoPart.TextureID = itemInfo.TextureId
				end
				spawnedModel = hangerClone
			end
		else
			local merchandiseFolder = shared:FindFirstChild("Merchandise")
			local meshesFolder = merchandiseFolder and (if rackType == "Shoes" then merchandiseFolder:FindFirstChild("ShoeMeshes") else merchandiseFolder:FindFirstChild("AccessoryMeshes"))
			if meshesFolder then
				local assetTemplate = meshesFolder:FindFirstChild(itemInfo.MeshName or "")
				if assetTemplate then
					spawnedModel = assetTemplate:Clone()
				end
			end
		end

		if not spawnedModel then
			continue
		end

		-- Setup physics securely
		if spawnedModel:IsA("BasePart") then
			spawnedModel.Anchored = true
			spawnedModel.CanCollide = false
			spawnedModel.CanTouch = false
			spawnedModel.CanQuery = false
		end
		for _, desc in ipairs(spawnedModel:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.Anchored = true
				desc.CanCollide = false
				desc.CanTouch = false
				desc.CanQuery = false
			elseif desc:IsA("ProximityPrompt") or desc:IsA("Script") then
				desc:Destroy()
			end
		end

		spawnedModel:SetAttribute("SlotPrice", itemInfo.SlotPrice)
		spawnedModel:SetAttribute("ItemName", itemInfo.ItemName)

		if rackType == "Shoes" then
			local parentGroup = Instance.new("Model")
			parentGroup.Name = itemInfo.ItemName
			parentGroup.Parent = displayFolder

			local shoeLeft = spawnedModel
			local shoeRight = spawnedModel:Clone()

			shoeLeft.Parent = parentGroup
			shoeRight.Parent = parentGroup

			shoeLeft:PivotTo(targetWorldCF * CFrame.new(-0.2, 0, 0) * CFrame.Angles(0, math.rad(-5), 0))
			shoeRight:PivotTo(targetWorldCF * CFrame.new(0.2, 0, 0) * CFrame.Angles(0, math.rad(5), 0))

			parentGroup:SetAttribute("SlotPrice", itemInfo.SlotPrice)
			parentGroup:SetAttribute("ItemName", itemInfo.ItemName)

			if sessionTrove then
				sessionTrove:Add(parentGroup)
			end
		else
			spawnedModel.Parent = displayFolder
			local modelAttachment = spawnedModel:FindFirstChild("HangerSnap", true)
			if spawnedModel:IsA("Model") then
				if modelAttachment then
					spawnedModel:PivotTo(targetWorldCF * modelAttachment.CFrame:Inverse())
				else
					spawnedModel:PivotTo(targetWorldCF)
				end
			else
				spawnedModel.CFrame = targetWorldCF
			end
			if sessionTrove then
				sessionTrove:Add(spawnedModel)
			end
		end
	end
end

-- Secure plot claiming handler
events.Remotes.ClaimPlot.OnServerEvent:Connect(function(player: Player, arguments: { [string]: any })
	local plotName: string = arguments.PlotName
	assert(typeof(plotName) == "string", `"PlotName" was not specified`)

	local plot: Instance? = workspace:FindFirstChild(plotName)
	assert(plot, `{plotName} does not exist`)

	local existingOwner = plot:GetAttribute("Owner")
	if existingOwner then
		return
	end

	for _, p in workspace:GetChildren() do
		if string.find(p.Name, "^Plot%d+$") and p:GetAttribute("Owner") == player.UserId then
			return
		end
	end

	plot:SetAttribute("Owner", player.UserId)
	plot:SetAttribute("OwnerName", player.Name)
	player:SetAttribute("ClaimedPlot", plotName)

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
		return
	end

	local object: Instance? = shared.Assets:FindFirstChild(objectName)
	assert(object, `{objectName} clear layout miss`)

	local newObject: Instance = object:Clone()
	newObject:PivotTo(CF)

	local plotBase: BasePart? = GetPlayerPlotBase(player)
	if not Validation.HasValidPlacement(newObject, plotBase) then
		newObject:Destroy()
		return
	end

	local dbSuccess = DatabaseService.AddPlacedObject(player, placementId :: string, objectName, CF)
	if not dbSuccess then
		newObject:Destroy()
		return
	end

	newObject:SetAttribute("PlacementId", placementId)
	newObject:SetAttribute("PlacedBy", player.UserId)
	newObject:SetAttribute("OccupiedSlots", 0)
	newObject.Parent = workspace.Objects

	local sessionTrove = DatabaseService.GetTrove(player)
	if sessionTrove then
		sessionTrove:Add(newObject)
	end
end)

-- Secure trash handler (UPGRADED: Fixed memory leak by explicit owner verification mapping)
events.Remotes.Delete.OnServerEvent:Connect(function(player: Player, arguments: { [string]: any })
	local targetObject: Instance? = arguments.Object
	local fallbackPlacementId: string? = arguments.PlacementId

	if not targetObject and typeof(fallbackPlacementId) == "string" then
		for _, child in ipairs(workspace.Objects:GetChildren()) do
			if child:GetAttribute("PlacementId") == fallbackPlacementId then
				targetObject = child
				break
			end
		end
	end

	assert(targetObject, `"Object" layout query missing alignment reference`)

	if targetObject and targetObject.Parent == workspace.Objects then
		if targetObject:GetAttribute("PlacedBy") ~= player.UserId then
			return
		end

		local placementId = targetObject:GetAttribute("PlacementId")
		if placementId then
			DatabaseService.RemovePlacedObject(player, placementId)

			-- Snapshot active shelf contents safely
			local serializedStock = {}
			local displayFolder = targetObject:FindFirstChild("DisplayItems")
			local maxSlots = targetObject:GetAttribute("MaxSlots") or 4

			if displayFolder then
				local index = 0
				for _, child in ipairs(displayFolder:GetChildren()) do
					index += 1
					if index > maxSlots then
						break
					end
					local itemConfig = shared.Modules.ShopConfig and require(shared.Modules.ShopConfig).Items[child:GetAttribute("ItemName")]
					table.insert(serializedStock, {
						AttachmentName = `Slot{index}`,
						ItemName = child:GetAttribute("ItemName"),
						SlotPrice = child:GetAttribute("SlotPrice") or 50,
						MeshName = itemConfig and itemConfig.MeshName,
						MannequinType = itemConfig and itemConfig.MannequinType,
						ShirtTemplate = itemConfig and itemConfig.ShirtTemplate,
						PantsTemplate = itemConfig and itemConfig.PantsTemplate,
						TextureId = itemConfig and itemConfig.TextureId,
					})
				end
			end

			-- Stash inside layout tracks safely bound to Owner to prevent server memory bloat
			deletedObjectsCache[placementId] = {
				Instance = targetObject,
				StockData = serializedStock,
				OccupiedSlots = targetObject:GetAttribute("OccupiedSlots") or 0,
				OwnerId = player.UserId, -- Added explicit owner tracking tag
			}

			local sessionTrove = DatabaseService.GetTrove(player)
			if sessionTrove then
				sessionTrove:Remove(targetObject)
			end
			targetObject.Parent = nil
		end
	end
end)

-- Secure restore handler (UPGRADED: Restores serialized stock visuals frame-perfectly)
events.Remotes.Restore.OnServerEvent:Connect(function(player: Player, arguments: { [string]: any })
	local placementId = arguments.PlacementId
	local cf = arguments.CF
	local objectName = arguments.ObjectName

	assert(typeof(placementId) == "string", `"PlacementId" malformed`)
	assert(typeof(cf) == "CFrame", `"CF" malformed`)
	assert(typeof(objectName) == "string", `"ObjectName" malformed`)

	local cacheEntry = deletedObjectsCache[placementId]
	local plotBase = GetPlayerPlotBase(player)
	local canReuseCache = false

	if cacheEntry and cacheEntry.Instance and cacheEntry.Instance.Parent == nil then
		local success = pcall(function()
			cacheEntry.Instance.Parent = workspace.Temp
			cacheEntry.Instance.Parent = nil
		end)
		canReuseCache = success
	end

	if canReuseCache and cacheEntry then
		local object = cacheEntry.Instance
		if object:GetAttribute("PlacedBy") ~= player.UserId then
			return
		end
		object:PivotTo(cf)
		if not Validation.HasValidPlacement(object, plotBase) then
			return
		end

		DatabaseService.AddPlacedObject(player, placementId, objectName, cf)
		object.Parent = workspace.Objects
		deletedObjectsCache[placementId] = nil

		local sessionTrove = DatabaseService.GetTrove(player)
		if sessionTrove then
			sessionTrove:Add(object)
		end
	else
		-- Blueprint Regeneration Path
		local asset = shared.Assets:FindFirstChild(objectName)
		if not asset then
			return
		end

		local newObject = asset:Clone()
		newObject:PivotTo(cf)
		newObject:SetAttribute("PlacementId", placementId)
		newObject:SetAttribute("PlacedBy", player.UserId)

		-- Reapply original stock counts instead of resetting blindly to 0
		local savedCount = cacheEntry and cacheEntry.OccupiedSlots or 0
		newObject:SetAttribute("OccupiedSlots", savedCount)

		if not Validation.HasValidPlacement(newObject, plotBase) then
			newObject:Destroy()
			return
		end

		DatabaseService.AddPlacedObject(player, placementId, objectName, cf)
		newObject.Parent = workspace.Objects

		-- Repopulate items dynamically from data snapshots
		if cacheEntry and cacheEntry.StockData then
			RebuildRestoredStock(newObject, cacheEntry.StockData, player)
		end

		local sessionTrove = DatabaseService.GetTrove(player)
		if sessionTrove then
			sessionTrove:Add(newObject)
		end
		deletedObjectsCache[placementId] = nil
	end
end)

-- Secure movement handler
events.Remotes.Move.OnServerEvent:Connect(function(player: Player, arguments: { [string]: any })
	local object: Instance? = arguments.Object
	local CF: CFrame = arguments.CF

	assert(object, `"Object" was not specified to be moved`)
	assert(typeof(CF) == "CFrame", `"CF" was not specified`)

	if not (object and object.Parent == workspace.Objects) then
		return
	end
	if object:GetAttribute("PlacedBy") ~= player.UserId then
		return
	end

	local placementId = object:GetAttribute("PlacementId")
	if not placementId then
		return
	end

	local originalCF = object:GetPivot()
	object:PivotTo(CF)

	local plotBase: BasePart? = GetPlayerPlotBase(player)
	if not Validation.HasValidPlacement(object, plotBase) then
		object:PivotTo(originalCF)
		return
	end

	DatabaseService.UpdatePlacedObjectCFrame(player, placementId, CF)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	-- UPGRADED: Completely sweeps out any dead data dictionary footprints from memory
	for placementId, cacheEntry in pairs(deletedObjectsCache) do
		if cacheEntry.OwnerId == player.UserId or (cacheEntry.Instance and cacheEntry.Instance:GetAttribute("PlacedBy") == player.UserId) then
			if cacheEntry.Instance then
				cacheEntry.Instance:Destroy()
			end
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

DatabaseService.Initialize()
EconomyService.Initialize()
ShopService.Initialize()
StockingService.Initialize()
