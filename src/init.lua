---@diagnostic disable: undefined-doc-name
--!strict
--!optimize 2

-- Original Author: AlternativeFent
-- Editor and Optimiser: EnumEnv

local RunService = game:GetService("RunService")

local Types = require(script.Types)
local Visualiser = require(script.Visualiser)
local Settings = require(script.Settings)
local Math = require(script.Math)
local LagCompensation = require(script.LagCompensation)
local FastSignal = require(script.Packages.fastsignal)
local Pooler = require(script.Pooler)

local Caster = {}
Caster.__index = Caster

local IS_SERVER = RunService:IsServer()
local MAX_FRAME = 0.1

local BulletFolder = workspace:FindFirstChild("BulletsFolder") or Instance.new("Folder")
BulletFolder.Name = "BulletsFolder"
BulletFolder.Parent = workspace

local BulletActors: { Actor } = {}
local CommHit: BindableEvent
local CommEnd: BindableEvent
local ActorsCreated = false

-- Actors run their own Script under a non-replicated container (ServerScriptService
-- on the server, the local player's PlayerScripts on the client) so they actually
-- execute and never leak across the network boundary.
local function ensureActors()
	if ActorsCreated then
		return
	end
	ActorsCreated = true

	local container: Instance
	local template: Instance?
	if RunService:IsServer() then
		container = game:GetService("ServerScriptService")
		template = script:FindFirstChild("BulletActorScriptServer")
	else
		container = game:GetService("Players").LocalPlayer:WaitForChild("PlayerScripts")
		template = script:FindFirstChild("BulletActorScriptClient")
	end

	local holder = Instance.new("Folder")
	holder.Name = "EnaltCastRuntime"

	CommHit = Instance.new("BindableEvent")
	CommHit.Name = "BulletHit"
	CommHit.Parent = holder

	CommEnd = Instance.new("BindableEvent")
	CommEnd.Name = "BulletEnd"
	CommEnd.Parent = holder

	for i = 1, Settings.ActorAmount do
		local actor = Instance.new("Actor")
		actor.Name = "BulletActor" .. i

		local moduleRef = Instance.new("ObjectValue")
		moduleRef.Name = "Module"
		moduleRef.Value = script
		moduleRef.Parent = actor

		if template then
			template:Clone().Parent = actor
		end

		actor.Parent = holder
		BulletActors[i] = actor
	end

	holder.Parent = container
end

type CastConfig = Types.CastConfig
type ProjectileData = Types.ProjectileData
type Pooler = Pooler.Pooler
export type Caster = typeof(Caster) & {
	_connections: { RBXScriptConnection },
	_activeBullets: { ProjectileData },
	_actorBullets: { [number]: ProjectileData },
	_actorWorkloads: { [number]: number },
	_bulletToActorMap: { [number]: number },
	_bulletIdCounter: number,
	_currentActorIndex: number,
	_useParallel: boolean,
	_commReady: boolean,
}

function Caster.new(): Caster
	local self: Caster = setmetatable({}, Caster) :: any

	self._connections = {}
	self._activeBullets = {}
	self._actorBullets = {}
	self._actorWorkloads = {}
	self._bulletToActorMap = {}
	self._bulletIdCounter = 0
	self._currentActorIndex = 1
	self._useParallel = Settings.ParallelProcessing
	self._commReady = false

	for i = 1, Settings.ActorAmount do
		self._actorWorkloads[i] = 0
	end

	if self._useParallel then
		ensureActors()
		self:_setupActorCommunication()
	end

	local signal = RunService:IsClient() and RunService.RenderStepped or RunService.Heartbeat
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
end

function Caster._pickActor(self: Caster): number
	if Settings.LoadBalanceStrategy == "RoundRobin" then
		local i = self._currentActorIndex
		self._currentActorIndex = (i % Settings.ActorAmount) + 1
		return i
	end

	local best, min = 1, math.huge
	for i = 1, Settings.ActorAmount do
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
		bullet = data.Bullet,
		origin = data.CurrentPosition,
		velocity = data.Velocity,
		extraForce = config.ExtraForce or Vector3.zero,
		lifetime = config.Lifetime or 5,
		time = data.Time,
		filter = table.clone(data.IgnoreList),
		filterType = rp.FilterType,
		ignoreWater = rp.IgnoreWater,
		respectCanCollide = rp.RespectCanCollide,
		collisionGroup = rp.CollisionGroup,
		penetrationPower = data.PenetrationPower,
		ricochetAngle = config.RichochetAngle,
		ricochetHardness = config.RichochetHardness,
		loss = config.Loss,
	}
end

