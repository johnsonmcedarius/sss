local UserInputS = game:GetService("UserInputService")
local RepS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService") -- Required to generate clean UUIDs for placement history tracking

local modules = script.Parent.Modules
local shared = RepS.Shared
local events = RepS.Events

local libraries = RepS.Libraries

local Settings = require(shared.Settings)
local Utility = require(shared.Utility)

local Trove = require(libraries.Trove)
local LemonSignal = require(libraries.LemonSignal)
local ParamsBuilder = require(libraries.ParamsBuilder)

local PlacingService = require(modules.PlacingService)

local player: Player = Players.LocalPlayer
local coreGui: ScreenGui = player.PlayerGui:WaitForChild("CoreGui")

local guiVisual: Folder = coreGui.Visual
local toolbar: Frame = coreGui:WaitForChild("Toolbar")

local undoButton: ImageButton = toolbar:WaitForChild("Undo")
local redoButton: ImageButton = toolbar:WaitForChild("Redo")
local deleteButton: ImageButton = toolbar:WaitForChild("Delete")

local objects: Frame = coreGui.Objects
local template: TextButton = objects.Template 

local previewHighlight: Highlight = guiVisual.PreviewHighlight

local canPlaceColor: Color3 = Settings.CanPlaceColor
local cannotPlaceColor: Color3 = Settings.CannotPlaceColor

local previewTrove: Trove = Trove.new()
local renderedEvent: Signal<Instance, number, boolean> = PlacingService.Rendered

type Trove = Trove.Trove
type Signal<T...> = LemonSignal.Signal<T...>

-- Chronological history stacks
local undoStack = {}
local redoStack = {}

template.Parent = nil

-- Visual indicator updating (dims buttons when stacks are empty)
local function UpdateHistoryUI()
	undoButton.ImageTransparency = if #undoStack > 0 then 0 else 0.5
	redoButton.ImageTransparency = if #redoStack > 0 then 0 else 0.5
end

-- Track a new action and clear the redo stack (forward history resets on new action)
local function PushAction(actionType: "Place" | "Delete", objectName: string, cf: CFrame, placementId: string)
	table.insert(undoStack, {
		Type = actionType,
		ObjectName = objectName,
		CF = cf,
		PlacementId = placementId
	})
	table.clear(redoStack)
	UpdateHistoryUI()
end

-- Helper to safely bubble up from any raycast hit to find the top-level parent inside workspace.Objects
local function GetTargetObject(targetInstance: Instance?): Instance?
	if not targetInstance then return nil end

	if targetInstance:IsDescendantOf(workspace.Objects) then
		local current = targetInstance
		while current and current.Parent ~= workspace.Objects do
			current = current.Parent
		end
		return current
	end

	return nil
end

-- Highly optimized helper to render a 3D preview of any object inside a ViewportFrame
local function SetupViewportPreview(viewport: ViewportFrame, originalObject: Instance)
	viewport:ClearAllChildren()

	local previewObject: Instance = originalObject:Clone()

	for _, descendant in previewObject:GetDescendants() do
		if descendant:IsA("ProximityPrompt") or descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end

	previewObject.Parent = viewport

	local camera = Instance.new("Camera")
	camera.FieldOfView = 45

	local center: CFrame
	local size: Vector3

	if previewObject:IsA("Model") then
		center, size = previewObject:GetBoundingBox()
	elseif previewObject:IsA("BasePart") then
		center, size = previewObject.CFrame, previewObject.Size
	else
		center, size = CFrame.identity, Vector3.new(2, 2, 2)
	end

	local maxDim: number = math.max(size.X, size.Y, size.Z)
	local distance: number = maxDim / (2 * math.tan(math.rad(camera.FieldOfView / 2))) * 1.4

	local cameraOffset = Vector3.new(1.1, 0.8, 1.1).Unit * distance
	camera.CFrame = CFrame.new(center.Position + cameraOffset, center.Position)

	viewport.CurrentCamera = camera
	camera.Parent = viewport
