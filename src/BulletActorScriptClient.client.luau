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

local function endRecord(id: number, b: any, handoff: boolean)
	return {
		bulletId = id,
		casterId = b.casterId,
		handoff = handoff,
		position = b.position,
		velocity = b.velocity,
		time = b.time,
		travelled = b.travelled,
		power = b.penetrationPower,
	}
end

actor:BindToMessage("CastBullet", function(p)
	-- Built here (serial) and never modified again: RaycastParams can't be written in parallel
	local params = RaycastParams.new()
	params.FilterType = p.filterType
	params.FilterDescendantsInstances = p.filter
	params.IgnoreWater = p.ignoreWater
	params.RespectCanCollide = p.respectCanCollide
	params.CollisionGroup = p.collisionGroup

	bullets[p.bulletId] = {
		casterId = p.casterId,
		bullet = p.bullet,
		position = p.origin,
		velocity = p.velocity,
		extraForce = p.extraForce,
		time = p.time or 0,
		travelled = p.travelled or 0,
		lifetime = p.lifetime,
		rayParams = params,
		penetrationPower = p.penetrationPower,
		ricochetAngle = p.ricochetAngle,
		ricochetHardness = p.ricochetHardness,
		loss = p.loss,
	}
end)

actor:BindToMessage("Cleanup", function(ids: { number }, handoff: boolean?)
	local handed: { any } = {}
	for _, id in ids do
		local b = bullets[id]
		if b then
			bullets[id] = nil
			if handoff then
				table.insert(handed, endRecord(id, b, true))
			end
		end
	end
	if #handed > 0 then
		endEvent:Fire(handed)
	end
end)

RunService.Heartbeat:ConnectParallel(function(deltaTime: number)
	local updates: { any }?, hits: { any }?, ended: { any }?
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
				local result = workspace:Raycast(from, to - from, b.rayParams)
				if not result then
					break
				end

				b.travelled += (result.Position - from).Magnitude
				from = result.Position
				local travelledAtHit = b.travelled

				local hardness = hardnessTable[result.Material] or hardnessTable.Default
				local decision = Math.Resolve(
					result, b.velocity, hardness,
					b.ricochetAngle, b.ricochetHardness, b.penetrationPower, b.loss,
					b.rayParams
				)
				local hitType = decision.Type

				if hitType == "Penetration" then
					local speed = b.velocity.Magnitude
					local newVelocity = decision.Velocity :: Vector3
					local ratio = if speed > 0 then newVelocity.Magnitude / speed else 0
					b.penetrationPower -= (decision.Cost :: number)
					b.velocity = newVelocity
					from = decision.Position :: Vector3
					b.travelled += (from - result.Position).Magnitude
					to = Math.ContinueSegment(result.Position, to, from, ratio)
				elseif hitType == "Ricochet" then
					b.velocity = (decision.Velocity :: Vector3)
					b.position = (decision.Position :: Vector3)
					b.travelled += (b.position - result.Position).Magnitude
					from = b.position
					to = b.position
				else
					to = result.Position
					stop = true
				end

				hits = hits or {}
				table.insert(hits, {
					bulletId = id,
					casterId = b.casterId,
					type = hitType,
					humanoid = decision.Humanoid,
					hitPosition = result.Position,
					position = decision.Position or result.Position,
					normal = result.Normal,
					instance = result.Instance,
					material = result.Material,
					distance = result.Distance,
					velocity = b.velocity,
					time = b.time,
					travelled = travelledAtHit,
					power = b.penetrationPower,
				})

				if hitType ~= "Penetration" then
					break
				end
			end

			b.travelled += (to - from).Magnitude
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
			table.insert(ended, endRecord(id, b, false))
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
