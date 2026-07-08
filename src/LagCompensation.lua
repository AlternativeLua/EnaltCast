--!strict
--!optimize 2

-- Server-side hitbox rewind. Records a short ring buffer of tracked characters'
-- part CFrames and tests casts against those historical positions, so a moving
-- target registers where the shooter saw it rather than where it is now. Done
-- geometrically (ray vs box) so live physics parts are never moved; the hit
-- still carries the real BasePart, so humanoid/zone handling is unchanged.
-- Server-only; every method is an inert fallback on the client.

local RunService = game:GetService("RunService")

local Settings = require(script.Parent.Settings)

local IS_SERVER = RunService:IsServer()
local EPSILON = 1e-6

type Snapshot = {
    Time: number,
    Poses: { [BasePart]: CFrame },
}

local LagCompensation = {}

local Tracked: { [Model]: true } = {}
local History: { Snapshot } = {}
local Connection: RBXScriptConnection? = nil

local WorldParams = RaycastParams.new()

-- Only queryable parts (a live raycast could hit them); accessories are CanQuery = false
local function collectParts(model: Model, into: { [BasePart]: CFrame })
    for _, child in model:GetChildren() do
        if child:IsA("BasePart") and child.CanQuery then
            into[child] = child.CFrame
        end
    end
end

local function record()
    local now = workspace:GetServerTimeNow()

    local poses: { [BasePart]: CFrame } = {}
    for model in Tracked do
        if model.Parent then
            collectParts(model, poses)
        end
    end

    table.insert(History, { Time = now, Poses = poses })

    local cutoff = now - Settings.LagCompensationHistory
    local removeCount = 0
    for i = 1, #History do
        if History[i].Time >= cutoff then break end
        removeCount += 1
    end
    for _ = 1, removeCount do
        table.remove(History, 1)
    end
end

-- Interpolated pose of a part at time t; live once t reaches the latest snapshot
local function poseAt(part: BasePart, t: number): CFrame?
    local count = #History
    if count == 0 then return part.CFrame end

    local newest = History[count]
    if t >= newest.Time then
        return part.CFrame
    end

    local oldest = History[1]
    if t <= oldest.Time then
        return oldest.Poses[part]
    end

    for i = count - 1, 1, -1 do
        local older = History[i]
        if older.Time <= t then
            local newer = History[i + 1]
            local a = older.Poses[part]
            local b = newer.Poses[part]
            if a and b then
                local span = newer.Time - older.Time
                local alpha = if span > EPSILON then (t - older.Time) / span else 0
                return a:Lerp(b, alpha)
            end
            return a or b
        end
    end

    return part.CFrame
end

-- Ray vs oriented box; returns the near hit as a fraction of direction (valid in [0, 1])
local function rayOBB(origin: Vector3, direction: Vector3, cframe: CFrame, size: Vector3): (number?, Vector3?)
    local localOrigin = cframe:PointToObjectSpace(origin)
    local localDir = cframe:VectorToObjectSpace(direction)

    local half = size * 0.5

    local o = { localOrigin.X, localOrigin.Y, localOrigin.Z }
    local d = { localDir.X, localDir.Y, localDir.Z }
    local h = { half.X, half.Y, half.Z }

    local tMin = 0
    local tMax = 1
    local hitAxis = 1
    local hitSign = 1

    for axis = 1, 3 do
        if math.abs(d[axis]) < EPSILON then
            if o[axis] < -h[axis] or o[axis] > h[axis] then
                return nil, nil
            end
        else
            local inv = 1 / d[axis]
            local t1 = (-h[axis] - o[axis]) * inv
            local t2 = (h[axis] - o[axis]) * inv
            local sign = -1
            if t1 > t2 then
                t1, t2 = t2, t1
                sign = 1
            end
            if t1 > tMin then
                tMin = t1
                hitAxis = axis
                hitSign = sign
            end
            if t2 < tMax then
                tMax = t2
            end
            if tMin > tMax then
                return nil, nil
            end
        end
    end

    local localNormal
    if hitAxis == 1 then
        localNormal = Vector3.new(hitSign, 0, 0)
    elseif hitAxis == 2 then
        localNormal = Vector3.new(0, hitSign, 0)
    else
        localNormal = Vector3.new(0, 0, hitSign)
    end

    return tMin, cframe:VectorToWorldSpace(localNormal)
end

-- Starts tracking a character/rig so it can be rewound. No-op on the client.
function LagCompensation.Register(model: Model)
    if not IS_SERVER then return end
    if Tracked[model] then return end
    Tracked[model] = true

    if not Connection then
        Connection = RunService.Heartbeat:Connect(record)
    end
end

-- Stops tracking a character/rig. Safe to call more than once.
function LagCompensation.Unregister(model: Model)
    if not IS_SERVER then return end
    Tracked[model] = nil

    if next(Tracked) == nil and Connection then
        Connection:Disconnect()
        Connection = nil
        table.clear(History)
    end
end

-- Casts world geometry live (tracked characters excluded) and tests tracked
-- characters at evalTime, returning whichever is nearer. Falls back to a plain
-- raycast on the client or when nothing is tracked.
function LagCompensation.Raycast(
    origin: Vector3,
    direction: Vector3,
    params: RaycastParams,
    ignoreList: { Instance },
    evalTime: number
): RaycastResult?
    if not IS_SERVER or next(Tracked) == nil then
        return workspace:Raycast(origin, direction, params)
    end

    local maxLen = direction.Magnitude
    if maxLen < EPSILON then return nil end

    -- World pass excludes tracked characters so their live positions don't shadow the rewound ones
    local worldIgnore = table.clone(ignoreList)
    for model in Tracked do
        table.insert(worldIgnore, model)
    end

    WorldParams.FilterType = Enum.RaycastFilterType.Exclude
    WorldParams.IgnoreWater = params.IgnoreWater
    WorldParams.RespectCanCollide = params.RespectCanCollide
    WorldParams.CollisionGroup = params.CollisionGroup
    WorldParams.FilterDescendantsInstances = worldIgnore

    local best = workspace:Raycast(origin, direction, WorldParams)
    local bestT = if best then best.Distance / maxLen else 1

    local ignoreSet: { [Instance]: true } = {}
    for _, inst in ignoreList do
        ignoreSet[inst] = true
    end

    for model in Tracked do
        if ignoreSet[model] then continue end

        for _, part in model:GetChildren() do
            if not part:IsA("BasePart") or not part.CanQuery then continue end

            local cframe = poseAt(part, evalTime)
            if not cframe then continue end

            local t, normal = rayOBB(origin, direction, cframe, part.Size)
            if t and t < bestT and normal then
                bestT = t
                best = {
                    Instance = part,
                    Position = origin + direction * t,
                    Normal = normal,
                    Distance = maxLen * t,
                    Material = part.Material,
                } :: any
            end
        end
    end

    return best
end

return LagCompensation