function Caster._handleActorHits(self: Caster, hits: { any })
	for _, h in hits do
		local data = self._actorBullets[h.bulletId]
		if not data then
			continue
		end

		local config = data.Config
		local result = {
			Instance = h.instance,
			Position = h.position,
			Normal = h.normal,
			Material = h.material,
			Distance = h.distance,
		} :: any

		if h.type == "Humanoid" then
			if config.OnHumanoidHit then
				config.OnHumanoidHit:Fire(result, data, h.humanoid)
			end
			if config.OnImpact then
				config.OnImpact:Fire(result, data)
			end
		elseif h.type == "Ricochet" then
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

		if Settings.Visualise then
			Visualiser.VisualiseHit(CFrame.new(h.position))
		end
	end
end

function Caster._handleActorEnds(self: Caster, ids: { number })
	for _, id in ids do
		local data = self._actorBullets[id]
		if data then
			if data.Pooler and data.Bullet then
				data.Pooler:Return(data.Bullet)
			elseif data.Bullet then
				data.Bullet:Destroy()
			end
		end

		local actorIndex = self._bulletToActorMap[id]
		if actorIndex then
			self._actorWorkloads[actorIndex] = math.max(0, self._actorWorkloads[actorIndex] - 1)
			self._bulletToActorMap[id] = nil
		end
		self._actorBullets[id] = nil
	end
end

function Caster.Destroy(self: Caster)
	for _, connection in self._connections do
		connection:Disconnect()
	end

	if self._useParallel then
		for i = 1, Settings.ActorAmount do
			if BulletActors[i] then
				BulletActors[i]:SendMessage("Cleanup")
			end
		end
	end

	self._connections = {}
	self._activeBullets = {}
	self._actorBullets = {}
	self._actorWorkloads = {}
	self._bulletToActorMap = {}
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
)
	if RunService:IsServer() and bullet and Settings.SafeMode then
		warn("It's recommended to replicate bullets on the client!")
		return
	end

	local pooler: Pooler? = nil
	if bullet and typeof(bullet) ~= "Instance" then
		pooler = bullet
		bullet = (bullet :: Pooler):Pull()
	end

	if bullet then
		(bullet :: BasePart).Parent = BulletFolder
	end

	local data: ProjectileData = {
		Config = config,
		Origin = origin,
		Direction = direction,
		Time = 0,
		RewindTime = config.RewindTime,
		CurrentPosition = origin,
		CurrentDirection = direction,
		Velocity = direction * config.Speed,
		IgnoreList = table.clone(config.RayParams.FilterDescendantsInstances),
		PenetrationPower = config.PenetrationPower,
		RayParams = Math.CloneRayParams(config.RayParams),
		Bullet = bullet :: BasePart?,
		Pooler = pooler,
	}

	if self._useParallel then
		self._bulletIdCounter += 1
		local id = self._bulletIdCounter
		self._actorBullets[id] = data

		local actorIndex = self:_pickActor()
		self._actorWorkloads[actorIndex] += 1
		self._bulletToActorMap[id] = actorIndex

		BulletActors[actorIndex]:SendMessage("CastBullet", self:_actorPayload(id, data))
	else
		table.insert(self._activeBullets, data)
	end
end

function Caster.GetBulletFolderAsync(self: Caster): Folder
	return BulletFolder or workspace:WaitForChild("BulletsFolder")
end

function Caster.NewSignal<T1, T2, T3>(self: Caster): FastSignal.ScriptSignal<T1, T2, T3?>
	return FastSignal.new()
end

function Caster.NewPooler(self: Caster, ...)
	return Pooler.new(...)
end

function Caster.GetWorkloadDistribution(self: Caster): { [number]: number }
	local distribution = {}
	for i = 1, Settings.ActorAmount do
		distribution[i] = self._actorWorkloads[i]
	end
	return distribution
end

function Caster.GetTotalActorBullets(self: Caster): number
	local total = 0
	for i = 1, Settings.ActorAmount do
		total += self._actorWorkloads[i]
	end
	return total
end

