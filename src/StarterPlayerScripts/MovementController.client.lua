--[[
	MovementController -- speed, sprint, and the camera lock.

	SPEED. The only thing this changes is WalkSpeed. The gait has no notion
	of a sprint button: ProceduralWalk blends its profiles purely on how
	fast you are actually moving, so anything else that changes your speed
	-- a slope, a slow effect, a vehicle dismount -- gets the right gait for
	free, and no state here can disagree with what the legs are doing.

	SPRINT IS DIRECTIONAL. You cannot sprint sideways or backwards, so
	holding sprint only reaches SprintSpeed when the input is actually
	forward; anything else settles for a jog. W, W+A and W+D all qualify.
	The gait follows on its own, because the gait only ever reads speed.

	Eased rather than switched, so a sprint builds and drops away instead of
	snapping, and the gait blend has something continuous to follow.

	CAMERA LOCK. Ctrl toggles it. It holds the character facing the camera
	and centres the mouse, which is shift lock in all but name -- the key
	moved because Shift is sprint now. It matters more than it looks: the
	gait's whole notion of strafing is velocity measured ACROSS the body's
	own facing, and unlocked, the character turns to face wherever it is
	going, so that measurement is always zero, pressing A is a left turn
	rather than a side-step, and every strafe feature correctly does
	nothing.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local UserSettings = UserSettings()

local Config = require(ReplicatedStorage:WaitForChild("IKSystem").Config)
local Util = require(ReplicatedStorage:WaitForChild("IKSystem").Util)

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local sprinting = false
local locked = false
local speed = Config.Motion.WalkSpeed

local function humanoid(): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

--[[
	How forward the input is, against the camera rather than the character:
	the character may be mid-turn, but what you asked for is what should
	decide whether it counts as a sprint.
]]
local function forwardness(human: Humanoid): number
	local wanted = human.MoveDirection
	if wanted.Magnitude < 1e-3 then
		return 0
	end
	local look = camera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		return 0
	end
	return wanted.Unit:Dot(flat.Unit)
end

local function step(dt: number)
	local human = humanoid()
	if not human then
		return
	end
	local motion = Config.Motion

	local wanted = motion.WalkSpeed
	if sprinting then
		wanted = (forwardness(human) >= motion.SprintForward)
			and motion.SprintSpeed
			or motion.JogSpeed
	end

	speed = Util.damp(speed, wanted, motion.SpeedChangeTime, dt)
	human.WalkSpeed = speed
end

local function setLocked(on: boolean)
	locked = on
	local ok, err = pcall(function()
		UserSettings:GetService("UserGameSettings").RotationType = locked
			and Enum.RotationType.CameraRelative
			or Enum.RotationType.MovementRelative
	end)
	if not ok then
		warn("[MovementController] could not set the rotation type: " .. tostring(err)
			.. " -- strafing will read as turning instead.")
	end
	UserInputService.MouseBehavior = locked
		and Enum.MouseBehavior.LockCenter
		or Enum.MouseBehavior.Default
end

--[[
	Both are sunk so the default controller never sees them: Shift is its
	shift-lock toggle, and leaving that bound would fight the lock below.
]]
ContextActionService:BindAction("Sprint", function(_, state)
	sprinting = state == Enum.UserInputState.Begin
	return Enum.ContextActionResult.Sink
end, false, Config.Motion.SprintKey)

ContextActionService:BindAction("CameraLock", function(_, state)
	if state == Enum.UserInputState.Begin then
		setLocked(not locked)
	end
	return Enum.ContextActionResult.Sink
end, false, Config.Motion.CameraLockKey)

--[[
	The mouse un-centres itself whenever anything else touches it, so the
	lock is re-asserted rather than set once.
]]
RunService.RenderStepped:Connect(function(dt)
	step(dt)
	if locked and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end
end)

player.CharacterAdded:Connect(function()
	speed = Config.Motion.WalkSpeed
end)

setLocked(false)
print(("[MovementController] walk %d, jog %d, sprint %d on %s (forward only); %s toggles the camera lock."):format(
	Config.Motion.WalkSpeed, Config.Motion.JogSpeed, Config.Motion.SprintSpeed,
	Config.Motion.SprintKey.Name, Config.Motion.CameraLockKey.Name))
