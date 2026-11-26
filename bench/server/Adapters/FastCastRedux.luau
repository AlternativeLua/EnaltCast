local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(script.Parent.Types)
local FastCast = require(ReplicatedStorage.DevPackages.FastCastRedux) :: any

return function(): Types.Adapter
	local caster
	local behavior
	local speed = 0
	local active: { [any]: true } = {}
	local count = 0

	local adapter = {}

	function adapter.Setup(scenario: Types.Scenario)
		caster = FastCast.new()
		behavior = FastCast.newBehavior()
		behavior.RaycastParams = scenario.Params
		behavior.Acceleration = scenario.Gravity
		behavior.MaxDistance = scenario.MaxDistance
		speed = scenario.Speed

		caster.CastTerminating:Connect(function(cast)
			if active[cast] then
				active[cast] = nil
				count -= 1
			end
		end)
	end

	function adapter.Fire(origin: Vector3, direction: Vector3)
		local cast = caster:Fire(origin, direction, speed, behavior)
		if cast and not active[cast] then
			active[cast] = true
			count += 1
		end
	end

	function adapter.Active(): number
		return count
	end

	function adapter.Teardown()
		local remaining = {}
		for cast in active do
			table.insert(remaining, cast)
		end
		for _, cast in remaining do
			if active[cast] then
				pcall(cast.Terminate, cast)
			end
		end
		table.clear(active)
		count = 0
		caster = nil
	end

	return adapter
end
