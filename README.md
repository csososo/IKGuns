# IKGuns — IK player controller

Animation-driven character with IK corrections layered on top. Configured for
the **Wumig** rig.

## Why not full IK

Full procedural locomotion means hand-writing step timing, foot placement
prediction, weight shift, hip sway and counter-swinging arms. It reads as
"floaty robot" until all of it is right. Animations already solve that.

So: **animations own the pose, IK fixes what animations cannot know.**

| Job | Owner |
| --- | --- |
| Idle / walk / run / jump | Animations |
| Feet on real ground, slopes, stairs | IK |
| Hips dropping so a leg can reach | IK |
| Chest and head aiming at the camera | IK |
| Support hand on the weapon foregrip | IK |

Solving uses Roblox's built-in `IKControl`. You supply targets, the engine
supplies joint angles, and it blends with the `Animator` natively.

## Before this will do anything

Two things the rig is missing:

1. **No `Animator` under the `Humanoid`.** `IKControl` is solved inside the
   animation pipeline and needs one. The code creates a temporary one and
   warns, but add a real `Animator` to the rig on the server so it replicates.
2. **No animations at all.** There is no `Animate` script and no joint names
   that Roblox's default one would recognise, so you cannot borrow the stock
   animations — the rig needs its own idle and walk authored in the Animation
   Editor. `TestLocomotion` stands in until then (see below).

## Rig mapping

`Humanoid.RigType` is `R6`, but the topology is fully custom and closer to R15
with extras. `Config.Parts` maps roles to this rig's names:

| Role | Wumig part |
| --- | --- |
| `Root` | `HumanoidRootPart` |
| `LegRoot` | `Hip` |
| `Spine` | `LowerTorso` |
| `Chest` | `Thorax` |
| `LeftFoot` / `RightFoot` | `LeftHeel` / `RightHeel` |

### Chain roots

`IKControl.ChainRoot` must be the **first moving segment of the limb**, not the
body part it hangs off:

| Chain | ChainRoot | EndEffector |
| --- | --- | --- |
| Legs | `LeftUpperLeg` / `RightUpperLeg` | `LeftHeel` / `RightHeel` |
| Arms | `LeftUpperArm` / `RightUpperArm` | `LeftHand` / `RightHand` |
| Head | `Neck` | attachment on `Head` |

Getting this wrong is spectacular rather than subtle. Rooting the legs at `Hip`
lets the solver rotate `Hip` to help reach a foot target — and `Hip` carries the
whole upper body, so the torso tips while two foot controls fight over the same
joint. It reads as a violent full-body spasm, not as a leg problem.

`Config.Only` is a bisect switch for exactly this kind of hunt: set it to
`"none"`, `"feet"`, `"aim"` or `"arms"` to run one subsystem at a time.

Two rig details worth knowing:

- **There is a `MainMover` part between the `HumanoidRootPart` and the `Hip`.**
  It is a leftover from when the rig was used for animating — not a collider.
  It should have `CanCollide` off, with `Humanoid.HipHeight` holding the
  character up instead. Keep the part: it sits in the chain as
  `HumanoidRootPart → MainMover → Hip`, so removing it means re-jointing the
  root. Hip height rides on `MainMoverJoint` (`MainMover → Hip`) and is applied
  in world space, so no assumption is made about any joint being upright.
- **The foot is three parts** (`Ankle → Heel → Forefoot`). IK ends at the heel;
  the toe stays animation-driven. If you want toe roll on slopes later, that is
  a second small `IKControl` on the `LeftForefoot` joint, not a rewrite.

Aim rotation is split across two spine joints (`HipSpine` 35%, `Waist` 65%) so
the turn reads as the whole torso instead of the chest shearing off the hips.
Weights are in `Config.Aim.SpineJoints`.

## Setup

1. Sync with Rojo (`rojo serve`), or copy by hand:
   - `src/ReplicatedStorage/IKSystem/` → a ModuleScript named `IKSystem` in
     `ReplicatedStorage`, with the others as children (`init.lua` is the module
     itself).
   - `src/StarterPlayerScripts/IKController.client.lua` → a LocalScript in
     `StarterPlayer > StarterPlayerScripts`.
