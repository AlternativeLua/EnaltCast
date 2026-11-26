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
	UpdateRate: number,
	ActorAmount: number,
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

	LagCompensation: boolean?,
	RewindTime: number?, --> client Workspace:GetServerTimeNow() at the shot

	OnImpact: Zignal.Signal<RaycastResult, ProjectileData>,
	OnPenetration: Zignal.Signal<RaycastResult, ProjectileData>,
	OnRichochet: Zignal.Signal<RaycastResult, ProjectileData>,
	OnHumanoidHit: Zignal.Signal<RaycastResult, ProjectileData, Humanoid>,
}

export type ProjectileData = {
	Config: CastConfig,
	Origin: Vector3,
	Direction: Vector3,
	CurrentPosition: Vector3,
	CurrentDirection: Vector3,
	Velocity: Vector3,
	DistanceTravelled: number,
	Time: number,
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
