--!strict
--!optimize 2

if not script:GetActor() then
	return
end

local RunService = game:GetService("RunService")

local actor = script:GetActor() :: Actor
local module = (script.Parent:WaitForChild("Module") :: ObjectValue).Value :: Instance
local Settings = require(module:WaitForChild("Settings") :: ModuleScript)
local Math = require(module:WaitForChild("Math") :: ModuleScript)

local holder = script.Parent.Parent
local hitEvent = holder:WaitForChild("BulletHit") :: BindableEvent
local endEvent = holder:WaitForChild("BulletEnd") :: BindableEvent

local MAX_FRAME = 0.1
local hardnessTable: any = Settings.SurfaceHardness
local bullets: { [number]: any } = {}

actor:BindToMessage("CastBullet", function(p)
	local params = RaycastParams.new()
	params.FilterType = p.filterType
	params.FilterDescendantsInstances = p.filter
	params.IgnoreWater = p.ignoreWater
	params.RespectCanCollide = p.respectCanCollide
	params.CollisionGroup = p.collisionGroup

	bullets[p.bulletId] = {
		bullet = p.bullet,
		position = p.origin,
		velocity = p.velocity,
		extraForce = p.extraForce,
		time = p.time or 0,
		lifetime = p.lifetime,
		ignoreList = p.filter,
		rayParams = params,
		penetrationPower = p.penetrationPower,
		ricochetAngle = p.ricochetAngle,
		ricochetHardness = p.ricochetHardness,
		loss = p.loss,
	}
end)

actor:BindToMessage("Cleanup", function()
	bullets = {}
end)

RunService.Heartbeat:ConnectParallel(function(deltaTime: number)
	local updates: { any }?, hits: { any }?, ended: { number }?
	local maxStep = 1 / Settings.UpdateRate

	for id, b in bullets do
		local force = b.extraForce
		local remaining = math.min(deltaTime, MAX_FRAME)
		local stop = false

		while remaining > 0 do
			local step = math.min(remaining, maxStep)
			remaining -= step
			b.time += step
			b.velocity += force * step

			local from = b.position
			local to = from + b.velocity * step

			while true do
				b.rayParams.FilterDescendantsInstances = b.ignoreList
				local result = workspace:Raycast(from, to - from, b.rayParams)
				if not result then
					break
				end

				local hardness = hardnessTable[result.Material] or hardnessTable.Default
				local decision = Math.Resolve(
					result, b.velocity, hardness,
					b.ricochetAngle, b.ricochetHardness, b.penetrationPower, b.loss
				)

				hits = hits or {}
				table.insert(hits, {
					bulletId = id,
					type = decision.Type,
					humanoid = decision.Humanoid,
					position = result.Position,
					normal = result.Normal,
					instance = result.Instance,
					material = result.Material,
					distance = result.Distance,
				})

				if decision.Type == "Penetration" then
					b.penetrationPower -= (decision.Cost :: number)
					table.insert(b.ignoreList, result.Instance)
					from = result.Position
				elseif decision.Type == "Ricochet" then
					b.velocity = (decision.Velocity :: Vector3)
					b.position = result.Position
					to = result.Position
					break
				else
					to = result.Position
					stop = true
					break
				end
			end

			b.position = to
			if stop or b.time >= b.lifetime then
				stop = true
				break
			end
		end

		if b.bullet then
			local v = b.velocity
			local facing = if v.Magnitude > 0 then v.Unit else -Vector3.zAxis
			updates = updates or {}
			table.insert(updates, b.bullet)
			table.insert(updates, CFrame.lookAlong(b.position, facing))
		end

		if stop then
			ended = ended or {}
			table.insert(ended, id)
			bullets[id] = nil
		end
	end

	if not (updates or hits or ended) then
		return
	end

	task.synchronize()

	if updates then
		for i = 1, #updates, 2 do
			(updates[i] :: BasePart).CFrame = updates[i + 1]
		end
	end
	if hits then
		hitEvent:Fire(hits)
	end
	if ended then
		endEvent:Fire(ended)
	end
end)
