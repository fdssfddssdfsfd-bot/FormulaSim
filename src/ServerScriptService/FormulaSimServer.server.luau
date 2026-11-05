--!strict
--[[
	FormulaSimServer  (Server)

	Responsibilities:
	  * Enforce world settings (gravity in studs for the 0.28 m/stud scale).
	  * Spawn one car per player at a server-defined spawn slot, and seat them.
	  * Authority: the seated owner gets NETWORK OWNERSHIP of their car assembly, so their
	    client simulates it (responsive, no input latency). Nobody else may drive it.
	  * Validate reset requests (only the car's owner, rate-limited); reset position comes
	    from the server, never from the client.
	  * Reset cars that fall out of the world.

	The server never accepts vehicle state, positions, race results or currency from clients.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local root = ReplicatedStorage:WaitForChild("FormulaSim")
local Shared = root:WaitForChild("Shared")
local UnitConversion = require(Shared:WaitForChild("UnitConversion"))
local VehicleConfig = require(Shared:WaitForChild("VehicleConfig"))
local CarBuilder = require(ServerStorage:WaitForChild("FormulaSim"):WaitForChild("CarBuilder"))

local requestReset = root:WaitForChild("Remotes"):WaitForChild("RequestReset") :: RemoteEvent

workspace.Gravity = UnitConversion.GRAVITY_STUDS_S2

local simFolder = workspace:WaitForChild("FormulaSim")
local carsFolder = simFolder:FindFirstChild("Cars") or Instance.new("Folder")
carsFolder.Name = "Cars"
carsFolder.Parent = simFolder
local slotsFolder = simFolder:WaitForChild("Track"):WaitForChild("Paddock"):WaitForChild("SpawnSlots")

type CarRecord = {
	owner: Player,
	model: Model,
	core: BasePart,
	seat: Seat,
	prompt: ProximityPrompt,
	slot: BasePart,
	lastReset: number,
	driverCharacter: Model?,
	masslessBackup: { [BasePart]: boolean },
}

local records: { [Player]: CarRecord } = {}

-- Parking pads hold an unoccupied car; while driven, the client's suspension carries it.
local function setParked(model: Model, parked: boolean)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("ContactPad") then
			d.CanCollide = parked
		end
	end
end

local function zeroForces(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("VectorForce") then
			d.Force = Vector3.zero
		end
	end
end

local function setNetworkOwner(rec: CarRecord, player: Player?)
	local ok, err = pcall(function()
		rec.core:SetNetworkOwner(player)
	end)
	if not ok then
		warn("[FormulaSim] SetNetworkOwner failed:", err)
	end
end

local function pickFreeSlot(): BasePart
	local used: { [BasePart]: boolean } = {}
	for _, rec in records do
		used[rec.slot] = true
	end
	local slots = slotsFolder:GetChildren()
	table.sort(slots, function(x, y)
		return x.Name < y.Name
	end)
	for _, s in slots do
		if s:IsA("BasePart") and not used[s] then
			return s
		end
	end
	return slots[1] :: BasePart
end

local function placeAtSlot(rec: CarRecord)
	zeroForces(rec.model)
	rec.model:PivotTo(rec.slot.CFrame)
	rec.core.AssemblyLinearVelocity = Vector3.zero
	rec.core.AssemblyAngularVelocity = Vector3.zero
	-- Tells the driving client to re-initialise wheel spin state.
	rec.model:SetAttribute("ResetCount", ((rec.model:GetAttribute("ResetCount") :: number?) or 0) + 1)
end

local function driverPlayer(rec: CarRecord): Player?
	if rec.driverCharacter then
		return Players:GetPlayerFromCharacter(rec.driverCharacter)
	end
	return nil
end

local function resetCar(rec: CarRecord)
	-- Take ownership briefly so the teleport is authoritative, then hand it back.
	setNetworkOwner(rec, nil)
	setParked(rec.model, true) -- pads hold the car while the server owns it
	placeAtSlot(rec)
	task.delay(0.15, function()
		local driver = driverPlayer(rec)
		if driver and rec.model.Parent then
			setNetworkOwner(rec, driver)
			setParked(rec.model, false)
		end
	end)
end

local function onOccupantChanged(rec: CarRecord)
	local humanoid = rec.seat.Occupant
	if humanoid then
		local character = humanoid.Parent :: Model
		local player = Players:GetPlayerFromCharacter(character)
		if player ~= rec.owner then
			-- Only the owner may drive this car.
			local seatWeld = rec.seat:FindFirstChild("SeatWeld")
			if seatWeld then
				seatWeld:Destroy()
			end
			return
		end
		-- The driver's body must not change the car's mass or CoM.
		rec.masslessBackup = {}
		for _, d in character:GetDescendants() do
			if d:IsA("BasePart") then
				rec.masslessBackup[d] = d.Massless
				d.Massless = true
			end
		end
		rec.driverCharacter = character
		setParked(rec.model, false)
		rec.prompt.Enabled = false
		rec.model:SetAttribute("DriverUserId", player.UserId)
		task.defer(function()
			if rec.seat.Occupant == humanoid then
				setNetworkOwner(rec, player)
			end
		end)
	else
		for part, wasMassless in rec.masslessBackup do
			if part.Parent then
				part.Massless = wasMassless
			end
		end
		rec.masslessBackup = {}
		rec.driverCharacter = nil
		zeroForces(rec.model)
		setNetworkOwner(rec, nil)
		setParked(rec.model, true)
		rec.prompt.Enabled = true
		rec.model:SetAttribute("DriverUserId", nil)
	end
end

local function seatOwner(rec: CarRecord)
	local character = rec.owner.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 and rec.seat.Occupant == nil then
		rec.seat:Sit(humanoid)
	end
end

local function spawnCar(player: Player): CarRecord
	local model = CarBuilder.build(VehicleConfig)
	model.Name = "FormulaCar_" .. player.Name
	model:SetAttribute("OwnerUserId", player.UserId)
	local core = model.PrimaryPart :: BasePart
	local seat = model:FindFirstChild("DriverSeat") :: Seat
	local prompt = seat:FindFirstChild("DrivePrompt") :: ProximityPrompt

	local rec: CarRecord = {
		owner = player,
		model = model,
		core = core,
		seat = seat,
		prompt = prompt,
		slot = pickFreeSlot(),
		lastReset = 0,
		driverCharacter = nil,
		masslessBackup = {},
	}
	model:PivotTo(rec.slot.CFrame)
	model.Parent = carsFolder

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		onOccupantChanged(rec)
	end)
	prompt.Triggered:Connect(function(who: Player)
		if who == rec.owner then
			seatOwner(rec)
		end
	end)
	records[player] = rec
	return rec
end

local function onPlayerAdded(player: Player)
	local rec = spawnCar(player)
	local function onCharacter(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if not humanoid then
			return
		end
		task.wait(1) -- let the character finish loading
		if records[player] == rec and character.Parent then
			seatOwner(rec)
		end
	end
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player: Player)
	local rec = records[player]
	if rec then
		records[player] = nil
		rec.model:Destroy()
	end
end)

requestReset.OnServerEvent:Connect(function(player: Player)
	local rec = records[player]
	if not rec then
		return
	end
	local now = os.clock()
	if now - rec.lastReset < VehicleConfig.Network.ResetCooldownS then
		return
	end
	rec.lastReset = now
	resetCar(rec)
end)

-- Out-of-world recovery (cars can drive off the edge of the map).
local fallCheckTimer = 0
RunService.Heartbeat:Connect(function(dt: number)
	fallCheckTimer += dt
	if fallCheckTimer < 0.5 then
		return
	end
	fallCheckTimer = 0
	for _, rec in records do
		if rec.core.Parent and rec.core.Position.Y < VehicleConfig.Network.FallResetHeightStuds then
			resetCar(rec)
		end
	end
end)
