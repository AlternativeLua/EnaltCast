local Zignal = require(script.Parent.Zignal)
local Pooler = require(script.Parent.Pooler)

-- Per-caster overrides for the defaults in Settings. SurfaceHardness entries are
-- merged over the default table (keyed by Enum.Material, plus "Default").
export type CasterSettings = {
	SurfaceHardness: { [any]: number }?,
	Visualise: boolean?,
	SafeMode: boolean?,

	LagCompensation: boolean?,
	LagCompensationHistory: number?,

	ParallelProcessing: boolean?,
	LoadBalanceStrategy: ("LeastLoadedActor" | "RoundRobin")?,
	TimeScale: number?,
	UpdateRate: number?,
	ActorAmount: number?,
}

-- CasterSettings after merging with the defaults: every field is present.
export type ResolvedSettings = {
	SurfaceHardness: { [any]: number },
	Visualise: boolean,
	SafeMode: boolean,

	LagCompensation: boolean,
	LagCompensationHistory: number,

	ParallelProcessing: boolean,
	LoadBalanceStrategy: "LeastLoadedActor" | "RoundRobin",
	TimeScale: number,
	UpdateRate: number,
	ActorAmount: number,
}

export type CasterStats = {
	ActiveBullets: number, -- stepped on the main thread
	ActorBullets: number, -- stepped by actors
	Casts: number, -- total since the caster was created
	Hits: number, -- impacts, ricochets, penetrations and humanoid hits, total
	StepTime: number, -- seconds the main-thread step took last frame
	ActorStepTime: number, -- seconds of actor compute last frame, summed over this caster's actors
	Workload: { number }, -- bullets per actor
}

export type CastConfig = {
	Speed: number,
	ExtraForce: Vector3,
	RayParams: RaycastParams,
	Lifetime: number?,

	Attributes: { any },

	RichochetAngle: number?,
	RichochetHardness: number?,
	PenetrationPower: number?,
	Loss: number?,
	MaxRicochets: number?,
	MaxPenetrations: number?,

	Drag: number?,
	Wind: Vector3?,

	LagCompensation: boolean?,
	RewindTime: number?, --> client Workspace:GetServerTimeNow() at the shot

	OnImpact: Zignal.Signal<RaycastResult, ProjectileData>,
	OnPenetration: Zignal.Signal<RaycastResult, ProjectileData>,
	OnRichochet: Zignal.Signal<RaycastResult, ProjectileData>,
	OnHumanoidHit: Zignal.Signal<RaycastResult, ProjectileData, Humanoid>,
	OnSegment: Zignal.Signal<Vector3, Vector3, ProjectileData>?,
	OnNearMiss: Zignal.Signal<Player, Vector3, number, ProjectileData>?,
	NearMissRadius: number?,
}

export type ProjectileData = {
	Config: CastConfig,
	Origin: Vector3,
	Direction: Vector3,
	CurrentPosition: Vector3,
	CurrentDirection: Vector3,
	Velocity: Vector3,
	DistanceTravelled: number,
	Ricochets: number,
	Penetrations: number,
	Time: number,
	Paused: boolean,
	Ended: boolean,
	NearMissed: { [Player]: true }?,
	ActorId: number?,
	RewindTime: number?,
	IgnoreList: { Instance },
	PenetrationPower: number?,
	RayParams: RaycastParams?,
	Bullet: BasePart?,
	Motor: Motor6D?, -- client only: drives Bullet via Transform
	Pooler: Pooler.Pooler?,
}

local Types = {}
return Types
