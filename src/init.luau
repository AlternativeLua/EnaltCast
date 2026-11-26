--!strict
--!optimize 2
--!native

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

local Types = require(script.Types)
local Visualiser = require(script.Visualiser)
local Settings = require(script.Settings)
local Math = require(script.Math)
local LagCompensation = require(script.LagCompensation)
local Zignal = require(script.Zignal)
local Pooler = require(script.Pooler)

local Caster = {}
Caster.__index = Caster

local IS_SERVER = RunService:IsServer()
local IS_CLIENT = RunService:IsClient()
local MAX_FRAME = 0.1
local MAX_SPECS = 64
local CAST_STRIDE = 12
local HIT_STRIDE = 16
local SEGMENT_STRIDE = 4
local END_STRIDE = 10
local HIT_HUMANOID = 2
local HIT_RICOCHET = 3
local HIT_PENETRATION = 4
local ZERO = Vector3.zero
local FORWARD = -Vector3.zAxis
local MOVE_MODE = Enum.BulkMoveMode.FireCFrameChanged
local PHASE_STEP = 0.6180339887

local BulletFolder = workspace:FindFirstChild("BulletsFolder") or Instance.new("Folder")
BulletFolder.Name = "BulletsFolder"
BulletFolder.Parent = workspace

local MOTOR_NAME = "EnaltCastMotor"
local BulletRoot: BasePart? = nil
if not IS_SERVER then
	local root = Instance.new("Part")
	root.Name = "BulletRoot"
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Transparency = 1
	root.Size = Vector3.one
	root.CFrame = CFrame.identity
	root.Parent = BulletFolder
	BulletRoot = root
end

local BulletActors: { Actor } = {}
local ActorPositions: { SharedTable } = {}
local ActorHolder: Folder? = nil
local ActorTemplate: Instance? = nil
local CommEvents: BindableEvent
local DEFAULT_NEAR_MISS_RADIUS = 10

local NextBulletId = 0
local NextCasterId = 0
local NextSpecId = 0

local Casters: { [number]: any } = {}

local TargetPlayers: { Player } = {}
local TargetCharacters: { Model } = {}
local TargetPoints: { Vector3 } = {}
local TargetCount = 0
local TargetsStale = true

-- Actors write their per-frame compute time here, keyed by actor name. Shared by
-- every caster using the same actors.
local ActorStepTimes = SharedTableRegistry:GetSharedTable("EnaltCastActorStepTime")

local function refreshTargets()
	TargetsStale = false
	local count = 0
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			local head = character:FindFirstChild("Head")
			count += 1
			TargetPlayers[count] = player
			TargetCharacters[count] = character
			TargetPoints[count] = if head and head:IsA("BasePart") then head.Position else character:GetPivot().Position
		end
	end
	for i = TargetCount, count + 1, -1 do
		TargetPlayers[i] = nil
		TargetCharacters[i] = nil
		TargetPoints[i] = nil
	end
	TargetCount = count
end

local function onActorEvents(hits: any, segments: any, ends: any)
	local finished: { any }? = nil
	if hits then
		for i = 1, #hits, HIT_STRIDE do
			local caster = Casters[hits[i + 1]]
			if caster and caster:_handleActorHit(hits, i) then
				local list = finished or {}
				finished = list
				table.insert(list, caster)
				table.insert(list, hits[i])
			end
		end
	end
	if segments then
		TargetsStale = true
		for i = 1, #segments, SEGMENT_STRIDE do
			local caster = Casters[segments[i + 1]]
			if caster then
				local data = caster._actorBullets[segments[i]]
				if data then
					if IS_CLIENT and caster._settings.Visualise then
						local trail = data.VisualTrail
						if not trail then
							local created: Visualiser.Trail = {}
							data.VisualTrail = created
							trail = created
						end
						Visualiser.Extend(trail :: Visualiser.Trail, segments[i + 2], segments[i + 3])
					end
					caster:_segment(data, segments[i + 2], segments[i + 3])
				end
			end
		end
	end
	if finished then
		for i = 1, #finished, 2 do
			finished[i]:_finishActorBullet(finished[i + 1])
		end
	end
	if ends then
		for i = 1, #ends, END_STRIDE do
			local caster = Casters[ends[i + 1]]
			if caster then
				caster:_handleActorEnd(ends, i)
			end
		end
	end
end

local function attachMotor(part: BasePart, cframe: CFrame): Motor6D
	local motor = part:FindFirstChild(MOTOR_NAME) :: Motor6D?
	if not motor then
		local newMotor = Instance.new("Motor6D")
		newMotor.Name = MOTOR_NAME
		newMotor.Parent = part
		motor = newMotor
	end
	assert(motor)

	motor.Transform = cframe
	part.Anchored = false
	motor.Part1 = part
	motor.Part0 = BulletRoot
	return motor
end

local function releaseBullet(data: Types.ProjectileData)
	local part = data.Bullet
	if not part then
		return
	end
	local motor = data.Motor
	if motor then
		-- Anchor before breaking the joint so the part doesn't drop as a loose physics part
		part.Anchored = true
		motor.Part0 = nil
		data.Motor = nil
	end
	if data.Pooler then
		data.Pooler:Return(part)
	else
		part:Destroy()
	end
	data.Bullet = nil
	data.Pooler = nil
end

