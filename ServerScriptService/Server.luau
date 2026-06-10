local RepS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local shared = RepS.Shared
local events = RepS.Events

local Validation = require(shared.Modules.Validation)

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

	-- Teleport player's character safely onto their custom SpawnLocation part
	local spawnLocation: Instance? = plot:FindFirstChild("SpawnLocation")
	if spawnLocation and spawnLocation:IsA("BasePart") then
		local char = player.Character
		if char and char:FindFirstChild("HumanoidRootPart") then
			-- Match the exact position and rotational facing direction of the spawn pad
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
	assert(object, `{objectName} couldn't not found in {shared.Assets}`)

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

	newObject.Parent = workspace.Objects
end)

-- Secure trash handler
events.Remotes.Delete.OnServerEvent:Connect(function(player: Player, arguments: {[string]: any})
	local object: Instance? = arguments.Object
	assert(object, `"Object" was not specified to be deleted`)

	if object and object.Parent == workspace.Objects then
		object:Destroy()
	else
		error(`Unauthorized deletion call attempt by {player.Name}`)
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	for _, p in workspace:GetChildren() do
		if string.find(p.Name, "^Plot%d+$") and p:GetAttribute("Owner") == player.UserId then
			p:SetAttribute("Owner", nil)
			p:SetAttribute("OwnerName", nil)
		end
	end
end)
