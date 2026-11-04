--!strict
-- Test harness for EnaltCast. Only used by test.project.json; never published.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EnaltCast = ReplicatedStorage.Packages.EnaltCast
local Caster = require(EnaltCast).new()
local LagCompensation = require(EnaltCast.LagCompensation)

local Fire = ReplicatedStorage.EnaltCastTest.Fire :: RemoteEvent
local BulletTemplate = ReplicatedStorage.EnaltCastTest.Bullet :: BasePart

local OnImpact = Caster:NewSignal()
local OnHumanoidHit = Caster:NewSignal()
local OnRichochet = Caster:NewSignal()
local OnPenetration = Caster:NewSignal()

OnImpact:Connect(function(result: RaycastResult)
	print("[EnaltCast] impact", result.Instance:GetFullName(), result.Position)
end)
OnHumanoidHit:Connect(function(_result: RaycastResult, _data, humanoid: Humanoid)
	print("[EnaltCast] humanoid hit", humanoid.Parent and humanoid.Parent.Name)
	humanoid:TakeDamage(10)
end)
OnRichochet:Connect(function(result: RaycastResult)
	print("[EnaltCast] ricochet", result.Instance.Name)
end)
OnPenetration:Connect(function(result: RaycastResult)
	print("[EnaltCast] penetration", result.Instance.Name)
end)

-- Track characters so lag-compensated casts can rewind them
local function onCharacter(character: Model)
	LagCompensation.Register(character)
	character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			LagCompensation.Unregister(character)
		end
	end)
end
local function onPlayer(player: Player)
	if player.Character then
		onCharacter(player.Character)
	end
	player.CharacterAdded:Connect(onCharacter)
end
Players.PlayerAdded:Connect(onPlayer)
for _, player in Players:GetPlayers() do
	onPlayer(player)
end

Fire.OnServerEvent:Connect(function(player: Player, origin: unknown, direction: unknown, shotTime: unknown)
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
		return
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character :: Instance }

	Caster:Cast({
		Speed = 200,
		ExtraForce = Vector3.new(0, -workspace.Gravity / 5, 0),
		RayParams = params,
		Lifetime = 5,
		Attributes = {},

		RichochetAngle = 10,
		RichochetHardness = 9,
		PenetrationPower = 50,

		LagCompensation = typeof(shotTime) == "number",
		RewindTime = if typeof(shotTime) == "number" then shotTime else nil,

		OnImpact = OnImpact,
		OnHumanoidHit = OnHumanoidHit,
		OnRichochet = OnRichochet,
		OnPenetration = OnPenetration,
	}, origin, direction.Unit, BulletTemplate:Clone())
end)
