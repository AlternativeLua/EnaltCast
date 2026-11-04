--!strict
--!optimize 2
-- AlternativeFent
-- A simple cache system for parts to optimize the costs of Instance.new() and :Clone() by already pooling pre existsing parts

local PoolFolder
if not workspace:FindFirstChild("PoolFolder") then
    PoolFolder = Instance.new("Folder", workspace)
    PoolFolder.Name = "PoolFolder" 
else
    PoolFolder = workspace:FindFirstChild("PoolFolder")
end

local FAR_CFRAME = CFrame.new(0, 10e8, 0)

local Pooler = {}
Pooler.__index = Pooler

export type Pooler = typeof(setmetatable({ } :: { 
    Pool: {  BasePart },
    InUse: {  BasePart },
    ExpansionSize: number,
    Parent: Instance,
    Template: BasePart
}, Pooler))

function Pooler.new(object: BasePart, ammount: number?, parent: Instance?): Pooler
    local self = setmetatable({
        Pool = {},
        InUse = {},
        ExpansionSize = ammount or 100,
        Parent = parent or PoolFolder,
        Template = object
    }, Pooler)

    print(object)

    for i = 1, self.ExpansionSize do    
        local newPart = Pooler._MakeNewPart(self)
        table.insert(self.Pool, newPart)
    end

    return self
end

function Pooler.Pull(self: Pooler): BasePart
    print(#self.Pool)
    if #self.Pool == 0 then self:Expand() end

    local part = self.Pool[#self.Pool]
    self.Pool[#self.Pool] = nil

    table.insert(self.InUse, part)

    return part
end

function Pooler.Return(self: Pooler, part: BasePart)
    local index = table.find(self.InUse, part)

    if index then
        table.remove(self.InUse, index)
        table.insert(self.Pool, part)

        part.CFrame = FAR_CFRAME
        part.Anchored = true
    else
        warn("Attempted to return a part that's not in use!, " .. part.Name)
    end
end

function Pooler.Destroy(self: Pooler)
    for _, v in self.Pool do v:Destroy() end
    for _, v in self.InUse do v:Destroy() end
    self.Pool = {}
    self.InUse = {}
end

function Pooler.Expand(self: Pooler)
    for i = 1, self.ExpansionSize do
        local newPart = self:_MakeNewPart()
        table.insert(self.Pool, newPart)
    end
end

-- // PRIVATE

function Pooler._MakeNewPart(self: Pooler): BasePart
    local newPart = self.Template:Clone()
    newPart.CFrame = FAR_CFRAME
    newPart.Anchored = true
    newPart.Parent = self.Parent or PoolFolder

    return newPart
end

return Pooler