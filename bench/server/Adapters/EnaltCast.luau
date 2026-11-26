local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(script.Parent.Types)
local EnaltCast = require(ReplicatedStorage.Packages.EnaltCast)

return function(parallel: boolean): Types.Adapter
	local caster
	local config

	local adapter = {}

	function adapter.Setup(scenario: Types.Scenario)
		caster = EnaltCast.new({ ParallelProcessing = parallel, LagCompensation = false })
		config = {
			Speed = scenario.Speed,
			ExtraForce = scenario.Gravity,
			RayParams = scenario.Params,
			Lifetime = scenario.Lifetime,
			Attributes = {},
			OnImpact = caster:NewSignal(),
		}
	end

	function adapter.Fire(origin: Vector3, direction: Vector3)
		caster:Cast(config, origin, direction)
	end

	function adapter.Active(): number
		local stats = caster:GetStats()
		return stats.ActiveBullets + stats.ActorBullets
	end

	function adapter.Teardown()
		caster:Destroy()
		caster = nil
	end

	return adapter
end
