--[[
	PrepareStarterCharacter -- one-time rig setup.

	Select your StarterCharacter model in the Explorer and paste this into the
	command bar. Run it on the StarterCharacter, not on a character that is
	already spawned, or the changes vanish on respawn.

	It fixes three things that are rig setup rather than IK:
	  1. Limb collision, which makes walking feel like wading.
	  2. The stock Animate script, which yields forever on this rig.
	  3. A missing Animator, which IKControl needs to solve at all.

	Everything it changes is printed. Nothing is destroyed.
]]

-- Parts that keep their collision. HumanoidRootPart is the humanoid's own
-- collider; MainMover looks like a deliberate floor plate, so it stays too.
-- If the character now floats or sinks, take MainMover out of this list.
local KEEP_COLLIDABLE = {
	HumanoidRootPart = true,
	MainMover = true,
}

-- Limbs hanging off Motor6Ds do not need mass of their own; the root carries
-- it. Set false if you would rather not touch this.
local MAKE_LIMBS_MASSLESS = true

local Selection = game:GetService("Selection")

local rig = Selection:Get()[1]
if not rig or not rig:IsA("Model") then
	warn("Select the StarterCharacter model in the Explorer first.")
	return
end
if rig.Name ~= "StarterCharacter" then
	warn(("Selected model is named %q, not \"StarterCharacter\". Continuing anyway -- "
		.. "but players only spawn as a model with that exact name."):format(rig.Name))
end

local changed = {}

-- 1. Collision
local uncollided = {}
for _, d in rig:GetDescendants() do
	if d:IsA("BasePart") and not KEEP_COLLIDABLE[d.Name] then
		if d.CanCollide then
			d.CanCollide = false
			table.insert(uncollided, d.Name)
		end
		if MAKE_LIMBS_MASSLESS and not d.Massless then
			d.Massless = true
		end
	end
end
if #uncollided > 0 then
	table.insert(changed, ("CanCollide off on %d parts: %s"):format(#uncollided, table.concat(uncollided, ", ")))
end

-- 2. Occupy the Animate name so Roblox never inserts its stock R6 one. It has
--    to live inside the model; StarterCharacterScripts is copied in too late.
local animate = rig:FindFirstChild("Animate")
if not animate then
	animate = Instance.new("LocalScript")
	animate.Name = "Animate"
	animate.Source = "-- Intentionally empty. Occupies the name so Roblox does not insert\n"
		.. "-- its stock R6 Animate script, which yields forever on this rig.\n"
	animate.Parent = rig
	table.insert(changed, "added an empty LocalScript named Animate")
end

-- 3. Animator
local humanoid = rig:FindFirstChildOfClass("Humanoid")
if humanoid then
	if not humanoid:FindFirstChildOfClass("Animator") then
		Instance.new("Animator").Parent = humanoid
		table.insert(changed, "added an Animator to the Humanoid")
	end
	if rig.PrimaryPart == nil then
		local root = rig:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			rig.PrimaryPart = root
			table.insert(changed, "set PrimaryPart to HumanoidRootPart")
		end
	end
else
	warn("No Humanoid found. This model will not work as a StarterCharacter.")
end

if #changed == 0 then
	print("[PrepareStarterCharacter] Nothing to change; already set up.")
else
	print("[PrepareStarterCharacter] " .. rig:GetFullName() .. "\n  - " .. table.concat(changed, "\n  - "))
end