function Caster.SetParallelProcessing(self: Caster, useParallel: boolean)
	if self._useParallel == useParallel then
		return
	end

	if useParallel then
		ensureActors()
		self:_setupActorCommunication()

		for i = #self._activeBullets, 1, -1 do
			local data = self._activeBullets[i]
			self._bulletIdCounter += 1
			local id = self._bulletIdCounter
			self._actorBullets[id] = data

			local actorIndex = self:_pickActor()
			self._actorWorkloads[actorIndex] += 1
			self._bulletToActorMap[id] = actorIndex

			BulletActors[actorIndex]:SendMessage("CastBullet", self:_actorPayload(id, data))
			self._activeBullets[i] = nil
		end
	else
		for i = 1, Settings.ActorAmount do
			if BulletActors[i] then
				BulletActors[i]:SendMessage("Cleanup")
			end
		end

		for _, data in self._actorBullets do
			table.insert(self._activeBullets, data)
		end

		self._actorBullets = {}
		self._bulletToActorMap = {}
		for i = 1, Settings.ActorAmount do
			self._actorWorkloads[i] = 0
		end
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

	local bullets = self._activeBullets
	for i = #bullets, 1, -1 do
		local data = bullets[i]
		if self:_stepProjectile(data, deltaTime) then
			if data.Pooler and data.Bullet then
				data.Pooler:Return(data.Bullet)
			elseif data.Bullet then
				data.Bullet:Destroy()
			end

			local n = #bullets
			bullets[i] = bullets[n]
			bullets[n] = nil
		end
	end
end

-- Advances a bullet by deltaTime, sub-stepping at UpdateRate so flight and hit
-- detection stay frame-rate independent while the part still moves every frame.
function Caster._stepProjectile(self: Caster, data: ProjectileData, deltaTime: number): boolean
	local config = data.Config
	local force = config.ExtraForce or Vector3.zero
	local lifetime = config.Lifetime or 5
	local maxStep = 1 / Settings.UpdateRate
	local params = data.RayParams :: RaycastParams

	-- Rewind tracked targets only on the server, for shots that opted in
	local useLagComp = IS_SERVER and Settings.LagCompensation and config.LagCompensation and data.RewindTime ~= nil

	local visFrom = data.CurrentPosition
	local remaining = math.min(deltaTime, MAX_FRAME)
	local stop = false

	while remaining > 0 do
		local step = math.min(remaining, maxStep)
		remaining -= step
		data.Time += step
		data.Velocity += force * step

		local from = data.CurrentPosition
		local to = from + data.Velocity * step

		while true do
			params.FilterDescendantsInstances = data.IgnoreList
			local result
			if useLagComp then
				result = LagCompensation.Raycast(from, to - from, params, data.IgnoreList, (data.RewindTime :: number) + data.Time)
			else
				result = workspace:Raycast(from, to - from, params)
			end
			if not result then
				break
			end

			local action = self:_resolveHit(data, result)
			if action == "penetration" then
				from = result.Position
			elseif action == "ricochet" then
				to = data.CurrentPosition
				break
			else
				to = result.Position
				stop = true
				break
			end
		end

		data.CurrentPosition = to
		data.CurrentDirection = data.Velocity

		if stop or data.Time >= lifetime then
			stop = true
			break
		end
	end

	local v = data.Velocity
	local facing = if v.Magnitude > 0 then v.Unit else -Vector3.zAxis

	if data.Bullet then
		data.Bullet.CFrame = CFrame.lookAlong(data.CurrentPosition, facing)
	end

	if Settings.Visualise and RunService:IsClient() then
		Visualiser.VisualiseSegment(CFrame.lookAlong(visFrom, facing), (data.CurrentPosition - visFrom).Magnitude)
	end

	return stop
end

function Caster._resolveHit(self: Caster, data: ProjectileData, result: RaycastResult): string
	local config = data.Config
	local hardness = Settings.SurfaceHardness[result.Material] or Settings.SurfaceHardness.Default
	local decision = Math.Resolve(
		result,
		data.Velocity,
		hardness,
		config.RichochetAngle,
		config.RichochetHardness,
		data.PenetrationPower,
		config.Loss
	)

	if decision.Type == "Humanoid" then
		if config.OnHumanoidHit then
			config.OnHumanoidHit:Fire(result, data, decision.Humanoid :: Humanoid)
		end
		if config.OnImpact then
			config.OnImpact:Fire(result, data)
		end
		return "stop"
	elseif decision.Type == "Ricochet" then
		data.Velocity = decision.Velocity :: Vector3
		data.CurrentPosition = result.Position
		data.Origin = result.Position
		if config.OnRichochet then
			config.OnRichochet:Fire(result, data)
		end
		return "ricochet"
	elseif decision.Type == "Penetration" then
		data.PenetrationPower = (data.PenetrationPower :: number) - (decision.Cost :: number)
		table.insert(data.IgnoreList, result.Instance)
		if config.OnPenetration then
			config.OnPenetration:Fire(result, data)
		end
		return "penetration"
	end

	if config.OnImpact then
		config.OnImpact:Fire(result, data)
	end
	return "stop"
end

return Caster :: Caster
