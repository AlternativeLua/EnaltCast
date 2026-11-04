return {
	SurfaceHardness = {
		Default = 10,
		[Enum.Material.Plastic] = 10,
	}, 

	Visualise = true, --> basically debug
	SafeMode = false, --> if to let the server handle the bullet replication or not
	ParallelProcessing = false, --> if should use multiple threads or not

	LagCompensation = true, --> server-side hitbox rewind (single-threaded path only; opt in per cast)
	LagCompensationHistory = 1, --> seconds of position history retained for rewinding

	LoadBalanceStrategy = "LeastLoadedActor", --> "RoundRobin", "LeastLoadedActor"
	UpdateRate = 60, --> max physics sub-steps per second (frame-rate independent)
	ActorAmount = 12,
}
