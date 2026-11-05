--!strict
--[[
	FormulaSimClient  (Client bootstrap)

	Watches the local character. When it sits in a FormulaSim seat, starts a driving session:
	  InputController -> VehicleController (physics, PreSimulation)
	  CameraController (render step)
	  TelemetryController (HUD, render step)
	When the character leaves the seat or dies, the session is torn down and the default
	camera is restored.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local root = ReplicatedStorage:WaitForChild("FormulaSim")
local Shared = root:WaitForChild("Shared")
local ClientModules = root:WaitForChild("Client")
local VehicleConfig = require(Shared:WaitForChild("VehicleConfig"))
local InputController = require(ClientModules:WaitForChild("InputController"))
local VehicleController = require(ClientModules:WaitForChild("VehicleController"))
local CameraController = require(ClientModules:WaitForChild("CameraController"))
local TelemetryController = require(ClientModules:WaitForChild("TelemetryController"))
local requestReset = root:WaitForChild("Remotes"):WaitForChild("RequestReset") :: RemoteEvent

local player = Players.LocalPlayer

type Session = {
	seat: BasePart,
	input: any,
	vehicle: any,
	camera: any,
	hud: any,
	hudConnection: RBXScriptConnection,
}

local session: Session? = nil
local startToken = 0

local function stopSession()
	startToken += 1
	local s = session
	if not s then
		return
	end
	session = nil
	s.hudConnection:Disconnect()
	s.vehicle:destroy()
	s.camera:destroy()
	s.hud:destroy()
	s.input:destroy()
end

local function startSession(seat: BasePart, character: Model)
	stopSession()
	local token = startToken
	local car = seat.Parent
	if not (car and car:IsA("Model")) then
		return
	end
	local input = InputController.new(VehicleConfig.Input)
	local vehicle = VehicleController.new(car, VehicleConfig, input) -- may yield on WaitForChild
	if token ~= startToken then
		-- the player left the seat while we were setting up
		vehicle:destroy()
		input:destroy()
		return
	end
	local camera = CameraController.new(VehicleConfig.Camera, vehicle.core, character)
	local hud = TelemetryController.new()

	input:bindAction("Reset", function()
		requestReset:FireServer()
	end)
	input:bindAction("Camera", function()
		camera:cycleMode()
	end)
	input:bindAction("ToggleDebug", function()
		hud:toggleDebug()
	end)
	input:setOverrideSource(car) -- Studio-only automated test inputs

	vehicle:start()
	camera:start()
	local hudConnection = RunService.RenderStepped:Connect(function(dt: number)
		local t = vehicle.telemetry
		t.cameraMode = camera.mode
		hud:update(t, dt)
	end)

	session = {
		seat = seat,
		input = input,
		vehicle = vehicle,
		camera = camera,
		hud = hud,
		hudConnection = hudConnection,
	}
end

local function watchCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local function evaluate()
		local seatPart = humanoid.SeatPart
		if seatPart and seatPart:GetAttribute("FormulaSimSeat") then
			if not session or session.seat ~= seatPart then
				startSession(seatPart, character)
			end
		else
			stopSession()
		end
	end
	humanoid:GetPropertyChangedSignal("SeatPart"):Connect(evaluate)
	humanoid.Died:Connect(stopSession)
	evaluate()
end

player.CharacterAdded:Connect(watchCharacter)
if player.Character then
	task.spawn(watchCharacter, player.Character)
end
