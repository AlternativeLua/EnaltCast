# EnaltCast

Super fast and easy to use casting system. Made for projectile physics that's super optimized and light weight.

# Credits

Authors: Alternative, EnumEnv
Visualiser: FastCast

# Example

`Server`

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fire = ReplicatedStorage.Fire
local Caster = require(ReplicatedStorage.EnaltCast).new()
local ImpactSignal = Caster.NewSignal()

Fire.OnServerEvent:Connect(function(player, origin, direction)
    local Pararms = RaycastParams.new()
	Pararms.FilterType = Enum.RaycastFilterType.Exclude
	Pararms.FilterDescendantsInstances = {player.Character}

    local bullet = ReplicatedStorage.Bullet:Clone()
    bullet.Parent = workspace

    Caster:Cast({
        Speed = 100,
        ExtraForce = Vector3.new(0, -workspace.Gravity / 5, 0),
		RayParams = Pararms,
        RichochetAngle = 10,
        RichochetHardness = 9,
        PenetrationPower = 50,
		OnImpact = ImpactSignal
    }, origin, direction, bullet)
end)

ImpactSignal:Connect(function(...)
    print(...)
end)
```

`Client`

```lua
local UserInputService = game:GetService("UserInputService")
local RpelicatedStorage = game:GetService("ReplicatedStorage")

local Player = game.Players.LocalPlayer
local Mouse = Player:GetMouse()

Player.CharacterAdded:Connect(function(character)
	character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			child.Activated:Connect(function()

				local origin = character.Head.Position
				local hit = Mouse.Hit

				local direction = (hit.Position - origin).unit

				RpelicatedStorage.Fire:FireServer(origin, direction)
			end)
		end
	end)
end)
```

# Docs

## Types

#### CastConfig

`Speed: number`: How fast the projectile would move \
`ExtraForce: Vector3`: An extra force you can use for things like gravity \
`RayParams: RaycastParams`: The raycast params you want to use \
`Lifetime: number?`: How long should the projectile should exist before getting deleted 

`RicochetAngle: number?`: The angle at which the projectile can ricochet \
`RicochetHardness: number?`: How hard the surface should be to ricochet \
`MaxRicochets: number?`: Ricochets allowed before a glancing hit becomes an impact (unlimited when nil) \
`MaxPenetrations: number?`: Parts the projectile can pass through before it stops (unlimited when nil)

`Radius: number?`: Makes the projectile a sphere of this radius (studs) swept with `workspace:Spherecast`, for rockets and other thick projectiles. Hit signals get the contact point on the surface; the projectile's position stays its centre \
`Drag: number?`: Air resistance; the projectile slows by `Drag * airspeed²` \
`Wind: Vector3?`: Air velocity in studs/s. It pushes the projectile through drag, so it needs `Drag` set

Surface hardness comes from the caster's `SurfaceHardness` table by material. A `Hardness` number attribute on a part overrides it for that part. \
`ProjectileData.DistanceTravelled` holds the distance flown so far (useful for damage falloff), alongside `Ricochets` and `Penetrations` counts.

`OnImpact: Zignal.Signal<RaycastResult, ProjectileData>`: This signal gets fired when the projectile hits something \
`OnSegment: Zignal.Signal<Vector3, Vector3, ProjectileData>?`: Fires every frame with the stretch the projectile just flew (from, to), split at ricochets. Use it for tracers and whiz sounds \
`OnNearMiss: Zignal.Signal<Player, Vector3, number, ProjectileData>?`: Fires once per player when the projectile passes within `NearMissRadius` of their head, with the closest point and distance. Players the projectile hits, and characters in the ignore list, are skipped \
`NearMissRadius: number?`: Radius for `OnNearMiss` in studs (default 10)

## Class
### Functions

#### `.new(settings: CasterSettings?): class`
Creates a new caster class \
**settings**: `CasterSettings?` Overrides for this caster only; anything left out uses the defaults in `Settings.luau`. `SurfaceHardness` entries are merged into the default table, so overriding one material keeps the rest \
**return:** `class` 

```lua
local Caster = require(ReplicatedStorage.EnaltCast).new({
    ParallelProcessing = true,
    ActorAmount = 8,
    SurfaceHardness = { [Enum.Material.Metal] = 40 },
})
```
#### `:SetTimeScale(scale: number)` / `:GetTimeScale(): number`
Speeds up or slows down every projectile from this caster, including ones already in flight. `1` is normal speed, `0.25` is quarter speed, `0` freezes them. Can also be set up front with the `TimeScale` setting. `Lifetime` is counted in scaled time, so slowed projectiles live longer in real time

#### `:Cast(config: CastConfig, origin: Vector3, direction: Vector3, bullet: BasePart?)` 
Starts a new projectile cast \
**config**: `CastConfig` The configuration of this projectile \
**origin**: `Vector3` Where the projectile starts \
**direction**: `Vector3` The direction where the projectile should go \
**bullet**: `BasePart?` The visual part of the projectile \
**return:** `CastHandle?` A handle to control the projectile (nil when SafeMode blocks a server-side bullet)

#### CastHandle
`:Terminate()`: Ends the projectile now and frees its bullet part. No signals fire \
`:GetPosition(): Vector3`: The projectile's current position (its last position once it has ended) \
`:SetVelocity(velocity: Vector3)`: Replaces the projectile's velocity \
`:Pause()` / `:Resume()`: Freezes the projectile in place, then lets it carry on

Calls on a projectile that has already ended do nothing.

# Development

Tools are pinned in `rokit.toml` (Rojo + Wally).

```sh
rokit install                       # install pinned tools
rojo serve test.project.json        # live-sync the test place into Studio
```

The test place puts EnaltCast in `ReplicatedStorage.Packages` (the same layout Wally gives consumers) and adds a baseplate, a wall, and a test harness in `test/`. Press Play and click to fire; impacts, ricochets, penetrations and humanoid hits print to the output.

For luau-lsp, generate a sourcemap with `rojo sourcemap test.project.json -o sourcemap.json`. `sourcemap.json` is generated and not committed.
