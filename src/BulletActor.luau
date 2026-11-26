--!strict
--!optimize 2
--!native

local SharedTableRegistry = game:GetService("SharedTableRegistry")

local Math = require(script.Parent.Math)

local MAX_FRAME = 0.1
local CAST_STRIDE = 12
local HIT_IMPACT = 1
local HIT_HUMANOID = 2
local HIT_RICOCHET = 3
local HIT_PENETRATION = 4
local ZERO = Vector3.zero
local FORWARD = -Vector3.zAxis
local MOVE_MODE = Enum.BulkMoveMode.FireCFrameChanged
local PHASE_STEP = 0.6180339887

type CasterState = {
	timeScale: number,
	lodLimits: { number }?,
	lodRates: { number }?,
}

type Spec = {
	casterId: number,
	caster: CasterState,
	force: Vector3,
	lifetime: number,
	params: RaycastParams,
	radius: number?,
	drag: number?,
	wind: Vector3,
	ricochetAngle: number?,
	ricochetHardness: number?,
	loss: number?,
	maxRicochets: number?,
	maxPenetrations: number?,
	tracks: boolean,
	hardness: { [string]: number },
	maxStep: number,
}

type Bullet = {
	id: number,
	spec: Spec,
	position: Vector3,
	velocity: Vector3,
	time: number,
	travelled: number,
	power: number?,
	ricochets: number,
	penetrations: number,
	paused: boolean,
	motor: Motor6D?,
	part: BasePart?,
	publish: boolean,
	phase: number,
}

