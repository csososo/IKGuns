--[[
	MovementController -- speed, sprint, and which way the body faces.

	Two jobs, and the second is the one that matters to the gait.

	SPEED. Shift picks between the walk and sprint speeds in Config.Run, and
	that is all it does. The gait has no notion of a sprint button:
	ProceduralWalk blends the walk and run profiles purely on how fast you
	are actually moving, so anything else that changes your speed -- a
	slope, a slow effect, a vehicle dismount -- gets the right gait for
	free, and no state here can disagree with what the legs are doing.

	FACING. The character is held facing the camera permanently, which is
	shift lock's behaviour without shift lock. The gait's whole notion of
	strafing is velocity measured ACROSS the body's own facing, and with
	Roblox's default rotation the character turns to face wherever it is
	going -- so that measurement is always zero, pressing A is a left turn
	rather than a side-step, and every strafe feature correctly does
	nothing. Facing the camera is also what this rig is ultimately for.

	That also frees Shift, which would otherwise toggle shift lock and
	fight this. The binding sinks it so the default controller never sees
	it.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local UserSettings = UserSettings()

local Config = require(ReplicatedStorage:WaitForChild("IKSystem").Config)

local player = Players.LocalPlayer
local sprinting = false

local function humanoid(): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function applySpeed()
	local human = humanoid()
	if not human then
		return
	end
	local run = Config.Run
	human.WalkSpeed = sprinting and run.SprintSpeed or run.WalkSpeed
end

--[[
	CameraRelative is the documented way to get shift lock's rotation
	without shift lock. Guarded because it is a user setting rather than
	something the place owns, and a failure here should say so rather than
	silently leaving the gait unable to see a strafe.
]]
local function faceCamera()
	local ok, err = pcall(function()
		UserSettings:GetService("UserGameSettings").RotationType =
			Enum.RotationType.CameraRelative
	end)
	if not ok then
		warn("[MovementController] could not force camera-relative rotation: "
			.. tostring(err) .. " -- strafing will read as turning instead.")
	end
end

ContextActionService:BindAction("Sprint", function(_, state)
	sprinting = state == Enum.UserInputState.Begin
	applySpeed()
	-- Sunk so the default controller never sees Shift and toggles shift
	-- lock underneath us.
	return Enum.ContextActionResult.Sink
end, false, Config.Run.SprintKey)

player.CharacterAdded:Connect(function()
	-- A fresh Humanoid arrives at the default speed, and the key may still
	-- be held.
	task.defer(function()
		applySpeed()
		faceCamera()
	end)
end)

faceCamera()
applySpeed()
print(("[MovementController] walk %d, sprint %d on %s; facing the camera."):format(
	Config.Run.WalkSpeed, Config.Run.SprintSpeed, Config.Run.SprintKey.Name))
