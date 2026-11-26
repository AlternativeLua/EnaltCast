---@diagnostic disable: undefined-doc-name
--!strict
--!optimize 2

-- Original Author: AlternativeFent
-- Editor and Optimiser: EnumEnv

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
local MAX_FRAME = 0.1

local BulletFolder = workspace:FindFirstChild("BulletsFolder") or Instance.new("Folder")
BulletFolder.Name = "BulletsFolder"
BulletFolder.Parent = workspace

-- Client bullets hang off one anchored root through a Motor6D and are moved by
-- writing Motor6D.Transform, which is far cheaper than setting CFrame. Transform
-- doesn't replicate, so server-side bullets keep using BulkMoveTo.
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
local CommHit: BindableEvent
local CommEnd: BindableEvent
local CommSegment: BindableEvent
local DEFAULT_NEAR_MISS_RADIUS = 10

local NextBulletId = 0
local NextCasterId = 0

-- Actors write their per-frame compute time here, keyed by actor name. Shared by
-- every caster using the same actors.
local ActorStepTimes = SharedTableRegistry:GetSharedTable("EnaltCastActorStepTime")

local function applyActorState(data: Types.ProjectileData, s: any)
	data.CurrentPosition = s.position
	data.Velocity = s.velocity
	data.CurrentDirection = s.velocity
	data.Time = s.time
	data.DistanceTravelled = s.travelled
	data.PenetrationPower = s.power
	data.Ricochets = s.ricochets
	data.Penetrations = s.penetrations
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

		CommHit = Instance.new("BindableEvent")
		CommHit.Name = "BulletHit"
		CommHit.Parent = holder

		CommEnd = Instance.new("BindableEvent")
		CommEnd.Name = "BulletEnd"
		CommEnd.Parent = holder

		CommSegment = Instance.new("BindableEvent")
		CommSegment.Name = "BulletSegment"
		CommSegment.Parent = holder

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

type CasterSettings = Types.CasterSettings
type ResolvedSettings = Types.ResolvedSettings
type CasterStats = Types.CasterStats
type CastConfig = Types.CastConfig
type ProjectileData = Types.ProjectileData
type Pooler = Pooler.Pooler
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
		local actorIndex = self._caster._bulletToActorMap[id]
		local live = actorIndex and ActorPositions[actorIndex][id]
		if live then
			return live :: Vector3
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

	table.insert(
		self._connections,
		CommHit.Event:Connect(function(hits)
			self:_handleActorHits(hits)
		end)
	)
	table.insert(
		self._connections,
		CommEnd.Event:Connect(function(ids)
			self:_handleActorEnds(ids)
		end)
	)
	table.insert(
		self._connections,
		CommSegment.Event:Connect(function(segments)
			self:_handleActorSegments(segments)
		end)
	)
end

function Caster._handleActorSegments(self: Caster, segments: { any })
	for _, s in segments do
		if s.casterId ~= self._id then
			continue
		end
		local data = self._actorBullets[s.bulletId]
		if data then
			self:_segment(data, s.from, s.to)
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

	local radius = config.NearMissRadius or DEFAULT_NEAR_MISS_RADIUS
	local segment = to - from
	local lengthSquared = segment:Dot(segment)
	local nearMissed = data.NearMissed

	for _, player in Players:GetPlayers() do
		if nearMissed and nearMissed[player] then
			continue
		end
		local character = player.Character
		if not character or table.find(data.IgnoreList, character) then
			continue
		end
		local head = character:FindFirstChild("Head")
		local point = if head and head:IsA("BasePart") then head.Position else character:GetPivot().Position

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

function Caster._actorPayload(self: Caster, id: number, data: ProjectileData)
	local config = data.Config
	local rp = config.RayParams
	return {
		bulletId = id,
		casterId = self._id,
		bullet = data.Bullet,
		motor = data.Motor,
		origin = data.CurrentPosition,
		velocity = data.Velocity,
		extraForce = config.ExtraForce or Vector3.zero,
		lifetime = config.Lifetime or 5,
		time = data.Time,
		travelled = data.DistanceTravelled,
		filter = table.clone(data.IgnoreList),
		filterType = rp.FilterType,
		ignoreWater = rp.IgnoreWater,
		respectCanCollide = rp.RespectCanCollide,
		collisionGroup = rp.CollisionGroup,
		penetrationPower = data.PenetrationPower,
		ricochetAngle = config.RichochetAngle,
		ricochetHardness = config.RichochetHardness,
		loss = config.Loss,
		radius = config.Radius,
		drag = config.Drag,
		wind = config.Wind,
		maxRicochets = config.MaxRicochets,
		maxPenetrations = config.MaxPenetrations,
		ricochets = data.Ricochets,
		paused = data.Paused,
		penetrations = data.Penetrations,
		tracks = config.OnSegment ~= nil or config.OnNearMiss ~= nil,
		hardness = self._actorHardness,
		updateRate = self._settings.UpdateRate,
		timeScale = self._settings.TimeScale,
	}
