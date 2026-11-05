--!strict
--[[
	InputController  (Client)

	Collects raw driver input and turns digital keyboard presses into smooth analogue
	signals with rate limits (configured in VehicleConfig.Input). Smoothing only shapes
	the *driver's hands*; it does not touch tyre behaviour.

	Continuous controls (polled every simulation step): Throttle, Brake, SteerLeft/Right.
	Discrete actions (edge-triggered): any other binding name, dispatched to handlers
	registered with bindAction(name, fn).

	Signs: steer -1 = full left, +1 = full right.

	Braking: Brake alone applies KeyboardBrakeLevel (moderate); Brake + BrakeFull applies 100%.

	Studio-only test override: if the override source (the car model) has attribute
	TestInputEnabled = true, the values of TestThrottle / TestBrake / TestSteer are used
	directly. This lets automated tests drive with exact analogue inputs. It is ignored
	outside Studio.
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local IS_STUDIO = RunService:IsStudio()

export type InputState = {
	throttle: number,
	brake: number,
	steer: number,
}

local InputController = {}
InputController.__index = InputController

local function anyDown(keys: { Enum.KeyCode }): boolean
	for _, key in keys do
		if UserInputService:IsKeyDown(key) then
			return true
		end
	end
	return false
end

local function approach(current: number, target: number, rate: number, dt: number): number
	local delta = target - current
	local step = rate * dt
	if math.abs(delta) <= step then
		return target
	end
	return current + math.sign(delta) * step
end

function InputController.new(inputConfig: any)
	local self = setmetatable({}, InputController)
	self.config = inputConfig
	self.state = { throttle = 0, brake = 0, steer = 0 } :: InputState
	self.handlers = {} :: { [string]: () -> () }
	self.overrideSource = nil :: Instance?
	self.connection = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		for action, keys in self.config.Bindings do
			local handler = self.handlers[action]
			if handler and table.find(keys, input.KeyCode) then
				task.spawn(handler)
			end
		end
	end)
	return self
end

function InputController:bindAction(action: string, handler: () -> ())
	self.handlers[action] = handler
end

function InputController:setOverrideSource(source: Instance?)
	self.overrideSource = source
end

-- speedMs is used only to slow keyboard steering at high speed (input shaping, not physics).
function InputController:update(dt: number, speedMs: number?): InputState
	local cfg = self.config
	local b = cfg.Bindings
	local s: InputState = self.state

	local source = self.overrideSource
	if IS_STUDIO and source and source:GetAttribute("TestInputEnabled") == true then
		s.throttle = math.clamp((source:GetAttribute("TestThrottle") :: number?) or 0, 0, 1)
		s.brake = math.clamp((source:GetAttribute("TestBrake") :: number?) or 0, 0, 1)
		s.steer = math.clamp((source:GetAttribute("TestSteer") :: number?) or 0, -1, 1)
		return s
	end
	local active = UserInputService:GetFocusedTextBox() == nil -- ignore keys while typing in chat

	local throttleTarget = if active and anyDown(b.Throttle) then 1 else 0
	local brakeTarget = 0
	if active and anyDown(b.Brake) then
		brakeTarget = if anyDown(b.BrakeFull) then 1 else cfg.KeyboardBrakeLevel
	end
	local steerTarget = 0
	if active then
		if anyDown(b.SteerRight) then
			steerTarget += 1
		end
		if anyDown(b.SteerLeft) then
			steerTarget -= 1
		end
	end

	s.throttle = approach(s.throttle, throttleTarget, if throttleTarget > s.throttle then cfg.ThrottleRiseRate else cfg.ThrottleFallRate, dt)
	s.brake = approach(s.brake, brakeTarget, if brakeTarget > s.brake then cfg.BrakeRiseRate else cfg.BrakeFallRate, dt)
	local returning = steerTarget == 0 or (s.steer ~= 0 and math.sign(steerTarget) ~= math.sign(s.steer))
	local speedFrac = math.clamp(math.abs(speedMs or 0) / cfg.SteerRateBlendSpeedMs, 0, 1)
	local attackRate = cfg.SteerRate + (cfg.SteerRateHighSpeed - cfg.SteerRate) * speedFrac
	s.steer = approach(s.steer, steerTarget, if returning then cfg.SteerReturnRate else attackRate, dt)
	return s
end

function InputController:destroy()
	self.connection:Disconnect()
	self.handlers = {}
end

return InputController
