export type Scenario = {
	Name: string,
	Speed: number,
	Gravity: Vector3,
	Lifetime: number,
	MaxDistance: number,
	Params: RaycastParams,
}

export type Adapter = {
	Setup: (scenario: Scenario) -> (),
	Fire: (origin: Vector3, direction: Vector3) -> (),
	Active: () -> number,
	Teardown: () -> (),
}

return {}