end

function Caster._handleActorHits(self: Caster, hits: { any })
	for _, h in hits do
		if h.casterId ~= self._id then
			continue
		end
		local data = self._actorBullets[h.bulletId]
		if not data then
			continue
		end
		self._hits += 1

		local config = data.Config
		local result = {
			Instance = h.instance,
			Position = h.hitPosition,
			Normal = h.normal,
			Material = h.material,
			Distance = h.distance,
		} :: any

		applyActorState(data, h)

		if h.type == "Humanoid" then
			self:_markHumanoidHit(data, h.humanoid)
			if config.OnHumanoidHit then
				config.OnHumanoidHit:Fire(result, data, h.humanoid)
			end
			if config.OnImpact then
				config.OnImpact:Fire(result, data)
			end
		elseif h.type == "Ricochet" then
			data.Origin = h.position
			if config.OnRichochet then
				config.OnRichochet:Fire(result, data)
			end
		elseif h.type == "Penetration" then
			if config.OnPenetration then
				config.OnPenetration:Fire(result, data)
			end
		elseif config.OnImpact then
			config.OnImpact:Fire(result, data)
		end

		if self._settings.Visualise then
			Visualiser.VisualiseHit(CFrame.new(h.hitPosition))
		end
	end
end

function Caster._handleActorEnds(self: Caster, ends: { any })
	for _, e in ends do
		if e.casterId ~= self._id then
			continue
		end
		local id = e.bulletId
		local data = self._actorBullets[id]

		local actorIndex = self._bulletToActorMap[id]
		if actorIndex then
			self._actorWorkloads[actorIndex] = math.max(0, self._actorWorkloads[actorIndex] - 1)
			self._bulletToActorMap[id] = nil
		end
		self._actorBullets[id] = nil

		if not data then
			continue
		end
		applyActorState(data, e)
		data.ActorId = nil

		if e.handoff then
			if self._useParallel then
				self:_dispatchToActor(data)
			else
				table.insert(self._activeBullets, data)
			end
		else
			data.Ended = true
			releaseBullet(data)
		end
	end
end

function Caster._dispatchToActor(self: Caster, data: ProjectileData)
	NextBulletId += 1
	local id = NextBulletId
	self._actorBullets[id] = data
	data.ActorId = id

	local actorIndex = self:_pickActor()
	self._actorWorkloads[actorIndex] += 1
	self._bulletToActorMap[id] = actorIndex

	BulletActors[actorIndex]:SendMessage("CastBullet", self:_actorPayload(id, data))
end

function Caster._dropActorBullet(self: Caster, id: number)
	local actorIndex = self._bulletToActorMap[id]
	if actorIndex then
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
		BulletActors[actorIndex]:SendMessage(message, id, value)
	end
end

-- With handoff, actors reply with each bullet's live state via the end event.
function Caster._cleanupActorBullets(self: Caster, handoff: boolean)
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
	if RunService:IsServer() and bullet and self._settings.SafeMode then
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
		IgnoreList = table.clone(config.RayParams.FilterDescendantsInstances),
		PenetrationPower = config.PenetrationPower,
		RayParams = Math.CloneRayParams(config.RayParams),
		Bullet = bullet :: BasePart?,
		Motor = motor,
		Pooler = pooler,
	}

	(data.RayParams :: RaycastParams).FilterDescendantsInstances = data.IgnoreList

	if self._useParallel then
		self:_dispatchToActor(data)
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

function Caster.SetParallelProcessing(self: Caster, useParallel: boolean)
	if self._useParallel == useParallel then
		return
	end

	if useParallel then
		ensureActors(self._settings.ActorAmount)
		self:_setupActorCommunication()

		for i = #self._activeBullets, 1, -1 do
			self:_dispatchToActor(self._activeBullets[i])
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

