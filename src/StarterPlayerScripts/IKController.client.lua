--[[
	IKController -- drives IKSystem for the local player's character.

	StarterPlayer > StarterPlayerScripts. It survives respawns on its own.

	This is client-local: only you see your own IK. See the README for what to
	add when you want other players to see it too.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IKSystem = require(ReplicatedStorage:WaitForChild("IKSystem"))

local RENDER_NAME = "IKSystemUpdate"
-- One tick before the engine's animation + IK pass, so this frame's targets
-- are the ones it solves.
local RENDER_PRIORITY = Enum.RenderPriority.Character.Value - 1

local player = Players.LocalPlayer
local active = nil
local generation = 0 -- bumped on every spawn/despawn so a slow setup can bail

local function findWeapon(character: Model): Instance?
	for _, child in character:GetChildren() do
		if child:IsA("Tool") or child:GetAttribute("IsWeapon") then
			return child
		end
	end
	return nil
end

local function teardown()
	generation += 1
	if not active then
		return
	end
	RunService:UnbindFromRenderStep(RENDER_NAME)
	for _, conn in active.connections do
		conn:Disconnect()
	end
	active.ik:Destroy()
	active = nil
end

local function setup(character: Model)
	teardown()
	local mine = generation

	-- CharacterAdded fires as soon as the model is parented; the limbs stream
	-- in just after. Wait for the ones we actually drive or the rig resolves
	-- half-empty and warns about parts that were only late.
	if not character:WaitForChild("Humanoid", 10) then
		return
	end
	for _, partName in IKSystem.Config.Parts do
		character:WaitForChild(partName, 5)
	end
	if mine ~= generation then
		return -- respawned again while we were waiting
	end

	local ik = IKSystem.new(character)
	if not ik then
		return
	end

	ik:SetWeapon(findWeapon(character))

	local connections = {
		character.ChildAdded:Connect(function(child)
			if child:IsA("Tool") or child:GetAttribute("IsWeapon") then
				ik:SetWeapon(child)
			end
		end),
		character.ChildRemoved:Connect(function(child)
			if child == ik.rig.weapon then
				ik:SetWeapon(findWeapon(character))
			end
		end),
	}

	active = { ik = ik, connections = connections }

	RunService:BindToRenderStep(RENDER_NAME, RENDER_PRIORITY, function(dt)
		if active then
			active.ik:Update(dt)
		end
	end)

	--[[
		Legs solve on Stepped, not RenderStep.

		RenderStep (PreRender) runs BEFORE the animation step in a frame, so
		Motor6D.Transform written there is overwritten by the Animator before
		anything is drawn -- the writes happen, they just never survive.
		Stepped (PreSimulation) runs after animations have been applied, so
		procedural joint writes stick.
	]]
	table.insert(connections, RunService.Stepped:Connect(function(_, dt)
		if active then
			active.ik:UpdateLate(dt)
		end
	end))
end

ContextActionService:BindAction("IKAim", function(_, state)
	if active then
		active.ik:SetAiming(state == Enum.UserInputState.Begin)
	end
	return Enum.ContextActionResult.Pass
end, false, Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonL2)

player.CharacterAdded:Connect(setup)
player.CharacterRemoving:Connect(teardown)

if player.Character then
	setup(player.Character)
end
