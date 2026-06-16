local UserInputS = game:GetService("UserInputService")
local RepS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunS = game:GetService("RunService")
local TweenS = game:GetService("TweenService")

local modules = script.Parent.Modules
local shared = RepS.Shared
local events = RepS.Events
local libraries = RepS.Libraries

local Settings = require(shared.Settings)
local Utility = require(shared.Utility)

local Trove = require(libraries.Trove)
local LemonSignal = require(libraries.LemonSignal)
local ParamsBuilder = require(libraries.ParamsBuilder)

-- Controllers & Services
local PlacingService = require(modules.PlacingService)
local ShopController = require(modules.ShopController)
local CrateToolController = require(modules.CrateToolController)
local StockingController = require(modules.StockingController)
local EconomyViewController = require(modules.EconomyViewController)

local player: Player = Players.LocalPlayer
local camera: Camera = workspace.CurrentCamera
local playerGui = player:WaitForChild("PlayerGui")

local coreGui: ScreenGui = playerGui:WaitForChild("CoreGui")
local guiVisual: Folder = coreGui.Visual
local toolbar: Frame = coreGui:WaitForChild("Toolbar")
local buildGui: ScreenGui = playerGui:WaitForChild("BuildGui")

local undoButton: ImageButton = toolbar:WaitForChild("Undo")
local redoButton: ImageButton = toolbar:WaitForChild("Redo")
local deleteButton: ImageButton = toolbar:WaitForChild("Delete")
local gridButton: ImageButton = toolbar:WaitForChild("Grid")
local paintButton: ImageButton = toolbar:WaitForChild("Paint")

local cancelFrame: Frame = coreGui:WaitForChild("CancelFrame")
local cancelTextLabel: TextLabel = cancelFrame:FindFirstChildOfClass("TextLabel")
local cancelTextButton: TextButton = cancelFrame:FindFirstChildOfClass("TextButton")

local objects: Frame = coreGui.Objects
local template: TextButton = objects.Template

local previewHighlight: Highlight = guiVisual.PreviewHighlight

local canPlaceColor: Color3 = Settings.CanPlaceColor
local cannotPlaceColor: Color3 = Settings.CannotPlaceColor

local previewTrove: Trove.Trove = Trove.new()
local renderedEvent = PlacingService.Rendered

local undoStack = {}
local redoStack = {}
local activeGridPrecision: number = Settings.GridUnit

local isEditing = false
local editingInstance: Instance? = nil
local originalCF: CFrame? = nil
local editingPlacementId: string? = nil

local claimPlotGui = playerGui:WaitForChild("ClaimPlotGui")
local mainButtonsGui = playerGui:WaitForChild("MainButtonsGui")

local leftArrow: TextButton = claimPlotGui:FindFirstChild("LeftArrowButton", true)
local rightArrow: TextButton = claimPlotGui:FindFirstChild("RightArrowButton", true)
local claimButton: TextButton = claimPlotGui:FindFirstChild("ClaimPlotButton", true)

local buildButton: ImageButton = mainButtonsGui:FindFirstChild("buildbutton", true) or mainButtonsGui:FindFirstChild("BuildButton", true)

local availablePlots = {}
local currentSelectionIndex = 1
local cameraTrove = Trove.new()

template.Parent = nil

local tweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local onScreenPosition = UDim2.new(0.95, 0, 0.5, 0)
local offScreenPosition = UDim2.new(1.3, 0, 0.5, 0)

local EnterEditMode

local function GetPlayerPlotBase(): BasePart?
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

local function UpdateGridTextureVisuals(forceDisable: boolean?)
	local base = GetPlayerPlotBase()
	if not base then return end

	local gridTexture = base:FindFirstChild("GridTexture")
	if gridTexture and gridTexture:IsA("Texture") then
		if forceDisable then
			gridTexture.Transparency = 1
		else
			gridTexture.Transparency = if objects.Visible then 0.5 else 1
			gridTexture.StudsPerTileU = activeGridPrecision
			gridTexture.StudsPerTileV = activeGridPrecision
		end
	end
end

local function SlideCancelFrame(show: boolean, itemName: string?)
	if show and itemName then
		cancelTextLabel.Text = itemName
		TweenS:Create(cancelFrame, tweenInfo, {Position = onScreenPosition}):Play()
	else
		TweenS:Create(cancelFrame, tweenInfo, {Position = offScreenPosition}):Play()
	end
