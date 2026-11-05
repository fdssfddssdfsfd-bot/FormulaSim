--!strict
--[[
	VehicleController  (Client - runs only on the driver's machine, which has network
	ownership of the car assembly)

	Each physics step (RunService.PreSimulation - tied to the simulation, not to rendering):
	  1. read smoothed input; read rigid-body state and convert to SI
	  2. aerodynamics: drag at the CoM, downforce at each axle
	  3. suspension per wheel: tyre-shaped spherecast -> compression -> spring + damper +
	     anti-roll bar = tyre normal load (load transfer and downforce emerge physically)
	  4. contact-patch velocity in the wheel frame
	  5. torques: engine (torque curve, rev limiter, engine braking) -> 8-speed gearbox ->
	     limited-slip differential; brake torque per wheel (bias, optional ABS); optional TC
	  6. wheel spin integration, WheelSubsteps per step, semi-implicit (linearised tyre force)
	     so the stiff wheel/tyre coupling stays stable at any frame rate:
	        I * domega/dt = T_drive - r * Fx(omega) - friction(brake + rolling resistance)
	     Friction torque can stop a wheel but never reverse it -> real lockup.
	  7. average tyre force over the substeps -> VectorForce at the contact point
	  8. telemetry

	The engine integrates the forces; chassis velocity and CFrame are never set directly.

	Remaining simplification: parallel steer (no Ackermann yet).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = script.Parent.Parent:WaitForChild("Shared")
local UnitConversion = require(Shared:WaitForChild("UnitConversion"))
local TireModel = require(Shared:WaitForChild("TireModel"))
local SteeringModel = require(Shared:WaitForChild("SteeringModel"))
local AeroModel = require(Shared:WaitForChild("AeroModel"))
local BrakeModel = require(Shared:WaitForChild("BrakeModel"))
local DifferentialModel = require(Shared:WaitForChild("DifferentialModel"))
local TransmissionModel = require(Shared:WaitForChild("TransmissionModel"))
local SuspensionModel = require(Shared:WaitForChild("SuspensionModel"))

local WHEEL_NAMES = { "FL", "FR", "RL", "RR" }
local MAX_FORCE_N = 1e6 -- invariant: anything above this is a numerical fault
local OMEGA_PROBE = 0.05 -- rad/s, finite-difference step for dFx/domega
local IS_STUDIO = RunService:IsStudio()

export type Wheel = {
	name: string,
	isFront: boolean,
	isLeft: boolean,
	isDriven: boolean,
	radiusM: number,
	center: Attachment,
	contact: Attachment,
	force: VectorForce,
	motor: Motor6D?,
	spinAngle: number,
	omega: number, -- rad/s, + = rolling forward
	absFactor: number,
	-- per-step state
	grounded: boolean,
	fz: number, -- tyre normal load = suspension force (N)
	massShareKg: number,
	staticLoadN: number,
	compressionM: number, -- + = compressed beyond static ride height
	prevX: number?,
	springN: number,
	damperN: number,
	vLong: number,
	vLat: number,
	heading: Vector3, -- unit, along the ground at the contact
	lateral: Vector3, -- unit, wheel's right along the ground
	steerRad: number,
	driveTorqueNm: number,
	brakeTorqueNm: number,
	fxN: number,
	fyN: number,
	slipRatio: number,
	slipAngleRad: number,
	combinedSlip: number,
	utilization: number,
}

local VehicleController = {}
VehicleController.__index = VehicleController

local function isFiniteVector(v: Vector3): boolean
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z and v.Magnitude < MAX_FORCE_N
end

function VehicleController.new(car: Model, config: any, input: any)
	local self = setmetatable({}, VehicleController)
	self.car = car
	self.config = config
	self.input = input
	local core = car:WaitForChild("MassCore") :: BasePart
	self.core = core
	self.aeroForce = core:WaitForChild("AeroForce") :: VectorForce
	self.downforceFront = core:WaitForChild("DownforceFront") :: VectorForce
	self.downforceRear = core:WaitForChild("DownforceRear") :: VectorForce
	self.transmission = TransmissionModel.new(config.Engine, config.Transmission)
	self.connection = nil :: RBXScriptConnection?
	self.prevVelocity = nil :: Vector3?
	self.axMs2 = 0
	self.ayMs2 = 0
	self.tcFactor = 1
	self.absEnabled = config.Assists.ABS == true
	self.tcEnabled = config.Assists.TC == true
	self.needsWheelInit = true
	self.faultCount = 0

	local wheels: { Wheel } = {}
	for _, name in WHEEL_NAMES do
		local center = core:WaitForChild("Wheel_" .. name) :: Attachment
		table.insert(wheels, {
			name = name,
			isFront = center:GetAttribute("IsFront") == true,
			isLeft = center:GetAttribute("IsLeft") == true,
			isDriven = center:GetAttribute("IsDriven") == true,
			radiusM = (center:GetAttribute("RadiusM") :: number?) or 0.36,
			center = center,
			contact = core:WaitForChild("Contact_" .. name) :: Attachment,
			force = core:WaitForChild("TireForce_" .. name) :: VectorForce,
			motor = core:FindFirstChild("WheelMotor_" .. name) :: Motor6D?,
			spinAngle = 0,
			omega = 0,
			absFactor = 1,
			grounded = false,
			fz = 0,
			massShareKg = 0,
			staticLoadN = 0,
			compressionM = 0,
			prevX = nil,
			springN = 0,
			damperN = 0,
			vLong = 0,
			vLat = 0,
			heading = Vector3.zero,
			lateral = Vector3.zero,
			steerRad = 0,
			driveTorqueNm = 0,
			brakeTorqueNm = 0,
			fxN = 0,
			fyN = 0,
			slipRatio = 0,
			slipAngleRad = 0,
			combinedSlip = 0,
			utilization = 0,
		})
	end
	self.wheels = wheels
	self.wheelByName = {} :: { [string]: Wheel }
	for _, w in wheels do
		self.wheelByName[w.name] = w
	end

	-- Geometry for load transfer, measured from the built car (always matches CarBuilder).
	local fl = self.wheelByName.FL.contact.Position
	local fr = self.wheelByName.FR.contact.Position
	local rl = self.wheelByName.RL.contact.Position
	local rr = self.wheelByName.RR.contact.Position
	self.wheelbaseM = UnitConversion.studsToMeters(rl.Z - fl.Z)
	self.frontTrackM = UnitConversion.studsToMeters(fr.X - fl.X)
	self.rearTrackM = UnitConversion.studsToMeters(rr.X - rl.X)
	self.cgHeightM = UnitConversion.studsToMeters(-fl.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = true
	local ignore: { Instance } = { car }
	local character = Players.LocalPlayer.Character
	if character then
		table.insert(ignore, character)
	end
	params.FilterDescendantsInstances = ignore
	self.rayParams = params

	self.telemetry = {
		speedKmh = 0,
		forwardSpeedMs = 0,
		gearLabel = self.transmission:gearLabel(),
		rpm = config.Engine.IdleRpm,
		autoShift = self.transmission.autoShift,
		throttle = 0,
		brake = 0,
		steer = 0,
		steerAngleDeg = 0,
		massKg = 0,
		groundedCount = 0,
		longG = 0,
		latG = 0,
		yawRateDegS = 0,
		sideslipDeg = 0,
		axleTorqueNm = 0,
		frontBrakeTorqueNm = 0,
		rearBrakeTorqueNm = 0,
		downforceN = 0,
		dragN = 0,
		absEnabled = self.absEnabled,
		tcEnabled = self.tcEnabled,
		tcFactor = 1,
		faultCount = 0,
		cameraMode = "",
		wheels = wheels,
	}

	input:bindAction("ShiftUp", function()
		self.transmission:requestShift(1, self.telemetry.forwardSpeedMs)
	end)
	input:bindAction("ShiftDown", function()
		self.transmission:requestShift(-1, self.telemetry.forwardSpeedMs)
	end)
	input:bindAction("ToggleAutoShift", function()
		self.transmission:setAutoShift(not self.transmission.autoShift)
	end)
	input:bindAction("ToggleABS", function()
		self.absEnabled = not self.absEnabled
	end)
	input:bindAction("ToggleTC", function()
		self.tcEnabled = not self.tcEnabled
	end)

	self.resetConnection = car:GetAttributeChangedSignal("ResetCount"):Connect(function()
		self:_onReset()
	end)
	return self
end

function VehicleController:_onReset()
	self.needsWheelInit = true
	self.prevVelocity = nil
	self.axMs2, self.ayMs2 = 0, 0
	self.tcFactor = 1
	for _, w in self.wheels do
		w.omega = 0
		w.absFactor = 1
		w.prevX = nil
	end
end


function VehicleController:start()
	if self.connection then
		return
	end
	self.connection = RunService.PreSimulation:Connect(function(dt: number)
		self:_step(dt)
	end)
end

-- One semi-implicit substep of wheel spin for wheel w. Returns the tyre result at the new omega.
function VehicleController:_integrateWheel(w: Wheel, h: number, dtFrame: number, extraInertia: number)
	local tireCfg = self.config.Tire
	local axle = if w.isFront then tireCfg.Front else tireCfg.Rear
	local r = w.radiusM

	local res0 = TireModel.evaluate(axle, tireCfg, w.fz, w.vLong, w.vLat, w.omega * r, w.massShareKg, dtFrame)
	local dFdOmega = 0
	if w.fz > 0 then
		local res1 = TireModel.evaluate(axle, tireCfg, w.fz, w.vLong, w.vLat, (w.omega + OMEGA_PROBE) * r, w.massShareKg, dtFrame)
		dFdOmega = math.max((res1.fxN - res0.fxN) / OMEGA_PROBE, 0)
	end

	-- Implicit in the tyre force: (I + h r dFx/domega) * d_omega = h * (T_drive - r * Fx)
	local inertiaEff = axle.WheelInertiaKgM2 + extraInertia + h * r * dFdOmega
	local omegaFree = w.omega + h * (w.driveTorqueNm - r * res0.fxN) / inertiaEff

	-- Brake + rolling resistance: friction torques that can stop the wheel but never reverse it.
	local frictionNm = w.brakeTorqueNm + axle.RollingResistance * w.fz * r
	local decel = h * frictionNm / inertiaEff
	local omegaOld = w.omega
	local omegaNew
	if omegaFree > decel then
		omegaNew = omegaFree - decel
	elseif omegaFree < -decel then
		omegaNew = omegaFree + decel
	else
		omegaNew = 0
	end

	-- Overshoot guard: past the grip peak the tyre curve is flat, so one step can carry the
	-- wheel through road speed. It may only cross road speed if the net torque AT road speed
	-- (where the longitudinal tyre force is ~0) points that way; otherwise stop at road speed
	-- and let the next substep (steep linear region, implicit) settle it.
	if w.fz > 0 then
		local omegaRoad = w.vLong / r
		local before = omegaOld - omegaRoad
		local after = omegaNew - omegaRoad
		if before * after < 0 then
			local netAtRoad = w.driveTorqueNm - (if omegaRoad >= 0 then frictionNm else -frictionNm)
			if netAtRoad * before > 0 then
				omegaNew = omegaRoad
			end
		end
	end
	w.omega = omegaNew

	if w.fz <= 0 then
		return res0
	end
	return TireModel.evaluate(axle, tireCfg, w.fz, w.vLong, w.vLat, w.omega * r, w.massShareKg, dtFrame)
end

function VehicleController:_step(rawDt: number)
	local dt = math.clamp(rawDt, 1 / 240, 1 / 20)
	local cfg = self.config
	local core: BasePart = self.core
	if not core.Parent then
		return
	end

	local cf = core.CFrame
	local forward, right, up = cf.LookVector, cf.RightVector, cf.UpVector
	local velocity = UnitConversion.velocityToMs(core.AssemblyLinearVelocity)
	local forwardSpeed = velocity:Dot(forward)

	local inputState = self.input:update(dt, forwardSpeed)
	local massKg = UnitConversion.rmuToKg(core.AssemblyMass)
	local g = UnitConversion.studsToMeters(Workspace.Gravity)

	-- 1. Filtered body-frame acceleration (telemetry only; loads now come from the springs)
	if self.prevVelocity then
		local accel = (velocity - self.prevVelocity) / dt
		local alpha = 1 - math.exp(-dt / cfg.Telemetry.AccelFilterS)
		self.axMs2 += (accel:Dot(forward) - self.axMs2) * alpha
		self.ayMs2 += (accel:Dot(right) - self.ayMs2) * alpha
	end
	self.prevVelocity = velocity

	-- 2. Aerodynamics (downforce is applied as a body force; the springs carry it to the tyres)
	local aero = AeroModel.compute(cfg.Aero, velocity, forward)
	local dragN = aero.dragN
	local dfFrontN, dfRearN = aero.downforceFrontN, aero.downforceRearN

	-- 3. Suspension: tyre-shaped spherecast per wheel -> compression -> spring/damper force
	local fwf = cfg.Mass.FrontWeightFraction
	local susp = cfg.Suspension
	local startAboveM = susp.ProbeStartAboveM
	local steerAngle = SteeringModel.roadWheelAngleRad(cfg.Steering, inputState.steer, forwardSpeed)

	local grounded = 0
	for _, w in self.wheels do
		local axleShare = if w.isFront then fwf else 1 - fwf
		w.massShareKg = massKg * axleShare * 0.5
		w.staticLoadN = massKg * g * axleShare * 0.5
		local steer = if w.isFront then steerAngle else 0
		w.steerRad = steer
		w.grounded = false
		w.fz = 0
		w.springN, w.damperN = 0, 0
		w.vLong = forwardSpeed
		w.vLat = 0

		local origin = w.center.WorldPosition + up * UnitConversion.metersToStuds(startAboveM)
		local travel = UnitConversion.metersToStuds(startAboveM + susp.MaxDroopM)
		local hit = Workspace:Spherecast(origin, UnitConversion.metersToStuds(w.radiusM), -up * travel, self.rayParams)
		if hit then
			-- wheel centre offset from static ride height (+ = compressed / wheel pushed up)
			local x = math.min(startAboveM - UnitConversion.studsToMeters(hit.Distance), susp.MaxCompressionM)
			local xdot = if w.prevX then (x - w.prevX) / dt else 0
			w.prevX = x
			w.compressionM = x
			local axleSusp = if w.isFront then susp.Front else susp.Rear
			w.springN, w.damperN = SuspensionModel.cornerForceN(axleSusp, susp, w.staticLoadN, x, xdot, dt)

			local normal = hit.Normal
			local headingRaw = forward * math.cos(steer) + right * math.sin(steer)
			local heading = headingRaw - normal * headingRaw:Dot(normal)
			if heading.Magnitude > 1e-4 then
				heading = heading.Unit
				local lateral = heading:Cross(normal) -- wheel's right
				local contactVel = UnitConversion.velocityToMs(core:GetVelocityAtPosition(hit.Position))
				local ground = hit.Instance
				if not ground.Anchored then
					contactVel -= UnitConversion.velocityToMs(ground:GetVelocityAtPosition(hit.Position))
				end
				w.grounded = true
				grounded += 1
				w.vLong = contactVel:Dot(heading)
				w.vLat = contactVel:Dot(lateral)
				w.contact.WorldPosition = hit.Position
				w.heading = heading
				w.lateral = lateral
			end
		else
			w.prevX = nil
			w.compressionM = -susp.MaxDroopM -- full droop, no contact
		end
	end

	-- Anti-roll bars, then the tyre normal load = clamped suspension force.
	for _, pair in { { "FL", "FR" }, { "RL", "RR" } } do
		local l, r = self.wheelByName[pair[1]], self.wheelByName[pair[2]]
		local axleSusp = if l.isFront then susp.Front else susp.Rear
		local arb = SuspensionModel.antiRollN(axleSusp, l.compressionM, r.compressionM)
		if l.grounded then
			l.fz = SuspensionModel.clampNormal(susp, l.staticLoadN, l.springN + l.damperN + arb)
		end
		if r.grounded then
			r.fz = SuspensionModel.clampNormal(susp, r.staticLoadN, r.springN + r.damperN - arb)
		end
	end

	-- Wheels start rolling at road speed (session start / after reset).
	if self.needsWheelInit then
		for _, w in self.wheels do
			w.omega = if w.grounded then w.vLong / w.radiusM else 0
		end
		self.needsWheelInit = false
	end

	-- 5. Torques
	local rl, rr = self.wheelByName.RL, self.wheelByName.RR
	local transmission = self.transmission
	-- Road-speed wheel omega from body speed (not wheel speed, which lies during spin/lockup)
	transmission:update(dt, (rl.omega + rr.omega) * 0.5, forwardSpeed / rl.radiusM)
	local tcScale = if self.tcEnabled then self.tcFactor else 1
	local frontBrakeNm, rearBrakeNm = BrakeModel.wheelTorquesNm(cfg.Brakes, inputState.brake)
	for _, w in self.wheels do
		local base = if w.isFront then frontBrakeNm else rearBrakeNm
		w.brakeTorqueNm = base * (if self.absEnabled then w.absFactor else 1)
		w.driveTorqueNm = 0
	end

	-- 6. Wheel spin substeps
	local substeps = math.max(1, cfg.Tire.WheelSubsteps)
	local h = dt / substeps
	local sumFx: { [Wheel]: number } = {}
	local sumFy: { [Wheel]: number } = {}
	for _, w in self.wheels do
		sumFx[w], sumFy[w] = 0, 0
	end
	local axleTorqueNm = 0
	for _ = 1, substeps do
		local drive = transmission:driveState(inputState.throttle, (rl.omega + rr.omega) * 0.5, tcScale)
		axleTorqueNm = drive.axleTorqueNm
		local tL, tR = DifferentialModel.split(cfg.Differential, axleTorqueNm, rl.omega, rr.omega)
		rl.driveTorqueNm, rr.driveTorqueNm = tL, tR
		for _, w in self.wheels do
			local res = self:_integrateWheel(w, h, dt, if w.isDriven then drive.reflectedInertiaPerWheel else 0)
			sumFx[w] += res.fxN
			sumFy[w] += res.fyN
			w.slipRatio = res.slipRatio
			w.slipAngleRad = res.slipAngleRad
			w.combinedSlip = res.combinedSlip
			w.utilization = res.utilization
		end
	end

	-- 7. Apply forces
	for _, w in self.wheels do
		local forceN = Vector3.zero
		if w.grounded then
			w.fxN = sumFx[w] / substeps
			w.fyN = sumFy[w] / substeps
			forceN = up * w.fz + w.heading * w.fxN + w.lateral * w.fyN
		else
			w.fxN, w.fyN, w.utilization, w.combinedSlip = 0, 0, 0, 0
		end
		if not isFiniteVector(forceN) or w.omega ~= w.omega then
			self.faultCount += 1
			if self.faultCount == 1 then
				warn("[FormulaSim] non-finite tyre state on", w.name, forceN, w.omega)
			end
			forceN = Vector3.zero
			if w.omega ~= w.omega then
				w.omega = 0
			end
		end
		w.force.Force = UnitConversion.forceToRoblox(forceN)

		w.spinAngle = (w.spinAngle - w.omega * dt) % (2 * math.pi)
		if w.motor then
			w.motor.Transform = CFrame.new(0, UnitConversion.metersToStuds(w.compressionM), 0)
				* CFrame.Angles(0, -w.steerRad, 0) * CFrame.Angles(w.spinAngle, 0, 0)
		end
	end

	if not isFiniteVector(dragN) then
		self.faultCount += 1
		dragN = Vector3.zero
	end
	self.aeroForce.Force = UnitConversion.forceToRoblox(dragN)
	self.downforceFront.Force = UnitConversion.forceToRoblox(-up * dfFrontN)
	self.downforceRear.Force = UnitConversion.forceToRoblox(-up * dfRearN)

	-- Assists (use this step's slip for the next step)
	local braking = inputState.brake > 0
	for _, w in self.wheels do
		w.absFactor = if self.absEnabled then BrakeModel.updateAbsFactor(cfg.Assists, w.absFactor, w.slipRatio, braking, dt) else 1
	end
	if self.tcEnabled then
		-- Proportional: cut harder the further wheelspin exceeds the target, recover steadily.
		local target = cfg.Assists.TcSlipTarget
		local excess = (math.max(rl.slipRatio, rr.slipRatio) - target) / target
		if excess > 0 then
			self.tcFactor = math.max(0.05, self.tcFactor - cfg.Assists.TcRate * excess * dt)
		else
			self.tcFactor = math.min(1, self.tcFactor + cfg.Assists.TcRecoverRate * dt)
		end
	else
		self.tcFactor = 1
	end

	-- 8. Telemetry
	local t = self.telemetry
	local yawRate = core.AssemblyAngularVelocity:Dot(up) -- + = turning left (CCW from above)
	t.forwardSpeedMs = forwardSpeed
	t.speedKmh = UnitConversion.msToKmh(velocity.Magnitude)
	t.throttle = inputState.throttle
	t.brake = inputState.brake
	t.steer = inputState.steer
	t.steerAngleDeg = math.deg(steerAngle)
	t.massKg = massKg
	t.groundedCount = grounded
	t.longG = self.axMs2 / g
	t.latG = self.ayMs2 / g
	t.yawRateDegS = -math.deg(yawRate) -- reported + = turning right, to match steering sign
	t.sideslipDeg = if velocity.Magnitude > 1 then math.deg(math.atan2(velocity:Dot(right), math.abs(forwardSpeed))) else 0
	t.axleTorqueNm = axleTorqueNm
	t.rpm = transmission.rpm
	t.gearLabel = transmission:gearLabel()
	t.autoShift = transmission.autoShift
	t.frontBrakeTorqueNm = self.wheelByName.FL.brakeTorqueNm + self.wheelByName.FR.brakeTorqueNm
	t.rearBrakeTorqueNm = rl.brakeTorqueNm + rr.brakeTorqueNm
	t.downforceN = dfFrontN + dfRearN
	t.dragN = dragN.Magnitude
	t.absEnabled = self.absEnabled
	t.tcEnabled = self.tcEnabled
	t.tcFactor = self.tcFactor
	t.faultCount = self.faultCount

	if IS_STUDIO then
		-- Client-local attributes, read by automated Studio tests.
		local car = self.car
		car:SetAttribute("Tel_SpeedKmh", t.speedKmh)
		car:SetAttribute("Tel_ForwardMs", forwardSpeed)
		car:SetAttribute("Tel_Throttle", t.throttle)
		car:SetAttribute("Tel_Brake", t.brake)
		car:SetAttribute("Tel_Steer", t.steer)
		car:SetAttribute("Tel_SteerDeg", t.steerAngleDeg)
		car:SetAttribute("Tel_Grounded", grounded)
		car:SetAttribute("Tel_LongG", t.longG)
		car:SetAttribute("Tel_LatG", t.latG)
		car:SetAttribute("Tel_YawRateDeg", t.yawRateDegS)
		car:SetAttribute("Tel_SideslipDeg", t.sideslipDeg)
		car:SetAttribute("Tel_AxleTorque", axleTorqueNm)
		car:SetAttribute("Tel_Rpm", transmission.rpm)
		car:SetAttribute("Tel_Gear", t.gearLabel)
		car:SetAttribute("Tel_Faults", self.faultCount)
		for _, w in self.wheels do
			car:SetAttribute("Tel_K_" .. w.name, w.slipRatio)
			car:SetAttribute("Tel_A_" .. w.name, math.deg(w.slipAngleRad))
			car:SetAttribute("Tel_Fz_" .. w.name, w.fz)
			car:SetAttribute("Tel_U_" .. w.name, w.utilization)
			car:SetAttribute("Tel_S_" .. w.name, w.combinedSlip)
			car:SetAttribute("Tel_W_" .. w.name, w.omega)
			car:SetAttribute("Tel_X_" .. w.name, w.compressionM)
		end
	end
end

function VehicleController:destroy()
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end
	self.resetConnection:Disconnect()
	for _, w in self.wheels do
		w.force.Force = Vector3.zero
	end
	self.aeroForce.Force = Vector3.zero
	self.downforceFront.Force = Vector3.zero
	self.downforceRear.Force = Vector3.zero
end

return VehicleController