return function(actor: Actor, events: BindableEvent)
	local actorName = actor.Name
	local stepTimes = SharedTableRegistry:GetSharedTable("EnaltCastActorStepTime")
	local positions = SharedTableRegistry:GetSharedTable("EnaltCastPositions" .. actorName)

	local casters: { [number]: CasterState } = {}
	local specs: { [number]: Spec } = {}
	local list: { Bullet } = {}
	local indexOf: { [number]: number } = {}
	local count = 0
	local reportedIdle = false
	local lodActive = false
	local clock = 0

	local function remove(index: number)
		local b = list[index]
		local last = list[count]
		list[index] = last
		indexOf[last.id] = index
		list[count] = nil
		indexOf[b.id] = nil
		count -= 1
	end

	local function refreshLod()
		lodActive = false
		for _, caster in casters do
			if caster.lodLimits then
				lodActive = true
				break
			end
		end
	end

	local Messages = {}

	function Messages.Cast(casterId: number, timeScale: number, defs: any, records: any, drops: any)
		local caster = casters[casterId]
		if not caster then
			caster = { timeScale = timeScale }
			casters[casterId] = caster
		end
		caster.timeScale = timeScale

		if defs then
			for _, def in defs do
				local params = RaycastParams.new()
				params.FilterType = def.filterType
				params.FilterDescendantsInstances = def.filter
				params.IgnoreWater = def.ignoreWater
				params.RespectCanCollide = def.respectCanCollide
				params.CollisionGroup = def.collisionGroup

				local drag = def.drag
				specs[def.id] = {
					casterId = casterId,
					caster = caster,
					force = def.extraForce,
					lifetime = def.lifetime,
					params = params,
					radius = def.radius,
					drag = if drag and drag > 0 then drag else nil,
					wind = def.wind or ZERO,
					ricochetAngle = def.ricochetAngle,
					ricochetHardness = def.ricochetHardness,
					loss = def.loss,
					maxRicochets = def.maxRicochets,
					maxPenetrations = def.maxPenetrations,
					tracks = def.tracks,
					hardness = def.hardness,
					maxStep = def.maxStep,
				}
			end
		end

		if records then
			for i = 1, #records, CAST_STRIDE do
				local spec = specs[records[i + 1]]
				if spec then
					local id = records[i]
					local motor = records[i + 10] or nil
					count += 1
					list[count] = {
						id = id,
						spec = spec,
						position = records[i + 2],
						velocity = records[i + 3],
						time = records[i + 4],
						travelled = records[i + 5],
						power = records[i + 6] or nil,
						ricochets = records[i + 7],
						penetrations = records[i + 8],
						paused = records[i + 9],
						motor = motor,
						part = records[i + 11] or nil,
						publish = motor == nil,
						phase = (id * PHASE_STEP) % 1,
					}
					indexOf[id] = count
				end
			end
		end

		if drops then
			for _, id in drops do
				specs[id] = nil
			end
		end
	end

	function Messages.SetVelocity(id: number, velocity: Vector3)
		local index = indexOf[id]
		if index then
			list[index].velocity = velocity
		end
	end

	function Messages.SetPaused(id: number, paused: boolean)
		local index = indexOf[id]
		if index then
			list[index].paused = paused
		end
	end

	function Messages.SetTimeScale(casterId: number, scale: number)
		local caster = casters[casterId]
		if caster then
			caster.timeScale = scale
		else
			casters[casterId] = { timeScale = scale }
		end
	end

	function Messages.SetRenderLOD(casterId: number, limits: any, rates: any)
		local caster = casters[casterId]
		if not caster then
			caster = { timeScale = 1 }
			casters[casterId] = caster
		end
		caster.lodLimits = limits or nil
		caster.lodRates = rates or nil
		refreshLod()
	end

	function Messages.DropCaster(casterId: number)
		casters[casterId] = nil
		refreshLod()
		for id, spec in specs do
			if spec.casterId == casterId then
				specs[id] = nil
			end
		end
	end

	function Messages.Cleanup(ids: { number }, handoff: boolean?)
		local handed: { any }? = nil
		for _, id in ids do
			local index = indexOf[id]
			if index then
				local b = list[index]
				remove(index)
				if b.publish then
					positions[id] = nil
				end
				if handoff then
					local out = handed or {}
					handed = out
					local n = #out
					out[n + 1] = id
					out[n + 2] = b.spec.casterId
					out[n + 3] = true
					out[n + 4] = b.position
					out[n + 5] = b.velocity
					out[n + 6] = b.time
					out[n + 7] = b.travelled
					out[n + 8] = b.power or false
					out[n + 9] = b.ricochets
					out[n + 10] = b.penetrations
				end
			end
		end
		if handed then
			events:Fire(false, false, handed)
		end
	end

	local function step(deltaTime: number)
		if count == 0 then
			if not reportedIdle then
				reportedIdle = true
				stepTimes[actorName] = 0
			end
			return
		end
		reportedIdle = false
		local started = os.clock()
		local frame = math.min(deltaTime, MAX_FRAME)
		local previous = clock
		clock += deltaTime

		local eye: Vector3? = nil
		if lodActive then
			local camera = workspace.CurrentCamera
			if camera then
				eye = camera.CFrame.Position
			end
		end

		local hits: { any }?, segments: { any }?, ends: { any }? = nil, nil, nil
		local motors: { Motor6D }?, motorCFrames: { CFrame }? = nil, nil
		local parts: { BasePart }?, partCFrames: { CFrame }? = nil, nil
		local hitCount, segmentCount, endCount, motorCount, partCount = 0, 0, 0, 0, 0

		for index = count, 1, -1 do
			local b = list[index]
			if b.paused then
				continue
			end

			local spec = b.spec
			local casterState = spec.caster
			local id = b.id
			local force = spec.force
			local drag = spec.drag
			local wind = spec.wind
			local maxStep = spec.maxStep
			local lifetime = spec.lifetime
			local params = spec.params
			local radius = spec.radius
			local tracks = spec.tracks

			local position = b.position
			local velocity = b.velocity
			local time = b.time
			local travelled = b.travelled
			local segmentFrom = position
			local remaining = frame * casterState.timeScale
			local stop = false
			local reported = false

			while remaining > 0 do
				local stepTime = if remaining < maxStep then remaining else maxStep
				remaining -= stepTime
				time += stepTime

				local from = position
				local to: Vector3
				if drag then
					-- Semi-implicit Euler with implicit quadratic drag relative to the wind
					local relative = velocity - wind
					relative /= 1 + drag * relative.Magnitude * stepTime
					velocity = wind + relative + force * stepTime
					to = from + velocity * stepTime
				else
					-- Exact for constant force, so the path doesn't depend on the step size (frame rate)
					to = from + velocity * stepTime + force * (0.5 * stepTime * stepTime)
					velocity += force * stepTime
				end
				local displacement = to - from
				local result: RaycastResult?
				if radius then
					result = if displacement:Dot(displacement) < 1e-12
						then nil
						else workspace:Spherecast(from, radius, displacement, params)
				else
					result = workspace:Raycast(from, displacement, params)
				end

				while result do
					local hit = Math.HitCenter(from, displacement, result, radius)
					travelled += (hit - from).Magnitude
					from = hit
					local travelledAtHit = travelled

					local casterId = spec.casterId
					local hardnessTable = spec.hardness
					local hardness = Math.PartHardness(result.Instance)
						or hardnessTable[result.Material.Name]
						or hardnessTable.Default
					local decision = Math.Resolve(
						result,
						velocity,
						hardness,
						if Math.UnderLimit(b.ricochets, spec.maxRicochets) then spec.ricochetAngle else nil,
						spec.ricochetHardness,
						if Math.UnderLimit(b.penetrations, spec.maxPenetrations) then b.power else nil,
						spec.loss,
						params,
						hit
					)
					local hitType = decision.Type
					local kind = HIT_IMPACT
					local recordPosition = decision.Position or hit
					local hitResult = result

					if hitType == "Penetration" then
						kind = HIT_PENETRATION
						local speed = velocity.Magnitude
						local newVelocity = decision.Velocity :: Vector3
						local ratio = if speed > 0 then newVelocity.Magnitude / speed else 0
						b.penetrations += 1
						b.power = (b.power :: number) - (decision.Cost :: number)
						velocity = newVelocity
						from = decision.Position :: Vector3
						travelled += (from - hit).Magnitude
						to = Math.ContinueSegment(hit, to, from, ratio)
						displacement = to - from
						result = Math.Cast(from, displacement, params, radius)
					elseif hitType == "Ricochet" then
						kind = HIT_RICOCHET
						local resume = decision.Position :: Vector3
						if tracks then
							local out = segments or {}
							segments = out
							out[segmentCount + 1] = id
							out[segmentCount + 2] = casterId
							out[segmentCount + 3] = segmentFrom
							out[segmentCount + 4] = hit
							segmentCount += 4
							segmentFrom = resume
						end
						b.ricochets += 1
						velocity = decision.Velocity :: Vector3
						travelled += (resume - hit).Magnitude
						from = resume
						to = resume
						result = nil
					else
						if hitType == "Humanoid" then
							kind = HIT_HUMANOID
						end
						to = hit
						stop = true
						reported = true
						result = nil
					end

					local out = hits or {}
					hits = out
					out[hitCount + 1] = id
					out[hitCount + 2] = casterId
					out[hitCount + 3] = kind
					out[hitCount + 4] = decision.Humanoid or false
					out[hitCount + 5] = hitResult.Instance
					out[hitCount + 6] = hitResult.Position
					out[hitCount + 7] = recordPosition
					out[hitCount + 8] = hitResult.Normal
					out[hitCount + 9] = hitResult.Material
					out[hitCount + 10] = hitResult.Distance
					out[hitCount + 11] = velocity
					out[hitCount + 12] = time
					out[hitCount + 13] = travelledAtHit
					out[hitCount + 14] = b.power or false
					out[hitCount + 15] = b.ricochets
					out[hitCount + 16] = b.penetrations
					hitCount += 16
				end

				travelled += (to - from).Magnitude
				position = to
				if stop or time >= lifetime then
					stop = true
					break
				end
			end

			b.position = position
			b.velocity = velocity
			b.time = time
			b.travelled = travelled

			if tracks then
				local out = segments or {}
				segments = out
				out[segmentCount + 1] = id
				out[segmentCount + 2] = spec.casterId
				out[segmentCount + 3] = segmentFrom
				out[segmentCount + 4] = position
				segmentCount += 4
			end

			local motor = b.motor
			local part = b.part
			if motor then
				local render = true
				local far = false
				if eye then
					local limits = casterState.lodLimits
					if limits then
						local offset = position - eye
						local distance = offset:Dot(offset)
						if distance > limits[1] then
							far = true
							if not stop then
								local tier = 1
								for i = 2, #limits do
									if distance <= limits[i] then
										break
									end
									tier = i
								end
								local rate = (casterState.lodRates :: { number })[tier]
								local phase = b.phase
								render = math.floor(clock * rate + phase) ~= math.floor(previous * rate + phase)
							end
						end
					end
				end
				if far ~= b.publish then
					b.publish = far
					if not far then
						positions[id] = nil
					end
				end
				if render then
					local targets = motors or table.create(count)
					local cframes = motorCFrames or table.create(count)
					motors, motorCFrames = targets, cframes
					motorCount += 1
					targets[motorCount] = motor
					cframes[motorCount] = CFrame.lookAlong(position, if velocity.Magnitude > 0 then velocity.Unit else FORWARD)
				end
			elseif part then
				local targets = parts or table.create(count)
				local cframes = partCFrames or table.create(count)
				parts, partCFrames = targets, cframes
				partCount += 1
				targets[partCount] = part
				cframes[partCount] = CFrame.lookAlong(position, if velocity.Magnitude > 0 then velocity.Unit else FORWARD)
			end

			if stop then
				if not reported then
					local out = ends or {}
					ends = out
					out[endCount + 1] = id
					out[endCount + 2] = spec.casterId
					out[endCount + 3] = false
					out[endCount + 4] = position
					out[endCount + 5] = velocity
					out[endCount + 6] = time
					out[endCount + 7] = travelled
					out[endCount + 8] = b.power or false
					out[endCount + 9] = b.ricochets
					out[endCount + 10] = b.penetrations
					endCount += 10
				end

				local last = list[count]
				list[index] = last
				indexOf[last.id] = index
				list[count] = nil
				indexOf[id] = nil
				count -= 1
				if b.publish then
					positions[id] = nil
				end
			elseif b.publish then
				positions[id] = position
			end
		end

		stepTimes[actorName] = os.clock() - started

		if not (motors or parts or hits or segments or ends) then
			return
		end

		task.synchronize()

		if motors and motorCFrames then
			for i = 1, motorCount do
				motors[i].Transform = motorCFrames[i]
			end
		end
		if parts and partCFrames then
			workspace:BulkMoveTo(parts, partCFrames, MOVE_MODE)
		end
		if hits or segments or ends then
			events:Fire(hits or false, segments or false, ends or false)
		end
	end

	return {
		Messages = Messages,
		Step = step,
	}
end