2. Add an `Animator` to the `Humanoid`.
3. Press play and walk onto a slope — feet should tilt, hips should dip.

Retargeting to a different rig: run `tools/DumpRig.lua` (select the rig in the
Explorer, paste into the command bar) and correct `Config.lua` from the output.

## TestLocomotion (throwaway)

`TestLocomotion.lua` is a crude procedural walk that exists **only so the IK
has something to correct** while you have no animations. Delete the file and
`Config.TestLocomotion`, or set `Enabled = false`, the moment you have a real
walk cycle.

It drives feet and hands as world-space targets rather than joint rotations,
which is deliberate:

- It needs to know nothing about how this rig's `C0`s are oriented, so there
  are no guessed rotation axes to get wrong.
- It gives `FootPlanter` an explicit "where the pose wants this foot", instead
  of `FootPlanter` reading the live part and feeding its own previous output
  back in. That feedback is harmless standing still but can make the hip offset
  hunt while walking. A real animation should supply the same thing — swap the
  `SetPoseSource` callback in `init.lua` when you get there.

The gait is a 0.5 duty-factor walk: one foot sweeps linearly backwards along
the ground while the other arcs forward through the air. Stride length is
derived from actual velocity (`stride = speed / (4 × Frequency)`), so the
stance foot travels at exactly ground speed and the feet do not skate.

What it will not do: turning, strafing, jumping, running as a distinct gait, or
anything resembling weight. It is a test fixture, not a shortcut past authoring
animations.

## Weapons

The gun welds to the right hand as normal. IK puts hands on the gun, not the
gun in the hands.

Put an `Attachment` named `LeftGrip` on the weapon where the support hand
belongs (and `RightGrip` plus `Config.Arms.DriveRightHand = true` if you want
both pinned). Equip it as a `Tool`, or parent it to the character with the
attribute `IsWeapon = true`.

## Tuning

Everything is in `Config.lua`. Worth touching first:

- `Aim.MaxYaw` — how far the torso twists before the legs have to turn.
- `Feet.HipInfluence` — `0` stops the hips dipping entirely.
- `Feet.SmoothTime` / `Aim.Responsiveness` — raise to smooth jitter, lower for
  snappier response.

### Collision

IK moves real, collidable parts. If walking feels heavy or snagged, check what
has `CanCollide` on — the system warns at startup listing every part besides
the root that can collide. Usually only the `HumanoidRootPart` and one
dedicated floor collider should.

### Joint limits

The solver respects `HingeConstraint` and `BallSocketConstraint` limits, which
is the cleanest fix if a knee or elbow ever inverts. This rig is already set up
for it: every joint has matching attachments on both parts (`LeftKneeAttachment`
on both `LeftUpperLeg` and `LeftLowerLeg`, and so on), which is exactly the
alignment constraints need. Add a `HingeConstraint` across a knee's two
attachments and the solver will obey it.

## Legs: foot IK over an authored animation

The animation owns the stride, the timing, the lift and the weight.
`FootIK.lua` only meets the ground, and on flat ground it does nothing at all.

A fully procedural gait was tried and abandoned. It works, but humans have an
extremely tuned sense for how people walk, so "nearly right" reads as wrong in
a way it never does for a spider or a mech. An authored walk cycle took about
an hour and immediately looked better than a day of procedural tuning.
Procedural still wins for terrain adaptation, which is exactly what is left.

### How the correction is derived

The correction is **relative**: how much higher or lower the real ground is
than the flat floor the animation assumes, which comes from the root part and
`HipHeight`. On level ground that is zero, so the animation plays untouched.
Setting an absolute foot height instead pins the foot to the floor, cancels
the animation's own vertical motion, and straightens the legs out.

