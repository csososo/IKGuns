--[[
	Sprint -- hold the key to run.

	All this does is change WalkSpeed. The gait has no notion of a sprint
	button: ProceduralWalk blends the walk and run profiles purely on how
	fast you are actually moving, so anything else that changes your speed
	-- a slope, a slow effect, a vehicle dismount -- gets the right gait for
	free, and there is no state here that can disagree with what the legs
	are doing.

	The key is deliberately not Shift, which is shift lock's, and the strafe
	behaviour depends on shift lock being usable. Change it in Config.Run.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("IKSystem").Config)

local player = Players.LocalPlayer

local function apply()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local run = Config.Run
	humanoid.WalkSpeed = UserInputService:IsKeyDown(run.SprintKey)
		and run.SprintSpeed
		or run.WalkSpeed
end

local function onInput(input: InputObject, typing: boolean)
	if not typing and input.KeyCode == Config.Run.SprintKey then
		apply()
	end
end

UserInputService.InputBegan:Connect(onInput)
UserInputService.InputEnded:Connect(onInput)

-- Respawning brings a fresh Humanoid at the default speed, and the key may
-- still be held.
player.CharacterAdded:Connect(function()
	task.defer(apply)
end)

apply()
print(("[Sprint] hold %s to run (%d studs/s, walk is %d)."):format(
	Config.Run.SprintKey.Name, Config.Run.SprintSpeed, Config.Run.WalkSpeed))
