--!strict
--!optimize 2
-- AlternativeFent
-- A simple cache system for parts to optimize the costs of Instance.new() and :Clone() by already pooling pre existing parts

local FAR_CFRAME = CFrame.new(0, 1e6, 0)

local PoolFolder = workspace:FindFirstChild("PoolFolder")
if not PoolFolder then
	local folder = Instance.new("Folder")
	folder.Name = "PoolFolder"
	folder.Parent = workspace
	PoolFolder = folder
end
assert(PoolFolder)

local Pooler = {}
Pooler.__index = Pooler

export type Pooler = typeof(setmetatable({} :: {
	Pool: { BasePart },
	InUse: { [BasePart]: true },
	ExpansionSize: number,
	Parent: Instance,
	Template: BasePart,
}, Pooler))

function Pooler.new(template: BasePart, amount: number?, parent: Instance?): Pooler
	local self = setmetatable({
		Pool = {},
		InUse = {},
		ExpansionSize = amount or 100,
		Parent = parent or PoolFolder,
		Template = template,
	}, Pooler)

	self:Expand()
	return self
end

function Pooler.Pull(self: Pooler): BasePart
	if #self.Pool == 0 then
		self:Expand()
	end

	local part = self.Pool[#self.Pool]
	self.Pool[#self.Pool] = nil
	self.InUse[part] = true

	return part
end

function Pooler.Return(self: Pooler, part: BasePart)
	if not self.InUse[part] then
		warn("Attempted to return a part that's not in use: " .. part.Name)
		return
	end

	self.InUse[part] = nil
	part.Anchored = true
	part.CFrame = FAR_CFRAME
	self.Pool[#self.Pool + 1] = part
end

function Pooler.Expand(self: Pooler)
	local parts = table.create(self.ExpansionSize)
	local cframes = table.create(self.ExpansionSize, FAR_CFRAME)

	for i = 1, self.ExpansionSize do
		local part = self:_MakeNewPart()
		parts[i] = part
		self.Pool[#self.Pool + 1] = part
	end

	workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end

function Pooler.Destroy(self: Pooler)
	for _, part in self.Pool do
		part:Destroy()
	end
	for part in self.InUse do
		part:Destroy()
	end
	table.clear(self.Pool)
	table.clear(self.InUse)
end

-- // PRIVATE

function Pooler._MakeNewPart(self: Pooler): BasePart
	local part = self.Template:Clone()
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Parent = self.Parent

	return part
end

return Pooler