end

local function CancelActiveSession()
	if isEditing and editingInstance and originalCF then
		editingInstance.Parent = workspace.Objects
		editingInstance:PivotTo(originalCF)
	end

	isEditing = false
	editingInstance = nil
	originalCF = nil
	editingPlacementId = nil

	previewTrove:Clean()
	PlacingService.Cancel()
	previewHighlight.Adornee = nil
	SlideCancelFrame(false)
	UpdateGridTextureVisuals()
end

local function RefreshAvailablePlots()
	table.clear(availablePlots)
	for i = 1, 6 do
		local plot = workspace:FindFirstChild("Plot" .. i)
		if plot then
			table.insert(availablePlots, plot)
		end
	end
end

local function FocusCameraOnPlot(plot: Instance)
	cameraTrove:Clean()
	camera.CameraType = Enum.CameraType.Scriptable

	local centerCF: CFrame = if plot:IsA("Model") then plot:GetPivot() else (plot:IsA("BasePart") and plot.CFrame or CFrame.identity)

	cameraTrove:BindToRenderStep("CameraPan", Enum.RenderPriority.Camera.Value, function()
		local targetCameraCF = centerCF * CFrame.new(0, 45, 65) * CFrame.Angles(math.rad(-33), 0, 0)
		camera.CFrame = camera.CFrame:Lerp(targetCameraCF, 0.1)
	end)
end

local function UpdateSelectionVisuals()
	if #availablePlots == 0 then return end
	local targetPlot = availablePlots[currentSelectionIndex]
	if not targetPlot then return end

	FocusCameraOnPlot(targetPlot)

	local ownerId = targetPlot:GetAttribute("Owner")
	local ownerName = targetPlot:GetAttribute("OwnerName")

	if ownerId then
		claimButton.Text = "Taken by " .. (ownerName or "Player")
		claimButton.BackgroundColor3 = Color3.fromRGB(150, 150, 150)
		claimButton.Active = false
	else
		claimButton.Text = "Claim Plot"
		claimButton.BackgroundColor3 = Color3.fromRGB(0, 170, 127)
		claimButton.Active = true
	end
end

local function CycleGridPrecision()
	if activeGridPrecision == 1 then activeGridPrecision = 2
	elseif activeGridPrecision == 2 then activeGridPrecision = 4
	else activeGridPrecision = 1 end

	PlacingService.GridUnit = activeGridPrecision

	local targetIcon: string? = Settings.GridIcons[activeGridPrecision]
	if targetIcon then gridButton.Image = targetIcon end
	UpdateGridTextureVisuals()
end

local function UpdateHistoryUI()
	undoButton.ImageTransparency = if #undoStack > 0 then 0 else 0.5
	redoButton.ImageTransparency = if #redoStack > 0 then 0 else 0.5
end

local function PushAction(actionType: "Place" | "Delete" | "Move", objectName: string, cf: CFrame, placementId: string, previousCF: CFrame?)
	table.insert(undoStack, {
		Type = actionType,
		ObjectName = objectName,
		CF = cf,
		PlacementId = placementId,
		PreviousCF = previousCF
	})
	table.clear(redoStack)
	UpdateHistoryUI()
end

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
	local cameraInstance = Instance.new("Camera")
	cameraInstance.FieldOfView = 45

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
	local distance: number = maxDim / (2 * math.tan(math.rad(cameraInstance.FieldOfView / 2))) * 1.4

	local cameraOffset = Vector3.new(1.1, 0.8, 1.1).Unit * distance
	cameraInstance.CFrame = CFrame.new(center.Position + cameraOffset, center.Position)

	viewport.CurrentCamera = cameraInstance
	cameraInstance.Parent = viewport
end

