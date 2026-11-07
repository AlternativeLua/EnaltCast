--!strict
-- Test harness for EnaltCast. Hold the left mouse button to fire at the mouse.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Fire = ReplicatedStorage:WaitForChild("EnaltCastTest"):WaitForChild("Fire") :: RemoteEvent

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
