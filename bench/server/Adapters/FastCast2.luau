local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(script.Parent.Types)
local FastCast2 = require(ReplicatedStorage.DevPackages.FastCast2) :: any

return function(): Types.Adapter
	local caster
	local behavior
	local speed = 0
	local count = 0

	local adapter = {}

	function adapter.Setup(scenario: Types.Scenario)
		FastCast2.Init()
		caster = FastCast2.new()
		behavior = FastCast2.newBehavior()
		behavior.RaycastParams = scenario.Params
		behavior.Acceleration = scenario.Gravity
		behavior.MaxDistance = scenario.MaxDistance
		behavior.MaxLifetime = scenario.Lifetime
		speed = scenario.Speed

		caster.CastTerminating:Connect(function()
			count -= 1
		end)
	end

	function adapter.Fire(origin: Vector3, direction: Vector3)
		caster:RaycastFire(origin, direction.Unit, speed, behavior)
		count += 1
	end

	function adapter.Active(): number
		return math.max(count, 0)
	end

	function adapter.Teardown()
		caster:Destroy()
		caster = nil
		count = 0
		FastCast2.Stop()
	end

	return adapter
end
