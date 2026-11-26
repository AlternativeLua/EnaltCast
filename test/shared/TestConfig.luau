--!strict
-- Settings shared by the server and client test scripts, so both sides simulate the same shot.

return {
	-- Draw paths and hits. The client draws the paths; server hits show as larger, fainter shells
	-- around the client's, so any mismatch between server and client hit registration stands out.
	Visualise = true,

	Shot = {
		Speed = 200,
		ExtraForce = Vector3.new(0, -workspace.Gravity / 5, 0),
		Lifetime = 5,
		RichochetAngle = 10,
		RichochetHardness = 9,
		PenetrationPower = 50,
	},
}
