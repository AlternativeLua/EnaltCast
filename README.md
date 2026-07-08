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
`RicochetHardness: number?`: How hard the surface should be to ricochet 

`OnImpact: FastSignal.ScriptSignal<RaycastResult, ProjectileData>`: This signal gets fired when the projectile hits something

## Class
### Functions

#### `.new(): class`
Creates a new caster class \
**return:** `class` 
#### `:Cast(config: CastConfig, origin: Vector3, direction: Vector3, bullet: BasePart?)` 
Starts a new projectile cast \
**config**: `CastConfig` The configuration of this projectile \
**origin**: `Vector3` Where the projectile starts \
**direction**: `Vector3` The direction where the projectile should go \
**bullet**: `BasePart?` The visual part of the projectile
