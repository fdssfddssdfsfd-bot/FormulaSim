--!strict
--[[
	TransmissionModel  (Shared; one instance per car, holds gearbox state)

	Eight-speed sequential gearbox + reverse + neutral, final drive, driveline efficiency.

	  overall ratio  R = GearRatio * FinalDrive      (negative in reverse)
	  engine speed   rpm = mean rear wheel omega * R * 60 / (2 pi)   when the clutch is engaged
	  axle torque    T_axle = T_engine(rpm, throttle) * R * Efficiency
	  inertia        engine inertia reflected to the axle = I_engine * R^2 (split over the two
	                 rear wheels). In low gears this is large, so wheelspin builds progressively.

	Launch clutch: below LaunchRpm (scaled by throttle) the clutch slips and the engine is held
	at that speed; with zero throttle the clutch opens, so the car never stalls or creeps.
	Shifts cut drive for ShiftTimeS (seamless-shift approximation).
	AutoShift (optional, default on for keyboard play) shifts on engine rpm; pressing a shift
	key switches to manual. Auto decisions use the rpm the engine would have at ROAD speed
	(front wheel speed), so wheelspin cannot make it hunt between gears, and enforce a
	minimum time between automatic shifts.
]]

local EngineModel = require(script.Parent:WaitForChild("EngineModel"))

export type Params = {
	Ratios: { number },
	ReverseRatio: number,
	FinalDrive: number,
	Efficiency: number,
	ShiftTimeS: number,
	AutoShift: boolean,
	AutoUpshiftRpm: number,
	AutoDownshiftRpm: number,
	AutoMinShiftIntervalS: number,
}

export type DriveState = {
	axleTorqueNm: number,
	reflectedInertiaPerWheel: number,
	rpm: number,
	clutchSlipping: boolean,
}

local RADS_TO_RPM = 60 / (2 * math.pi)

local TransmissionModel = {}
TransmissionModel.__index = TransmissionModel

function TransmissionModel.new(engineParams: any, params: Params)
	local self = setmetatable({}, TransmissionModel)
	self.engine = engineParams
	self.params = params
	self.gear = 1
	self.shiftTimer = 0
	self.sinceShift = 0
	self.autoShift = params.AutoShift
	self.rpm = engineParams.IdleRpm
	return self
end

function TransmissionModel:overallRatio(gear: number?): number
	local g = gear or self.gear
	local p = self.params
	if g >= 1 then
		return p.Ratios[g] * p.FinalDrive
	elseif g == -1 then
		return -p.ReverseRatio * p.FinalDrive
	end
	return 0
end

function TransmissionModel:rpmAt(gear: number, rearOmega: number): number
	return rearOmega * self:overallRatio(gear) * RADS_TO_RPM
end

function TransmissionModel:gearLabel(): string
	if self.gear == -1 then
		return "R"
	elseif self.gear == 0 then
		return "N"
	end
	return tostring(self.gear)
end

function TransmissionModel:_setGear(target: number)
	local from = self.gear
	if target == from then
		return
	end
	self.gear = target
	self.shiftTimer = if from >= 1 and target >= 1 then self.params.ShiftTimeS else 0
	self.sinceShift = 0
end

-- Driver shift request (E / Q). Switches the gearbox to manual mode.
function TransmissionModel:requestShift(direction: number, forwardSpeedMs: number)
	self.autoShift = false
	local target = math.clamp(self.gear + direction, -1, #self.params.Ratios)
	if target == -1 and forwardSpeedMs > 1 then
		return -- reverse only when (nearly) stopped
	end
	if self.gear == -1 and target == 0 and forwardSpeedMs < -1 then
		return -- leave reverse only when (nearly) stopped
	end
	self:_setGear(target)
end

function TransmissionModel:setAutoShift(enabled: boolean)
	self.autoShift = enabled
	if enabled and self.gear < 1 then
		self:_setGear(1)
	end
end

-- Once per physics step: shift timer and automatic shifting.
-- rearOmega: driven wheel speed (actual engine speed); roadOmega: road-speed equivalent.
function TransmissionModel:update(dt: number, rearOmega: number, roadOmega: number)
	self.shiftTimer = math.max(0, self.shiftTimer - dt)
	self.sinceShift += dt
	if not self.autoShift or self.shiftTimer > 0 or self.gear < 1 then
		return
	end
	local p = self.params
	if self.sinceShift < p.AutoMinShiftIntervalS then
		return
	end
	local engineRpm = self:rpmAt(self.gear, rearOmega)
	local roadRpm = self:rpmAt(self.gear, roadOmega)
	if self.gear < #p.Ratios and math.max(engineRpm, roadRpm) > p.AutoUpshiftRpm
		and self:rpmAt(self.gear + 1, roadOmega) > p.AutoDownshiftRpm + 500 then
		-- upshift only into a gear the car can actually pull at this road speed
		self:_setGear(self.gear + 1)
	elseif self.gear > 1 and roadRpm < p.AutoDownshiftRpm and self:rpmAt(self.gear - 1, roadOmega) < p.AutoUpshiftRpm - 1000 then
		self:_setGear(self.gear - 1)
	end
end

-- Drive torque at the rear axle for the current rear wheel speed (called every substep).
-- torqueScale (0..1) is an engine torque reduction requested by traction control.
function TransmissionModel:driveState(throttle: number, rearOmega: number, torqueScale: number?): DriveState
	local scale = torqueScale or 1
	local e = self.engine
	local p = self.params
	if self.gear == 0 or self.shiftTimer > 0 then
		local target = if self.gear == 0 then e.IdleRpm + throttle * (e.LimiterRpm - e.IdleRpm) * 0.7 else self.rpm
		self.rpm = target
		return { axleTorqueNm = 0, reflectedInertiaPerWheel = 0, rpm = self.rpm, clutchSlipping = false }
	end

	local ratio = self:overallRatio()
	local coupledRpm = rearOmega * ratio * RADS_TO_RPM
	local launchRpm = e.IdleRpm + (e.LaunchRpm - e.IdleRpm) * math.clamp(throttle, 0, 1)

	if coupledRpm < launchRpm then
		-- Clutch slipping: engine held at launch speed; open clutch with no throttle.
		if throttle <= 0.01 then
			self.rpm = math.max(e.IdleRpm, coupledRpm)
			return { axleTorqueNm = 0, reflectedInertiaPerWheel = 0, rpm = self.rpm, clutchSlipping = true }
		end
		self.rpm = launchRpm
		local torque = math.max(EngineModel.torqueNm(e, launchRpm, throttle), 0) * scale
		return { axleTorqueNm = torque * ratio * p.Efficiency, reflectedInertiaPerWheel = 0, rpm = launchRpm, clutchSlipping = true }
	end

	self.rpm = coupledRpm
	local torque = EngineModel.torqueNm(e, coupledRpm, throttle)
	if torque > 0 then
		torque *= scale -- TC only reduces drive torque, never engine braking
	end
	return {
		axleTorqueNm = torque * ratio * p.Efficiency,
		reflectedInertiaPerWheel = e.InertiaKgM2 * ratio * ratio * 0.5,
		rpm = coupledRpm,
		clutchSlipping = false,
	}
end

return TransmissionModel
