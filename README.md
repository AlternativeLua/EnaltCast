# EnaltCast

EnaltCast is a projectile module made for all kinds of purposes. It's the most performant library out there greatly beating FastCast. With also many useful functions and capabilities packed within.

## Features
* **Insanely fast**: up to ~2× SwiftCast's FPS at 16,000 bullets alive at once (see [BENCHMARKS.md](BENCHMARKS.md))
* **Parallelism**: optionally runs bullets across Actors, with least-loaded or round-robin balancing.
* **Ricochets and penetration**
* **Shape Casting**: give a bullet a radius and it uses spherecasts instead of thin rays
* **Lag compensation**: server-side hitbox rewind
* **Humanoid hits and near misses**: dedicated signals for hitting a character and for bullets passing close to a player
* **Full cast control**: pause, resume, terminate, read position or change velocity mid-flight
* **Efficient rendering**: bullet object pooling and distance-based render LOD
* **Time scale**: slow motion or speed up all bullets on a caster

## Usage

Install with [Wally](https://wally.run):

```toml
[dependencies]
EnaltCast = "nametakenbonk/enaltcast@1.0.0"
```

Create a caster, then fire bullets with a cast config:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EnaltCast = require(ReplicatedStorage.Packages.EnaltCast)

local caster = EnaltCast.new({ ParallelProcessing = true })

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.FilterDescendantsInstances = { workspace.Shooter }

local config = {
	Speed = 300,
	ExtraForce = Vector3.new(0, -workspace.Gravity, 0),
	RayParams = params,
	Lifetime = 3,
	Attributes = {},

	OnImpact = caster:NewSignal(),
	OnHumanoidHit = caster:NewSignal(),
	OnRichochet = caster:NewSignal(),
	OnPenetration = caster:NewSignal(),
}

config.OnImpact:Connect(function(result: RaycastResult)
	print("hit", result.Instance, result.Position)
end)

config.OnHumanoidHit:Connect(function(result, data, humanoid: Humanoid)
	humanoid:TakeDamage(10)
end)

-- Fire from an origin in a unit direction. Optionally pass a BasePart (or a pooler) as the bullet visual.
local handle = caster:Cast(config, origin, direction.Unit)
```

## Benchmarks

See [BENCHMARKS.md](BENCHMARKS.md) for performance comparisons against SwiftCast

## Contribution

Open to contribution, if you feel like you want a feature or expeirence a bug open an issue. I will respond ASAP. If you also feel like wanting to write your own code fork the repo and open a PR. 
