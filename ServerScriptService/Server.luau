local RepS = game:GetService("ReplicatedStorage")

local shared = RepS.Shared
local events = RepS.Events

local Validation = require(shared.Modules.Validation)

-- Secure placement handler
events.Remotes.Place.OnServerEvent:Connect(function(player: Player, arguments: {[string]: any})
	local objectName: string = arguments.ObjectName
	local CF: CFrame = arguments.CF
	local placementId: string? = arguments.PlacementId

	assert(typeof(objectName) == "string", `"ObjectName" was not specified`)
	assert(typeof(CF) == "CFrame", `"CF" was not specified`)

	local object: Instance? = shared.Assets:FindFirstChild(objectName)
	assert(object, `{objectName} couldn't not found in {shared.Assets}`)

	local newObject: Instance = object:Clone()
	newObject:PivotTo(CF)

	local hasValidPlacement: boolean = Validation.HasValidPlacement(newObject)
	if not hasValidPlacement then
		newObject:Destroy()
		error(`{objectName} has invalid placement`)

		return
	end

	-- Apply tracking attribute so client side history stacks can map it securely on undo/redo
	if placementId then
		newObject:SetAttribute("PlacementId", placementId)
	end

	newObject.Parent = workspace.Objects
end)

-- Secure trash handler
events.Remotes.Delete.OnServerEvent:Connect(function(player: Player, arguments: {[string]: any})
	local object: Instance? = arguments.Object
	assert(object, `"Object" was not specified to be deleted`)

	-- Strict server security check: Make sure they are only deleting children inside workspace.Objects folder
	if object and object.Parent == workspace.Objects then
		object:Destroy()
	else
		error(`Unauthorized deletion call attempt by {player.Name}`)
	end
end)
