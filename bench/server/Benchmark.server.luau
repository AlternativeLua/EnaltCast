--!strict

local RunService = game:GetService("RunService")

local Types = require(script.Parent.Adapters.Types)
local Adapters = script.Parent.Adapters

local CONFIG = {
	Loads = { 250, 500, 1000, 2000, 4000, 8000, 16000 },
	-- Full load sweeps per library; every cell in the report is the mean across runs.
	Runs = 3,
	-- Minimum warmup per load. Raised to the scenario's FlightTime so the active count is saturated before measuring.
	Warmup = 1.5,
	Measure = 2.5,
	Cooldown = 2,
	TargetFps = 55,
	StopBelowFps = 30,
	Speed = 300,
	-- Run N uses Seed + N - 1; every library in the same run gets identical shots.
	Seed = 1,
	StartDelay = 3,
	BaselineSeconds = 5,
	-- Optional filters, e.g. { "Open air" } or { "EnaltCast", "SwiftCast" }. nil runs everything.
	OnlyScenarios = nil :: { string }?,
	OnlyEntries = nil :: { string }?,
}

type Entry = { Name: string, Create: () -> Types.Adapter }

local ENTRIES: { Entry } = {
	{ Name = "EnaltCast", Create = function() return (require(Adapters.EnaltCast) :: any)(false) end },
	{ Name = "EnaltCast parallel", Create = function() return (require(Adapters.EnaltCast) :: any)(true) end },
	{ Name = "SwiftCast", Create = function() return (require(Adapters.SwiftCast) :: any)() end },
}

local function params(): RaycastParams
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.FilterDescendantsInstances = {}
	return p
end

type ScenarioSpec = Types.Scenario & {
	-- Approximate seconds a bullet stays alive; sets the fire rate so `load` is roughly the active count.
	FlightTime: number,
	Aim: (rng: Random) -> (Vector3, Vector3),
	-- Optional world setup for the scenario; returns a cleanup function.
	World: (() -> () -> ())?,
}

local function upwardAim(rng: Random)
	local origin = Vector3.new(rng:NextNumber(-50, 50), rng:NextNumber(5, 15), rng:NextNumber(-10, 10))
	local direction = Vector3.new(rng:NextNumber(-0.3, 0.3), 1, rng:NextNumber(0, 0.5)).Unit
	return origin, direction
end

local function wallAim(rng: Random)
	local origin = Vector3.new(rng:NextNumber(-50, 50), rng:NextNumber(20, 60), rng:NextNumber(-10, 10))
	local direction = Vector3.new(rng:NextNumber(-0.2, 0.2), rng:NextNumber(-0.05, 0.1), -1).Unit
	return origin, direction
end

-- 324 anchored 4-stud cubes between the firing line and the wall; roughly half of wallAim shots hit one.
local function clutterField(): () -> ()
	local folder = Instance.new("Folder")
	folder.Name = "BenchClutter"
	for x = -60, 60, 15 do
		for y = 15, 70, 11 do
			for z = -30, -130, -20 do
				local part = Instance.new("Part")
				part.Anchored = true
				part.Size = Vector3.new(4, 4, 4)
				part.Position = Vector3.new(x, y, z)
				part.Parent = folder
			end
		end
	end
	folder.Parent = workspace
	return function()
		folder:Destroy()
	end
end

