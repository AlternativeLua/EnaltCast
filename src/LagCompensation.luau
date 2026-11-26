--!strict
--!optimize 2
--!native

-- Server-side hitbox rewind. Records a short ring buffer of tracked characters'
-- part CFrames and tests casts against those historical positions, so a moving
-- target registers where the shooter saw it rather than where it is now. Done
-- geometrically (ray vs box) so live physics parts are never moved; the hit
-- still carries the real BasePart, so humanoid/zone handling is unchanged.
-- Server-only; every method is an inert fallback on the client.

local RunService = game:GetService("RunService")

local Settings = require(script.Parent.Settings)
local Math = require(script.Parent.Math)

local IS_SERVER = RunService:IsServer()
local EPSILON = 1e-6
local RECORD_RATE = 30
local RECORD_INTERVAL = 1 / RECORD_RATE

type Slot = {
    Time: number,
    Poses: { [BasePart]: CFrame },
    Parts: { [Model]: { BasePart } },
    Centers: { [Model]: Vector3 },
    Radii: { [Model]: number },
}

type Filter = {
    Version: number,
    Params: RaycastParams,
    Ignored: { [Instance]: true },
}

local LagCompensation = {}

local Tracked: { [Model]: true } = {}
local TrackedVersion = 0
local Connection: RBXScriptConnection? = nil
local HistoryLength: number = Settings.LagCompensationHistory

local Slots: { Slot } = {}
local Capacity = 0
local Head = 0
local Count = 0

local Frame = 0
local NextRecord = 0
local LiveFrame: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local LiveCenters: { [Model]: Vector3 } = setmetatable({}, { __mode = "k" }) :: any
local LiveRadii: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any

local Filters: { [{ Instance }]: Filter } = setmetatable({}, { __mode = "k" }) :: any

local function newSlot(): Slot
    return { Time = -math.huge, Poses = {}, Parts = {}, Centers = {}, Radii = {} }
end

local function slotAt(index: number): Slot
    return Slots[(Head - Count + index - 1) % Capacity + 1]
end

local function resize(capacity: number)
    local resized: { Slot } = table.create(capacity)
    local kept = math.min(Count, capacity)
    for i = 1, kept do
        resized[i] = slotAt(Count - kept + i)
    end
    for i = kept + 1, capacity do
        resized[i] = newSlot()
    end
    Slots = resized
    Capacity = capacity
    Count = kept
    Head = if kept > 0 then kept else capacity
end

local function capacityFor(seconds: number): number
    return math.ceil(seconds * RECORD_RATE) + 2
end

local function measure(model: Model, poses: { [BasePart]: CFrame }?): (Vector3, number, { BasePart })
    local center = model:GetPivot().Position
    local radius = 0
    local parts = {}
    for _, child in model:GetChildren() do
        if child:IsA("BasePart") and child.CanQuery then
            local cframe = child.CFrame
            if poses then
                poses[child] = cframe
            end
            table.insert(parts, child)
            radius = math.max(radius, (cframe.Position - center).Magnitude + child.Size.Magnitude * 0.5)
        end
    end
    return center, radius, parts
end

local function record(now: number)
    Head = Head % Capacity + 1
    Count = math.min(Count + 1, Capacity)

    local slot = Slots[Head]
    slot.Time = now
    table.clear(slot.Poses)
    table.clear(slot.Parts)
    table.clear(slot.Centers)
    table.clear(slot.Radii)

    for model in Tracked do
        if model.Parent then
            local center, radius, parts = measure(model, slot.Poses)
            slot.Parts[model] = parts
            slot.Centers[model] = center
            slot.Radii[model] = radius
        end
    end
end

local function onHeartbeat()
    Frame += 1
    local now = workspace:GetServerTimeNow()
    if Count == 0 or now >= NextRecord then
        record(now)
        NextRecord += RECORD_INTERVAL
        if NextRecord <= now then
            NextRecord = now + RECORD_INTERVAL
        end
    end
end

local function liveSphere(model: Model): (Vector3, number)
    if LiveFrame[model] ~= Frame then
        local center, radius = measure(model, nil)
        LiveFrame[model] = Frame
        LiveCenters[model] = center
        LiveRadii[model] = radius
    end
    return LiveCenters[model], LiveRadii[model]
end

local function bracket(t: number, now: number): (Slot, Slot?, number)
    local newest = Slots[Head]
    if t >= newest.Time then
        local span = now - newest.Time
        return newest, nil, if span > EPSILON then math.min((t - newest.Time) / span, 1) else 1
    end

    local oldest = slotAt(1)
    if t <= oldest.Time then
        return oldest, oldest, 0
    end

    local lo, hi = 1, Count
    while hi - lo > 1 do
        local mid = (lo + hi) // 2
        if slotAt(mid).Time <= t then
            lo = mid
        else
            hi = mid
        end
    end

    local older, newer = slotAt(lo), slotAt(hi)
    local span = newer.Time - older.Time
    return older, newer, if span > EPSILON then (t - older.Time) / span else 0
end

