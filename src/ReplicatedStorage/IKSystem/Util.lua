--[[
	Util -- small CFrame and smoothing helpers shared by the IK modules.
]]

local Util = {}

--[[
	Rotate a joint's child around the joint pivot, in the PARENT part's axes.

	Motor6D solves part1.CFrame = part0.CFrame * C0 * Transform * C1:Inverse(),
	so pre-multiplying C0 applies the rotation in part0's space. Doing it around
	the pivot point keeps the joint from sliding. This is rig-agnostic: it does
	not care how the base C0 happens to be oriented, which R15's Waist and Root
	both are (they carry a 90 degree twist).
]]
function Util.rotateAboutPivot(baseC0: CFrame, rotation: CFrame): CFrame
	local pivot = baseC0.Position
	return CFrame.new(pivot) * rotation * CFrame.new(-pivot) * baseC0
end

-- Translate the child in the parent part's own axes.
function Util.translate(baseC0: CFrame, offset: Vector3): CFrame
	return CFrame.new(offset) * baseC0
end

--[[
	Translate the child by a WORLD-space offset whatever the parent is doing.

	Motor6D offsets are expressed in part0's axes, so "down" through a joint
	whose part0 is tilted would otherwise come out sideways. Converting the
	world offset into part0's space first means the caller does not have to
	know or assume anything about that part's orientation.
]]
function Util.translateWorld(baseC0: CFrame, part0: BasePart, worldOffset: Vector3): CFrame
	return CFrame.new(part0.CFrame:VectorToObjectSpace(worldOffset)) * baseC0
end

--[[
	Framerate-independent exponential smoothing. `smoothTime` is roughly the
	number of seconds to close most of the gap; 0 snaps instantly.
]]
function Util.damp(current: number, target: number, smoothTime: number, dt: number): number
	if smoothTime <= 0 then
		return target
	end
	return current + (target - current) * (1 - math.exp(-dt / smoothTime))
end

--[[
	The shortest rotation taking `from` onto `to`, both unit vectors.

	Used to tilt a foot onto a slope. Applying this to the posed rotation
	preserves whatever the pose was doing and adds only the ground tilt.
	Rebuilding the rotation from scratch instead would silently flatten any
	pitch or roll the rest pose had, which shows up as feet snapping to a
	different angle the moment IK engages.
]]
function Util.rotationBetween(from: Vector3, to: Vector3): CFrame
	local dot = math.clamp(from:Dot(to), -1, 1)
	if dot > 0.99999 then
		return CFrame.identity
	end
	if dot < -0.99999 then
		-- Opposite: any perpendicular axis gives a valid half turn.
		local axis = from:Cross(Vector3.xAxis)
		if axis.Magnitude < 1e-4 then
			axis = from:Cross(Vector3.zAxis)
		end
		return CFrame.fromAxisAngle(axis.Unit, math.pi)
	end
	return CFrame.fromAxisAngle(from:Cross(to).Unit, math.acos(dot))
end

--[[
	A joint Transform that also shifts its child by a WORLD offset.

	Motor6D solves part1 = part0 * C0 * Transform * C1:Inverse(). Conjugating
	the offset into the joint's own frame means the child moves by exactly
	`worldOffset` in world space, whatever orientation the joint carries.

	Use this to move a body part for real, rather than pretending it moved
	when solving something else -- offsetting a solve's origin without moving
	the actual joint is what tears a limb away from its socket.
]]
function Util.translateJointWorld(motor: Motor6D, worldOffset: Vector3): CFrame
	return Util.applyWorldToJoint(motor, CFrame.new(worldOffset))
end

--[[
	Apply an arbitrary world-space transformation to a joint's child.

	`worldOp` is what should happen to part1 in world terms; conjugating it
	into the joint's frame produces the Transform that achieves it, whatever
	orientation the joint carries.
]]
function Util.applyWorldToJoint(motor: Motor6D, worldOp: CFrame): CFrame
	local base = motor.Part0.CFrame * motor.C0
	return (base:Inverse() * worldOp * base) * motor.Transform
end

-- A world rotation of `angle` about `axis`, pivoted on `pivot`.
function Util.rotateAboutWorld(pivot: Vector3, axis: Vector3, angle: number): CFrame
	return CFrame.new(pivot) * CFrame.fromAxisAngle(axis, angle) * CFrame.new(-pivot)
end

return Util
