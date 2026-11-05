--!strict
--[[
	TestTrackBuilder  (edit-time / server only)

	Builds the Phase-1 proving ground under Workspace.FormulaSim.Track.
	The track is saved with the place, so this only needs to run when the layout changes.
	Run from the Studio command bar (clone avoids the command bar's require cache):
	    require(game.ServerStorage.FormulaSim.TestTrackBuilder:Clone()).build()

	Layout coordinates are "track-plane" metres: x = east, n = north.
	North is world -Z, which is the direction cars face when they spawn.
	Heading angles: 0 = north, +90 deg = east (clockwise when seen from above).

	Contents:
	  Paddock / reset area (spawn slots)     x -20..20,   n -60..5
	  Main straight, 1000 m                  x = 0,       n 5..1005
	  Braking zone pad                       x -60..20,   n 1005..1305
	  Handling loop: hairpin R20, medium R60, high-speed R150, esses R80, R50, R40, R40, R25
	  Vehicle dynamics pad (west): slalom, R40 skidpad, curb test lane

	Collidable surfaces: ground, road, pads, curbs, curb-test bumps.
	Markers (lines, cones, signs) are CanCollide/CanQuery false so they never affect physics.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UnitConversion = require(ReplicatedStorage:WaitForChild("FormulaSim"):WaitForChild("Shared"):WaitForChild("UnitConversion"))

local S = UnitConversion.metersToStuds

local ROAD_WIDTH_M = 15
local SLAB_THICK_STUDS = 2
local CURB_WIDTH_M = 1.0
local CURB_HEIGHT_M = 0.035
local LINE_WIDTH_M = 0.15
local LINE_RAISE_M = 0.004
local MAX_PIECE_M = 500 -- keeps every part under Roblox's 2048-stud size limit

local COLOR = {
	asphalt = Color3.fromRGB(56, 58, 62),
	runoff = Color3.fromRGB(74, 76, 82),
	paddock = Color3.fromRGB(118, 120, 126),
	grass = Color3.fromRGB(78, 122, 66),
	white = Color3.fromRGB(235, 235, 235),
	red = Color3.fromRGB(205, 40, 40),
	yellow = Color3.fromRGB(240, 200, 40),
	orange = Color3.fromRGB(255, 120, 20),
	blue = Color3.fromRGB(40, 110, 220),
	sign = Color3.fromRGB(24, 24, 30),
}

type Turtle = { x: number, n: number, a: number }
type Ctx = { folder: Instance, flip: boolean }

local TestTrackBuilder = {}

local function toWorld(x: number, n: number, yM: number): Vector3
	return Vector3.new(S(x), S(yM), -S(n))
end

local function dirWorld(a: number): Vector3
	return Vector3.new(math.sin(a), 0, -math.cos(a))
end

local function rightNormal(a: number): Vector2
	return Vector2.new(math.cos(a), -math.sin(a))
end

local function makePart(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, solid: boolean): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.CanCollide = solid
	p.CanQuery = solid
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- Axis-aligned slab whose top surface is at topM, tiled to respect the part size limit.
local function slab(parent: Instance, name: string, x0: number, x1: number, n0: number, n1: number, topM: number, color: Color3, material: Enum.Material)
	local nx = math.ceil((x1 - x0) / MAX_PIECE_M)
	local nn = math.ceil((n1 - n0) / MAX_PIECE_M)
	local w = (x1 - x0) / nx
	local l = (n1 - n0) / nn
	for i = 0, nx - 1 do
		for j = 0, nn - 1 do
			local cx = x0 + w * (i + 0.5)
			local cn = n0 + l * (j + 0.5)
			local pos = toWorld(cx, cn, topM) - Vector3.new(0, SLAB_THICK_STUDS / 2, 0)
			makePart(parent, name, Vector3.new(S(w), SLAB_THICK_STUDS, S(l)), CFrame.new(pos), color, material, true)
		end
	end
end

-- Thin painted (non-collidable) strip centred at (x, n) along heading a.
local function paint(parent: Instance, x: number, n: number, a: number, lengthM: number, widthM: number, color: Color3, topM: number?)
	local top = (topM or 0) + LINE_RAISE_M
	local thick = 0.05
	local pos = toWorld(x, n, top) - Vector3.new(0, thick / 2, 0)
	local cf = CFrame.lookAt(pos, pos + dirWorld(a))
	makePart(parent, "Paint", Vector3.new(S(widthM), thick, S(lengthM)), cf, color, Enum.Material.SmoothPlastic, false)
end

-- Road strip from p0 to p1 (track-plane metres) with white edge lines.
local function roadStrip(ctx: Ctx, p0: Vector2, p1: Vector2, extraLenM: number)
	local d = p1 - p0
	local len = d.Magnitude + extraLenM
	if len < 1e-3 then
		return
	end
	local mid = (p0 + p1) / 2
	local a = math.atan2(d.X, d.Y)
	-- Alternate a 1 mm height offset so overlapping neighbours never z-fight.
	ctx.flip = not ctx.flip
	local top = if ctx.flip then 0.001 else 0
	local pos = toWorld(mid.X, mid.Y, top) - Vector3.new(0, SLAB_THICK_STUDS / 2, 0)
	makePart(ctx.folder, "Road", Vector3.new(S(ROAD_WIDTH_M), SLAB_THICK_STUDS, S(len)), CFrame.lookAt(pos, pos + dirWorld(a)), COLOR.asphalt, Enum.Material.Asphalt, true)
	local rn = rightNormal(a)
	for side = -1, 1, 2 do
		local c = mid + rn * (side * (ROAD_WIDTH_M / 2 - LINE_WIDTH_M / 2 - 0.1))
		paint(ctx.folder, c.X, c.Y, a, len, LINE_WIDTH_M, COLOR.white, top)
	end
end

local function sign(parent: Instance, text: string, x: number, n: number, faceA: number, bg: Color3, widthM: number?, heightM: number?)
	local w = widthM or 4
	local h = heightM or 1.6
	local elev = 1.2
	local pos = toWorld(x, n, elev + h / 2)
	local board = makePart(parent, "Sign", Vector3.new(S(w), S(h), 0.3), CFrame.lookAt(pos, pos + dirWorld(faceA)), bg, Enum.Material.SmoothPlastic, false)
	local postPos = toWorld(x, n, elev / 2)
	makePart(parent, "SignPost", Vector3.new(0.4, S(elev), 0.4), CFrame.new(postPos), Color3.fromRGB(90, 90, 95), Enum.Material.Metal, false)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 24
	gui.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Text = text
	label.Parent = gui
	gui.Parent = board
end

local function cone(parent: Instance, x: number, n: number, color: Color3)
	local h = 0.5
	local cf = CFrame.new(toWorld(x, n, h / 2)) * CFrame.Angles(0, 0, math.pi / 2)
	local p = makePart(parent, "Cone", Vector3.new(S(h), S(0.3), S(0.3)), cf, color, Enum.Material.SmoothPlastic, false)
	p.Shape = Enum.PartType.Cylinder
end

-- Turtle: straight road
local function straight(ctx: Ctx, t: Turtle, lengthM: number)
	local pieces = math.max(1, math.ceil(lengthM / 200))
	local d = Vector2.new(math.sin(t.a), math.cos(t.a))
	local start = Vector2.new(t.x, t.n)
	for i = 1, pieces do
		local p0 = start + d * (lengthM * (i - 1) / pieces)
		local p1 = start + d * (lengthM * i / pieces)
		roadStrip(ctx, p0, p1, 0.2)
	end
	local e = start + d * lengthM
	t.x, t.n = e.X, e.Y
end

-- Turtle: move without building (used where a pad already covers the surface)
local function skip(t: Turtle, lengthM: number)
	t.x += math.sin(t.a) * lengthM
	t.n += math.cos(t.a) * lengthM
end

-- Turtle: constant-radius arc. side = 1 for a right turn, -1 for a left turn.
local function arc(ctx: Ctx, t: Turtle, radiusM: number, angleDeg: number, side: number, label: string?)
	local theta = math.rad(angleDeg)
	local steps = math.max(4, math.ceil(theta * radiusM / 3))
	local dTheta = theta / steps
	if label then
		-- sign on the outside of the corner entry, facing approaching cars
		local outward = rightNormal(t.a) * (-side * (ROAD_WIDTH_M / 2 + 6))
		local back = Vector2.new(math.sin(t.a), math.cos(t.a)) * -25
		local p = Vector2.new(t.x, t.n) + outward + back
		sign(ctx.folder, label, p.X, p.Y, t.a + math.pi, COLOR.sign, 6, 1.6)
	end
	local outerChordFactor = 2 * (radiusM + ROAD_WIDTH_M / 2) * math.sin(dTheta / 2)
	local curbRadius = radiusM - ROAD_WIDTH_M / 2 + CURB_WIDTH_M / 2
	for i = 1, steps do
		local mid = t.a + side * dTheta / 2
		local chord = 2 * radiusM * math.sin(dTheta / 2)
		local p0 = Vector2.new(t.x, t.n)
		local p1 = p0 + Vector2.new(math.sin(mid), math.cos(mid)) * chord
		roadStrip(ctx, p0, p1, outerChordFactor - chord + 0.1)

		-- apex curb on the inside of the corner (middle 70% of the arc)
		local frac = (i - 0.5) / steps
		if frac >= 0.15 and frac <= 0.85 then
			local pm = (p0 + p1) / 2
			local inner = rightNormal(mid) * side
			local c = pm + inner * (ROAD_WIDTH_M / 2 - CURB_WIDTH_M / 2)
			local len = 2 * curbRadius * math.sin(dTheta / 2) + 0.02
			local sizeY = S(CURB_HEIGHT_M) + 0.5
			local pos = toWorld(c.X, c.Y, CURB_HEIGHT_M) - Vector3.new(0, sizeY / 2, 0)
			local color = if i % 2 == 0 then COLOR.red else COLOR.white
			makePart(ctx.folder, "Curb", Vector3.new(S(CURB_WIDTH_M), sizeY, S(len)), CFrame.lookAt(pos, pos + dirWorld(mid)), color, Enum.Material.SmoothPlastic, true)
		end

		t.x, t.n = p1.X, p1.Y
		t.a += side * dTheta
	end
end

local function newFolder(name: string, parent: Instance): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

function TestTrackBuilder.build(): Folder
	local simFolder = workspace:FindFirstChild("FormulaSim")
	if not simFolder then
		simFolder = newFolder("FormulaSim", workspace)
	end
	assert(simFolder)
	local old = simFolder:FindFirstChild("Track")
	if old then
		old:Destroy() -- only ever removes our own generated track
	end

	local track = Instance.new("Folder")
	track.Name = "Track"

	-- Each section is built off-DataModel, parented, then we yield so Studio stays responsive.
	local function section(name: string, fn: (Folder) -> ())
		local f = Instance.new("Folder")
		f.Name = name
		fn(f)
		f.Parent = track
		if track.Parent == nil then
			track.Parent = simFolder
		end
		task.wait()
	end

	section("Ground", function(f)
		slab(f, "Grass", -320, 620, -150, 1460, -0.02, COLOR.grass, Enum.Material.Grass) -- 2 cm below asphalt
	end)

	section("Paddock", function(f)
		slab(f, "PaddockSurface", -20, 20, -60, 5, 0, COLOR.paddock, Enum.Material.Concrete)
		local slots = newFolder("SpawnSlots", f)
		for i, x in { -4, 4, -12, 12 } do
			local pos = toWorld(x, -25, 0.03)
			local slot = makePart(slots, "Slot" .. i, Vector3.new(1, 0.2, 1), CFrame.lookAt(pos, pos + dirWorld(0)), COLOR.yellow, Enum.Material.SmoothPlastic, false)
			slot.Transparency = 1
			-- painted grid box (2.4 m x 6 m)
			paint(f, x - 1.2, -25, 0, 6, 0.12, COLOR.yellow)
			paint(f, x + 1.2, -25, 0, 6, 0.12, COLOR.yellow)
			paint(f, x, -22, math.pi / 2, 2.52, 0.12, COLOR.yellow)
		end
		local spawnPos = toWorld(0, -50, 0.01) - Vector3.new(0, 0.2, 0)
		local sp = Instance.new("SpawnLocation")
		sp.Name = "DriverSpawn"
		sp.Anchored = true
		sp.Size = Vector3.new(S(4), 0.4, S(4))
		sp.CFrame = CFrame.lookAt(spawnPos, spawnPos + dirWorld(0))
		sp.Neutral = true
		sp.Duration = 0
		sp.Color = COLOR.blue
		sp.Material = Enum.Material.SmoothPlastic
		sp.TopSurface = Enum.SurfaceType.Smooth
		sp.Parent = f
		sign(f, "PADDOCK / RESET AREA", 0, -58, 0, COLOR.blue, 8, 1.6)
	end)

	section("MainStraight", function(f)
		local ctx: Ctx = { folder = f, flip = false }
		local t: Turtle = { x = 0, n = 5, a = 0 }
		straight(ctx, t, 1000)
		-- start line (chequer-like: white bar)
		paint(f, 0, 5, math.pi / 2, ROAD_WIDTH_M, 0.6, COLOR.white, 0.001)
		sign(f, "START  0 m", 11, 5, math.pi, COLOR.sign)
		for d = 100, 900, 100 do
			sign(f, d .. " m", -11, 5 + d, math.pi, COLOR.sign, 3, 1.2)
		end
		-- braking boards before the braking zone
		for _, d in { 300, 200, 100 } do
			sign(f, tostring(d), 11, 1005 - d, math.pi, COLOR.red, 2.4, 1.6)
		end
	end)

	section("BrakingZone", function(f)
		slab(f, "BrakingPad", -60, 20, 1005, 1305, 0, COLOR.runoff, Enum.Material.Asphalt)
		paint(f, 0, 1005, math.pi / 2, 80, 0.5, COLOR.yellow)
		sign(f, "BRAKING ZONE", 26, 1000, math.pi, COLOR.red, 7, 1.6)
		for n = 1005, 1305, 50 do
			cone(f, -7.5, n, COLOR.orange)
			cone(f, 7.5, n, COLOR.orange)
			if n > 1005 then
				paint(f, -12, n, math.pi / 2, 3, 0.3, COLOR.white)
			end
		end
	end)

	section("HandlingLoop", function(f)
		local ctx: Ctx = { folder = f, flip = false }
		local t: Turtle = { x = 0, n = 1305, a = 0 }
		straight(ctx, t, 20)
		arc(ctx, t, 20, 180, 1, "T1 HAIRPIN R20")
		straight(ctx, t, 200)
		arc(ctx, t, 60, 90, -1, "T2 MEDIUM R60")
		straight(ctx, t, 150)
		arc(ctx, t, 150, 90, 1, "T3 FAST R150")
		straight(ctx, t, 300)
		arc(ctx, t, 80, 60, -1, "T4-T5 ESSES R80")
		arc(ctx, t, 80, 60, 1)
		straight(ctx, t, 200)
		arc(ctx, t, 50, 90, 1, "T6 R50")
		straight(ctx, t, 310)
		arc(ctx, t, 40, 90, -1, "T7 R40")
		straight(ctx, t, t.n - 60)
		arc(ctx, t, 40, 90, 1, "T8 R40")
		straight(ctx, t, t.x - 25)
		arc(ctx, t, 25, 90, 1, "T9 R25")
		track:SetAttribute("LoopEndX", t.x)
		track:SetAttribute("LoopEndN", t.n)
		track:SetAttribute("LoopEndHeadingDeg", math.deg(t.a) % 360)
	end)

	section("DynamicsPad", function(f)
		slab(f, "DynamicsPadSurface", -230, -20, -60, 520, 0, COLOR.runoff, Enum.Material.Asphalt)

		-- Slalom: cones every 20 m
		sign(f, "SLALOM  20 m", -60, 22, math.pi, COLOR.sign, 6, 1.6)
		cone(f, -66, 30, COLOR.blue)
		cone(f, -54, 30, COLOR.blue)
		for n = 40, 400, 20 do
			cone(f, -60, n, COLOR.orange)
		end

		-- Skidpad: R40 centre line, 8 m lane
		local cx, cn = -150, 300
		local segs = 96
		for _, r in { 36, 44 } do
			for i = 0, segs - 1 do
				local phi = (i + 0.5) / segs * 2 * math.pi
				local x = cx + r * math.sin(phi)
				local n = cn + r * math.cos(phi)
				paint(f, x, n, phi + math.pi / 2, 2 * math.pi * r / segs + 0.05, 0.2, COLOR.white)
			end
		end
		for i = 0, 7 do
			local phi = i / 8 * 2 * math.pi
			cone(f, cx + 40 * math.sin(phi), cn + 40 * math.cos(phi), COLOR.yellow)
		end
		sign(f, "SKIDPAD R40", cx, cn, math.pi, COLOR.sign, 6, 1.6)

		-- Curb test lane, heading north at x = -120
		local lx = -120
		paint(f, lx - 5, 50, 0, 70, 0.15, COLOR.white)
		paint(f, lx + 5, 50, 0, 70, 0.15, COLOR.white)
		sign(f, "CURB TEST  3 / 5 / 8 cm + LEFT ONLY", lx, 10, math.pi, COLOR.sign, 9, 1.6)
		local function bump(xCenter: number, n: number, lengthM: number, heightM: number)
			local r = 0.3
			local pos = toWorld(xCenter, n, heightM - r)
			local p = makePart(f, "CurbBump", Vector3.new(S(lengthM), S(2 * r), S(2 * r)), CFrame.new(pos), COLOR.red, Enum.Material.SmoothPlastic, true)
			p.Shape = Enum.PartType.Cylinder
		end
		bump(lx, 30, 10, 0.03)
		bump(lx, 45, 10, 0.05)
		bump(lx, 60, 10, 0.08)
		bump(lx - 1.3, 75, 2.5, 0.05) -- left wheels only
	end)

	return track
end

return TestTrackBuilder
