--!strict
--!optimize 2
-- Shared ballistics. Used by the single-threaded caster and the parallel actors
-- so penetration/ricochet behave identically in both paths.

local Math = {}

local MAX_PROBE = 512
-- Max obstacles stepped over while searching for a penetration exit
local MAX_EXIT_STEPS = 8
-- Lift the next ray off a surface (ricochet, penetration exit) so it can't re-hit it
local SURFACE_OFFSET = 0.01

export type HitType = "Impact" | "Humanoid" | "Ricochet" | "Penetration"
export type Decision = {
	Type: HitType,
	Stop: boolean,
	Humanoid: Humanoid?,
	Velocity: Vector3?,
	Position: Vector3?,
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

local function findHumanoid(instance: Instance): Humanoid?
	local model = instance:FindFirstAncestorOfClass("Model")
	while model do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			return humanoid
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

-- Finds where a ray leaves `instance` by casting back from beyond it. Uses the
-- bullet's own params and steps past anything in the way instead of swapping in
-- an Include filter: RaycastParams can't be modified in parallel.
local function findExit(instance: BasePart, entry: Vector3, travel: Vector3, params: RaycastParams): Vector3?
	local probe = math.min(instance.Size.Magnitude, MAX_PROBE)
	local origin = entry + travel * probe
	local remaining = probe
	for _ = 1, MAX_EXIT_STEPS do
		local hit = workspace:Raycast(origin, -travel * remaining, params)
		if not hit then
			return nil
		end
		if hit.Instance == instance then
			return hit.Position
		end
		local advance = hit.Distance + SURFACE_OFFSET
		remaining -= advance
		if remaining <= 0 then
			return nil
		end
		origin -= travel * advance
	end
	return nil
end

-- After a penetration, returns the new segment end: the travel left in this step
-- past the exit, scaled by the speed kept.
function Math.ContinueSegment(entry: Vector3, to: Vector3, resume: Vector3, speedRatio: number): Vector3
	local segment = to - entry
	local length = segment.Magnitude
	if length == 0 then
		return resume
	end
	local left = math.max(length - (resume - entry).Magnitude, 0) * speedRatio
	return resume + segment / length * left
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
	loss: number?,
	params: RaycastParams
): Decision
	local instance = result.Instance
	local humanoid = instance and findHumanoid(instance)
	if humanoid then
		return { Type = "Humanoid", Stop = true, Humanoid = humanoid }
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
			return {
				Type = "Ricochet",
				Stop = false,
				Velocity = reflected,
				Position = result.Position + normal * SURFACE_OFFSET,
			}
		end
	end

	if penetrationPower and instance and instance ~= workspace.Terrain then
		-- No exit found means we can't measure the part, so treat it as solid
		local exit = findExit(instance :: BasePart, result.Position, travel, params)
		if exit then
			local cost = (exit - result.Position).Magnitude * hardness
			if penetrationPower >= cost then
				local kept = if penetrationPower > 0 then math.sqrt((penetrationPower - cost) / penetrationPower) else 1
				return {
					Type = "Penetration",
					Stop = false,
					Cost = cost,
					Velocity = velocity * kept,
					-- Resume just past the exit so the part never needs filtering out
					Position = exit + travel * SURFACE_OFFSET,
				}
			end
		end
	end

	return { Type = "Impact", Stop = true }
end

return Math