local SCENARIOS: { ScenarioSpec } = {
	{
		Name = "Open air",
		Speed = CONFIG.Speed,
		Gravity = Vector3.zero,
		Lifetime = 2,
		MaxDistance = CONFIG.Speed * 2,
		FlightTime = 2,
		Params = params(),
		Aim = upwardAim,
	},
	{
		Name = "Impacts",
		Speed = CONFIG.Speed,
		Gravity = Vector3.new(0, -workspace.Gravity / 5, 0),
		Lifetime = 5,
		MaxDistance = CONFIG.Speed * 5,
		FlightTime = 150 / CONFIG.Speed,
		Params = params(),
		Aim = wallAim,
	},
	{
		-- Full gravity lobs that arc up and land on the baseplate.
		Name = "Gravity arcs",
		Speed = 150,
		Gravity = Vector3.new(0, -workspace.Gravity, 0),
		Lifetime = 4,
		MaxDistance = 600,
		FlightTime = 1.15,
		Params = params(),
		Aim = function(rng: Random)
			local origin = Vector3.new(rng:NextNumber(-50, 50), rng:NextNumber(5, 15), rng:NextNumber(-10, 10))
			local direction = Vector3.new(rng:NextNumber(-0.3, 0.3), 1, rng:NextNumber(0.8, 1.2)).Unit
			return origin, direction
		end,
	},
	{
		-- Mixed early and late hits against dense geometry.
		Name = "Cluttered",
		Speed = CONFIG.Speed,
		Gravity = Vector3.new(0, -workspace.Gravity / 5, 0),
		Lifetime = 5,
		MaxDistance = CONFIG.Speed * 5,
		FlightTime = 0.4,
		Params = params(),
		Aim = wallAim,
		World = clutterField,
	},
	{
		-- Very fast, short-lived shots: dominated by per-cast spawn and cleanup cost.
		Name = "Short range burst",
		Speed = 1500,
		Gravity = Vector3.zero,
		Lifetime = 0.25,
		MaxDistance = 1500 * 0.25,
		FlightTime = 0.25,
		Params = params(),
		Aim = upwardAim,
	},
	{
		-- Slow, long-lived shots: dominated by per-bullet step cost with a low spawn rate.
		Name = "Slow long-lived",
		Speed = 60,
		Gravity = Vector3.zero,
		Lifetime = 4,
		MaxDistance = 60 * 4,
		FlightTime = 4,
		Params = params(),
		Aim = upwardAim,
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

type Summary = {
	Count: number,
	Active: number,
	Fps: number,
	LowFps: number,
	WorkMs: number,
	WorkSd: number,
}

local function allowed(name: string, names: { string }?): boolean
	return names == nil or table.find(names, name) ~= nil
end

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

local function runLoad(adapter: Types.Adapter, scenario: ScenarioSpec, load: number, seed: number, baselineMs: number): Sample
	local rng = Random.new(seed)
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

	measure(math.max(CONFIG.Warmup, scenario.FlightTime), fire)
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

-- One full load sweep for one library. Returns samples indexed like CONFIG.Loads, or nil if the library could not start.
local function runSweep(entry: Entry, scenario: ScenarioSpec, run: number, baselineMs: number): { Sample }?
	local ok, adapter = pcall(entry.Create)
	if not ok then
		warn(`[Bench] {entry.Name} skipped: {adapter}`)
		return nil
	end

	local setupOk, setupError = pcall(adapter.Setup, scenario)
	if not setupOk then
		warn(`[Bench] {entry.Name} skipped: {setupError}`)
		return nil
	end

	local samples: { Sample } = {}
	local seed = CONFIG.Seed + run - 1

	for _, load in CONFIG.Loads do
		local runOk, sample = pcall(runLoad, adapter, scenario, load, seed, baselineMs)
		if not runOk then
			warn(`[Bench] {entry.Name} failed at {load}: {sample}`)
			break
		end
		table.insert(samples, sample)
		print(string.format(
			"[Bench] %s | run %d/%d | %s | load %d (active %d): %.0f FPS, 1%% low %.0f, %.2f ms",
			scenario.Name, run, CONFIG.Runs, entry.Name, load, sample.Active, sample.Fps, sample.LowFps, sample.WorkMs
		))
		if sample.Fps < CONFIG.StopBelowFps then
			break
		end
	end

	drain(adapter)
	pcall(adapter.Teardown)
	task.wait(CONFIG.Cooldown)

	return samples
end

local function summarize(samples: { Sample }): Summary?
	local count = #samples
	if count == 0 then
		return nil
	end

	local active, fps, lowFps, work = 0, 0, 0, 0
	for _, s in samples do
		active += s.Active
		fps += s.Fps
		lowFps += s.LowFps
		work += s.WorkMs
	end
	work /= count

	local variance = 0
	for _, s in samples do
		variance += (s.WorkMs - work) ^ 2
	end

	return {
		Count = count,
		Active = active / count,
		Fps = fps / count,
		LowFps = lowFps / count,
		WorkMs = work,
		WorkSd = if count > 1 then math.sqrt(variance / (count - 1)) else 0,
	}
end

local function formatTable(scenario: ScenarioSpec, results: { [string]: { { Sample } } }): string
	local lines = {}
	local header = "| Load |"
	local divider = "|---:|"
	for _, entry in ENTRIES do
		if results[entry.Name] then
			header ..= ` {entry.Name} |`
			divider ..= "---:|"
		end
	end
	table.insert(lines, `### {scenario.Name}`)
	table.insert(lines, `Mean of {CONFIG.Runs} runs. Cell: avg FPS / 1% low FPS / main-thread ms per frame ± std dev`)
	table.insert(lines, "")
	table.insert(lines, header)
	table.insert(lines, divider)

	local partial = false
	for index, load in CONFIG.Loads do
		local row = `| {load} |`
		local any = false
		for _, entry in ENTRIES do
			local byLoad = results[entry.Name]
			if byLoad then
				local s = summarize(byLoad[index])
				if s then
					any = true
					local marker = ""
					if s.Count < CONFIG.Runs then
						marker = ` ({s.Count}/{CONFIG.Runs})`
						partial = true
					end
					row ..= string.format(" %.0f / %.0f / %.2f ± %.2f%s |", s.Fps, s.LowFps, s.WorkMs, s.WorkSd, marker)
				else
					row ..= " – |"
				end
			end
		end
		if any then
			table.insert(lines, row)
		end
	end

	if partial then
		table.insert(lines, "")
		table.insert(lines, "(n/N): only n of N runs reached this load before dropping below the stop threshold.")
	end

	table.insert(lines, "")
	table.insert(lines, `Highest load held at ≥ {CONFIG.TargetFps} avg FPS across all runs:`)
	for _, entry in ENTRIES do
		local byLoad = results[entry.Name]
		if byLoad then
			local best = 0
			for index, load in CONFIG.Loads do
				local s = summarize(byLoad[index])
				if s and s.Count == CONFIG.Runs and s.Fps >= CONFIG.TargetFps then
					best = math.max(best, load)
				end
			end
			table.insert(lines, `- {entry.Name}: {if best > 0 then tostring(best) else "below lowest load"}`)
		end
	end

	return table.concat(lines, "\n")
end

task.wait(CONFIG.StartDelay)

local entries: { Entry } = {}
for _, entry in ENTRIES do
	if allowed(entry.Name, CONFIG.OnlyEntries) then
		table.insert(entries, entry)
	end
end

print(`[Bench] measuring idle baseline ({CONFIG.BaselineSeconds}s)`)
local _, _, baselineMs = measure(CONFIG.BaselineSeconds)
print(string.format("[Bench] baseline main-thread work %.2f ms per frame", baselineMs))

local report = {}

for _, scenario in SCENARIOS do
	if not allowed(scenario.Name, CONFIG.OnlyScenarios) then
		continue
	end

	local cleanupWorld = if scenario.World then scenario.World() else nil
	local results: { [string]: { { Sample } } } = {}
	local disabled: { [string]: boolean } = {}

	for run = 1, CONFIG.Runs do
		print(`[Bench] {scenario.Name} | run {run}/{CONFIG.Runs}`)

		-- Rotate the order each run so no library always goes first (or last, on a warmer server).
		for offset = 0, #entries - 1 do
			local entry = entries[(offset + run - 1) % #entries + 1]
			if disabled[entry.Name] then
				continue
			end

			local samples = runSweep(entry, scenario, run, baselineMs)
			if not samples then
				disabled[entry.Name] = true
				continue
			end

			local byLoad = results[entry.Name]
			if not byLoad then
				byLoad = {}
				for index in CONFIG.Loads do
					byLoad[index] = {}
				end
				results[entry.Name] = byLoad
			end
			for index, sample in samples do
				table.insert(byLoad[index], sample)
			end
		end
	end

	if cleanupWorld then
		cleanupWorld()
	end

	local section = formatTable(scenario, results)
	print(`[Bench] {scenario.Name} done\n\n{section}`)
	table.insert(report, section)
end

print("[Bench] results\n\n" .. table.concat(report, "\n\n"))
