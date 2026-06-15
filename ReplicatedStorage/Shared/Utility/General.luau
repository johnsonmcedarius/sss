local UserInputS = game:GetService("UserInputService")
local RepS = game:GetService("ReplicatedStorage")

local shared = RepS.Shared
local events = RepS.Events

local camera: Camera = workspace.CurrentCamera

local RAYCAST_DISTANCE: number = 2^11

local General = {}

--[[
	Abbreviates numbers gracefully based on scale thresholds:
	- Less than 1K: Whole integers
	- Between 1K and 999K: Rounds to one decimal with a "K" (e.g., 1.5K)
	- 1M+: Rounds to one decimal with an "M" (e.g., 1.5M)
]]
function General.Abbreviate(value: number): string
	local absVal = math.abs(value)
	if absVal < 1000 then
		return string.format("%d", value)
	elseif absVal < 1000000 then
		local formatted = string.format("%.1f", value / 1000)
		-- Clean up trailing .0 for cleaner aesthetics (e.g. "1.0K" -> "1K")
		if string.sub(formatted, -2) == ".0" then
			formatted = string.sub(formatted, 1, -3)
		end
		return formatted .. "K"
	else
		local formatted = string.format("%.1f", value / 1000000)
		if string.sub(formatted, -2) == ".0" then
			formatted = string.sub(formatted, 1, -3)
		end
		return formatted .. "M"
	end
end

--[[
	Standard Linear Interpolation (Frame-rate independent alpha helper)
]]
function General.Lerp(startValue: number, endValue: number, alpha: number): number
	return startValue + (endValue - startValue) * alpha
end

function General.IsPointInPart(part: BasePart, point: Vector3): boolean
	local relativePoint: Vector3 = part.CFrame:PointToObjectSpace(point)

	return math.abs(relativePoint.X) < part.Size.X / 2
		and math.abs(relativePoint.Y) < part.Size.Y / 2
		and math.abs(relativePoint.Z) < part.Size.Z / 2
end

function General.Weld(part0: BasePart, part1: BasePart): WeldConstraint
	local weldConstraint: WeldConstraint = Instance.new("WeldConstraint")
	weldConstraint.Part0 = part0
	weldConstraint.Part1 = part1
	weldConstraint.Parent = part0

	return weldConstraint
end

function General.GetMouseResult(raycastParams: RaycastParams?): RaycastResult?
	local mousePos: Vector2 = UserInputS:GetMouseLocation()
	local ray: Ray = camera:ViewportPointToRay(mousePos.X, mousePos.Y)

	local currentParams: RaycastParams = raycastParams or RaycastParams.new()
	local raycastResult: RaycastResult? = workspace:Raycast(ray.Origin, ray.Direction * RAYCAST_DISTANCE, currentParams)

	return raycastResult
end

return General