function EnterEditMode()
	CancelActiveSession()
	UpdateGridTextureVisuals()

	previewTrove:BindToRenderStep("EditHover", Enum.RenderPriority.Camera.Value, function()
		if not objects.Visible or isEditing then 
			if not isEditing then previewHighlight.Adornee = nil end
			return 
		end

		local raycastParams = RaycastParams.new()
		local params = ParamsBuilder.new(raycastParams)
		params:Include(workspace.Objects)

		local mouseResult = Utility.General.GetMouseResult(raycastParams)
		local target = if mouseResult then mouseResult.Instance else nil
		local rootObject = GetTargetObject(target)

		if rootObject then
			previewHighlight.Adornee = rootObject
			previewHighlight.OutlineColor = Color3.fromRGB(50, 150, 255)
			previewHighlight.FillColor = Color3.fromRGB(50, 150, 255)
			previewHighlight.FillTransparency = 0.6
		else
			previewHighlight.Adornee = nil
		end
	end)

	previewTrove:Connect(UserInputS.InputBegan, function(inputObject: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then return end
		if not objects.Visible or isEditing then return end

		if inputObject.UserInputType == Enum.UserInputType.MouseButton1 then
			local raycastParams = RaycastParams.new()
			local params = ParamsBuilder.new(raycastParams)
			params:Include(workspace.Objects)

			local mouseResult = Utility.General.GetMouseResult(raycastParams)
			local target = if mouseResult then mouseResult.Instance else nil
			local rootObject = GetTargetObject(target)

			if rootObject then
				isEditing = true
				editingInstance = rootObject
				originalCF = rootObject:GetPivot()
				editingPlacementId = rootObject:GetAttribute("PlacementId")
				local objectName = rootObject.Name

				rootObject.Parent = nil

				local asset = shared.Assets:FindFirstChild(objectName)
				if asset then
					PlacingService.GridUnit = activeGridPrecision
					PlacingService.SetPreview(asset)
					SlideCancelFrame(true, "Moving: " .. objectName)
					UpdateGridTextureVisuals()

					local editTrove = Trove.new()
					previewTrove:Add(editTrove)

					editTrove:Connect(renderedEvent, function(preview: Model, _, canPlace: boolean)
						previewHighlight.Adornee = preview
						if canPlace then previewHighlight.OutlineColor, previewHighlight.FillColor = canPlaceColor, canPlaceColor
						else previewHighlight.OutlineColor, previewHighlight.FillColor = cannotPlaceColor, cannotPlaceColor end
					end)

					editTrove:Connect(UserInputS.InputBegan, function(placementInput: InputObject, placementProcessed: boolean)
						if placementProcessed then return end

						local rotateY: Enum.KeyCode = Settings.RotateY
						local cancelKey: Enum.KeyCode = Settings.Cancel

						if placementInput.UserInputType == Enum.UserInputType.MouseButton1 then
							local preview: Instance? = PlacingService.GetPreview()
							if not preview then return end

							local CF: CFrame = PlacingService._CF
							local canPlace: boolean = PlacingService.CanPlace
							if not canPlace then return end

							if editingInstance then
								editingInstance.Parent = workspace.Objects
								editingInstance:PivotTo(CF)
								events.Remotes.Move:FireServer({
									Object = editingInstance,
									CF = CF
								})
								PushAction("Move", objectName, CF, editingPlacementId, originalCF)
							else
								local newPlacementId = editingPlacementId or HttpService:GenerateGUID(false)
								events.Remotes.Place:FireServer({
									ObjectName = objectName,
									CF = CF,
									PlacementId = newPlacementId
								})
								PushAction("Place", objectName, CF, newPlacementId)
							end

							isEditing = false
							editingInstance = nil
							originalCF = nil
							editingPlacementId = nil

							editTrove:Clean()
							EnterEditMode()
						elseif placementInput.KeyCode == rotateY then
							PlacingService.Rotate(Vector3.yAxis)
						elseif placementInput.KeyCode == cancelKey then
							if editingInstance then
								editingInstance.Parent = workspace.Objects
								editingInstance:PivotTo(originalCF)
							end

							isEditing = false
							editingInstance = nil
							originalCF = nil
							editingPlacementId = nil

							editTrove:Clean()
							EnterEditMode()
						end
					end)
				else
					rootObject.Parent = workspace.Objects
					isEditing = false
					editingInstance = nil
				end
			end
		end
	end)
end

local function EnterDeleteMode()
	CancelActiveSession()
	SlideCancelFrame(true, "Trash Tool")
	UpdateGridTextureVisuals()

	previewTrove:BindToRenderStep("DeleteHover", Enum.RenderPriority.Camera.Value, function()
		local raycastParams = RaycastParams.new()
		local params = ParamsBuilder.new(raycastParams)
		params:Include(workspace.Objects)

		local mouseResult = Utility.General.GetMouseResult(raycastParams)
		local target = if mouseResult then mouseResult.Instance else nil
		local rootObject = GetTargetObject(target)

		if rootObject then
			previewHighlight.Adornee = rootObject
			previewHighlight.OutlineColor = Color3.fromRGB(255, 50, 50)
			previewHighlight.FillColor = Color3.fromRGB(255, 50, 50)
			previewHighlight.FillTransparency = 0.6
		else
			previewHighlight.Adornee = nil
		end
	end)

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

				if not placementId then
					placementId = HttpService:GenerateGUID(false)
					rootObject:SetAttribute("PlacementId", placementId)
				end

				events.Remotes.Delete:FireServer({ Object = rootObject })
				PushAction("Delete", objectName, cf, placementId)
			end
		elseif inputObject.KeyCode == Settings.Cancel then
			CancelActiveSession()
			EnterEditMode()
		end
	end)