-- Actors run their own Script under a non-replicated container (ServerScriptService
-- on the server, the local player's PlayerScripts on the client) so they actually
-- execute and never leak across the network boundary.
-- The actor pool is shared by every caster; it grows to the largest ActorAmount
-- any caster asks for, and each caster only uses the first ActorAmount actors.
local function ensureActors(count: number)
	if not ActorHolder then
		local container: Instance
		if RunService:IsServer() then
			container = game:GetService("ServerScriptService")
			ActorTemplate = script:FindFirstChild("BulletActorScriptServer")
		else
			container = game:GetService("Players").LocalPlayer:WaitForChild("PlayerScripts")
			ActorTemplate = script:FindFirstChild("BulletActorScriptClient")
		end

		local holder = Instance.new("Folder")
		holder.Name = "EnaltCastRuntime"

		CommEvents = Instance.new("BindableEvent")
		CommEvents.Name = "BulletEvents"
		CommEvents.Event:Connect(onActorEvents)
		CommEvents.Parent = holder

		holder.Parent = container
		ActorHolder = holder
	end

	for i = #BulletActors + 1, count do
		local actor = Instance.new("Actor")
		actor.Name = "BulletActor" .. i

		local moduleRef = Instance.new("ObjectValue")
		moduleRef.Name = "Module"
		moduleRef.Value = script
		moduleRef.Parent = actor

		if ActorTemplate then
			ActorTemplate:Clone().Parent = actor
		end

		actor.Parent = ActorHolder
		BulletActors[i] = actor
		ActorPositions[i] = SharedTableRegistry:GetSharedTable("EnaltCastPositions" .. actor.Name)
	end
end

-- Builds this caster's settings: defaults from the Settings module with the
-- overrides on top. SurfaceHardness is merged entry by entry so overriding one
-- material keeps the rest (and Default).
local function resolveSettings(overrides: Types.CasterSettings?): Types.ResolvedSettings
	local resolved = table.clone(Settings) :: any
	resolved.SurfaceHardness = table.clone(Settings.SurfaceHardness)

	if overrides then
		for key, value in overrides :: any do
			if Settings[key] == nil then
				warn(`EnaltCast: unknown setting "{tostring(key)}" ignored`)
			elseif key == "SurfaceHardness" then
				for material, hardness in value do
					resolved.SurfaceHardness[material] = hardness
				end
			else
				resolved[key] = value
			end
		end
	end

	assert(resolved.UpdateRate > 0, "EnaltCast: UpdateRate must be greater than 0")
	assert(resolved.TimeScale >= 0, "EnaltCast: TimeScale can't be negative")
	assert(resolved.ActorAmount >= 1, "EnaltCast: ActorAmount must be at least 1")
	resolved.ActorAmount = math.floor(resolved.ActorAmount)

	return resolved
end

-- Enum keys don't survive Actor:SendMessage, so actors get hardness by material name
local function hardnessByName(hardness: { [any]: number }): { [string]: number }
	local byName = {}
	for material, value in hardness do
		byName[if typeof(material) == "EnumItem" then material.Name else tostring(material)] = value
	end
	return byName
end

type RenderLODTier = Types.RenderLODTier

type Lod = {
	Limits: { number },
	Rates: { number },
	Eye: Vector3,
	Now: number,
	Previous: number,
}

local function compileLod(tiers: { RenderLODTier } | false): Lod?
	if not BulletRoot or not tiers or #tiers == 0 then
		return nil
	end

	local sorted = table.clone(tiers)
	table.sort(sorted, function(a, b)
		return a.Distance < b.Distance
	end)

	local limits = table.create(#sorted)
	local rates = table.create(#sorted)
	for i, tier in sorted do
		assert(tier.Distance >= 0, "EnaltCast: RenderLOD Distance can't be negative")
		assert(tier.Rate > 0, "EnaltCast: RenderLOD Rate must be greater than 0")
		limits[i] = tier.Distance * tier.Distance
		rates[i] = tier.Rate
	end

	return { Limits = limits, Rates = rates, Eye = ZERO, Now = 0, Previous = 0 }
end

type CasterSettings = Types.CasterSettings
type ResolvedSettings = Types.ResolvedSettings
type CasterStats = Types.CasterStats
type CastConfig = Types.CastConfig
type ProjectileData = Types.ProjectileData
type Pooler = Pooler.Pooler

type SpecDefinition = {
	id: number,
	casterId: number,
	extraForce: Vector3,
	lifetime: number,
	filter: { Instance },
	filterType: Enum.RaycastFilterType,
	ignoreWater: boolean,
	respectCanCollide: boolean,
	collisionGroup: string,
	ricochetAngle: number?,
	ricochetHardness: number?,
	loss: number?,
	radius: number?,
	drag: number?,
	wind: Vector3?,
	maxRicochets: number?,
	maxPenetrations: number?,
	tracks: boolean,
	hardness: { [string]: number },
	maxStep: number,
}

type Spec = {
	Id: number,
	Sent: { [number]: true },
	RayParams: RaycastParams,
	FilterCount: number,
	Definition: SpecDefinition,
}

type Outbox = {
	Specs: { SpecDefinition },
	Bullets: { any },
	Drops: { number },
}

local Handle = {}
Handle.__index = Handle

export type CastHandle = typeof(setmetatable({} :: {
	_caster: Caster,
	_data: ProjectileData,
}, Handle))

function Handle.Terminate(self: CastHandle)
	local data = self._data
	if data.Ended then
		return
	end
	data.Ended = true
	local id = data.ActorId
	if id then
		self._caster:_dropActorBullet(id)
	end
	releaseBullet(data)
end

function Handle.GetPosition(self: CastHandle): Vector3
	local data = self._data
	local id = data.ActorId
	if id then
		local caster = self._caster
		local motor = data.Motor
		if motor and not caster._lod then
			return motor.Transform.Position
		end
		local actorIndex = caster._bulletToActorMap[id]
		local live = actorIndex and ActorPositions[actorIndex][id]
		if live then
			return live :: Vector3
		end
		if motor then
			return motor.Transform.Position
		end
	end
	return data.CurrentPosition
end

function Handle.SetVelocity(self: CastHandle, velocity: Vector3)
	local data = self._data
	if data.Ended then
		return
	end
	data.Velocity = velocity
	data.CurrentDirection = velocity
	self._caster:_messageActor(data, "SetVelocity", velocity)
end

function Handle.Pause(self: CastHandle)
	local data = self._data
	if data.Ended or data.Paused then
		return
	end
	data.Paused = true
	self._caster:_messageActor(data, "SetPaused", true)
end

function Handle.Resume(self: CastHandle)
	local data = self._data
	if data.Ended or not data.Paused then
		return
	end
	data.Paused = false
	self._caster:_messageActor(data, "SetPaused", false)
end

export type Caster = typeof(Caster) & {
	_connections: { RBXScriptConnection },
	_activeBullets: { ProjectileData },
	_actorBullets: { [number]: ProjectileData },
	_actorWorkloads: { [number]: number },
	_bulletToActorMap: { [number]: number },
	_newCFrames: { CFrame },
	_bulletParts: { BasePart },
	_id: number,
	_settings: ResolvedSettings,
	_actorHardness: { [string]: number },
	_lod: Lod?,
	_specs: { Spec },
	_outbox: { Outbox },
	_flushQueued: boolean,
	_currentActorIndex: number,
	_useParallel: boolean,
	_commReady: boolean,
	_casts: number,
	_hits: number,
	_stepTime: number,
}

function Caster.new(settings: CasterSettings?): Caster
	local self: Caster = setmetatable({}, Caster) :: any

	local resolved = resolveSettings(settings)
	self._settings = resolved
	self._actorHardness = hardnessByName(resolved.SurfaceHardness)
	self._lod = compileLod(resolved.RenderLOD)

	if IS_SERVER and resolved.LagCompensation then
		LagCompensation.EnsureHistory(resolved.LagCompensationHistory)
	end

	self._connections = {}
	self._activeBullets = {}
	self._actorBullets = {}
	self._actorWorkloads = {}
	self._bulletToActorMap = {}
	self._newCFrames = {}
	self._bulletParts = {}
	self._specs = {}
	self._outbox = {}
	self._flushQueued = false
	NextCasterId += 1
	self._id = NextCasterId
	self._currentActorIndex = 1
	self._useParallel = resolved.ParallelProcessing
	self._commReady = false
	self._casts = 0
	self._hits = 0
	self._stepTime = 0

	for i = 1, resolved.ActorAmount do
		self._actorWorkloads[i] = 0
		self._outbox[i] = { Specs = {}, Bullets = {}, Drops = {} }
	end

	if self._useParallel then
		ensureActors(resolved.ActorAmount)
		self:_setupActorCommunication()
	end

	local signal = RunService:IsClient() and RunService.PreRender or RunService.Heartbeat
	table.insert(
		self._connections,
		signal:Connect(function(deltaTime: number)
			self:_heartbeat(deltaTime)
		end)
	)

	return self
end

function Caster._setupActorCommunication(self: Caster)
	if self._commReady then
		return
	end
	self._commReady = true
	Casters[self._id] = self
	if self._lod then
		self:_sendLod()
	end
end

function Caster._sendLod(self: Caster)
	local lod = self._lod
	local limits: any = if lod then lod.Limits else false
	local rates: any = if lod then lod.Rates else false
	for i = 1, self._settings.ActorAmount do
		local actor = BulletActors[i]
		if actor then
			actor:SendMessage("SetRenderLOD", self._id, limits, rates)
		end
	end
end

function Caster._segment(self: Caster, data: ProjectileData, from: Vector3, to: Vector3)
	local config = data.Config
	if config.OnSegment then
		config.OnSegment:Fire(from, to, data)
	end
	local onNearMiss = config.OnNearMiss
	if not onNearMiss then
		return
	end

	if TargetsStale then
		refreshTargets()
	end

	local radius = config.NearMissRadius or DEFAULT_NEAR_MISS_RADIUS
	local segment = to - from
	local lengthSquared = segment:Dot(segment)
	local nearMissed = data.NearMissed
	local ignoreList = data.IgnoreList

	for i = 1, TargetCount do
		local player = TargetPlayers[i]
		if nearMissed and nearMissed[player] then
			continue
		end
		if table.find(ignoreList, TargetCharacters[i]) then
			continue
		end
		local point = TargetPoints[i]

		local along = if lengthSquared > 0 then math.clamp((point - from):Dot(segment) / lengthSquared, 0, 1) else 0
		local closest = from + segment * along
		local distance = (point - closest).Magnitude
		if distance <= radius then
			local set = nearMissed or {}
			set[player] = true
			nearMissed = set
			data.NearMissed = set
			onNearMiss:Fire(player, closest, distance, data)
		end
	end
end

function Caster._markHumanoidHit(self: Caster, data: ProjectileData, humanoid: Humanoid)
	if not data.Config.OnNearMiss then
		return
	end
	local player = humanoid.Parent and Players:GetPlayerFromCharacter(humanoid.Parent)
	if player then
		local nearMissed = data.NearMissed or {}
		nearMissed[player] = true
		data.NearMissed = nearMissed
	end
end

function Caster._pickActor(self: Caster): number
	local settings = self._settings
	if settings.LoadBalanceStrategy == "RoundRobin" then
		local i = self._currentActorIndex
		self._currentActorIndex = (i % settings.ActorAmount) + 1
		return i
	end

	local best, min = 1, math.huge
	for i = 1, settings.ActorAmount do
		local workload = self._actorWorkloads[i]
		if workload < min then
			min, best = workload, i
		end
	end
	return best
end

function Caster._resolveSpec(self: Caster, config: CastConfig, rayParams: RaycastParams, filter: { Instance }): Spec
	local force = config.ExtraForce or ZERO
	local lifetime = config.Lifetime or 5
	local ricochetAngle = config.RichochetAngle
	local ricochetHardness = config.RichochetHardness
	local loss = config.Loss
	local radius = config.Radius
	local drag = config.Drag
	local wind = config.Wind
	local maxRicochets = config.MaxRicochets
	local maxPenetrations = config.MaxPenetrations
	-- Actors only report path segments when something needs them, including the client visualiser
	local tracks = config.OnSegment ~= nil or config.OnNearMiss ~= nil or (self._settings.Visualise and IS_CLIENT)
	local filterType = rayParams.FilterType
	local ignoreWater = rayParams.IgnoreWater
	local respectCanCollide = rayParams.RespectCanCollide
	local collisionGroup = rayParams.CollisionGroup
	local filterCount = #filter
	local first = filter[1]

	local specs = self._specs
	for index = 1, #specs do
		local spec = specs[index]
		local def = spec.Definition
		local specFilter = def.filter
		if
			spec.FilterCount == filterCount
			and specFilter[1] == first
			and def.extraForce == force
			and def.lifetime == lifetime
			and def.ricochetAngle == ricochetAngle
			and def.ricochetHardness == ricochetHardness
			and def.loss == loss
			and def.radius == radius
			and def.drag == drag
			and def.wind == wind
			and def.maxRicochets == maxRicochets
			and def.maxPenetrations == maxPenetrations
			and def.tracks == tracks
			and def.filterType == filterType
			and def.ignoreWater == ignoreWater
			and def.respectCanCollide == respectCanCollide
			and def.collisionGroup == collisionGroup
		then
			local same = true
			for j = 2, filterCount do
				if specFilter[j] ~= filter[j] then
					same = false
					break
				end
			end
			if same then
				if index > 1 then
					table.remove(specs, index)
					table.insert(specs, 1, spec)
				end
				return spec
			end
		end
	end

	if #specs >= MAX_SPECS then
		local evicted = table.remove(specs) :: Spec
		for actorIndex in evicted.Sent do
			table.insert(self._outbox[actorIndex].Drops, evicted.Id)
		end
	end

	local shared = Math.CloneRayParams(rayParams)
	shared.FilterDescendantsInstances = filter

	NextSpecId += 1
	local spec: Spec = {
		Id = NextSpecId,
		Sent = {},
		RayParams = shared,
		FilterCount = filterCount,
		Definition = {
			id = NextSpecId,
			casterId = self._id,
			extraForce = force,
			lifetime = lifetime,
			filter = table.clone(filter),
			filterType = filterType,
			ignoreWater = ignoreWater,
			respectCanCollide = respectCanCollide,
			collisionGroup = collisionGroup,
			ricochetAngle = ricochetAngle,
			ricochetHardness = ricochetHardness,
			loss = loss,
			radius = radius,
			drag = drag,
			wind = wind,
			maxRicochets = maxRicochets,
			maxPenetrations = maxPenetrations,
			tracks = tracks,
			hardness = self._actorHardness,
			maxStep = 1 / self._settings.UpdateRate,
		},
	}
	table.insert(specs, 1, spec)
	return spec
end

function Caster._handleActorHit(self: Caster, hits: { any }, i: number): boolean
	local data = self._actorBullets[hits[i]]
	if not data then
		return false
	end
	self._hits += 1

	local config = data.Config
	local kind = hits[i + 2]
	local hitPosition = hits[i + 5]
	local position = hits[i + 6]
	local velocity = hits[i + 10]
	local result = {
		Instance = hits[i + 4],
		Position = hitPosition,
		Normal = hits[i + 7],
		Material = hits[i + 8],
		Distance = hits[i + 9],
	} :: any

	data.CurrentPosition = position
	data.Velocity = velocity
	data.CurrentDirection = velocity
	data.Time = hits[i + 11]
	data.DistanceTravelled = hits[i + 12]
	data.PenetrationPower = hits[i + 13] or nil
	data.Ricochets = hits[i + 14]
	data.Penetrations = hits[i + 15]

	if kind == HIT_HUMANOID then
		local humanoid = hits[i + 3]
		self:_markHumanoidHit(data, humanoid)
		if config.OnHumanoidHit then
			config.OnHumanoidHit:Fire(result, data, humanoid)
		end
		if config.OnImpact then
			config.OnImpact:Fire(result, data)
		end
	elseif kind == HIT_RICOCHET then
		data.Origin = position
		if config.OnRichochet then
			config.OnRichochet:Fire(result, data)
		end
	elseif kind == HIT_PENETRATION then
		if config.OnPenetration then
			config.OnPenetration:Fire(result, data)
		end
	elseif config.OnImpact then
		config.OnImpact:Fire(result, data)
	end

	if self._settings.Visualise then
		local name: Visualiser.HitKind = if kind == HIT_HUMANOID
			then "Humanoid"
			elseif kind == HIT_RICOCHET then "Ricochet"
			elseif kind == HIT_PENETRATION then "Penetration"
			else "Impact"
		Visualiser.Hit(hitPosition, result.Normal, name)
		if kind == HIT_PENETRATION then
			Visualiser.Penetration(hitPosition, position)
		end
	end

	return kind < HIT_RICOCHET
end

function Caster._finishActorBullet(self: Caster, id: number)
	local data = self._actorBullets[id]
	local actorIndex = self._bulletToActorMap[id]
	if actorIndex then
		self._actorWorkloads[actorIndex] = math.max(0, self._actorWorkloads[actorIndex] - 1)
		self._bulletToActorMap[id] = nil
	end
	self._actorBullets[id] = nil

	if data then
		data.ActorId = nil
		data.Ended = true
		local trail = data.VisualTrail
		if trail then
			Visualiser.Flush(trail)
		end
		releaseBullet(data)
	end
end

function Caster._handleActorEnd(self: Caster, ends: { any }, i: number)
	local id = ends[i]
	local data = self._actorBullets[id]
	if not data then
		self:_finishActorBullet(id)
		return
	end

	local velocity = ends[i + 4]
	data.CurrentPosition = ends[i + 3]
	data.Velocity = velocity
	data.CurrentDirection = velocity
	data.Time = ends[i + 5]
	data.DistanceTravelled = ends[i + 6]
	data.PenetrationPower = ends[i + 7] or nil
	data.Ricochets = ends[i + 8]
	data.Penetrations = ends[i + 9]

	if not ends[i + 2] then
		self:_finishActorBullet(id)
		return
	end

	local actorIndex = self._bulletToActorMap[id]
	if actorIndex then
		self._actorWorkloads[actorIndex] = math.max(0, self._actorWorkloads[actorIndex] - 1)
		self._bulletToActorMap[id] = nil
	end
	self._actorBullets[id] = nil
	data.ActorId = nil

	if self._useParallel then
		self:_dispatchToActor(data)
	else
		local own = Math.CloneRayParams(data.RayParams or data.Config.RayParams)
		own.FilterDescendantsInstances = data.IgnoreList
		data.RayParams = own
		table.insert(self._activeBullets, data)
	end
end

function Caster._dispatchToActor(self: Caster, data: ProjectileData, known: Spec?)
	local spec = known or self:_resolveSpec(data.Config, data.RayParams or data.Config.RayParams, data.IgnoreList)

	NextBulletId += 1
	local id = NextBulletId
	self._actorBullets[id] = data
	data.ActorId = id

	local actorIndex = self:_pickActor()
	self._actorWorkloads[actorIndex] += 1
	self._bulletToActorMap[id] = actorIndex

	local outbox = self._outbox[actorIndex]
	if not spec.Sent[actorIndex] then
		spec.Sent[actorIndex] = true
		table.insert(outbox.Specs, spec.Definition)
	end

	local motor = data.Motor
	local bullets = outbox.Bullets
	local n = #bullets
	bullets[n + 1] = id
	bullets[n + 2] = spec.Id
	bullets[n + 3] = data.CurrentPosition
	bullets[n + 4] = data.Velocity
	bullets[n + 5] = data.Time
	bullets[n + 6] = data.DistanceTravelled
	bullets[n + 7] = data.PenetrationPower or false
	bullets[n + 8] = data.Ricochets
	bullets[n + 9] = data.Penetrations
	bullets[n + 10] = data.Paused
	bullets[n + 11] = motor or false
	bullets[n + CAST_STRIDE] = if motor then false else data.Bullet or false

	if not self._flushQueued then
		self._flushQueued = true
		task.defer(self._flush, self)
	end
end

function Caster._flush(self: Caster)
	if not self._flushQueued then
		return
	end
	self._flushQueued = false

	local casterId = self._id
	local timeScale = self._settings.TimeScale
	for actorIndex, outbox in self._outbox do
		local specs, bullets, drops = outbox.Specs, outbox.Bullets, outbox.Drops
		local hasSpecs, hasBullets, hasDrops = #specs > 0, #bullets > 0, #drops > 0
		if hasSpecs or hasBullets or hasDrops then
			BulletActors[actorIndex]:SendMessage(
				"Cast",
				casterId,
				timeScale,
				if hasSpecs then specs else false,
				if hasBullets then bullets else false,
				if hasDrops then drops else false
			)
			if hasSpecs then
				outbox.Specs = {}
			end
			if hasBullets then
				outbox.Bullets = {}
			end
			if hasDrops then
				outbox.Drops = {}
			end
		end
	end
end

function Caster._dropActorBullet(self: Caster, id: number)
	local actorIndex = self._bulletToActorMap[id]
	if actorIndex then
		self:_flush()
		self._actorWorkloads[actorIndex] = math.max(0, self._actorWorkloads[actorIndex] - 1)
		self._bulletToActorMap[id] = nil
		BulletActors[actorIndex]:SendMessage("Cleanup", { id }, false)
	end
	local data = self._actorBullets[id]
	if data then
		data.ActorId = nil
	end
	self._actorBullets[id] = nil
end

function Caster._messageActor(self: Caster, data: ProjectileData, message: string, value: any)
	local id = data.ActorId
	local actorIndex = id and self._bulletToActorMap[id]
	if actorIndex then
		self:_flush()
		BulletActors[actorIndex]:SendMessage(message, id, value)
	end
end

-- With handoff, actors reply with each bullet's live state via the end event.
function Caster._cleanupActorBullets(self: Caster, handoff: boolean)
	self:_flush()

	local perActor: { [number]: { number } } = {}
	for id, actorIndex in self._bulletToActorMap do
		local ids = perActor[actorIndex]
		if not ids then
			ids = {}
			perActor[actorIndex] = ids
		end
		table.insert(ids, id)
	end

	for actorIndex, ids in perActor do
		local actor = BulletActors[actorIndex]
		if actor then
			actor:SendMessage("Cleanup", ids, handoff)
		end
	end
end

function Caster.Destroy(self: Caster)
	for _, connection in self._connections do
		connection:Disconnect()
	end

	self:_cleanupActorBullets(false)

	if self._commReady then
		Casters[self._id] = nil
		for i = 1, self._settings.ActorAmount do
			local actor = BulletActors[i]
			if actor then
				actor:SendMessage("DropCaster", self._id)
			end
		end
	end

	for _, data in self._activeBullets do
		data.Ended = true
		releaseBullet(data)
	end
	for _, data in self._actorBullets do
		data.Ended = true
		data.ActorId = nil
		releaseBullet(data)
	end

	self._connections = {}
	self._activeBullets = {}
	self._actorBullets = {}
	self._actorWorkloads = {}
	self._bulletToActorMap = {}
	self._newCFrames = {}
	self._bulletParts = {}
	self._specs = {}
	self._outbox = {}
	self._flushQueued = false
end

--- Casts a projectile.
--- @param config CastConfig
--- @param origin Vector3
--- @param direction Vector3 unit direction; speed comes from config.Speed
--- @param bullet BasePart | Pooler | nil visual part (replicate on the client)
function Caster.Cast(
	self: Caster,
	config: CastConfig,
	origin: Vector3,
	direction: Vector3,
	bullet: BasePart | Pooler | nil
): CastHandle?
	if IS_SERVER and bullet and self._settings.SafeMode then
		warn("It's recommended to replicate bullets on the client!")
		return nil
	end

	local pooler: Pooler? = nil
	if bullet and typeof(bullet) ~= "Instance" then
		pooler = bullet
		bullet = (bullet :: Pooler):Pull()
	end

	local motor: Motor6D? = nil
	if bullet then
		local part = bullet :: BasePart
		local start = CFrame.lookAlong(origin, direction)
		if BulletRoot then
			motor = attachMotor(part, start)
		else
			part.CFrame = start
		end
		part.Parent = BulletFolder
	end

	self._casts += 1

	local rayParams = config.RayParams
	local ignoreList = rayParams.FilterDescendantsInstances
	local spec: Spec? = nil
	local params: RaycastParams
	if self._useParallel then
		local resolved = self:_resolveSpec(config, rayParams, ignoreList)
		spec = resolved
		params = resolved.RayParams
	else
		params = Math.CloneRayParams(rayParams)
		params.FilterDescendantsInstances = ignoreList
	end

	local data: ProjectileData = {
		Config = config,
		Origin = origin,
		Direction = direction,
		Time = 0,
		DistanceTravelled = 0,
		Ricochets = 0,
		Penetrations = 0,
		Paused = false,
		Ended = false,
		RewindTime = config.RewindTime,
		CurrentPosition = origin,
		CurrentDirection = direction,
		Velocity = direction * config.Speed,
		IgnoreList = ignoreList,
		PenetrationPower = config.PenetrationPower,
		RayParams = params,
		Bullet = bullet :: BasePart?,
		Motor = motor,
		Pooler = pooler,
		RenderPhase = (self._casts * PHASE_STEP) % 1,
	}

	if spec then
		self:_dispatchToActor(data, spec)
	else
		table.insert(self._activeBullets, data)
	end

	return setmetatable({ _caster = self, _data = data }, Handle)
end

function Caster.GetBulletFolderAsync(self: Caster): Folder
	return BulletFolder or workspace:WaitForChild("BulletsFolder")
end

function Caster.NewSignal<T...>(self: Caster): Zignal.Signal<T...>
	return Zignal.new()
end

function Caster.NewPooler(self: Caster, ...)
	return Pooler.new(...)
end

function Caster.GetWorkloadDistribution(self: Caster): { [number]: number }
	local distribution = {}
	for i = 1, self._settings.ActorAmount do
		distribution[i] = self._actorWorkloads[i]
	end
	return distribution
end

--- Performance counters for this caster. Cheap enough to poll every frame.
function Caster.GetStats(self: Caster): CasterStats
	local actorStepTime = 0
	if self._useParallel then
		for i = 1, self._settings.ActorAmount do
			local actor = BulletActors[i]
			if actor then
				actorStepTime += (ActorStepTimes[actor.Name] :: number?) or 0
			end
		end
	end

	return {
		ActiveBullets = #self._activeBullets,
		ActorBullets = self:GetTotalActorBullets(),
		Casts = self._casts,
		Hits = self._hits,
		StepTime = if self._useParallel then 0 else self._stepTime,
		ActorStepTime = actorStepTime,
		Workload = self:GetWorkloadDistribution(),
	}
end

function Caster.GetTotalActorBullets(self: Caster): number
	local total = 0
	for i = 1, self._settings.ActorAmount do
		total += self._actorWorkloads[i]
	end
	return total
end

function Caster.SetTimeScale(self: Caster, scale: number)
	assert(scale >= 0, "EnaltCast: TimeScale can't be negative")
	self._settings.TimeScale = scale
	if not self._commReady then
		return
	end
	for i = 1, self._settings.ActorAmount do
		local actor = BulletActors[i]
		if actor then
			actor:SendMessage("SetTimeScale", self._id, scale)
		end
	end
end

function Caster.GetTimeScale(self: Caster): number
	return self._settings.TimeScale
end

function Caster.SetRenderLOD(self: Caster, tiers: { RenderLODTier } | false)
	local lod = compileLod(tiers)
	self._settings.RenderLOD = tiers
	self._lod = lod
	if self._commReady then
		self:_sendLod()
	end
end

function Caster.SetParallelProcessing(self: Caster, useParallel: boolean)
	if self._useParallel == useParallel then
		return
	end

	if useParallel then
		ensureActors(self._settings.ActorAmount)
		self:_setupActorCommunication()

		for i = #self._activeBullets, 1, -1 do
			local data = self._activeBullets[i]
			if not data.Ended then
				self:_dispatchToActor(data)
			end
			self._activeBullets[i] = nil
		end
	else
		self:_cleanupActorBullets(true)
	end

	self._useParallel = useParallel
end

---------------------
-- PRIVATE METHODS --
---------------------

local function castSegment(
	data: ProjectileData,
	useLagComp: boolean,
	from: Vector3,
	displacement: Vector3,
	params: RaycastParams,
	radius: number?
): RaycastResult?
	if useLagComp then
		return LagCompensation.Raycast(from, displacement, params, data.IgnoreList, (data.RewindTime :: number) + data.Time, radius)
	end
	return Math.Cast(from, displacement, params, radius)
end

-- Advances a bullet by deltaTime, sub-stepping at UpdateRate so flight and hit
-- detection stay frame-rate independent while the part still moves every frame.
local function stepProjectile(
	self: Caster,
	data: ProjectileData,
	frame: number,
	maxStep: number,
	lagComp: boolean,
	visualise: boolean,
	lod: Lod?
): boolean
	local config = data.Config
	local force = config.ExtraForce or ZERO
	local lifetime = config.Lifetime or 5
	local radius = config.Radius
	local wind = config.Wind or ZERO
	local drag = config.Drag
	if drag and drag <= 0 then
		drag = nil
	end
	local params = data.RayParams :: RaycastParams

	-- Rewind tracked targets only on the server, for shots that opted in
	local useLagComp = (lagComp and config.LagCompensation and data.RewindTime ~= nil) == true
	local tracks = config.OnSegment ~= nil or config.OnNearMiss ~= nil

	local position = data.CurrentPosition
	local velocity = data.Velocity
	local direction = data.CurrentDirection
	local time = data.Time
	local travelled = data.DistanceTravelled
	local segmentFrom = position
	local speedScale = if visualise and config.Speed > 0 then 1 / config.Speed else 0
	local trail: Visualiser.Trail? = nil
	if visualise then
		trail = data.VisualTrail
		if not trail then
			local created: Visualiser.Trail = {}
			data.VisualTrail = created
			trail = created
		end
	end
	local remaining = frame
	local stop = false

	while remaining > 0 do
		local step = if remaining < maxStep then remaining else maxStep
		remaining -= step
		time += step

		local from = position
		local drawFrom = position
		local to: Vector3
		if drag then
			-- Semi-implicit Euler with implicit quadratic drag relative to the wind
			local relative = velocity - wind
			relative /= 1 + drag * relative.Magnitude * step
			velocity = wind + relative + force * step
			to = from + velocity * step
		else
			-- Exact for constant force, so the path doesn't depend on the step size (frame rate)
			to = from + velocity * step + force * (0.5 * step * step)
			velocity += force * step
		end
		local displacement = to - from
		local result: RaycastResult?
		if useLagComp then
			result = LagCompensation.Raycast(from, displacement, params, data.IgnoreList, (data.RewindTime :: number) + time, radius)
		elseif radius then
			result = if displacement:Dot(displacement) < 1e-12 then nil else workspace:Spherecast(from, radius, displacement, params)
		else
			result = workspace:Raycast(from, displacement, params)
		end

		if result then
			data.Time = time
			data.Velocity = velocity
			data.CurrentPosition = position
			data.CurrentDirection = direction
			data.DistanceTravelled = travelled

			while result do
				local hit = Math.HitCenter(from, displacement, result, radius)
				data.DistanceTravelled += (hit - from).Magnitude
				from = hit

				local speed = data.Velocity.Magnitude
				if trail then
					-- Pieces always end exactly at a hit
					Visualiser.Extend(trail, drawFrom, hit, speed * speedScale)
					Visualiser.Flush(trail)
					drawFrom = hit
				end
				local action, decision = self:_resolveHit(data, result, hit)
				if data.Ended then
					return true
				end
				if action == "penetration" then
					local ratio = if speed > 0 then data.Velocity.Magnitude / speed else 0
					from = decision.Position :: Vector3
					if trail then
						Visualiser.Penetration(hit, from)
						drawFrom = from
					end
					data.DistanceTravelled += (from - hit).Magnitude
					to = Math.ContinueSegment(hit, to, from, ratio)
					displacement = to - from
					result = castSegment(data, useLagComp, from, displacement, params, radius)
				elseif action == "ricochet" then
					if tracks then
						self:_segment(data, segmentFrom, hit)
						segmentFrom = data.CurrentPosition
					end
					data.DistanceTravelled += (data.CurrentPosition - hit).Magnitude
					from = data.CurrentPosition
					drawFrom = from
					to = from
					result = nil
				else
					to = hit
					stop = true
					result = nil
				end
			end

			time = data.Time
			velocity = data.Velocity
			travelled = data.DistanceTravelled
		end

		if trail then
			Visualiser.Extend(trail, drawFrom, to, velocity.Magnitude * speedScale)
		end
		travelled += (to - from).Magnitude
		position = to
		direction = velocity

		if stop or time >= lifetime then
			stop = true
			break
		end
	end

	if stop and trail then
		Visualiser.Flush(trail)
	end

	data.Time = time
	data.Velocity = velocity
	data.CurrentPosition = position
	data.CurrentDirection = direction
	data.DistanceTravelled = travelled

	if tracks then
		self:_segment(data, segmentFrom, position)
		if data.Ended then
			return true
		end
		velocity = data.Velocity
	end

	local motor = data.Motor
	local bullet = data.Bullet
	local render = not stop and (motor ~= nil or bullet ~= nil)
	if render and lod and motor then
		local offset = position - lod.Eye
		local distance = offset:Dot(offset)
		local limits = lod.Limits
		if distance > limits[1] then
			local tier = 1
			for i = 2, #limits do
				if distance <= limits[i] then
					break
				end
				tier = i
			end
			local rate = lod.Rates[tier]
			local phase = data.RenderPhase
			render = math.floor(lod.Now * rate + phase) ~= math.floor(lod.Previous * rate + phase)
		end
	end
	if render then
		local facing = if velocity.Magnitude > 0 then velocity.Unit else FORWARD
		if motor then
			motor.Transform = CFrame.lookAlong(position, facing)
		elseif bullet then
			local parts = self._bulletParts
			local n = #parts + 1
			parts[n] = bullet
			self._newCFrames[n] = CFrame.lookAlong(position, facing)
		end
	end

	return stop
end

function Caster._heartbeat(self: Caster, deltaTime: number)
	if self._useParallel then
		return
	end

	local bullets = self._activeBullets
	local count = #bullets
	if count == 0 then
		self._stepTime = 0
		return
	end

	local started = os.clock()
	local settings = self._settings
	local frame = math.min(deltaTime, MAX_FRAME) * settings.TimeScale
	local maxStep = 1 / settings.UpdateRate
	local lagComp = IS_SERVER and settings.LagCompensation
	local visualise = settings.Visualise and IS_CLIENT
	TargetsStale = true

	local lod = self._lod
	if lod then
		local camera = workspace.CurrentCamera
		if camera then
			lod.Eye = camera.CFrame.Position
			lod.Previous = lod.Now
			lod.Now += deltaTime
		else
			lod = nil
		end
	end

	for i = count, 1, -1 do
		local data = bullets[i]
		if data.Ended or (not data.Paused and stepProjectile(self, data, frame, maxStep, lagComp, visualise, lod)) then
			data.Ended = true
			releaseBullet(data)

			local n = #bullets
			bullets[i] = bullets[n]
			bullets[n] = nil
		end
	end

	local parts = self._bulletParts
	if #parts > 0 then
		workspace:BulkMoveTo(parts, self._newCFrames, MOVE_MODE)
		table.clear(self._newCFrames)
		table.clear(parts)
	end

	self._stepTime = os.clock() - started
end

function Caster._resolveHit(self: Caster, data: ProjectileData, result: RaycastResult, center: Vector3): (string, Math.Decision)
	self._hits += 1
	local config = data.Config
	local hardnessTable = self._settings.SurfaceHardness
	local hardness = Math.PartHardness(result.Instance)
		or hardnessTable[result.Material]
		or hardnessTable.Default
	local decision = Math.Resolve(
		result,
		data.Velocity,
		hardness,
		if Math.UnderLimit(data.Ricochets, config.MaxRicochets) then config.RichochetAngle else nil,
		config.RichochetHardness,
		if Math.UnderLimit(data.Penetrations, config.MaxPenetrations) then data.PenetrationPower else nil,
		config.Loss,
		data.RayParams :: RaycastParams,
		center
	)

	if self._settings.Visualise then
		Visualiser.Hit(result.Position, result.Normal, decision.Type)
	end

	if decision.Type == "Humanoid" then
		self:_markHumanoidHit(data, decision.Humanoid :: Humanoid)
		if config.OnHumanoidHit then
			config.OnHumanoidHit:Fire(result, data, decision.Humanoid :: Humanoid)
		end
		if config.OnImpact then
			config.OnImpact:Fire(result, data)
		end
		return "stop", decision
	elseif decision.Type == "Ricochet" then
		data.Ricochets += 1
		data.Velocity = decision.Velocity :: Vector3
		data.CurrentPosition = decision.Position :: Vector3
		data.Origin = decision.Position :: Vector3
		if config.OnRichochet then
			config.OnRichochet:Fire(result, data)
		end
		return "ricochet", decision
	elseif decision.Type == "Penetration" then
		data.Penetrations += 1
		data.PenetrationPower = (data.PenetrationPower :: number) - (decision.Cost :: number)
		data.Velocity = decision.Velocity :: Vector3
		if config.OnPenetration then
			config.OnPenetration:Fire(result, data)
		end
		return "penetration", decision
	end

	if config.OnImpact then
		config.OnImpact:Fire(result, data)
	end
	return "stop", decision
end

return Caster :: Caster
