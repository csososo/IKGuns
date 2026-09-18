--[[
	DiagnoseMovement -- run in the command bar WHILE PLAYING, then stand still
	for a few seconds and walk for a few more.

	Reads only. Changes nothing.

	It samples EVERY FRAME and prints the min/max range over each half second.
	Ranges, not instantaneous values: a 60Hz spasm is invisible to a 2Hz
	sample of instantaneous numbers, but shows up immediately as a wide range.

	What to look for:
	  yaw range wide while standing still -> the aim is whipping the torso.
	  angVel high with speed near 0        -> the body is physically spinning.
	  err large and steady                 -> the solver cannot reach the foot
	                                          target, which reads as one leg
	                                          stuck out of pose.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local character
for _, plr in Players:GetPlayers() do
	if plr.Character then
		character = plr.Character
		break
	end
end
if not character then
	warn("No spawned character found. Run this during play.")
	return
end

local humanoid = character:FindFirstChildOfClass("Humanoid")
local hrp = character:FindFirstChild("HumanoidRootPart")
if not (humanoid and hrp) then
	warn("Character is missing a Humanoid or HumanoidRootPart.")
	return
end

print(("[Diagnose] %s  RigType=%s  HipHeight=%.3f  AutoRotate=%s"):format(
	character.Name, humanoid.RigType.Name, humanoid.HipHeight, tostring(humanoid.AutoRotate)))

local function attr(name, default)
	local v = character:GetAttribute(name)
	if v == nil then return default end
	return v
end

-- Accumulates min/max between prints.
local Range = {}
Range.__index = Range
function Range.new()
	return setmetatable({ lo = math.huge, hi = -math.huge }, Range)
end
function Range:add(v)
	if v < self.lo then self.lo = v end
	if v > self.hi then self.hi = v end
end
function Range:span()
	return (self.hi > self.lo) and (self.hi - self.lo) or 0
end
function Range:fmt(decimals)
	if self.lo == math.huge then return "n/a" end
	-- Luau's string.format has no "%.*f" star width, so build the spec.
	local one = "%+." .. decimals .. "f"
	return one:format(self.lo) .. ".." .. one:format(self.hi)
end

local tracked, order = {}, { "rootYaw", "angVel", "aimYaw", "rawYaw", "hip", "lErr", "rErr" }
local function reset()
	for _, k in order do
		tracked[k] = Range.new()
	end
end
reset()

local frames = 0
local nextPrint, finish = os.clock() + 0.5, os.clock() + 12
local conn
conn = RunService.Heartbeat:Connect(function()
	if not character.Parent then
		conn:Disconnect()
		return
	end

	frames += 1
	local look = hrp.CFrame.LookVector
	tracked.rootYaw:add(math.deg(math.atan2(-look.X, -look.Z)))
	tracked.angVel:add(hrp.AssemblyAngularVelocity.Magnitude)
	tracked.aimYaw:add(attr("IK_AimYaw", 0))
	tracked.rawYaw:add(attr("IK_AimRawYaw", 0))
	tracked.hip:add(attr("IK_HipOffset", 0))
	tracked.lErr:add(attr("IK_LeftError", 0))
	tracked.rErr:add(attr("IK_RightError", 0))

	local now = os.clock()
	if now < nextPrint then
		return
	end
	nextPrint = now + 0.5

	local vel = hrp.AssemblyLinearVelocity
	print(("[Diagnose] %s %-9s spd=%5.1f f=%2d | rootYaw %s (span %6.1f) | angVel %s | aimYaw %s raw %s | hip %s | err L %s R %s"):format(
		humanoid:GetState().Name:sub(1, 8),
		humanoid.FloorMaterial.Name:sub(1, 9),
		Vector3.new(vel.X, 0, vel.Z).Magnitude,
		frames,
		tracked.rootYaw:fmt(1), tracked.rootYaw:span(),
		tracked.angVel:fmt(1),
		tracked.aimYaw:fmt(1),
		tracked.rawYaw:fmt(1),
		tracked.hip:fmt(3),
		tracked.lErr:fmt(2),
		tracked.rErr:fmt(2)))

	frames = 0
	reset()

	if now > finish then
		conn:Disconnect()
		print("[Diagnose] done")
	end
end)
