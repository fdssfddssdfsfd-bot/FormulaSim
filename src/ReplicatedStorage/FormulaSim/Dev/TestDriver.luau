--!strict
--[[
	TestDriver  (Studio-only diagnostics; not used by the game)

	Automated driving tests with exact analogue inputs, using the Studio-only input override
	in InputController (car attributes TestInputEnabled / TestThrottle / TestBrake / TestSteer)
	and the Tel_* telemetry attributes published by VehicleController.

	Usage from the Studio command bar during Play:
	  Server context:  require(game.ReplicatedStorage.FormulaSim.Dev.TestDriver).place(x, n)
	                   (track-plane metres, heading north, wheels re-initialised)
	  Client context:  local TD = require(game.ReplicatedStorage.FormulaSim.Dev.TestDriver)
	                   TD.start("A")  ...  print(TD.report("A"))

	Scenarios: F straight full throttle, E high-speed small steering, D 100% braking,
	           A part throttle in a corner, B full throttle in a corner + driver recovery,
	           C moderate braking in a corner, C2 hard braking in a corner.
]]

local RunService = game:GetService("RunService")
local Shared = script.Parent.Parent:WaitForChild("Shared")
local SteeringModel = require(Shared:WaitForChild("SteeringModel"))
local VehicleConfig = require(Shared:WaitForChild("VehicleConfig"))

local S = 1 / 0.28
local TestDriver = {}
TestDriver.results = {} :: { [string]: any }

local function getCar(): Model
	return workspace:WaitForChild("FormulaSim"):WaitForChild("Cars"):GetChildren()[1] :: Model
end

-- SERVER: place the car at rest at track-plane (x, n) heading north.
function TestDriver.place(x: number, n: number)
	assert(RunService:IsServer(), "place() must run in the Server context")
	local car = getCar()
	local core = car.PrimaryPart :: BasePart
	local owner = core:GetNetworkOwner()
	core:SetNetworkOwner(nil)
	for _, d in car:GetDescendants() do
		if d:IsA("VectorForce") then
			d.Force = Vector3.zero
		end
	end
	local p = Vector3.new(x * S, 0.03 * S, -n * S)
	car:PivotTo(CFrame.lookAt(p, p + Vector3.new(0, 0, -1)))
	core.AssemblyLinearVelocity = Vector3.zero
	core.AssemblyAngularVelocity = Vector3.zero
	car:SetAttribute("ResetCount", ((car:GetAttribute("ResetCount") :: number?) or 0) + 1)
	task.wait(0.3)
	core:SetNetworkOwner(owner)
end

local function ramp(t: number, t0: number, dur: number, a: number, b: number): number
	return a + (b - a) * math.clamp((t - t0) / dur, 0, 1)
end

local function hold(a: any, kmh: number): number
	return math.clamp((kmh - a.Tel_SpeedKmh) * 0.08, 0, 1)
end

