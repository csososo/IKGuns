--[[
	IKSystem -- animation-driven character with IK corrections on top.

	The animations own the pose. IK only fixes the three things animations
	cannot know about: where the ground actually is, where the camera is
	pointing, and where the weapon's grips are.

		local ik = IKSystem.new(character)
		RunService:BindToRenderStep("IK", Enum.RenderPriority.Character.Value - 1, function(dt)
			ik:Update(dt)
		end)

	Update must run just BEFORE Enum.RenderPriority.Character (300), which is
	where the engine evaluates animations and solves IKControls. Writing the
	targets first means they are solved the same frame instead of one late.
]]

local Config = require(script.Config)
local Rig = require(script.Rig)
local Aim = require(script.Aim)
local FootIK = require(script.FootIK)
local ProceduralWalk = require(script.ProceduralWalk)
local Util = require(script.Util)

local IKSystem = {}
IKSystem.__index = IKSystem

IKSystem.Config = Config

function IKSystem.new(character: Model)
	local rig = Rig.new(character)
	if not rig then
		return nil
	end

	local self = setmetatable({}, IKSystem)
	self.character = character
	self.rig = rig
	self.aim = Aim.new(rig)
	--[[
		Exactly one of these owns the leg joints. Running both means two
		systems writing Motor6D.Transform with no agreement about who owns the
		frame, and the loser is whichever wrote first.
	]]
	if Config.isOn("legs") then
		if Config.Gait == "procedural" then
			self.walk = ProceduralWalk.new(rig)
		else
			self.legs = FootIK.new(rig)
		end
	end
	self.armWeight = { Left = 0, Right = 0 }

	return self
end

--[[
	Pin the hands to a weapon's grip attachments. The weapon should already be
	welded or Motor6D'd to the right hand -- IK places the hands on the gun,
	not the gun in the hands. Pass nil to release the arms.

	Expected inside the weapon model: an Attachment named LeftGrip (foregrip)
	and optionally RightGrip. Names are in Config.Arms.
]]
function IKSystem:SetWeapon(weapon: Instance?)
	self.rig:SetWeapon(weapon)
end

-- Hold to aim: turns the body to face the camera and tightens the upper body.
function IKSystem:SetAiming(aiming: boolean)
	self.aim:SetAiming(aiming)
end

-- Fade the whole upper-body aim out, e.g. while sprinting or reloading.
function IKSystem:SetAimWeight(weight: number)
	self.aim:SetWeight(weight)
end

function IKSystem:_updateArms(dt: number)
	local rig = self.rig
	if not (rig.features.arms and Config.isOn("arms")) then
		return
	end

	local grips = rig.grips or {}
	for _, side in { "Left", "Right" } do
		local control = rig.controls[side .. "ArmIK"]
		if control then
			local grip = grips[side]
			local holding = grip and (side == "Left" or Config.Arms.DriveRightHand)
			local wantWeight = 0

			if holding then
				-- A weapon grip always wins over the placeholder swing.
				control.Target = grip
				wantWeight = 1
			else
				-- Nothing else drives the hands; they stay with the animation.
			end

			self.armWeight[side] = Util.damp(self.armWeight[side], wantWeight, 0.12, dt)
			control.Weight = self.armWeight[side]
			if wantWeight == 0 and self.armWeight[side] < 0.01 then
				rig:RelaxChain(side .. "Hand")
			end
		end
	end
end

function IKSystem:Update(dt: number)
	if not self.character.Parent then
		return
	end
	self.aim:Update(dt)
	self:_updateArms(dt)
end

--[[
	Runs AFTER the engine's animation and IK pass, unlike Update.

	The legs are solved here so they override the animation instead of being
	overwritten by it -- the Animator rewrites Motor6D.Transform every frame
	at that pass, so anything written before it is simply discarded.
]]
function IKSystem:UpdateLate(dt: number)
	if not self.character.Parent then
		return
	end
	if self.walk then
		self.walk:Update(dt)
	elseif self.legs then
		self.legs:Update(dt)
	end
end

function IKSystem:Destroy()
	if self.walk then
		self.walk:Reset()
	end
	self.aim:Reset()
	self.rig:Destroy()
end

--[[
	Diagnostic. Run from the command bar against your rig to see the real part
	and Motor6D names, then correct Config if they do not match:

		require(game.ReplicatedStorage.IKSystem).Dump(workspace.YourRig)
]]
function IKSystem.Dump(character: Model)
	local lines = { ("[IKSystem] %s"):format(character:GetFullName()) }
	for _, d in character:GetDescendants() do
		if d:IsA("Motor6D") then
			table.insert(lines, ("  Motor6D %-16s  %s -> %s"):format(
				d.Name,
				d.Part0 and d.Part0.Name or "nil",
				d.Part1 and d.Part1.Name or "nil"))
		end
	end
	for _, d in character:GetChildren() do
		if d:IsA("BasePart") then
			table.insert(lines, ("  Part    %s"):format(d.Name))
		end
	end
	print(table.concat(lines, "\n"))
end

return IKSystem
