--!strict
--!optimize 2
-- Shared ballistics. Used by the single-threaded caster and the parallel actors
-- so penetration/ricochet behave identically in both paths.

local Math = {}

local MAX_PROBE = 512
local backParams = RaycastParams.new()
backParams.FilterType = Enum.RaycastFilterType.Include

export type HitType = "Impact" | "Humanoid" | "Ricochet" | "Penetration"
export type Decision = {
	Type: HitType,
	Stop: boolean,
	Humanoid: Humanoid?,
	Velocity: Vector3?,
	Cost: number?,
}

function Math.Displacement(velocity: Vector3, force: Vector3, t: number): Vector3
	return velocity * t + force * (0.5 * t * t)
end

function Math.CloneRayParams(src: RaycastParams): RaycastParams
	local p = RaycastParams.new()
	p.FilterType = src.FilterType
	p.IgnoreWater = src.IgnoreWater
	p.RespectCanCollide = src.RespectCanCollide
	p.CollisionGroup = src.CollisionGroup
	return p
end

-- Decides what a bullet does when its segment hits something. Pure aside from
-- read-only spatial queries, so it is safe to call from parallel actor code.
function Math.Resolve(
	result: RaycastResult,
	velocity: Vector3,
	hardness: number,
	ricochetAngle: number?,
	ricochetHardness: number?,
	penetrationPower: number?,
	loss: number?
): Decision
	local instance = result.Instance
	local model = instance and instance:FindFirstAncestorOfClass("Model")
	if model then
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			return { Type = "Humanoid", Stop = true, Humanoid = humanoid }
		end
	end

	local speed = velocity.Magnitude
	local travel = speed > 0 and velocity / speed or -Vector3.zAxis
	local normal = result.Normal

	if ricochetAngle then
		local grazing = math.deg(math.asin(math.clamp(-travel:Dot(normal), 0, 1)))
		if grazing <= ricochetAngle and hardness >= (ricochetHardness or 0) then
			local reflected = velocity - (2 * velocity:Dot(normal)) * normal
			if loss then
				reflected *= 1 - loss
			end
			return { Type = "Ricochet", Stop = false, Velocity = reflected }
		end
	end

	if penetrationPower and instance and instance ~= workspace.Terrain then
		local probe = math.min(instance.Size.Magnitude, MAX_PROBE)
		backParams.FilterDescendantsInstances = { instance }
		local back = workspace:Raycast(result.Position + travel * probe, -travel * probe, backParams)
		local exit = back and back.Position or result.Position
		local cost = (exit - result.Position).Magnitude * hardness
		if penetrationPower >= cost then
			return { Type = "Penetration", Stop = false, Cost = cost }
		end
	end

	return { Type = "Impact", Stop = true }
end

return Math