-- CLIENT: run a profile(t, attrs, stats) -> throttle, brake, steer, phase
function TestDriver.run(name: string, duration: number, profile: any)
	local car = getCar()
	local core = car.PrimaryPart :: BasePart
	local function heading(): number
		local l = core.CFrame.LookVector
		return math.deg(math.atan2(l.X, -l.Z))
	end
	local log = {}
	local st: any = { maxBeta = 0, maxYaw = 0, minGnd = 4, maxRearK = -9, minFrontK = 9, minRearK = 9, maxUtilF = 0, maxUtilR = 0, peakDecelG = 0, minYawMeasured = math.huge, maxLatG = 0 }
	local faults0 = (car:GetAttribute("Tel_Faults") :: number?) or 0
	local p0 = core.Position
	local prevH = heading()
	local unwrapped = 0
	TestDriver.results[name] = nil
	car:SetAttribute("TestThrottle", 0)
	car:SetAttribute("TestBrake", 0)
	car:SetAttribute("TestSteer", 0)
	car:SetAttribute("TestInputEnabled", true)
	local t0 = os.clock()
	local nextLog = 0
	local conn: RBXScriptConnection
	conn = RunService.PreSimulation:Connect(function()
		local t = os.clock() - t0
		local a: any = car:GetAttributes()
		local thr, brk, str, phase = profile(t, a, st)
		car:SetAttribute("TestThrottle", thr)
		car:SetAttribute("TestBrake", brk)
		car:SetAttribute("TestSteer", str)
		local h = heading()
		unwrapped += (h - prevH + 540) % 360 - 180
		prevH = h
		if phase ~= "skip" then
			st.maxBeta = math.max(st.maxBeta, math.abs(a.Tel_SideslipDeg or 0))
			st.maxYaw = math.max(st.maxYaw, math.abs(a.Tel_YawRateDeg or 0))
			st.minYawMeasured = math.min(st.minYawMeasured, math.abs(a.Tel_YawRateDeg or 0))
			st.maxLatG = math.max(st.maxLatG, math.abs(a.Tel_LatG or 0))
			st.maxRearK = math.max(st.maxRearK, a.Tel_K_RL or 0, a.Tel_K_RR or 0)
			st.minRearK = math.min(st.minRearK, a.Tel_K_RL or 0, a.Tel_K_RR or 0)
			st.minFrontK = math.min(st.minFrontK, a.Tel_K_FL or 0, a.Tel_K_FR or 0)
			st.maxUtilF = math.max(st.maxUtilF, a.Tel_U_FL or 0, a.Tel_U_FR or 0)
			st.maxUtilR = math.max(st.maxUtilR, a.Tel_U_RL or 0, a.Tel_U_RR or 0)
			st.peakDecelG = math.max(st.peakDecelG, -(a.Tel_LongG or 0))
		end
		st.minGnd = math.min(st.minGnd, a.Tel_Grounded or 4)
		if t >= nextLog then
			nextLog += 0.25
			table.insert(log, string.format(
				"t=%5.2f %-7s v=%5.1f G%s %5.0f thr=%.2f brk=%.2f str=%+.2f(%+5.2f°) yaw=%+6.1f β=%+5.1f latG=%+.2f lonG=%+.2f κF%+.2f/%+.2f κR%+.2f/%+.2f αF%+5.1f αR%+5.1f UF%.2f UR%.2f",
				t, tostring(phase or ""), a.Tel_SpeedKmh, tostring(a.Tel_Gear), a.Tel_Rpm or 0, a.Tel_Throttle, a.Tel_Brake, a.Tel_Steer, a.Tel_SteerDeg or 0,
				a.Tel_YawRateDeg, a.Tel_SideslipDeg, a.Tel_LatG, a.Tel_LongG, a.Tel_K_FL, a.Tel_K_FR, a.Tel_K_RL, a.Tel_K_RR,
				((a.Tel_A_FL or 0) + (a.Tel_A_FR or 0)) / 2, ((a.Tel_A_RL or 0) + (a.Tel_A_RR or 0)) / 2,
				math.max(a.Tel_U_FL, a.Tel_U_FR), math.max(a.Tel_U_RL, a.Tel_U_RR)))
		end
		if t >= duration then
			conn:Disconnect()
			car:SetAttribute("TestInputEnabled", false)
			st.faults = ((car:GetAttribute("Tel_Faults") :: number?) or 0) - faults0
			st.headingChange = unwrapped
			st.disp = (core.Position - p0) * 0.28
			st.endSpeed = car:GetAttribute("Tel_SpeedKmh")
			TestDriver.results[name] = { log = log, stats = st }
		end
	end)
end

