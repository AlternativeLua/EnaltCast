local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(script.Parent.Types)
local SwiftCast = require(ReplicatedStorage.DevPackages.SwiftCast) :: any

return function(): Types.Adapter
	local settings
	local speed = 0
	local gravity = Vector3.zero
	local active: { [any]: true } = {}
	local count = 0

	local function onDestroy(projectile)
		if active[projectile] then
			active[projectile] = nil
			count -= 1
		end
	end

	local adapter = {}

	function adapter.Setup(scenario: Types.Scenario)
		if not SwiftCast.IsRunning() then
			SwiftCast.Start()
		end
		settings = SwiftCast.ProjectileSettings.new({
			MaxFlyTime = scenario.Lifetime,
			MaxFlyDistance = scenario.MaxDistance,
			RaycastParams = scenario.Params,
		})
		speed = scenario.Speed
		gravity = scenario.Gravity
	end

	function adapter.Fire(origin: Vector3, direction: Vector3)
		local projectile = SwiftCast.SpawnProjectile({
			Position = origin,
			Velocity = direction.Unit * speed,
			Acceleration = gravity,
			OnDestroy = onDestroy,
		}, settings)
		if projectile and not active[projectile] then
			active[projectile] = true
			count += 1
		end
	end

	function adapter.Active(): number
		return count
	end

	function adapter.Teardown()
		local remaining = {}
		for projectile in active do
			table.insert(remaining, projectile)
		end
		for _, projectile in remaining do
			if not projectile._Destroyed then
				pcall(SwiftCast.TerminateProjectile, projectile, "Benchmark")
			end
		end
		table.clear(active)
		count = 0
		SwiftCast.Stop()
	end

	return adapter
end
