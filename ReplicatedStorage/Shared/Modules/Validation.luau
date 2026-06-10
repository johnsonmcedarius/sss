local RepS = game:GetService("ReplicatedStorage")

local shared = RepS.Shared
local events = RepS.Events

local libraries = RepS.Libraries

local Settings = require(shared.Settings)

local ParamsBuilder = require(libraries.ParamsBuilder)

type Params = ParamsBuilder.Params

local Validation = {}

local function Snap(number: number, unit: number): number
	return math.floor(number / unit + 0.5) * unit
end

-- Checks if the preview is completely enclosed within the horizontal boundaries of the Plot Base
function Validation.IsInsidePlot(toCheck: Instance, plotBase: BasePart?): boolean
	if not plotBase then return true end -- If no plot base defined, bypass to allow testing anywhere

	local plotCF: CFrame = plotBase.CFrame
	local plotSize: Vector3 = plotBase.Size

	local previewCF: CFrame, previewSize: Vector3
	if toCheck:IsA("Model") then
		previewCF, previewSize = toCheck:GetBoundingBox()
	elseif toCheck:IsA("BasePart") then
		previewCF, previewSize = toCheck.CFrame, toCheck.Size
	else
		return false
	end

	-- Transform all 8 outer corners of the physical bounding box to the Plot Base local coordinate space
	local half: Vector3 = previewSize / 2
	local localCorners: { Vector3 } = {
		Vector3.new(half.X, half.Y, half.Z),
		Vector3.new(-half.X, half.Y, half.Z),  
		Vector3.new(half.X, -half.Y, half.Z),
		Vector3.new(half.X, half.Y, -half.Z),
		Vector3.new(-half.X, -half.Y, half.Z),
		Vector3.new(half.X, -half.Y, -half.Z),
		Vector3.new(-half.X, half.Y, -half.Z),
		Vector3.new(-half.X, -half.Y, -half.Z),
	}

	for _, localCorner: Vector3 in localCorners do
		local worldPoint: Vector3 = previewCF:PointToWorldSpace(localCorner)
		local pointInPlotLocal: Vector3 = plotCF:PointToObjectSpace(worldPoint)

		-- Check if the corner exceeds the X/Z boundaries of the Plot floor.
		-- We add a minute buffer of 0.01 studs to prevent floating-point precision issues
		if math.abs(pointInPlotLocal.X) > plotSize.X / 2 + 0.01 or
			math.abs(pointInPlotLocal.Z) > plotSize.Z / 2 + 0.01 then
			return false
		end

		-- Check if the player is trying to place items below the floor level
		if pointInPlotLocal.Y < -plotSize.Y / 2 - 0.5 then
			return false
		end
	end

	return true
end

function Validation.HasValidPlacement(toCheck: any, plotBase: BasePart?): boolean
	if not toCheck then return end

	-- Verify boundaries first. If the object isn't inside their plot, immediately fail validation!
	if typeof(toCheck) == "table" then
		for _, instance: Instance in toCheck do
			if not Validation.IsInsidePlot(instance, plotBase) then return false end
		end
	else
		if not Validation.IsInsidePlot(toCheck, plotBase) then return false end
	end

	local overlapParams: OverlapParams = OverlapParams.new()
	local params: Params = ParamsBuilder.new(overlapParams)

	local function HasValidPlacement(basePart: BasePart, parent: Instance?): boolean
		local CF: CFrame = basePart.CFrame
		local size: Vector3 = basePart.Size

		if not basePart.CanQuery then return true end
		if Settings.CanOverlapWithOtherParts then return true end

		local intersectingParts: { BasePart } = workspace:GetPartsInPart(basePart, overlapParams)
		for _, intersectingPart: BasePart in intersectingParts do
			if (
				parent and
					intersectingPart:IsDescendantOf(parent)
				)
			then
				continue end

			local ignoreCollision: boolean = intersectingPart:HasTag("Object_IgnoreCollision")
			if ignoreCollision then continue end

			return false
		end

		return true
	end

	params.CollisionGroup = ""
	params:Include(workspace.Objects)
	params:Include(workspace.Other)

	if typeof(toCheck) == "table" then 
		for _, instance: Instance in toCheck do 
			if not instance:IsA("BasePart") then continue end

			local hasValidPlacement: boolean = HasValidPlacement(instance)
			if hasValidPlacement then continue end

			return false
		end
	elseif toCheck:IsA("BasePart") then
		local hasValidPlacement: boolean = HasValidPlacement(toCheck)
		return hasValidPlacement
	elseif toCheck:IsA("Model") then 
		for _, descendant: BasePart in toCheck:GetDescendants() do 
			if not descendant:IsA("BasePart") then continue end

			local hasValidPlacement: boolean = HasValidPlacement(descendant, toCheck)
			if hasValidPlacement then continue end

			return false
		end 
	end

	return true
end

return Validation