function TestDriver.report(name: string, every: number?, from: number?, to: number?): string
	local r = TestDriver.results[name]
	if not r then
		return name .. ": not finished"
	end
	local s = r.stats
	local out = { string.format(
		"== %s: maxβ=%.2f° max|yaw|=%.1f°/s maxLatG=%.2f Δhdg=%.1f° rearκ %+.3f..%+.3f frontκmin %+.3f utilF %.2f utilR %.2f peakDecel %.2fg minGnd=%d faults=%d endV=%.1f%s",
		name, s.maxBeta, s.maxYaw, s.maxLatG, s.headingChange, s.minRearK, s.maxRearK, s.minFrontK, s.maxUtilF, s.maxUtilR, s.peakDecelG, s.minGnd, s.faults, s.endSpeed,
		if s.note then "  | " .. s.note else "") }
	for i = from or 1, math.min(to or #r.log, #r.log), every or 1 do
		table.insert(out, r.log[i])
	end
	return table.concat(out, "\n")
end

-- Corner set-up shared by A / B / C: hold speed, steer left (-0.6) and settle.
local function cornerApproach(t: number, a: any, kmh: number, steer: number)
	if t < 4 then
		return hold(a, kmh), 0, 0, "skip"
	end
	return hold(a, kmh), 0, ramp(t, 4, 0.4, 0, steer), "skip"
end

TestDriver.scenarios = {
	F = { 10, function(t: number)
		return math.min(1, t * 1.5), 0, 0, "measure"
	end },
	E = { 3, function(t: number)
		local s = 0
		if t < 0.5 then s = 0.15 elseif t < 1.0 then s = 0 elseif t < 1.5 then s = -0.15 elseif t < 2.0 then s = 0 elseif t < 2.5 then s = 0.15 end
		return 1, 0, s, "measure"
	end },
	D = { 6, function()
		return 0, 1, 0, "measure"
	end },
	-- A: part throttle (smooth ramp to 50% pedal over 1 s) in a ~1 g corner at 80 km/h
	A = { 10, function(t: number, a: any, st: any)
		if t < 6.5 then
			return cornerApproach(t, a, 80, -0.6)
		end
		if t < 9.5 then
			st.thr0 = st.thr0 or a.Tel_Throttle
			return ramp(t, 6.5, 1.0, st.thr0, 0.5), 0, -0.6, "measure"
		end
		return 0, 0.2, 0, "skip"
	end },
	-- B: full throttle (keyboard ramp) in the same corner; when sideslip exceeds 4 deg the
	-- "driver" lifts and counter-steers proportionally. Checks progressive, recoverable loss.
	B = { 11, function(t: number, a: any, st: any)
		if t < 6.5 then
			return cornerApproach(t, a, 80, -0.6)
		end
		local beta = a.Tel_SideslipDeg or 0
		if not st.liftT and beta > 4 then
			st.liftT = t
			st.note = string.format("oversteer detected at t=%.2f (%.2f s after throttle)", t, t - 6.5)
		end
		if st.beta2T == nil and beta > 2 then st.beta2T = t end
		if st.beta10T == nil and beta > 10 then st.beta10T = t end
		if st.liftT then
			if not st.recoveredT and math.abs(beta) < 2 and t > st.liftT + 0.2 then
				st.recoveredT = t
				st.note ..= string.format("; recovered |β|<2° %.2f s after lift", t - st.liftT)
			end
			return 0, 0, math.clamp(-0.6 + beta * 0.12, -1, 1), "measure"
		end
		return math.min(1, (t - 6.5) * 1.5), 0, -0.6, "measure"
	end },
	-- B_human: like B but the driver reacts 0.25 s after sideslip exceeds 4 deg (human-like)
	B_human = { 11, function(t: number, a: any, st: any)
		if t < 6.5 then
			return cornerApproach(t, a, 80, -0.6)
		end
		local beta = a.Tel_SideslipDeg or 0
		if not st.detectT and beta > 4 then st.detectT = t end
		if st.beta2T == nil and beta > 2 then st.beta2T = t end
		if st.detectT and t >= st.detectT + 0.25 then
			st.liftT = st.liftT or t
			if not st.recoveredT and math.abs(beta) < 2 and t > st.liftT + 0.2 then
				st.recoveredT = t
			end
			st.note = string.format("β>2° %.2fs after throttle; lift 0.25s after β>4°; peak β %.1f°; recovered %s",
				(st.beta2T or t) - 6.5, st.maxBeta, if st.recoveredT then string.format("%.2fs after lift", st.recoveredT - st.liftT) else "NO")
			return 0, 0, math.clamp(-0.6 + beta * 0.12, -1, 1), "measure"
		end
		return math.min(1, (t - 6.5) * 1.5), 0, -0.6, "measure"
	end },
	-- C: moderate braking (keyboard S = 0.35) in a corner at 100 km/h, steering held
	C = { 9, function(t: number, a: any, st: any)
		if t < 6.5 then
			local thr, brk, str, ph = cornerApproach(t, a, 100, -0.5)
			if t > 6.0 then
				st.yawBefore = a.Tel_YawRateDeg
				st.curvBefore = math.abs(a.Tel_YawRateDeg) / math.max(a.Tel_SpeedKmh, 1)
			end
			return thr, brk, str, ph
		end
		if t < 8.0 then
			st.curvDuring = math.abs(a.Tel_YawRateDeg) / math.max(a.Tel_SpeedKmh, 1)
			st.note = string.format("path curvature (yaw/speed) before %.4f, end of braking %.4f (ratio %.2f)", st.curvBefore or 0, st.curvDuring, st.curvDuring / math.max(st.curvBefore or 1e-6, 1e-6))
			return 0, 0.35, -0.5, "measure"
		end
		return 0, 0, 0, "skip"
	end },
	-- C2: 100% braking (ABS off) in the same corner - lockup / understeer allowed
	C2 = { 9, function(t: number, a: any, st: any)
		if t < 6.5 then
			return cornerApproach(t, a, 100, -0.5)
		end
		if t < 8.0 then
			return 0, 1, -0.5, "measure"
		end
		return 0, 0, 0, "skip"
	end },
}

function TestDriver.start(name: string, variant: string?)
	local sc = TestDriver.scenarios[name]
	assert(sc, "unknown scenario " .. name)
	TestDriver.run(variant or name, sc[1], sc[2])
end

-- SERVER: place the car at rest at (x, n) facing headingDeg (0 = north, 90 = east).
function TestDriver.placeHeading(x: number, n: number, headingDeg: number)
	assert(RunService:IsServer(), "placeHeading() must run in the Server context")
	local car = getCar()
	local core = car.PrimaryPart :: BasePart
	local owner = core:GetNetworkOwner()
	core:SetNetworkOwner(nil)
	for _, d in car:GetDescendants() do
		if d:IsA("VectorForce") then
			d.Force = Vector3.zero
		end
	end
	local a = math.rad(headingDeg)
	local p = Vector3.new(x * S, 0.03 * S, -n * S)
	car:PivotTo(CFrame.lookAt(p, p + Vector3.new(math.sin(a), 0, -math.cos(a))))
	core.AssemblyLinearVelocity = Vector3.zero
	core.AssemblyAngularVelocity = Vector3.zero
	car:SetAttribute("ResetCount", ((car:GetAttribute("ResetCount") :: number?) or 0) + 1)
	task.wait(0.3)
	core:SetNetworkOwner(owner)
end

-- Ordered centreline (studs, Y = 0) of the handling loop, sampled every ~4 m.
local function loopCentreline(): { Vector3 }
	local strips = {}
	for _, c in workspace.FormulaSim.Track.HandlingLoop:GetChildren() do
		if c:IsA("BasePart") and c.Name == "Road" then
			local half = c.CFrame.LookVector * (c.Size.Z / 2)
			table.insert(strips, { a = c.Position - half, b = c.Position + half, used = false })
		end
	end
	-- the loop starts at the strip nearest the braking-zone exit (0, 1305 m)
	local startPt = Vector3.new(0, 0, -1305 * S)
	local current, bestD = nil, math.huge
	for _, st in strips do
		local d = (Vector3.new(st.a.X, 0, st.a.Z) - startPt).Magnitude
		if d < bestD then
			bestD, current = d, st
		end
	end
	local pts = {}
	while current do
		current.used = true
		local a, b = Vector3.new(current.a.X, 0, current.a.Z), Vector3.new(current.b.X, 0, current.b.Z)
		local n = math.max(1, math.floor((b - a).Magnitude / (4 * S)))
		for i = 0, n - 1 do
			table.insert(pts, a:Lerp(b, i / n))
		end
		local nextStrip, nd = nil, 3 * S -- next strip must start within 3 m of this one's end
		for _, st in strips do
			if not st.used then
				local d = (Vector3.new(st.a.X, 0, st.a.Z) - b).Magnitude
				if d < nd then
					nd, nextStrip = d, st
				end
			end
		end
		current = nextStrip
	end
	return pts
end

-- CLIENT: drive the handling loop with a pure-pursuit driver and a curvature speed planner.
-- opts: latG (cornering target, g), brakeG (planned braking, g), maxBrake (pedal), maxKmh
function TestDriver.lapLoop(name: string, opts: any?)
	local o = opts or {}
	local latG, brakeG, maxBrake, maxKmh = o.latG or 1.4, o.brakeG or 1.2, o.maxBrake or 0.6, o.maxKmh or 260
	local car = getCar()
	local core = car.PrimaryPart :: BasePart
	local pts = loopCentreline()
	local n = #pts
	-- curvature-limited speed at each point, then backward pass for braking distance
	local vmax = table.create(n, maxKmh / 3.6)
	for i = 2, n - 1 do
		local d1, d2 = pts[i] - pts[i - 1], pts[i + 1] - pts[i]
		if d1.Magnitude > 0.01 and d2.Magnitude > 0.01 then
			local ang = math.acos(math.clamp(d1.Unit:Dot(d2.Unit), -1, 1))
			local ds = (d1.Magnitude + d2.Magnitude) / 2 / S
			local k = ang / ds
			if k > 1e-5 then
				vmax[i] = math.min(vmax[i], math.sqrt(latG * 9.81 / k))
			end
		end
	end
	for i = n - 1, 1, -1 do
		local ds = (pts[i + 1] - pts[i]).Magnitude / S
		vmax[i] = math.min(vmax[i], math.sqrt(vmax[i + 1] ^ 2 + 2 * brakeG * 9.81 * ds))
	end

	local st: any = { idx = 1, maxBeta = 0, gndDropFrames = 0, airborneFrames = 0, maxOffM = 0, drops = {}, done = false, log = {} }
	TestDriver.results[name] = nil
	local faults0 = (car:GetAttribute("Tel_Faults") :: number?) or 0
	car:SetAttribute("TestInputEnabled", true)
	local t0 = os.clock()
	local nextLog = 0
	local conn: RBXScriptConnection
	conn = RunService.PreSimulation:Connect(function()
		local t = os.clock() - t0
		local a: any = car:GetAttributes()
		local pos = Vector3.new(core.Position.X, 0, core.Position.Z)
		local searchEnd = math.min(n, st.idx + 30)
		local bestI, bestD = st.idx, math.huge
		for i = st.idx, searchEnd do
			local d = (pts[i] - pos).Magnitude
			if d < bestD then
				bestD, bestI = d, i
			end
		end
		st.idx = bestI
		st.maxOffM = math.max(st.maxOffM, bestD / S)
		local v = a.Tel_SpeedKmh / 3.6
		local ld = math.max(10, v * 0.55)
		local look = st.idx
		while look < n and (pts[look] - pos).Magnitude / S < ld do
			look += 1
		end
		local fwd = core.CFrame.LookVector
		fwd = Vector3.new(fwd.X, 0, fwd.Z).Unit
		local rgt = core.CFrame.RightVector
		rgt = Vector3.new(rgt.X, 0, rgt.Z).Unit
		local toT = pts[look] - pos
		local dist = math.max(toT.Magnitude / S, 1)
		local alpha = math.atan2(toT.Unit:Dot(rgt), toT.Unit:Dot(fwd))
		local delta = math.atan(3.6 * 2 * math.sin(alpha) / dist)
		local maxDelta = SteeringModel.maxRoadWheelAngleRad(VehicleConfig.Steering, v)
		local steer = math.clamp(delta / maxDelta, -1, 1)
		local vT = vmax[math.min(n, st.idx + 2)]
		local thr, brk = 0, 0
		if v < vT - 0.5 then
			thr = math.clamp((vT - v) * 0.2, 0, 1)
		elseif v > vT + 1 then
			brk = math.clamp((v - vT) * 0.08, 0, maxBrake)
		end
		car:SetAttribute("TestThrottle", thr)
		car:SetAttribute("TestBrake", brk)
		car:SetAttribute("TestSteer", steer)

		local beta = a.Tel_SideslipDeg or 0
		if v > 5 then
			st.maxBeta = math.max(st.maxBeta, math.abs(beta))
		end
		local gnd = a.Tel_Grounded or 4
		if gnd < 4 then
			st.gndDropFrames += 1
			if gnd == 0 then
				st.airborneFrames += 1
			end
			if #st.drops < 12 then
				table.insert(st.drops, string.format("t=%.2f x=%.0f n=%.0f v=%.0f gnd=%d off=%.1fm", t, core.Position.X * 0.28, -core.Position.Z * 0.28, a.Tel_SpeedKmh, gnd, bestD / S))
			end
		end
		if t >= nextLog then
			nextLog += 1
			table.insert(st.log, string.format(
				"t=%5.1f x=%5.0f n=%5.0f v=%5.1f/%5.1f G%s thr%.2f brk%.2f str%+.2f yaw%+6.1f β%+5.1f lat%+.2f lon%+.2f gnd%d off%.1f susp %+3.0f %+3.0f %+3.0f %+3.0f mm Fz %4.0f %4.0f %4.0f %4.0f",
				t, core.Position.X * 0.28, -core.Position.Z * 0.28, a.Tel_SpeedKmh, vT * 3.6, tostring(a.Tel_Gear), thr, brk, steer, a.Tel_YawRateDeg, beta, a.Tel_LatG, a.Tel_LongG, gnd, bestD / S,
				(a.Tel_X_FL or 0) * 1000, (a.Tel_X_FR or 0) * 1000, (a.Tel_X_RL or 0) * 1000, (a.Tel_X_RR or 0) * 1000,
				a.Tel_Fz_FL, a.Tel_Fz_FR, a.Tel_Fz_RL, a.Tel_Fz_RR))
		end
		local finished = st.idx >= n - 2
		local spun = math.abs(beta) > 25 and v > 5
		if finished or spun or t > 120 then
			conn:Disconnect()
			car:SetAttribute("TestInputEnabled", false)
			st.result = if spun then "SPUN" elseif finished then "COMPLETED" else "TIMEOUT"
			st.time = t
			st.faults = ((car:GetAttribute("Tel_Faults") :: number?) or 0) - faults0
			st.points = n
			st.done = true
			TestDriver.results[name] = st
		end
	end)
end

function TestDriver.lapReport(name: string): string
	local st = TestDriver.results[name]
	if not st then
		return name .. ": not finished"
	end
	return string.format("== %s: %s in %.1f s (%d pts) | maxβ %.1f° | contact-loss frames %d (all-wheels-airborne %d) | max off-centre %.1f m | faults %d\n-- contact losses:\n%s\n-- log:\n%s",
		name, st.result, st.time, st.points, st.maxBeta, st.gndDropFrames, st.airborneFrames, st.maxOffM, st.faults,
		table.concat(st.drops, "\n"), table.concat(st.log, "\n"))
end

function TestDriver.await(name: string, timeout: number?): boolean
	local t = os.clock()
	while not TestDriver.results[name] and os.clock() - t < (timeout or 20) do
		task.wait(0.2)
	end
	return TestDriver.results[name] ~= nil
end

return TestDriver