end

for _, object: Instance in shared.Assets:GetChildren() do
	assert(object:IsA("BasePart") or object:IsA("Model"), `{object} is not a valid object`)

	local newButton: TextButton = template:Clone()
	newButton.Name = object.Name
	newButton.Text = ""

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
		CancelActiveSession()

		PlacingService.GridUnit = activeGridPrecision
		PlacingService.SetPreview(object)

		local assetName = object.Name
		SlideCancelFrame(true, "Placing: " .. assetName)
		UpdateGridTextureVisuals()

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
				local placementId: string = HttpService:GenerateGUID(false)

				preview:PivotTo(CF)
				events.Remotes.Place:FireServer({
					ObjectName = objectName,
					CF = CF,
					PlacementId = placementId
				})

				PushAction("Place", objectName, CF, placementId)

				if UserInputS:IsKeyDown(Enum.KeyCode.LeftControl) then return end

				CancelActiveSession()
				EnterEditMode()
			elseif inputObject.KeyCode == rotateY then PlacingService.Rotate(Vector3.yAxis)
			elseif inputObject.KeyCode == cancel then
				CancelActiveSession()
				EnterEditMode()
			end
		end)
	end)
end

if buildButton then
	buildButton.MouseButton1Click:Connect(function()
		local nextVisibility = not objects.Visible
		objects.Visible = nextVisibility
		toolbar.Visible = nextVisibility

		if nextVisibility then
			EnterEditMode()
		else
			CancelActiveSession()
			UpdateGridTextureVisuals(true)
		end
	end)
end

cancelTextButton.MouseButton1Click:Connect(function()
	CancelActiveSession()
	EnterEditMode()
end)

gridButton.MouseButton1Click:Connect(function()
	CycleGridPrecision()
end)

deleteButton.MouseButton1Click:Connect(function()
	EnterDeleteMode()
end)

undoButton.MouseButton1Click:Connect(function()
	if #undoStack == 0 then return end
	local action = table.remove(undoStack)

	if action.Type == "Place" then
		local targetItem: Instance? = nil
		for _, child in workspace.Objects:GetChildren() do
			if child:GetAttribute("PlacementId") == action.PlacementId then
				targetItem = child
				break
			end
		end
		if targetItem then 
			events.Remotes.Delete:FireServer({ Object = targetItem, ObjectName = action.ObjectName }) 
		end
	elseif action.Type == "Delete" then
		local restoreRemote = events.Remotes:FindFirstChild("Restore")
		if restoreRemote then
			restoreRemote:FireServer({
				ObjectName = action.ObjectName,
				CF = action.CF,
				PlacementId = action.PlacementId
			})
		else
			events.Remotes.Place:FireServer({
				ObjectName = action.ObjectName,
				CF = action.CF,
				PlacementId = action.PlacementId
			})
		end
	elseif action.Type == "Move" then
		local targetItem: Instance? = nil
		for _, child in workspace.Objects:GetChildren() do
			if child:GetAttribute("PlacementId") == action.PlacementId then
				targetItem = child
				break
			end
		end
		if targetItem and action.PreviousCF then
			targetItem:PivotTo(action.PreviousCF)
			events.Remotes.Move:FireServer({
				Object = targetItem,
				CF = action.PreviousCF
			})
		end
	end

	table.insert(redoStack, action)
	UpdateHistoryUI()
end)

