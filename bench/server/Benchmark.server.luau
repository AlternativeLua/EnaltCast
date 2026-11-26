--!strict

local RunService = game:GetService("RunService")

local Types = require(script.Parent.Adapters.Types)
local Adapters = script.Parent.Adapters

local CONFIG = {
	Loads = { 250, 500, 1000, 2000, 4000, 8000, 16000 },
	Warmup = 2,
	Measure = 3,
	Cooldown = 2,
	TargetFps = 55,
	StopBelowFps = 30,
	Speed = 300,
	Seed = 1,
	StartDelay = 3,
}

type Entry = { Name: string, Create: () -> Types.Adapter }

local ENTRIES: { Entry } = {
	{ Name = "EnaltCast", Create = function() return (require(Adapters.EnaltCast) :: any)(false) end },
	{ Name = "EnaltCast parallel", Create = function() return (require(Adapters.EnaltCast) :: any)(true) end },
	{ Name = "FastCast Redux", Create = function() return (require(Adapters.FastCastRedux) :: any)() end },
	{ Name = "FastCast2", Create = function() return (require(Adapters.FastCast2) :: any)() end },
	{ Name = "SwiftCast", Create = function() return (require(Adapters.SwiftCast) :: any)() end },
}

local function params(): RaycastParams
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.FilterDescendantsInstances = {}
	return p
end

type ScenarioSpec = Types.Scenario & {
	FlightTime: number,
	Aim: (rng: Random) -> (Vector3, Vector3),
}

local SCENARIOS: { ScenarioSpec } = {
	{
		Name = "Open air",
		Speed = CONFIG.Speed,
		Gravity = Vector3.zero,
		Lifetime = 2,
		MaxDistance = CONFIG.Speed * 2,
		FlightTime = 2,
		Params = params(),
		Aim = function(rng: Random)
			local origin = Vector3.new(rng:NextNumber(-50, 50), rng:NextNumber(5, 15), rng:NextNumber(-10, 10))
			local direction = Vector3.new(rng:NextNumber(-0.3, 0.3), 1, rng:NextNumber(0, 0.5)).Unit
			return origin, direction
		end,
	},
	{
		Name = "Impacts",
		Speed = CONFIG.Speed,
		Gravity = Vector3.new(0, -workspace.Gravity / 5, 0),
		Lifetime = 5,
		MaxDistance = CONFIG.Speed * 5,
		FlightTime = 150 / CONFIG.Speed,
		Params = params(),
		Aim = function(rng: Random)
			local origin = Vector3.new(rng:NextNumber(-50, 50), rng:NextNumber(20, 60), rng:NextNumber(-10, 10))
			local direction = Vector3.new(rng:NextNumber(-0.2, 0.2), rng:NextNumber(-0.05, 0.1), -1).Unit
			return origin, direction
		end,
	},
}

local frameStart = os.clock()
local lastWork = 0
RunService.PreSimulation:Connect(function()
	frameStart = os.clock()
end)
RunService.PostSimulation:Connect(function()
	local started = frameStart
	task.defer(function()
		lastWork = os.clock() - started
	end)
end)

type Sample = {
	Load: number,
	Active: number,
	Fps: number,
	LowFps: number,
	WorkMs: number,
}

