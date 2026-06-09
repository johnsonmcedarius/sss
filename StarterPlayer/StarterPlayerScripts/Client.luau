local UserInputS = game:GetService("UserInputService")
local RepS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local modules = script.Parent.Modules
local shared = RepS.Shared
local events = RepS.Events

local libraries = RepS.Libraries

local Settings = require(shared.Settings)

local Trove = require(libraries.Trove)
local LemonSignal = require(libraries.LemonSignal)

local PlacingService = require(modules.PlacingService)

local player: Player = Players.LocalPlayer
local coreGui: ScreenGui = player.PlayerGui:WaitForChild("CoreGui")

local guiVisual: Folder = coreGui.Visual

local objects: Frame = coreGui.Objects
local template: ImageButton = objects.Template

local previewHighlight: Highlight = guiVisual.PreviewHighlight

local canPlaceColor: Color3 = Settings.CanPlaceColor
local cannotPlaceColor: Color3 = Settings.CannotPlaceColor

local previewTrove: Trove = Trove.new()
local renderedEvent: Signal<Instance, number, boolean> = PlacingService.Rendered

type Trove = Trove.Trove
type Signal<T...> = LemonSignal.Signal<T...>

template.Parent = nil

-- Highly optimized helper to render a 3D preview of any object inside a ViewportFrame
local function SetupViewportPreview(viewport: ViewportFrame, originalObject: Instance)
	viewport:ClearAllChildren()

	-- Clone asset into viewport and make sure it has zero physics interactions
	local previewObject: Instance = originalObject:Clone()

	-- Strip out unnecessary client-side visual clutter or performance hogs
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

	-- Create and configure a viewport camera
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

	-- Calculate perfect distance based on bounding size so the asset fits perfectly without clipping
	local maxDim: number = math.max(size.X, size.Y, size.Z)
	local distance: number = maxDim / (2 * math.tan(math.rad(camera.FieldOfView / 2))) * 1.4 -- 1.4 adds safety padding

	-- Set up a sleek high-angle isometric perspective (pointing down and slightly turned)
	local cameraOffset = Vector3.new(1.1, 0.8, 1.1).Unit * distance
	camera.CFrame = CFrame.new(center.Position + cameraOffset, center.Position)

	viewport.CurrentCamera = camera
	camera.Parent = viewport
end

for _, object: Instance in shared.Assets:GetChildren() do
	assert(
		object:IsA("BasePart") or object:IsA("Model"),
		`{object} is not a valid object`
	)

	local newButton: ImageButton = template:Clone()
	newButton.Name = object.Name

	-- Grab or dynamically construct a ViewportFrame inside our button
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

	-- Generate our beautiful real-time 3D thumbnail!
	SetupViewportPreview(viewport, object)

	-- Update text caption label if you have one inside the template (e.g. for display names)
	local label: TextLabel? = newButton:FindFirstChildOfClass("TextLabel")
	if label then
		label.Text = object.Name
		label.ZIndex = viewport.ZIndex + 1 -- Make sure text renders on top of the model
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

				preview:PivotTo(CF)
				events.Remotes.Place:FireServer({
					ObjectName = objectName,
					CF = CF
				})

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