function Caster._heartbeat(self: Caster, deltaTime: number)
	if self._useParallel then
		return
	end

	local started = os.clock()
	local bullets = self._activeBullets
	for i = #bullets, 1, -1 do
		local data = bullets[i]
		if data.Ended or (not data.Paused and self:_stepProjectile(data, deltaTime)) then
			data.Ended = true
			releaseBullet(data)

			local n = #bullets
			bullets[i] = bullets[n]
			bullets[n] = nil
		end
	end

	if #self._bulletParts > 0 then
		workspace:BulkMoveTo(self._bulletParts, self._newCFrames)
		table.clear(self._newCFrames)
		table.clear(self._bulletParts)
	end

	self._stepTime = os.clock() - started
end

-- Advances a bullet by deltaTime, sub-stepping at UpdateRate so flight and hit
-- detection stay frame-rate independent while the part still moves every frame.
function Caster._stepProjectile(self: Caster, data: ProjectileData, deltaTime: number): boolean
	local config = data.Config
	local force = config.ExtraForce or Vector3.zero
	local lifetime = config.Lifetime or 5
	local settings = self._settings
	local maxStep = 1 / settings.UpdateRate
	local params = data.RayParams :: RaycastParams

	-- Rewind tracked targets only on the server, for shots that opted in
	local useLagComp = IS_SERVER and settings.LagCompensation and config.LagCompensation and data.RewindTime ~= nil

	local visFrom = data.CurrentPosition
	local tracks = config.OnSegment ~= nil or config.OnNearMiss ~= nil
	local radius = config.Radius
	local segmentFrom = visFrom
	local remaining = math.min(deltaTime, MAX_FRAME) * settings.TimeScale
	local stop = false

	while remaining > 0 do
		local step = math.min(remaining, maxStep)
		remaining -= step
		data.Time += step
		data.Velocity = Math.Integrate(data.Velocity, force, config.Drag, config.Wind, step)

		local from = data.CurrentPosition
		local to = from + data.Velocity * step

		while true do
			local displacement = to - from
			local result
			if useLagComp then
				result = LagCompensation.Raycast(from, displacement, params, data.IgnoreList, (data.RewindTime :: number) + data.Time, radius)
			else
				result = Math.Cast(from, displacement, params, radius)
			end
			if not result then
				break
			end

			local hit = Math.HitCenter(from, displacement, result, radius)
			data.DistanceTravelled += (hit - from).Magnitude
			from = hit

			local speed = data.Velocity.Magnitude
			local action, decision = self:_resolveHit(data, result, hit)
			if data.Ended then
				return true
			end
			if action == "penetration" then
				local ratio = if speed > 0 then data.Velocity.Magnitude / speed else 0
				from = decision.Position :: Vector3
				data.DistanceTravelled += (from - hit).Magnitude
				to = Math.ContinueSegment(hit, to, from, ratio)
			elseif action == "ricochet" then
				if tracks then
					self:_segment(data, segmentFrom, hit)
					segmentFrom = data.CurrentPosition
				end
				data.DistanceTravelled += (data.CurrentPosition - hit).Magnitude
				from = data.CurrentPosition
				to = data.CurrentPosition
				break
			else
				to = hit
				stop = true
				break
			end
		end

		data.DistanceTravelled += (to - from).Magnitude
		data.CurrentPosition = to
		data.CurrentDirection = data.Velocity

		if stop or data.Time >= lifetime then
			stop = true
			break
		end
	end

	if tracks then
		self:_segment(data, segmentFrom, data.CurrentPosition)
		if data.Ended then
			return true
		end
	end

	local v = data.Velocity
	local facing = if v.Magnitude > 0 then v.Unit else -Vector3.zAxis

	local motor = data.Motor
	if motor then
		motor.Transform = CFrame.lookAlong(data.CurrentPosition, facing)
	elseif data.Bullet then
		table.insert(self._bulletParts, data.Bullet)
		table.insert(self._newCFrames, CFrame.lookAlong(data.CurrentPosition, facing))
	end

	if settings.Visualise and RunService:IsClient() then
		Visualiser.VisualiseSegment(CFrame.lookAlong(visFrom, facing), (data.CurrentPosition - visFrom).Magnitude)
	end

	return stop
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
