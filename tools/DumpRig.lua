--[[
	DumpRig -- paste this whole thing into Studio's command bar with your rig
	selected in the Explorer, then paste the output back.

	It reports everything the IK system has to assume about a rig: joint names
	and topology, whether it is R6/R15/custom, part-based or skinned, where the
	foot pivots sit, and which way the head's face points.
]]

local Selection = game:GetService("Selection")

local rig = Selection:Get()[1]
if not rig or not rig:IsA("Model") then
	warn("Select the rig Model in the Explorer first, then run this again.")
	return
end

local out = { ("== %s =="):format(rig:GetFullName()) }
local function add(fmt, ...)
	table.insert(out, select("#", ...) > 0 and fmt:format(...) or fmt)
end

-- What kind of rig is this
local humanoid = rig:FindFirstChildOfClass("Humanoid")
local animController = rig:FindFirstChildOfClass("AnimationController")
add("Humanoid: %s   AnimationController: %s",
	humanoid and ("yes, RigType=" .. humanoid.RigType.Name) or "no",
	animController and "yes" or "no")
if humanoid then
	add("Animator: %s   HipHeight: %.3f",
		humanoid:FindFirstChildOfClass("Animator") and "yes" or "NO (IKControl needs one)",
		humanoid.HipHeight)
end
add("Animate script: %s", rig:FindFirstChild("Animate") and "yes" or "no")

-- Joint topology. This is the part the config has to match.
local motors, bones, meshParts = {}, 0, 0
for _, d in rig:GetDescendants() do
	if d:IsA("Motor6D") then
		table.insert(motors, d)
	elseif d:IsA("Bone") then
		bones += 1
	elseif d:IsA("MeshPart") then
		meshParts += 1
	end
end
add("Motor6Ds: %d   Bones: %d   MeshParts: %d", #motors, bones, meshParts)

add("\n-- Motor6D chain (name: Part0 -> Part1, C0 offset) --")
table.sort(motors, function(a, b) return a.Name < b.Name end)
for _, m in motors do
	local p = m.C0.Position
	add("  %-18s %-16s -> %-16s  C0 pos (%.2f, %.2f, %.2f)",
		m.Name,
		m.Part0 and m.Part0.Name or "nil",
		m.Part1 and m.Part1.Name or "nil",
		p.X, p.Y, p.Z)
end

-- Sizes and pivots. Foot IK assumes the sole sits at half the part's height
-- below its origin, which is false for meshes with an offset pivot.
add("\n-- Parts (size, pivot offset from centre) --")
for _, d in rig:GetChildren() do
	if d:IsA("BasePart") then
		local s = d.Size
		local off = d.CFrame:ToObjectSpace(d:GetPivot()).Position
		add("  %-18s size (%.2f, %.2f, %.2f)  pivot offset (%.2f, %.2f, %.2f)%s",
			d.Name, s.X, s.Y, s.Z, off.X, off.Y, off.Z,
			d:IsA("MeshPart") and "  [MeshPart]" or "")
	end
end

-- Which way does the head actually face
local head = rig:FindFirstChild("Head")
if head then
	local faces = {}
	for _, d in head:GetDescendants() do
		if d:IsA("Decal") or d:IsA("Texture") then
			table.insert(faces, ("%s on %s"):format(d.ClassName, d.Face.Name))
		elseif d:IsA("SurfaceGui") then
			table.insert(faces, ("SurfaceGui on %s"):format(d.Face.Name))
		end
	end
	add("\nHead face markers: %s", #faces > 0 and table.concat(faces, ", ") or "none found")
end

-- Attachments already present, e.g. grips the weapon code might reuse
local atts = {}
for _, d in rig:GetDescendants() do
	if d:IsA("Attachment") then
		table.insert(atts, ("%s/%s"):format(d.Parent and d.Parent.Name or "?", d.Name))
	end
end
add("\nAttachments (%d): %s", #atts, #atts > 0 and table.concat(atts, ", ") or "none")

print(table.concat(out, "\n"))
