--!strict
-- Performance overlay for the EnaltCast test place. F2 shows or hides it.
-- Client numbers are measured here; server numbers are attributes published by
-- the server test script on ReplicatedStorage.EnaltCastTest.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")

local REFRESH = 0.5 -- seconds per readout; also the averaging window
local TOGGLE_KEY = Enum.KeyCode.F2

local COLORS = {
	Surface = Color3.fromRGB(24, 24, 27),
	Text = Color3.fromRGB(236, 236, 240),
	TextSecondary = Color3.fromRGB(160, 160, 170),
	Warning = Color3.fromRGB(240, 180, 80),
	Danger = Color3.fromRGB(240, 100, 90),
}
local FONT = Font.new("rbxasset://fonts/families/BuilderSans.json")
local FONT_HEADING = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.SemiBold)
local FONT_VALUE = Font.new("rbxasset://fonts/families/RobotoMono.json")
local TEXT_SIZE = 13
local ROW_HEIGHT = 16

local player = Players.LocalPlayer
local statsFolder = ReplicatedStorage:WaitForChild("EnaltCastTest")

--------
-- UI --
--------

local gui = Instance.new("ScreenGui")
gui.Name = "EnaltCastPerfStats"
gui.ResetOnSpawn = false
gui.DisplayOrder = 100

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(1, 0)
panel.Position = UDim2.new(1, -12, 0, 12)
panel.Size = UDim2.fromOffset(260, 0)
panel.AutomaticSize = Enum.AutomaticSize.Y
panel.BackgroundColor3 = COLORS.Surface
panel.BackgroundTransparency = 0.1
panel.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = panel

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 12)
padding.PaddingBottom = UDim.new(0, 12)
padding.PaddingLeft = UDim.new(0, 12)
padding.PaddingRight = UDim.new(0, 12)
padding.Parent = panel

-- Groups sit 12px apart, rows inside a group 4px apart
local panelLayout = Instance.new("UIListLayout")
panelLayout.SortOrder = Enum.SortOrder.LayoutOrder
panelLayout.Padding = UDim.new(0, 12)
panelLayout.Parent = panel

local order = 0
local function nextOrder(): number
	order += 1
	return order
end

local function label(parent: Instance, text: string, font: Font, color: Color3, alignment: Enum.TextXAlignment): TextLabel
	local textLabel = Instance.new("TextLabel")
	textLabel.BackgroundTransparency = 1
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.FontFace = font
	textLabel.TextSize = TEXT_SIZE
	textLabel.TextColor3 = color
	textLabel.TextXAlignment = alignment
	textLabel.Text = text
	textLabel.Parent = parent
	return textLabel
end

local function group(title: string, hint: string?): Frame
	local frame = Instance.new("Frame")
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromScale(1, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.LayoutOrder = nextOrder()
	frame.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = frame

	local heading = Instance.new("Frame")
	heading.BackgroundTransparency = 1
	heading.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	heading.LayoutOrder = nextOrder()
	heading.Parent = frame
	label(heading, title, FONT_HEADING, COLORS.Text, Enum.TextXAlignment.Left)
	if hint then
		label(heading, hint, FONT, COLORS.TextSecondary, Enum.TextXAlignment.Right)
	end

	return frame
end

local function row(parent: Frame, name: string): TextLabel
	local frame = Instance.new("Frame")
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	frame.LayoutOrder = nextOrder()
	frame.Parent = parent

	label(frame, name, FONT, COLORS.TextSecondary, Enum.TextXAlignment.Left)
	return label(frame, "–", FONT_VALUE, COLORS.Text, Enum.TextXAlignment.Right)
end

local clientGroup = group("Client", "F2 to hide")
local fpsValue = row(clientGroup, "FPS")
local frameValue = row(clientGroup, "Frame avg / worst")
local pingValue = row(clientGroup, "Ping")
local memoryValue = row(clientGroup, "Memory")
local shotsValue = row(clientGroup, "Shots")
local visibleValue = row(clientGroup, "Bullets in view")

local serverGroup = group("Server caster")
local serverFpsValue = row(serverGroup, "FPS")
local bulletsValue = row(serverGroup, "Bullets")
local castsValue = row(serverGroup, "Casts")
local hitsValue = row(serverGroup, "Hits")
local stepValue = row(serverGroup, "Step avg / worst")
local actorValue = row(serverGroup, "Actor load busiest / avg")

gui.Parent = player:WaitForChild("PlayerGui")

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == TOGGLE_KEY then
		panel.Visible = not panel.Visible
	end
end)