local function measure(seconds: number, onFrame: ((dt: number) -> ())?, active: (() -> number)?): (number, number, number, number)
	local deltas: { number } = {}
	local work = 0
	local activeTotal = 0
	local elapsed = 0
	local done = false

	local connection = RunService.Heartbeat:Connect(function(dt: number)
		if done then
			return
		end
		if onFrame then
			onFrame(dt)
		end
		table.insert(deltas, dt)
		work += lastWork
		if active then
			activeTotal += active()
		end
		elapsed += dt
		if elapsed >= seconds then
			done = true
		end
	end)

	while not done do
		RunService.Heartbeat:Wait()
	end
	connection:Disconnect()

	local frames = #deltas
	table.sort(deltas, function(a, b)
		return a > b
	end)
	local worstCount = math.max(1, frames // 100)
	local worst = 0
	for i = 1, worstCount do
		worst += deltas[i]
	end

	return frames / elapsed, worstCount / worst, work / frames * 1000, activeTotal / frames
end

local function runLoad(adapter: Types.Adapter, scenario: ScenarioSpec, load: number, baselineMs: number): Sample
	local rng = Random.new(CONFIG.Seed)
	local rate = load / scenario.FlightTime
	local owed = 0

	local function fire(dt: number)
		owed += rate * dt
		while owed >= 1 do
			owed -= 1
			local origin, direction = scenario.Aim(rng)
			adapter.Fire(origin, direction)
		end
	end

	measure(CONFIG.Warmup, fire)
	local fps, lowFps, workMs, active = measure(CONFIG.Measure, fire, adapter.Active)

	return {
		Load = load,
		Active = math.round(active),
		Fps = fps,
		LowFps = lowFps,
		WorkMs = math.max(workMs - baselineMs, 0),
	}
end

local function drain(adapter: Types.Adapter)
	local deadline = os.clock() + 10
	while adapter.Active() > 0 and os.clock() < deadline do
		RunService.Heartbeat:Wait()
	end
end

local function formatTable(scenario: ScenarioSpec, results: { [string]: { Sample } }): string
	local lines = {}
	local header = "| Load |"
	local divider = "|---:|"
	for _, entry in ENTRIES do
		if results[entry.Name] then
			header ..= ` {entry.Name} |`
			divider ..= "---:|"
		end
	end
	table.insert(lines, `### {scenario.Name}  (cell: avg FPS / 1% low FPS / main-thread ms per frame)`)
	table.insert(lines, header)
	table.insert(lines, divider)

	for index, load in CONFIG.Loads do
		local row = `| {load} |`
		local any = false
		for _, entry in ENTRIES do
			local samples = results[entry.Name]
			if samples then
				local s = samples[index]
				if s then
					any = true
					row ..= string.format(" %.0f / %.0f / %.2f |", s.Fps, s.LowFps, s.WorkMs)
				else
					row ..= " – |"
				end
			end
		end
		if any then
			table.insert(lines, row)
		end
	end

	table.insert(lines, "")
	table.insert(lines, `Highest load held at ≥ {CONFIG.TargetFps} FPS:`)
	for _, entry in ENTRIES do
		local samples = results[entry.Name]
		if samples then
			local best = 0
			for _, s in samples do
				if s.Fps >= CONFIG.TargetFps then
					best = math.max(best, s.Load)
				end
			end
			table.insert(lines, `- {entry.Name}: {if best > 0 then tostring(best) else "below lowest load"}`)
		end
	end

	return table.concat(lines, "\n")
end

task.wait(CONFIG.StartDelay)

print("[Bench] measuring idle baseline")
local _, _, baselineMs = measure(CONFIG.Measure)
print(string.format("[Bench] baseline main-thread work %.2f ms per frame", baselineMs))

local report = {}

for _, scenario in SCENARIOS do
	local results: { [string]: { Sample } } = {}

	for _, entry in ENTRIES do
		local ok, adapter = pcall(entry.Create)
		if not ok then
			warn(`[Bench] {entry.Name} skipped: {adapter}`)
			continue
		end

		local setupOk, setupError = pcall(adapter.Setup, scenario)
		if not setupOk then
			warn(`[Bench] {entry.Name} skipped: {setupError}`)
			continue
		end

		local samples: { Sample } = {}
		results[entry.Name] = samples

		for _, load in CONFIG.Loads do
			local runOk, sample = pcall(runLoad, adapter, scenario, load, baselineMs)
			if not runOk then
				warn(`[Bench] {entry.Name} failed at {load}: {sample}`)
				break
			end
			table.insert(samples, sample)
			print(string.format(
				"[Bench] %s | %s | load %d (active %d): %.0f FPS, 1%% low %.0f, %.2f ms",
				scenario.Name, entry.Name, load, sample.Active, sample.Fps, sample.LowFps, sample.WorkMs
			))
			if sample.Fps < CONFIG.StopBelowFps then
				break
			end
		end

		drain(adapter)
		pcall(adapter.Teardown)
		task.wait(CONFIG.Cooldown)
	end

	table.insert(report, formatTable(scenario, results))
end

print("[Bench] results\n\n" .. table.concat(report, "\n\n"))