That reference is taken **live from the root, never smoothed and never
raycast**. Power IK does the same: its ground plane is a bone, normally the
root, and what gets smoothed is the foot effector. Smoothing the reference
looks harmless and is not — the Humanoid climbs a step by physically lifting
the character, so a reference that lags claims the ground under the body has
not moved yet, invents a correction for a foot that needs none, and unwinds
it once it catches up. That pump was the twitch, and it peaked at exactly the
moment it was meant to help. Root jitter is the dead zone's job instead.

The animated pose is read by **forward kinematics through the joints'
Transform values**, never from the live parts — the live parts still carry
last frame's correction, so measuring from them measures this system's own
output and compounds until the leg is pinned straight.

Each foot gets a **plant factor**, because a foot the animation has lifted is
deliberately in the air: correcting it fights the animation, and letting it
vote on hip height sinks the body under a leg carrying no weight.

That factor comes from the animation, never from the ground. Unity and Unreal
bake a foot-contact curve into the clip and drive the IK weight from it; the
raycast only decides *where* the ground is. Roblox clips carry no such curve,
so it is recovered by comparing the two feet against the root: the lower one
is taking the weight, and the other is as lifted as the animation lifted it.
Measuring clearance above the surface instead inverts exactly when it matters
— stepping up, the swinging foot passes low over the new surface and reads as
planted, so the IK hauls it down mid-stride.

### Pelvis and foot roll

The two legs' needs split into a shared part and a difference. The average
becomes a hip drop; the difference becomes a **roll about the forward axis**,
so one foot can reach lower while the other stays exactly where it was.
Dropping by the worst of the two drags the leg that needed nothing down too.

The spine **counter-rotates** against that roll (`CounterFraction`), because
everything above the hips is rigidly attached to them. Full cancellation reads
as stiff; a real back absorbs most but not all of it.

When the target is beyond the leg's span the foot **rolls onto its toe**
rather than snapping straight, which buys real extra reach.

### Two mistakes worth not repeating

**Everything below the hips is a chain.** A leg needing no ground correction
still has to be solved whenever the pelvis moves, or it rides the roll and its
foot lifts. "No correction" only means "leave it alone" when the pelvis is
still.

**A joint Transform is relative to its Part0 at solve time.** The root write
moves the pelvis, so a leg's goal must be converted against the pelvis's
post-move CFrame. Using the pre-move one applies the roll twice and throws the
legs clear of the body.

## Ordering (the part that bites people)

**`RenderStepped` runs BEFORE the animation step, not after.** Anything written
to `Motor6D.Transform` from a `BindToRenderStep` callback — at any priority,
including `Character + 1` — is overwritten by the Animator before the frame is
drawn. The writes happen; they just never survive.

So procedural joint writes go on `RunService.Stepped` (PreSimulation), which
runs after animations are applied. That is why `ProceduralLegs` is driven from
`Stepped` while `IKSystem:Update` (which writes `C0`, not `Transform`, and sets
IKControl targets) stays on `BindToRenderStep` at
`Enum.RenderPriority.Character.Value - 1`.

A symptom worth recognising: joint writes that appear to do nothing at all,
with no error. Verify a write survived to the next frame before debugging the
value you wrote — a write that never survives is indistinguishable from a write
that never happened.

Aim offsets are written to `Motor6D.C0`, not `.Transform`. The `Animator`
overwrites `Transform` every frame; `C0` is the bind pose, so animation
composes on top of the aim instead of erasing it. `Util.rotateAboutPivot`
rotates around the joint pivot in the parent part's axes, so it does not care
how any given `C0` happens to be oriented.

## Multiplayer

As shipped this is client-local: **you only see your own IK.** To extend it:

1. Run `IKSystem.new` over every character on each client, not just
   `LocalPlayer.Character`. Foot planting then works for everyone for free.
2. Aim direction does not replicate. Send it to the server on a `RemoteEvent`
   at ~10–20 Hz, write it to a character attribute, and have remote characters
   read that instead of `workspace.CurrentCamera`.

Do not create the `IKControl`s on the server and drive targets from the client —
client-side attachment positions do not replicate, so the server would solve
against stale targets.
