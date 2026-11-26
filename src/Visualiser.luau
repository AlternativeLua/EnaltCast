--!strict
--!optimize 2
-- Debug drawing for casts.
--
-- Adornments live in fixed-size ring buffers. Each pool's adornments share one
-- lifetime, so live ones are always contiguous and oldest-first: expiring them only
-- touches the ones that actually expired, and a full pool reuses its oldest adornment.
-- There's no fade animation; adornments are hidden when they expire.
--
-- A bullet's path is joined into pieces of at least MIN_SEGMENT_LENGTH studs (see
-- Trail), so a long flight is a handful of adornments instead of one per frame.
--
-- Hits are coloured by type, with a short stub along the surface normal. Path pieces
-- are coloured by speed (white at the cast's initial speed, dark red near 0), and the
-- path through a penetrated wall is drawn in blue.
--
-- Markers created on the server replicate to clients, so they're drawn as larger,
-- fainter shells: a client hit should sit inside the server hit for the same shot.

local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()

export type HitKind = "Impact" | "Humanoid" | "Ricochet" | "Penetration"

-- Per-bullet state for joining path pieces. Keep one per bullet and pass it to Extend/Flush.
export type Trail = {
	From: Vector3?, -- start of the piece not yet drawn
	Last: Vector3?, -- end of the last extension
	Ratio: number?,
}

local Visualiser = {}

Visualiser.Colors = {
	Impact = Color3.fromRGB(255, 80, 60),
	Humanoid = Color3.fromRGB(255, 60, 220),
	Ricochet = Color3.fromRGB(255, 210, 50),
	Penetration = Color3.fromRGB(60, 170, 255),
	FullSpeed = Color3.fromRGB(245, 245, 245),
	NoSpeed = Color3.fromRGB(110, 15, 15),
}

local MIN_SEGMENT_LENGTH = 8
local SEGMENT_LIFETIME = 3
local HIT_LIFETIME = 5
local MAX_SEGMENTS = 2000
local MAX_HITS = 500

local SCALE = if IS_SERVER then 1.8 else 1
local TRANSPARENCY = if IS_SERVER then 0.6 else 0.15
local NORMAL_LENGTH = 1.5 * SCALE

type Pool = {
	ClassName: string,
	Lifetime: number,
	Max: number,
	Radius: number,
	Head: number, -- slot written last
	Live: number, -- visible adornments, ending at Head
	Items: { HandleAdornment },
	Born: { number },
	Colors: { Color3 },
}

local function newPool(className: string, lifetime: number, max: number, radius: number): Pool
	return {
		ClassName = className,
		Lifetime = lifetime,
		Max = max,
		Radius = radius,
		Head = 0,
		Live = 0,
		Items = {},
		Born = {},
		Colors = {},
	}
end

local segments = newPool("CylinderHandleAdornment", SEGMENT_LIFETIME, MAX_SEGMENTS, 0.06 * SCALE)
local walls = newPool("CylinderHandleAdornment", SEGMENT_LIFETIME, MAX_HITS, 0.09 * SCALE)
local spheres = newPool("SphereHandleAdornment", HIT_LIFETIME, MAX_HITS, 0.35 * SCALE)
local normals = newPool("CylinderHandleAdornment", HIT_LIFETIME, MAX_HITS, 0.04 * SCALE)
local pools = { segments, walls, spheres, normals }

local folder: Folder? = nil
local connection: RBXScriptConnection? = nil

local function reset()
	for _, pool in pools do
		pool.Head = 0
		pool.Live = 0
		table.clear(pool.Items)
		table.clear(pool.Born)
		table.clear(pool.Colors)
	end
end

local function expire()
	local current = folder
	if current and current.Parent == nil then
		-- Someone destroyed the folder (and every adornment with it)
		folder = nil
		reset()
	end

	local now = os.clock()
	local any = false
	for _, pool in pools do
		local live = pool.Live
		if live == 0 then
			continue
		end
		local max = pool.Max
		local born = pool.Born
		local items = pool.Items
		local deadline = now - pool.Lifetime
		local oldest = (pool.Head - live) % max + 1
		while live > 0 and born[oldest] <= deadline do
			items[oldest].Visible = false
			live -= 1
			oldest = oldest % max + 1
		end
		pool.Live = live
		if live > 0 then
			any = true
		end
	end

	if not any and connection then
		connection:Disconnect()
		connection = nil
	end
end

local function getFolder(): Folder
	local current = folder
	if current then
		return current
	end
	local created = Instance.new("Folder")
	created.Name = "EnaltCastVisualiser"
	created.Parent = workspace
	folder = created
	return created
end

local function acquire(pool: Pool, color: Color3): HandleAdornment
	local slot = pool.Head % pool.Max + 1
	pool.Head = slot

	local existing: HandleAdornment? = pool.Items[slot]
	local item: HandleAdornment
	if existing then
		item = existing
		if pool.Live < pool.Max then
			-- Slot was expired and hidden; a full pool reuses its oldest, still visible
			pool.Live += 1
			item.Visible = true
		end
	else
		item = (Instance.new :: any)(pool.ClassName)
		item.Adornee = workspace.Terrain
		item.Transparency = TRANSPARENCY
		;(item :: any).Radius = pool.Radius
		item.Parent = getFolder()
		pool.Items[slot] = item
		pool.Live += 1
	end

	if pool.Colors[slot] ~= color then
		pool.Colors[slot] = color
		item.Color3 = color
	end
	pool.Born[slot] = os.clock()

	if not connection then
		connection = RunService.Heartbeat:Connect(expire)
	end
	return item
end

local function cylinder(pool: Pool, from: Vector3, to: Vector3, color: Color3)
	local offset = to - from
	local length = offset.Magnitude
	if length < 1e-3 then
		return
	end
	local item = acquire(pool, color) :: CylinderHandleAdornment
	-- Cylinders are centred on their CFrame and run along its Z axis
	item.CFrame = CFrame.lookAlong(from + offset * 0.5, offset)
	item.Height = length
end

local function speedColor(ratio: number?): Color3
	if ratio and ratio < 1 then
		-- Quantised so nearby speeds share a Color3 and skip the property write
		local step = math.floor(math.max(ratio, 0) * 8 + 0.5) / 8
		return Visualiser.Colors.NoSpeed:Lerp(Visualiser.Colors.FullSpeed, step)
	end
	return Visualiser.Colors.FullSpeed
end

-- Draws one piece of path directly. `speedRatio` is current speed / initial speed;
-- omit it to draw at full-speed colour.
function Visualiser.Segment(from: Vector3, to: Vector3, speedRatio: number?)
	cylinder(segments, from, to, speedColor(speedRatio))
end

-- Adds from -> to to a bullet's trail, drawing once the undrawn part is long enough.
-- A gap (from ~= the previous `to`, e.g. after a ricochet) draws the pending piece first.
function Visualiser.Extend(trail: Trail, from: Vector3, to: Vector3, speedRatio: number?)
	local pending, last = trail.From, trail.Last
	local start: Vector3
	if pending and last == from then
		start = pending
	else
		if pending and last then
			Visualiser.Segment(pending, last, trail.Ratio)
		end
		start = from
	end

	if (to - start).Magnitude >= MIN_SEGMENT_LENGTH then
		Visualiser.Segment(start, to, speedRatio)
		start = to
	end
	trail.From = start
	trail.Last = to
	trail.Ratio = speedRatio
end

-- Draws whatever is pending on the trail, e.g. when the bullet hits something or ends.
function Visualiser.Flush(trail: Trail)
	local start, last = trail.From, trail.Last
	if start and last then
		Visualiser.Segment(start, last, trail.Ratio)
	end
	trail.From = nil
	trail.Last = nil
end

-- The path through a penetrated wall, from entry to exit.
function Visualiser.Penetration(entry: Vector3, exit: Vector3)
	cylinder(walls, entry, exit, Visualiser.Colors.Penetration)
end

function Visualiser.Hit(position: Vector3, normal: Vector3?, kind: HitKind)
	local color = Visualiser.Colors[kind] or Visualiser.Colors.Impact
	local sphere = acquire(spheres, color) :: SphereHandleAdornment
	sphere.CFrame = CFrame.new(position)

	if normal and normal.Magnitude > 0 then
		cylinder(normals, position, position + normal.Unit * NORMAL_LENGTH, color)
	end
end

-- Hides everything immediately.
function Visualiser.Clear()
	for _, pool in pools do
		for _, item in pool.Items do
			item.Visible = false
		end
		pool.Live = 0
	end
end

return Visualiser