end

-- Activation function for the dynamic trash tool
local function EnterDeleteMode()
	previewTrove:Clean()
	PlacingService.Cancel() -- Make sure we aren't placing something

	-- Frame loop tracking whatever is directly under the user's cursor inside workspace.Objects
	previewTrove:BindToRenderStep("DeleteHover", Enum.RenderPriority.Camera.Value, function()
		local raycastParams = RaycastParams.new()
		local params = ParamsBuilder.new(raycastParams)
		params:Include(workspace.Objects)

		local mouseResult = Utility.General.GetMouseResult(raycastParams)
		local target = if mouseResult then mouseResult.Instance else nil
		local rootObject = GetTargetObject(target)

		if rootObject then
			previewHighlight.Adornee = rootObject
			previewHighlight.OutlineColor = Color3.fromRGB(255, 50, 50) -- Hot red highlight for deletion
			previewHighlight.FillColor = Color3.fromRGB(255, 50, 50)
			previewHighlight.FillTransparency = 0.6
		else
			previewHighlight.Adornee = nil
		end
	end)

	-- Single click deletion execution + escape bindings
	previewTrove:Connect(UserInputS.InputBegan, function(inputObject: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then return end

		if inputObject.UserInputType == Enum.UserInputType.MouseButton1 then
			local raycastParams = RaycastParams.new()
			local params = ParamsBuilder.new(raycastParams)
			params:Include(workspace.Objects)

			local mouseResult = Utility.General.GetMouseResult(raycastParams)
			local target = if mouseResult then mouseResult.Instance else nil
			local rootObject = GetTargetObject(target)

			if rootObject then
				local objectName = rootObject.Name
				local cf = rootObject:GetPivot()
				local placementId = rootObject:GetAttribute("PlacementId")

				-- Ensure untagged assets get a history tracking tag before we send the delete remote
				if not placementId then
					placementId = HttpService:GenerateGUID(false)
					rootObject:SetAttribute("PlacementId", placementId)
				end

				events.Remotes.Delete:FireServer({
					Object = rootObject
				})

				-- Cache deletion details to our history stacks
				PushAction("Delete", objectName, cf, placementId)
			end
		elseif inputObject.KeyCode == Settings.Cancel then
			previewTrove:Clean()
			previewHighlight.Adornee = nil
		end
	end)
end

-- Render all 3D buttons inside our catalog menu
for _, object: Instance in shared.Assets:GetChildren() do
	assert(
		object:IsA("BasePart") or object:IsA("Model"),
		`{object} is not a valid object`
	)

	local newButton: TextButton = template:Clone()
	newButton.Name = object.Name
	newButton.Text = "" -- Clean default text out

	local viewport: ViewportFrame? = newButton:FindFirstChildOfClass("ViewportFrame")
	if not viewport then
		local newViewport = Instance.new("ViewportFrame")
		newViewport.Size = UDim2.fromScale(1, 1)
		newViewport.Position = UDim2.fromScale(0, 0)
		newViewport.BackgroundTransparency = 1
		newViewport.BorderSizePixel = 0
		newViewport.ZIndex = newButton.ZIndex + 1
		newViewport.Parent = newButton
		viewport = newViewport
	end

	SetupViewportPreview(viewport, object)

	local label: TextLabel? = newButton:FindFirstChildOfClass("TextLabel")
	if label then
		label.Text = object.Name
		label.ZIndex = viewport.ZIndex + 1
	end

	newButton.Parent = objects

	newButton.MouseButton1Click:Connect(function()
		previewTrove:Clean()

		PlacingService.SetPreview(object)
		previewTrove:Connect(renderedEvent, function(preview: Model, _, canPlace: boolean)
			previewHighlight.Adornee = preview

			if canPlace then previewHighlight.OutlineColor, previewHighlight.FillColor = canPlaceColor, canPlaceColor
			else previewHighlight.OutlineColor, previewHighlight.FillColor = cannotPlaceColor, cannotPlaceColor end
		end)

		previewTrove:Connect(UserInputS.InputBegan, function(inputObject: InputObject, gameProcessedEvent: boolean)
			if gameProcessedEvent then return end

			local rotateY: Enum.KeyCode = Settings.RotateY
			local cancel: Enum.KeyCode = Settings.Cancel

			if inputObject.UserInputType == Enum.UserInputType.MouseButton1 then 
				local preview: Instance? = PlacingService.GetPreview()
				if not preview then return end

				local CF: CFrame = PlacingService._CF
				local canPlace: boolean = PlacingService.CanPlace

				if not canPlace then return end

				local objectName: string = object.Name
				local placementId: string = HttpService:GenerateGUID(false) -- Generate dynamic identifier for tracking

				preview:PivotTo(CF)
				events.Remotes.Place:FireServer({
					ObjectName = objectName,
					CF = CF,
					PlacementId = placementId
				})

				-- Log to client undo history
				PushAction("Place", objectName, CF, placementId)

				if UserInputS:IsKeyDown(Enum.KeyCode.LeftControl) then return end

				previewTrove:Clean()
				PlacingService.Cancel()

				previewHighlight.Adornee = nil
			elseif inputObject.KeyCode == rotateY then PlacingService.Rotate(Vector3.yAxis)
			elseif inputObject.KeyCode == cancel then
				previewTrove:Clean()
				PlacingService.Cancel()

				previewHighlight.Adornee = nil
			end
		end)
	end)
end

-- Connect toolbar utility functions
deleteButton.MouseButton1Click:Connect(function()
	EnterDeleteMode()
end)

undoButton.MouseButton1Click:Connect(function()
	if #undoStack == 0 then return end

	local action = table.remove(undoStack)

	if action.Type == "Place" then
		-- Undoing placement means we delete it
		local targetItem: Instance? = nil
		for _, child in workspace.Objects:GetChildren() do
			if child:GetAttribute("PlacementId") == action.PlacementId then
				targetItem = child
				break
			end
		end

		if targetItem then
			events.Remotes.Delete:FireServer({
				Object = targetItem
			})
		end

	elseif action.Type == "Delete" then
		-- Undoing deletion means we place it back exactly where it was
		events.Remotes.Place:FireServer({
			ObjectName = action.ObjectName,
			CF = action.CF,
			PlacementId = action.PlacementId
		})
	end

	table.insert(redoStack, action)
	UpdateHistoryUI()
end)

redoButton.MouseButton1Click:Connect(function()
	if #redoStack == 0 then return end

	local action = table.remove(redoStack)

	if action.Type == "Place" then
		-- Redoing placement means we place it back down
		events.Remotes.Place:FireServer({
			ObjectName = action.ObjectName,
			CF = action.CF,
			PlacementId = action.PlacementId
		})

	elseif action.Type == "Delete" then
		-- Redoing deletion means we look for the reconstructed object and delete it again
		local targetItem: Instance? = nil
		for _, child in workspace.Objects:GetChildren() do
			if child:GetAttribute("PlacementId") == action.PlacementId then
				targetItem = child
				break
			end
		end

		if targetItem then
			events.Remotes.Delete:FireServer({
				Object = targetItem
			})
		end
	end

	table.insert(undoStack, action)
	UpdateHistoryUI()
end)

-- Initialize button dimming states on start
UpdateHistoryUI()

do
	local function OnCharacterAdded(char: Model)
		for _, child: Instance in char:GetChildren() do
			if not child:IsA("BasePart") then continue end

			child.CollisionGroup = "Player"
		end
	end

	player.CharacterAdded:Connect(OnCharacterAdded)

	local char: Model? = player.Character
	if char then OnCharacterAdded(char) end
end
