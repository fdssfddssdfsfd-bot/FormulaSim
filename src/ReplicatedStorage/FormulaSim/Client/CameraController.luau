--!strict
--[[
	CameraController  (Client, render-step only - never affects physics)

	Modes (cycle with the Camera binding, default C):
	  Chase   - behind and above the car. Only the camera's *direction* is smoothed, so it
	            never lags further behind at high speed; it stays level (ignores roll/pitch).
	  Cockpit - rigidly attached at the driver's eye point; the driver's own body is hidden
	            locally.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = script.Parent.Parent:WaitForChild("Shared")
local UnitConversion = require(Shared:WaitForChild("UnitConversion"))
local S = UnitConversion.metersToStuds

local BIND_NAME = "FormulaSimCamera"
local MODES = { "Chase", "Cockpit" }

local CameraController = {}
CameraController.__index = CameraController

function CameraController.new(cameraConfig: any, core: BasePart, character: Model?)
	local self = setmetatable({}, CameraController)
	self.config = cameraConfig
	self.core = core
	self.character = character
	self.modeIndex = 1
	self.mode = MODES[1]
	self.smoothedDir = nil :: Vector3?
	self.characterHidden = false
	return self
end

function CameraController:start()
	Workspace.CurrentCamera.CameraType = Enum.CameraType.Scriptable
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt: number)
		self:_update(dt)
	end)
end

function CameraController:cycleMode()
	self.modeIndex = self.modeIndex % #MODES + 1
	self.mode = MODES[self.modeIndex]
	self.smoothedDir = nil
end

function CameraController:_setCharacterHidden(hidden: boolean)
	local character = self.character
	if not character then
		return
	end
	self.characterHidden = hidden
	local value = if hidden then 1 else 0
	for _, d in character:GetDescendants() do
		if d:IsA("BasePart") or d:IsA("Decal") then
			(d :: any).LocalTransparencyModifier = value
		end
	end
end

function CameraController:_update(dt: number)
	local camera = Workspace.CurrentCamera
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	local cf = self.core.CFrame

	if self.mode == "Cockpit" then
		local c = self.config.Cockpit
		camera.FieldOfView = c.FovDeg
		camera.CFrame = cf * CFrame.new(UnitConversion.vectorToStuds(c.OffsetM))
		self:_setCharacterHidden(true)
		return
	end

	if self.characterHidden then
		self:_setCharacterHidden(false)
	end
	local c = self.config.Chase
	local look = cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		flat = self.smoothedDir or Vector3.new(0, 0, -1)
	else
		flat = flat.Unit
	end
	local smoothed = self.smoothedDir or flat
	local alpha = 1 - math.exp(-c.DirectionStiffness * dt)
	local blended = smoothed:Lerp(flat, alpha)
	smoothed = if blended.Magnitude > 1e-3 then blended.Unit else flat
	self.smoothedDir = smoothed

	local pivot = cf.Position
	local camPos = pivot - smoothed * S(c.DistanceM) + Vector3.yAxis * S(c.HeightM)
	local target = pivot + smoothed * S(c.LookAheadM) + Vector3.yAxis * S(c.LookHeightM)
	camera.FieldOfView = c.FovDeg
	camera.CFrame = CFrame.lookAt(camPos, target)
end

function CameraController:destroy()
	RunService:UnbindFromRenderStep(BIND_NAME)
	self:_setCharacterHidden(false)
	local camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = 70
	local character = self.character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			camera.CameraSubject = humanoid
		end
	end
end

return CameraController
