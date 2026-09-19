--[[
	TwoBone -- analytic inverse kinematics for a two-bone limb.

	Two bones and a target form a triangle, so the law of cosines gives the
	middle joint's position outright. There is exactly one answer per bend
	direction, which is why this cannot flicker the way a general chain solver
	can when asked an underdetermined question.

	Everything is computed in world space and handed back as world CFrames.
	Callers convert to joint space through the Motor6D definition

		part1 = part0 * C0 * Transform * C1:Inverse()
		so    Transform = (part0 * C0):Inverse() * part1 * C1

	which holds whatever orientation C0 and C1 carry -- so no part of this
	assumes anything about how a rig's joints are oriented.
]]

local TwoBone = {}

local EPS = 1e-4

--[[
	Rotation frame with +Y down the bone and +X perpendicular to the pole.

	Matching two such frames aligns the bone direction AND its roll, which is
	what lets a solved bone keep the rig's original twist instead of picking
	an arbitrary one.
]]
function TwoBone.boneFrame(dir: Vector3, pole: Vector3): CFrame
	local side = dir:Cross(pole)
	if side.Magnitude < EPS then
		side = dir:Cross(Vector3.xAxis)
		if side.Magnitude < EPS then
			side = dir:Cross(Vector3.zAxis)
		end
	end
	return CFrame.fromMatrix(Vector3.zero, side.Unit, dir)
end

export type Bone = {
	l1: number,        -- length of the upper bone
	l2: number,        -- length of the lower bone
	upperDir: Vector3, -- upper bone's direction in its own local space
	lowerDir: Vector3, -- lower bone's direction in its own local space
	poleUpper: Vector3, -- bind-pose bend direction, in the upper bone's space
	poleLower: Vector3, -- and in the lower bone's space
	startInUpper: Vector3, -- root joint, in the upper bone's space
	midInLower: Vector3,   -- middle joint, in the lower bone's space
}

--[[
	Solve so the limb's tip reaches targetPos.

	Returns the upper and lower bones' world CFrames and the tip position,
	or nil if the limb is degenerate.
]]
function TwoBone.solve(rootPos: Vector3, targetPos: Vector3, bone: Bone, poleWorld: Vector3, margin: number?)
	local toTarget = targetPos - rootPos
	if toTarget.Magnitude < EPS then
		return nil
	end

	--[[
		Clamp into the span the bones can cover, keeping a real margin at both
		ends rather than a token one.

		At full extension the middle joint's offset from the line between the
		ends goes to zero, so which way the limb bends becomes numerically
		undefined and can flip between frames. Stepping down extends a leg
		almost straight, which is exactly when that shows up as a twitch.
		Holding a fraction of bend in reserve keeps the direction well defined.
	]]
	local span = bone.l1 + bone.l2
	local m = margin or 0.02
	local lo = math.abs(bone.l1 - bone.l2) + span * m
	local hi = span * (1 - m)
	local d = math.clamp(toTarget.Magnitude, lo, hi)
	local dir = toTarget.Unit

	-- How far along dir the middle joint sits, and how far off that line.
	local a = (bone.l1 * bone.l1 - bone.l2 * bone.l2 + d * d) / (2 * d)
	local h = math.sqrt(math.max(0, bone.l1 * bone.l1 - a * a))

	local poleOrtho = poleWorld - dir * poleWorld:Dot(dir)
	if poleOrtho.Magnitude < EPS then
		poleOrtho = dir:Cross(Vector3.yAxis)
		if poleOrtho.Magnitude < EPS then
			poleOrtho = dir:Cross(Vector3.xAxis)
		end
	end
	poleOrtho = poleOrtho.Unit

	local midPos = rootPos + dir * a + poleOrtho * h
	local tipPos = rootPos + dir * d

	local upperRot = TwoBone.boneFrame((midPos - rootPos).Unit, poleOrtho)
		* TwoBone.boneFrame(bone.upperDir, bone.poleUpper):Inverse()
	local upperCF = CFrame.new(rootPos) * upperRot * CFrame.new(-bone.startInUpper)

	local lowerRot = TwoBone.boneFrame((tipPos - midPos).Unit, poleOrtho)
		* TwoBone.boneFrame(bone.lowerDir, bone.poleLower):Inverse()
	local lowerCF = CFrame.new(midPos) * lowerRot * CFrame.new(-bone.midInLower)

	return upperCF, lowerCF, tipPos
end

--[[
	Read a two-bone limb's geometry out of its three joints.

	Taken from C0/C1 rather than from live part positions, so the character's
	pose or spawn state at the time of reading cannot corrupt it.
	`forward` is the character's facing in root space, used to record which
	way the limb should bend.
]]
function TwoBone.measure(rig, rootJoint: Motor6D, midJoint: Motor6D, tipJoint: Motor6D, forward: Vector3): Bone?
	local startInUpper = rootJoint.C1.Position
	local midInUpper = midJoint.C0.Position
	local midInLower = midJoint.C1.Position
	local tipInLower = tipJoint.C0.Position

	local upperVec = midInUpper - startInUpper
	local lowerVec = tipInLower - midInLower
	if upperVec.Magnitude < EPS or lowerVec.Magnitude < EPS then
		return nil
	end

	local bindUpper = rig:GetBindOffset(rootJoint.Part1)
	local bindLower = rig:GetBindOffset(midJoint.Part1)

	return {
		l1 = upperVec.Magnitude,
		l2 = lowerVec.Magnitude,
		upperDir = upperVec.Unit,
		lowerDir = lowerVec.Unit,
		poleUpper = bindUpper and bindUpper:VectorToObjectSpace(forward) or forward,
		poleLower = bindLower and bindLower:VectorToObjectSpace(forward) or forward,
		startInUpper = startInUpper,
		midInLower = midInLower,
	}
end

return TwoBone