redoButton.MouseButton1Click:Connect(function()
	if #redoStack == 0 then return end
	local action = table.remove(redoStack)

	if action.Type == "Place" then
		local restoreRemote = events.Remotes:FindFirstChild("Restore")
		if restoreRemote then
			restoreRemote:FireServer({
				ObjectName = action.ObjectName,
				CF = action.CF,
				PlacementId = action.PlacementId
			})
		else
			events.Remotes.Place:FireServer({
				ObjectName = action.ObjectName,
				CF = action.CF,
				PlacementId = action.PlacementId
			})
		end
	elseif action.Type == "Delete" then
		local targetItem: Instance? = nil
		for _, child in workspace.Objects:GetChildren() do
			if child:GetAttribute("PlacementId") == action.PlacementId then
				targetItem = child
				break
			end
		end

		if targetItem then 
			events.Remotes.Delete:FireServer({ Object = targetItem, ObjectName = action.ObjectName }) 
		else
			events.Remotes.Delete:FireServer({ PlacementId = action.PlacementId, ObjectName = action.ObjectName })
		end
	elseif action.Type == "Move" then
		local targetItem: Instance? = nil
		for _, child in workspace.Objects:GetChildren() do
			if child:GetAttribute("PlacementId") == action.PlacementId then
				targetItem = child
				break
			end
		end
		if targetItem then
			targetItem:PivotTo(action.CF)
			events.Remotes.Move:FireServer({
				Object = targetItem,
				CF = action.CF
			})
		end
	end

	table.insert(undoStack, action)
	UpdateHistoryUI()
end)

UserInputS.InputBegan:Connect(function(inputObject: InputObject, gameProcessedEvent: boolean)
	if gameProcessedEvent then return end
	if inputObject.KeyCode == Settings.GridCycleKey then
		CycleGridPrecision()
	end
end)

UpdateHistoryUI()
local initialIcon: string? = Settings.GridIcons[activeGridPrecision]
if initialIcon then gridButton.Image = initialIcon end

local function InitializeEntryFlow()
	RefreshAvailablePlots()

	mainButtonsGui.Enabled = false
	coreGui.Enabled = false
	objects.Visible = false
	toolbar.Visible = false
	cancelFrame.Position = offScreenPosition

	claimPlotGui.Enabled = true
	if #availablePlots > 0 then UpdateSelectionVisuals()
	else
		claimPlotGui.Enabled = false
		mainButtonsGui.Enabled = true
		coreGui.Enabled = true
	end
end

player:GetAttributeChangedSignal("ClaimedPlot"):Connect(function()
	local claimedPlot = player:GetAttribute("ClaimedPlot")
	if claimedPlot then
		cameraTrove:Clean()
		camera.CameraType = Enum.CameraType.Custom

		claimPlotGui.Enabled = false
		mainButtonsGui.Enabled = true
		coreGui.Enabled = true

		if objects.Visible then
			EnterEditMode()
		else
			UpdateGridTextureVisuals(true)
		end
	end
end)

leftArrow.MouseButton1Click:Connect(function()
	if #availablePlots <= 1 then return end
	currentSelectionIndex = if currentSelectionIndex == 1 then #availablePlots else currentSelectionIndex - 1
	UpdateSelectionVisuals()
end)

rightArrow.MouseButton1Click:Connect(function()
	if #availablePlots <= 1 then return end
	currentSelectionIndex = if currentSelectionIndex == #availablePlots then 1 else currentSelectionIndex + 1
	UpdateSelectionVisuals()
end)

claimButton.MouseButton1Click:Connect(function()
	if #availablePlots == 0 then return end
	local selectedPlot = availablePlots[currentSelectionIndex]
	if not selectedPlot then return end
	if not selectedPlot:GetAttribute("Owner") then
		events.Remotes.ClaimPlot:FireServer({ PlotName = selectedPlot.Name })
	end
end)

local function BindPlotListener(plot: Instance)
	if not string.find(plot.Name, "^Plot%d+$") then return end
	plot.AttributeChanged:Connect(function(attributeName)
		if attributeName == "Owner" or attributeName == "OwnerName" then
			RefreshAvailablePlots()
			UpdateSelectionVisuals()
		end
	end)
end

for _, child in workspace:GetChildren() do BindPlotListener(child) end
workspace.ChildAdded:Connect(BindPlotListener)

-- Initialize Local Systems
CrateToolController.Initialize()
ShopController.Initialize()
StockingController.Initialize()
EconomyViewController.Initialize()

print("[Client]: All client controllers and UI synced systems successfully loaded.")

task.spawn(InitializeEntryFlow)

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
