-- TAKEN FROM FAST CAST
local Debris = game:GetService("Debris")

local Visualiser = {}

function Visualiser.VisualiseSegment(startCFrame: CFrame, length: number): ConeHandleAdornment
	local adornment = Instance.new("ConeHandleAdornment")
	adornment.Adornee = workspace.Terrain
	adornment.CFrame = startCFrame
	adornment.Height = length
	adornment.Color3 = Color3.new()
	adornment.Radius = 0.25
	adornment.Transparency = 0.5
	adornment.Parent = workspace

	Debris:AddItem(adornment, 3)
	return adornment
end

function Visualiser.VisualiseHit(hit: CFrame): SphereHandleAdornment
	local adornment = Instance.new("SphereHandleAdornment")
	adornment.Adornee = workspace.Terrain
	adornment.CFrame = hit
	adornment.Radius = 0.4
	adornment.Transparency = 0.25
	adornment.Color3 = Color3.new(0.2, 1, 0.5)
	adornment.Parent = workspace

	Debris:AddItem(adornment, 5)
	return adornment
end

return Visualiser
