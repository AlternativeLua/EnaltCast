--!strict
-- Test harness for EnaltCast. Click (with or without the tool) to fire at the mouse.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Fire = ReplicatedStorage:WaitForChild("EnaltCastTest"):WaitForChild("Fire") :: RemoteEvent

local player = Players.LocalPlayer
local mouse = player:GetMouse()

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return
	end

	local character = player.Character
	local head = character and character:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end

	local origin = head.Position
	local direction = (mouse.Hit.Position - origin).Unit
	Fire:FireServer(origin, direction, workspace:GetServerTimeNow())
end)