local function filterFor(ignoreList: { Instance }, params: RaycastParams): Filter
    local filter = Filters[ignoreList]
    if filter and filter.Version == TrackedVersion then
        return filter
    end

    local ignored: { [Instance]: true } = {}
    local exclude = table.clone(ignoreList)
    for _, instance in ignoreList do
        ignored[instance] = true
    end
    for model in Tracked do
        table.insert(exclude, model)
    end

    local worldParams = RaycastParams.new()
    worldParams.FilterType = Enum.RaycastFilterType.Exclude
    worldParams.IgnoreWater = params.IgnoreWater
    worldParams.RespectCanCollide = params.RespectCanCollide
    worldParams.CollisionGroup = params.CollisionGroup
    worldParams.FilterDescendantsInstances = exclude

    local built = { Version = TrackedVersion, Params = worldParams, Ignored = ignored }
    Filters[ignoreList] = built
    return built
end

local function slab(o: number, d: number, h: number): (number, number, number)
    if math.abs(d) < EPSILON then
        if o < -h or o > h then
            return math.huge, -math.huge, 0
        end
        return -math.huge, math.huge, 0
    end
    local inv = 1 / d
    local t1 = (-h - o) * inv
    local t2 = (h - o) * inv
    if t1 > t2 then
        return t2, t1, 1
    end
    return t1, t2, -1
end

-- Ray vs oriented box; returns the near hit as a fraction of direction (valid in [0, 1])
local function rayOBB(origin: Vector3, direction: Vector3, cframe: CFrame, size: Vector3): (number?, Vector3?)
    local o = cframe:PointToObjectSpace(origin)
    local d = cframe:VectorToObjectSpace(direction)
    local half = size * 0.5

    local xMin, xMax, xSign = slab(o.X, d.X, half.X)
    local yMin, yMax, ySign = slab(o.Y, d.Y, half.Y)
    local zMin, zMax, zSign = slab(o.Z, d.Z, half.Z)

    local tMin = math.max(xMin, yMin, zMin, 0)
    local tMax = math.min(xMax, yMax, zMax, 1)
    if tMin > tMax then
        return nil, nil
    end

    local localNormal
    if tMin == xMin then
        localNormal = Vector3.new(xSign, 0, 0)
    elseif tMin == yMin then
        localNormal = Vector3.new(0, ySign, 0)
    elseif tMin == zMin then
        localNormal = Vector3.new(0, 0, zSign)
    else
        localNormal = Vector3.xAxis
    end

    return tMin, cframe:VectorToWorldSpace(localNormal)
end

local function segmentHitsSphere(origin: Vector3, direction: Vector3, lengthSquared: number, center: Vector3, radius: number): boolean
    local along = math.clamp((center - origin):Dot(direction) / lengthSquared, 0, 1)
    local closest = origin + direction * along
    return (center - closest).Magnitude <= radius
end

function LagCompensation.EnsureHistory(seconds: number)
    HistoryLength = math.max(HistoryLength, seconds)
    if Capacity > 0 and capacityFor(HistoryLength) > Capacity then
        resize(capacityFor(HistoryLength))
    end
end

-- Starts tracking a character/rig so it can be rewound. No-op on the client.
function LagCompensation.Register(model: Model)
    if not IS_SERVER then return end
    if Tracked[model] then return end
    Tracked[model] = true
    TrackedVersion += 1

    if not Connection then
        resize(capacityFor(HistoryLength))
        Connection = RunService.Heartbeat:Connect(onHeartbeat)
    end
end

-- Stops tracking a character/rig. Safe to call more than once.
function LagCompensation.Unregister(model: Model)
    if not IS_SERVER then return end
    if not Tracked[model] then return end
    Tracked[model] = nil
    TrackedVersion += 1

    if next(Tracked) == nil and Connection then
        Connection:Disconnect()
        Connection = nil
        Count = 0
        Head = 0
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
    evalTime: number,
    radius: number?
): RaycastResult?
    if not IS_SERVER or next(Tracked) == nil or Count == 0 then
        return Math.Cast(origin, direction, params, radius)
    end

    local now = workspace:GetServerTimeNow()
    if evalTime >= now then
        return Math.Cast(origin, direction, params, radius)
    end

    local lengthSquared = direction:Dot(direction)
    if lengthSquared < EPSILON * EPSILON then return nil end
    local maxLen = math.sqrt(lengthSquared)

    local filter = filterFor(ignoreList, params)
    local best = Math.Cast(origin, direction, filter.Params, radius)
    local bestT = if best then best.Distance / maxLen else 1

    local older, newer, alpha = bracket(evalTime, now)
    local thickness = radius or 0
    local inflate = Vector3.one * (thickness * 2)

    for model in Tracked do
        if filter.Ignored[model] then continue end

        local parts = older.Parts[model]
        local centerA = older.Centers[model]
        if not parts or not centerA then continue end

        local centerB, radiusB
        if newer then
            centerB, radiusB = newer.Centers[model], newer.Radii[model]
        else
            centerB, radiusB = liveSphere(model)
        end
        local radiusA = older.Radii[model]
        local center = if centerB then centerA:Lerp(centerB, alpha) else centerA
        local bound = math.max(radiusA, radiusB or 0) + thickness

        if not segmentHitsSphere(origin, direction, lengthSquared, center, bound) then continue end

        local posesA = older.Poses
        local posesB = if newer then newer.Poses else nil

        for _, part in parts do
            local a = posesA[part]
            local b = if posesB then posesB[part] else part.CFrame
            local cframe = if b then a:Lerp(b, alpha) else a

            local t, normal = rayOBB(origin, direction, cframe, part.Size + inflate)
            if t and t < bestT and normal then
                bestT = t
                best = {
                    Instance = part,
                    Position = origin + direction * t - normal * thickness,
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
