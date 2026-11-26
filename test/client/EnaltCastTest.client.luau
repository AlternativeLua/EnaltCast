--!strict
-- Test harness for EnaltCast. Hold the left mouse button to fire at the mouse.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local TestFolder = ReplicatedStorage:WaitForChild("EnaltCastTest")
local Fire = TestFolder:WaitForChild("Fire") :: RemoteEvent
local TestConfig = require(TestFolder:WaitForChild("TestConfig") :: ModuleScript) :: any

-- Visual-only caster: casts the same shot locally with no bullet part, so the visualiser
-- can draw paths (it only draws them on the client). The server's cast is authoritative.
local EnaltCast = (ReplicatedStorage:WaitForChild("Packages") :: Folder):WaitForChild("EnaltCast") :: ModuleScript
local VisualCaster = if TestConfig.Visualise
	then (require(EnaltCast) :: any).new({
		Visualise = true,
		LagCompensation = false,
	})
	else nil
local VisualSignals = if VisualCaster
	then {
		OnImpact = VisualCaster:NewSignal(),
		OnHumanoidHit = VisualCaster:NewSignal(),
		OnRichochet = VisualCaster:NewSignal(),
		OnPenetration = VisualCaster:NewSignal(),
	}
	else nil

local FIRE_RATE = 100 -- shots per second while held
local FIRE_INTERVAL = 1 / FIRE_RATE

local player = Players.LocalPlayer
local mouse = player:GetMouse()

local held = false
local cooldown = 0
local shots = 0

local function fire()
	local character = player.Character
	local head = character and character:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end

	local origin = head.Position
	local direction = (mouse.Hit.Position - origin).Unit
	Fire:FireServer(origin, direction, workspace:GetServerTimeNow())

	if VisualCaster and VisualSignals then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { character :: Instance }

		local shot = TestConfig.Shot
		VisualCaster:Cast({
			Speed = shot.Speed,
			ExtraForce = shot.ExtraForce,
			RayParams = params,
			Lifetime = shot.Lifetime,
			Attributes = {},

			RichochetAngle = shot.RichochetAngle,
			RichochetHardness = shot.RichochetHardness,
			PenetrationPower = shot.PenetrationPower,

			OnImpact = VisualSignals.OnImpact,
			OnHumanoidHit = VisualSignals.OnHumanoidHit,
			OnRichochet = VisualSignals.OnRichochet,
			OnPenetration = VisualSignals.OnPenetration,
		} :: any, origin, direction)
	end

	-- Read by PerfStats for the shots/s readout
	shots += 1
	player:SetAttribute("EnaltCastShots", shots)
end

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.UserInputType == Enum.UserInputType.MouseButton1 then
		held = true
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		held = false
	end
end)

-- Releasing the mouse outside the window never fires InputEnded
UserInputService.WindowFocusReleased:Connect(function()
	held = false
end)

RunService.Heartbeat:Connect(function(deltaTime: number)
	cooldown -= deltaTime
	if held then
		-- Fire every shot that's due this frame so the rate holds at low FPS
		while cooldown <= 0 do
			fire()
			cooldown += FIRE_INTERVAL
		end
	elseif cooldown < 0 then
		-- Don't bank shots while idle
		cooldown = 0
	end
end)
