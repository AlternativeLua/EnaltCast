local FastSignal = require(script.Parent.Packages.fastsignal)
local Pooler = require(script.Parent.Pooler)

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

	OnImpact: FastSignal.ScriptSignal<RaycastResult, ProjectileData>,
	OnPenetration: FastSignal.ScriptSignal<RaycastResult, ProjectileData>,
	OnRichochet: FastSignal.ScriptSignal<RaycastResult, ProjectileData>,
	OnHumanoidHit: FastSignal.ScriptSignal<RaycastResult, ProjectileData, Humanoid>,
}

export type ProjectileData = {
	Config: CastConfig,
	Origin: Vector3,
	Direction: Vector3,
	CurrentPosition: Vector3,
	CurrentDirection: Vector3,
	Velocity: Vector3,
	Time: number,
	IgnoreList: { Instance },
	PenetrationPower: number?,
	RayParams: RaycastParams?,
	Bullet: BasePart?,
	Pooler: Pooler.Pooler?,
}

local Types = {}
return Types
