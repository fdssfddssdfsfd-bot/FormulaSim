--!strict
--[[
	CarBuilder  (Server only)

	Builds the placeholder single-seat open-wheel car from VehicleConfig, so wheelbase,
	track, CoM and tyre sizes always match the physics configuration.

	Physical structure (one rigid assembly, all joined by WeldConstraints):
	  MassCore      invisible box at the centre of mass, carries 100% of the mass
	                (density computed so assembly mass = Mass.TotalKg). Root part.
	  CollisionBody invisible box around the tub; the only collidable body part.
	  Pad_XX        PLACEHOLDER rigid spherical contact pads at each wheel (Milestone A only;
	                replaced by raycast suspension in Milestone B). Frictionless while driven.
	  Visual parts  Massless, non-colliding, non-queryable.

	Per wheel (XX = FL, FR, RL, RR), all under MassCore:
	  Attachment  Wheel_XX     wheel centre (attributes: IsFront, IsLeft, IsDriven, RadiusM, WidthM)
	  Attachment  Contact_XX   contact patch; moved to the ray hit point each step by the client
	  VectorForce TireForce_XX world-space tyre force applied at Contact_XX
	  Motor6D     WheelMotor_XX visual-only steer/spin for WheelVisual_XX

	Car-local frame: origin at the CoM, -Z forward, +X right, +Y up.
	MassCore.PivotOffset puts the model pivot on the ground below the CoM, so
	model:PivotTo(groundCFrame) places the car at ride height.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("FormulaSim"):WaitForChild("Shared")
local UnitConversion = require(Shared:WaitForChild("UnitConversion"))

local S = UnitConversion.metersToStuds

local BODY = Color3.fromRGB(18, 92, 168)
local ACCENT = Color3.fromRGB(255, 140, 0)
local DARK = Color3.fromRGB(26, 26, 30)
local TIRE = Color3.fromRGB(20, 20, 20)

local CarBuilder = {}

local function vm(v: Vector3): Vector3
	return UnitConversion.vectorToStuds(v)
end

local function weld(part0: BasePart, part1: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = part0
	w.Part1 = part1
	w.Parent = part1
end

local function visual(model: Model, core: BasePart, name: string, sizeM: Vector3, posM: Vector3, color: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = vm(sizeM)
	p.CFrame = CFrame.new(vm(posM))
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Massless = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	weld(core, p)
	return p
end

type WheelSpec = { name: string, front: boolean, left: boolean }
local WHEELS: { WheelSpec } = {
	{ name = "FL", front = true, left = true },
	{ name = "FR", front = true, left = false },
	{ name = "RL", front = false, left = true },
	{ name = "RR", front = false, left = false },
}

function CarBuilder.build(config: any): Model
	local mass = config.Mass
	local geo = config.Geometry
	local h = mass.CgHeightM
	local a = geo.WheelbaseM * (1 - mass.FrontWeightFraction) -- CoM to front axle
	local b = geo.WheelbaseM * mass.FrontWeightFraction -- CoM to rear axle
	local gy = -h -- ground height in car-local metres

	local model = Instance.new("Model")
	model.Name = "FormulaCar"

	-- Mass carrier ---------------------------------------------------------------
	local core = Instance.new("Part")
	core.Name = "MassCore"
	core.Size = vm(mass.InertiaBoxM)
	local volume = core.Size.X * core.Size.Y * core.Size.Z
	local density = UnitConversion.kgToRmu(mass.TotalKg) / volume
	core.CustomPhysicalProperties = PhysicalProperties.new(density, 0.3, 0, 1, 1)
	core.CFrame = CFrame.new()
	core.Transparency = 1
	core.CanCollide = false
	core.CanQuery = false
	core.CanTouch = false
	core.RootPriority = 127
	core.PivotOffset = CFrame.new(0, S(gy), 0)
	core.Parent = model
	model.PrimaryPart = core
	model:SetAttribute("DesignMassKg", mass.TotalKg)

	local comAttachment = Instance.new("Attachment")
	comAttachment.Name = "CoM"
	comAttachment.Parent = core

	local aero = Instance.new("VectorForce")
	aero.Name = "AeroForce"
	aero.Attachment0 = comAttachment
	aero.ApplyAtCenterOfMass = true
	aero.RelativeTo = Enum.ActuatorRelativeTo.World
	aero.Force = Vector3.zero
	aero.Parent = core

	-- Downforce is applied at each axle (longitudinal position), so it loads the right tyres.
	for name, z in { Front = -a, Rear = b } do
		local att = Instance.new("Attachment")
		att.Name = "Aero" .. name
		att.Position = vm(Vector3.new(0, 0, z))
		att.Parent = core
		local df = Instance.new("VectorForce")
		df.Name = "Downforce" .. name
		df.Attachment0 = att
		df.ApplyAtCenterOfMass = false
		df.RelativeTo = Enum.ActuatorRelativeTo.World
		df.Force = Vector3.zero
		df.Parent = core
	end

	-- Collision body ---------------------------------------------------------------
	local bodyH = 0.42
	local collision = Instance.new("Part")
	collision.Name = "CollisionBody"
	collision.Size = vm(Vector3.new(0.85, bodyH, 3.6))
	collision.CFrame = CFrame.new(vm(Vector3.new(0, gy + config.Collision.BodyClearanceM + bodyH / 2, -0.25)))
	collision.Transparency = 1
	collision.Massless = true
	collision.CanCollide = true
	collision.CanQuery = false
	collision.CanTouch = false
	collision.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.3, 0.1, 1, 1)
	collision.Parent = model
	weld(core, collision)

	-- Wheels -----------------------------------------------------------------------
	for _, spec in WHEELS do
		local track = if spec.front then geo.FrontTrackM else geo.RearTrackM
		local r = if spec.front then geo.FrontTireRadiusM else geo.RearTireRadiusM
		local width = if spec.front then geo.FrontTireWidthM else geo.RearTireWidthM
		local x = (track / 2) * (if spec.left then -1 else 1)
		local z = if spec.front then -a else b
		local centerM = Vector3.new(x, gy + r, z)

		local center = Instance.new("Attachment")
		center.Name = "Wheel_" .. spec.name
		center.Position = vm(centerM)
		center:SetAttribute("IsFront", spec.front)
		center:SetAttribute("IsLeft", spec.left)
		center:SetAttribute("IsDriven", not spec.front)
		center:SetAttribute("RadiusM", r)
		center:SetAttribute("WidthM", width)
		center.Parent = core

		local contact = Instance.new("Attachment")
		contact.Name = "Contact_" .. spec.name
		contact.Position = vm(Vector3.new(x, gy, z))
		contact.Parent = core

		local force = Instance.new("VectorForce")
		force.Name = "TireForce_" .. spec.name
		force.Attachment0 = contact
		force.ApplyAtCenterOfMass = false
		force.RelativeTo = Enum.ActuatorRelativeTo.World
		force.Force = Vector3.zero
		force.Parent = core

		-- PLACEHOLDER rigid contact pad (Milestone A only)
		local pad = Instance.new("Part")
		pad.Name = "Pad_" .. spec.name
		pad.Shape = Enum.PartType.Ball
		pad.Size = Vector3.one * S(2 * r)
		pad.CFrame = CFrame.new(vm(centerM))
		pad.Transparency = 1
		pad.Massless = true
		pad.CanCollide = true
		pad.CanQuery = false
		pad.CanTouch = false
		pad.CustomPhysicalProperties = PhysicalProperties.new(0.7, config.Collision.ParkedPadFriction, 0, 100, 100)
		pad:SetAttribute("ContactPad", true)
		pad.Parent = model
		weld(core, pad)

		-- Visual wheel driven by a Motor6D (Transform is set locally by the driving client)
		local wheel = Instance.new("Part")
		wheel.Name = "WheelVisual_" .. spec.name
		wheel.Shape = Enum.PartType.Cylinder
		wheel.Size = vm(Vector3.new(width, 2 * r, 2 * r))
		wheel.CFrame = CFrame.new(vm(centerM))
		wheel.Color = TIRE
		wheel.Material = Enum.Material.SmoothPlastic
		wheel.Massless = true
		wheel.CanCollide = false
		wheel.CanQuery = false
		wheel.CanTouch = false
		wheel.Parent = model

		local motor = Instance.new("Motor6D")
		motor.Name = "WheelMotor_" .. spec.name
		motor.Part0 = core
		motor.Part1 = wheel
		motor.C0 = CFrame.new(vm(centerM))
		motor.C1 = CFrame.new()
		motor.Parent = core

		local outward = if spec.left then -1 else 1
		local rim = Instance.new("Part")
		rim.Name = "Rim_" .. spec.name
		rim.Shape = Enum.PartType.Cylinder
		rim.Size = vm(Vector3.new(0.02, 1.25 * r, 1.25 * r))
		rim.CFrame = CFrame.new(vm(centerM + Vector3.new(outward * (width / 2 + 0.005), 0, 0)))
		rim.Color = Color3.fromRGB(150, 150, 155)
		rim.Material = Enum.Material.Metal
		rim.Massless = true
		rim.CanCollide = false
		rim.CanQuery = false
		rim.CanTouch = false
		rim.Parent = model
		weld(wheel, rim)

		local marker = Instance.new("Part")
		marker.Name = "SpinMarker_" .. spec.name
		marker.Size = vm(Vector3.new(0.02, 1.2 * r, 0.07))
		marker.CFrame = CFrame.new(vm(centerM + Vector3.new(outward * (width / 2 + 0.016), 0, 0)))
		marker.Color = ACCENT
		marker.Material = Enum.Material.SmoothPlastic
		marker.Massless = true
		marker.CanCollide = false
		marker.CanQuery = false
		marker.CanTouch = false
		marker.Parent = model
		weld(wheel, marker)

		-- simple suspension arm visuals from body to wheel
		local innerX = if spec.front then 0.17 else 0.275
		local outerX = math.abs(x) - width / 2
		local armLen = outerX - innerX
		for _, dy in { -0.08, 0.08 } do
			visual(model, core, "Arm_" .. spec.name, Vector3.new(armLen, 0.03, 0.05), Vector3.new(outward * (innerX + armLen / 2), gy + r + dy, z), DARK)
		end
	end

	-- Body (visual only) -------------------------------------------------------------
	visual(model, core, "Tub", Vector3.new(0.85, 0.50, 3.2), Vector3.new(0, gy + 0.33, -0.35), BODY)
	visual(model, core, "Nose", Vector3.new(0.34, 0.26, 1.25), Vector3.new(0, gy + 0.22, -2.55), BODY)
	visual(model, core, "NoseTip", Vector3.new(0.30, 0.20, 0.15), Vector3.new(0, gy + 0.18, -3.22), ACCENT, Enum.Material.Neon)
	visual(model, core, "FrontWing", Vector3.new(1.80, 0.04, 0.45), Vector3.new(0, gy + 0.10, -3.05), DARK)
	visual(model, core, "FrontWingFlap", Vector3.new(1.60, 0.03, 0.20), Vector3.new(0, gy + 0.16, -2.88), BODY)
	visual(model, core, "FrontWingEndL", Vector3.new(0.03, 0.22, 0.50), Vector3.new(-0.90, gy + 0.19, -3.05), ACCENT)
	visual(model, core, "FrontWingEndR", Vector3.new(0.03, 0.22, 0.50), Vector3.new(0.90, gy + 0.19, -3.05), ACCENT)
	visual(model, core, "SidepodL", Vector3.new(0.42, 0.40, 1.50), Vector3.new(-0.62, gy + 0.28, 0.10), BODY)
	visual(model, core, "SidepodR", Vector3.new(0.42, 0.40, 1.50), Vector3.new(0.62, gy + 0.28, 0.10), BODY)
	visual(model, core, "EngineCover", Vector3.new(0.55, 0.50, 1.90), Vector3.new(0, gy + 0.55, 1.25), BODY)
	visual(model, core, "RollHoop", Vector3.new(0.30, 0.30, 0.35), Vector3.new(0, gy + 0.85, 0.30), DARK)
	visual(model, core, "Cockpit", Vector3.new(0.50, 0.02, 0.90), Vector3.new(0, gy + 0.585, -0.55), DARK)
	visual(model, core, "Floor", Vector3.new(1.10, 0.03, 2.80), Vector3.new(0, gy + 0.065, -0.10), DARK)
	visual(model, core, "Diffuser", Vector3.new(1.00, 0.18, 0.50), Vector3.new(0, gy + 0.14, 1.85), DARK)
	visual(model, core, "RearWing", Vector3.new(0.95, 0.05, 0.35), Vector3.new(0, gy + 0.92, 2.25), DARK)
	visual(model, core, "RearWingFlap", Vector3.new(0.95, 0.04, 0.20), Vector3.new(0, gy + 0.99, 2.18), BODY)
	visual(model, core, "RearWingEndL", Vector3.new(0.03, 0.55, 0.60), Vector3.new(-0.49, gy + 0.75, 2.20), ACCENT)
	visual(model, core, "RearWingEndR", Vector3.new(0.03, 0.55, 0.60), Vector3.new(0.49, gy + 0.75, 2.20), ACCENT)
	visual(model, core, "RearWingPylon", Vector3.new(0.06, 0.45, 0.10), Vector3.new(0, gy + 0.68, 2.10), DARK)
	visual(model, core, "RainLight", Vector3.new(0.12, 0.08, 0.03), Vector3.new(0, gy + 0.32, 2.12), Color3.fromRGB(255, 30, 30), Enum.Material.Neon)

	-- Driver seat ------------------------------------------------------------------
	local seat = Instance.new("Seat")
	seat.Name = "DriverSeat"
	seat.Size = vm(Vector3.new(0.45, 0.06, 0.45))
	seat.CFrame = CFrame.new(vm(Vector3.new(0, gy + 0.12, -0.55)))
	seat.Transparency = 1
	seat.Massless = true
	seat.CanCollide = false
	seat.CanQuery = false
	seat.CanTouch = false -- entry is via ProximityPrompt / server Sit(), never by touch
	seat:SetAttribute("FormulaSimSeat", true)
	seat.Parent = model
	weld(core, seat)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "DrivePrompt"
	prompt.ActionText = "Drive"
	prompt.ObjectText = config.Name
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = seat

	return model
end

return CarBuilder
