--!strict
--!optimize 2

if not script:GetActor() then
	return
end

local RunService = game:GetService("RunService")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

local actor = script:GetActor() :: Actor
local module = (script.Parent:WaitForChild("Module") :: ObjectValue).Value :: Instance
local Math = require(module:WaitForChild("Math") :: ModuleScript)

local holder = script.Parent.Parent
local hitEvent = holder:WaitForChild("BulletHit") :: BindableEvent
local endEvent = holder:WaitForChild("BulletEnd") :: BindableEvent

local MAX_FRAME = 0.1
local bullets: { [number]: any } = {}

-- Read by Caster:GetStats; a SharedTable so it can be written without synchronising
local stepTimes = SharedTableRegistry:GetSharedTable("EnaltCastActorStepTime")
local actorName = actor.Name
local positions = SharedTableRegistry:GetSharedTable("EnaltCastPositions" .. actorName)
local reportedIdle = false

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
		ricochets = b.ricochets,
		penetrations = b.penetrations,
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
		motor = p.motor, -- set on the client; Transform doesn't replicate so the server moves CFrame
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
		drag = p.drag,
		wind = p.wind,
		maxRicochets = p.maxRicochets,
		maxPenetrations = p.maxPenetrations,
		ricochets = p.ricochets or 0,
		penetrations = p.penetrations or 0,
		paused = p.paused,
		hardness = p.hardness, -- keyed by material name (see Caster hardnessByName)
		maxStep = 1 / p.updateRate,
	}
end)

actor:BindToMessage("SetVelocity", function(id: number, velocity: Vector3)
	local b = bullets[id]
	if b then
		b.velocity = velocity
	end
end)

actor:BindToMessage("SetPaused", function(id: number, paused: boolean)
	local b = bullets[id]
	if b then
		b.paused = paused
	end
end)

actor:BindToMessage("Cleanup", function(ids: { number }, handoff: boolean?)
	local handed: { any } = {}
	for _, id in ids do
		local b = bullets[id]
		if b then
			bullets[id] = nil
			positions[id] = nil
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
	if next(bullets) == nil then
		if not reportedIdle then
			reportedIdle = true
			stepTimes[actorName] = 0
		end
		return
	end
	reportedIdle = false
	local started = os.clock()

	local updates: { any }?, hits: { any }?, ended: { any }?

	for id, b in bullets do
		if b.paused then
			continue
		end
		local force = b.extraForce
		local maxStep = b.maxStep
		local hardnessTable = b.hardness
		local remaining = math.min(deltaTime, MAX_FRAME)
		local stop = false

		while remaining > 0 do
			local step = math.min(remaining, maxStep)
			remaining -= step
			b.time += step
			b.velocity = Math.Integrate(b.velocity, force, b.drag, b.wind, step)

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

				local hardness = Math.PartHardness(result.Instance)
					or hardnessTable[result.Material.Name]
					or hardnessTable.Default
				local decision = Math.Resolve(
					result, b.velocity, hardness,
					if Math.UnderLimit(b.ricochets, b.maxRicochets) then b.ricochetAngle else nil,
					b.ricochetHardness,
					if Math.UnderLimit(b.penetrations, b.maxPenetrations) then b.penetrationPower else nil,
					b.loss,
					b.rayParams
				)
				local hitType = decision.Type

				if hitType == "Penetration" then
					local speed = b.velocity.Magnitude
					local newVelocity = decision.Velocity :: Vector3
					local ratio = if speed > 0 then newVelocity.Magnitude / speed else 0
					b.penetrations += 1
					b.penetrationPower -= (decision.Cost :: number)
					b.velocity = newVelocity
					from = decision.Position :: Vector3
					b.travelled += (from - result.Position).Magnitude
					to = Math.ContinueSegment(result.Position, to, from, ratio)
				elseif hitType == "Ricochet" then
					b.ricochets += 1
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
					ricochets = b.ricochets,
					penetrations = b.penetrations,
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

		local target = b.motor or b.bullet
		if target then
			local v = b.velocity
			local facing = if v.Magnitude > 0 then v.Unit else -Vector3.zAxis
			updates = updates or {}
			table.insert(updates, target)
			table.insert(updates, CFrame.lookAlong(b.position, facing))
		end

		if stop then
			ended = ended or {}
			table.insert(ended, endRecord(id, b, false))
			bullets[id] = nil
			positions[id] = nil
		else
			positions[id] = b.position
		end
	end

	stepTimes[actorName] = os.clock() - started

	if not (updates or hits or ended) then
		return
	end

	task.synchronize()

	if updates then
		for i = 1, #updates, 2 do
			local target = updates[i]
			if target:IsA("Motor6D") then
				target.Transform = updates[i + 1]
			else
				(target :: BasePart).CFrame = updates[i + 1]
			end
		end
	end
	if hits then
		hitEvent:Fire(hits)
	end
	if ended then
		endEvent:Fire(ended)
	end
end)