--------------
-- Readouts --
--------------

-- Higher is worse when warnAt < dangerAt (times); lower is worse otherwise (FPS)
local function severity(value: number, warnAt: number, dangerAt: number): Color3
	local worse = if warnAt < dangerAt then value >= dangerAt else value <= dangerAt
	local bad = if warnAt < dangerAt then value >= warnAt else value <= warnAt
	return if worse then COLORS.Danger elseif bad then COLORS.Warning else COLORS.Text
end

local function attribute(name: string): number?
	local value = statsFolder:GetAttribute(name)
	return if typeof(value) == "number" then value else nil
end

local function countBullets(): number
	local folder = workspace:FindFirstChild("BulletsFolder")
	if not folder then
		return 0
	end
	local count = 0
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") and child.Name ~= "BulletRoot" then
			count += 1
		end
	end
	return count
end

local frames = 0
local elapsed = 0
local worstFrame = 0
local lastShots = 0

local function refresh()
	local fps = frames / elapsed
	local averageMs = elapsed / frames * 1000
	local worstMs = worstFrame * 1000

	fpsValue.Text = string.format("%d", math.round(fps))
	fpsValue.TextColor3 = severity(fps, 55, 30)
	frameValue.Text = string.format("%.1f / %.1f ms", averageMs, worstMs)
	frameValue.TextColor3 = severity(worstMs, 33, 100)

	local pingMs = player:GetNetworkPing() * 1000
	pingValue.Text = string.format("%d ms", math.round(pingMs))
	pingValue.TextColor3 = severity(pingMs, 150, 300)

	memoryValue.Text = string.format("%d MB", math.round(Stats:GetTotalMemoryUsageMb()))

	local shots = player:GetAttribute("EnaltCastShots")
	local shotCount = if typeof(shots) == "number" then shots else 0
	shotsValue.Text = string.format("%d /s", math.round((shotCount - lastShots) / elapsed))
	lastShots = shotCount

	visibleValue.Text = tostring(countBullets())

	-- Server: "–" until the first publish arrives
	local serverFps = attribute("ServerFps")
	serverFpsValue.Text = if serverFps then string.format("%d", math.round(serverFps)) else "–"
	serverFpsValue.TextColor3 = if serverFps then severity(serverFps, 55, 30) else COLORS.Text

	local bullets = attribute("Bullets")
	bulletsValue.Text = if bullets then tostring(bullets) else "–"

	local casts = attribute("CastsPerSecond")
	castsValue.Text = if casts then string.format("%d /s", math.round(casts)) else "–"

	local hits = attribute("HitsPerSecond")
	hitsValue.Text = if hits then string.format("%d /s", math.round(hits)) else "–"

	local stepMs, stepWorstMs = attribute("StepMs"), attribute("StepWorstMs")
	stepValue.Text = if stepMs and stepWorstMs then string.format("%.2f / %.2f ms", stepMs, stepWorstMs) else "–"
	stepValue.TextColor3 = if stepWorstMs then severity(stepWorstMs, 4, 10) else COLORS.Text

	local busiest, average = attribute("ActorBusiest"), attribute("ActorAverage")
	actorValue.Text = if busiest and average then string.format("%d / %.1f", busiest, average) else "–"
end

RunService.PreRender:Connect(function(deltaTime: number)
	frames += 1
	elapsed += deltaTime
	worstFrame = math.max(worstFrame, deltaTime)

	if elapsed >= REFRESH then
		refresh()
		frames, elapsed, worstFrame = 0, 0, 0
	end
end)
