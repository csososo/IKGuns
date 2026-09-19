# IKGuns — IK player controller

Animation-driven character with IK corrections layered on top. Configured for
the **Wumig** rig.

## Where this landed

It started as animations with IK corrections and ended as a fully procedural
gait, having been both. Both paths still work and `Config.Gait` picks one;
the argument for each is under **Two gaits** below.

| Job | `"procedural"` | `"animation"` |
| --- | --- | --- |
| Idle / walk | `ProceduralWalk.lua` | authored clips |
| Feet on real ground, slopes, stairs | `ProceduralWalk.lua` | `FootIK.lua` |
| Hips dropping so a leg can reach | `ProceduralWalk.lua` | `FootIK.lua` |
| Chest and head aiming at the camera | `Aim.lua` | `Aim.lua` |
| Support hand on the weapon foregrip | `Arms` (off) | `Arms` (off) |

Legs are solved analytically by `TwoBone.lua` rather than by `IKControl`. Two
bones and a target form a triangle, so the law of cosines gives the answer
outright — there is exactly one solution per bend direction, which is why it
cannot flicker the way a general chain solver can when asked an
underdetermined question. `IKControl` is still used for the arms and head.

## What the rig needs

- **An `Animator` under the `Humanoid`.** `CharacterSetup.server.lua` adds one
  if it is missing, but a real one on the rig replicates properly.
- **`Humanoid.HipHeight` set** (2.7 for this rig) and automatic scaling off.
  `CharacterSetup` enforces both, because they were observed reverting during
  spawn. With HipHeight at 0 the rig's feet sit 2.7 studs underground and the
  Humanoid never registers a floor.
- **Nothing collidable but the root.** Every other part is IK-driven, and a
  limb in the floor drags the whole character.

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
`"none"`, `"legs"`, `"aim"` or `"arms"` to run one subsystem at a time.
Make sure it really covers what you are ruling out — it once gated aim and
arms but not the legs, which made `"none"` read as evidence when it was not.

Two rig details worth knowing:

- **There is a `MainMover` part between the `HumanoidRootPart` and the `Hip`.**
  It is a leftover from when the rig was used for animating — not a collider.
  It should have `CanCollide` off, with `Humanoid.HipHeight` holding the
  character up instead. Keep the part: it sits in the chain as
  `HumanoidRootPart → MainMover → Hip`, so removing it means re-jointing the
  root. Hip height rides on `MainMoverJoint` (`MainMover → Hip`) and is applied
  in world space, so no assumption is made about any joint being upright.
- **The foot is three parts** (`Ankle → Heel → Forefoot`). The leg IK ends at
  the ankle plate; the heel joint carries the ankle rocker and the forefoot
  joint the toe bend, which is what gives heel strike and toe-off.

Aim rotation is split across two spine joints (`HipSpine` 35%, `Waist` 65%) so
the turn reads as the whole torso instead of the chest shearing off the hips.
Weights are in `Config.Aim.SpineJoints`.

## Setup

1. Sync with Rojo (`rojo serve`), or copy by hand:
   - `src/ReplicatedStorage/IKSystem/` → a ModuleScript named `IKSystem` in
     `ReplicatedStorage`, with the others as children (`init.lua` is the module
     itself).
   - `src/StarterPlayerScripts/` → LocalScripts in
     `StarterPlayer > StarterPlayerScripts`: `IKController` drives the system,
     `CharacterAnimator` plays the clips, `WalkTuner` is the gait panel.
   - `src/ServerScriptService/CharacterSetup.server.lua` → a Script in
     `ServerScriptService`.
2. Press play. Walk onto a slope — feet should tilt and meet it.
3. Press `]` for the gait tuner.

New top-level mappings in `default.project.json` are read at startup, so
restart `rojo serve` after adding one. Files inside a folder that is already
mapped sync without a restart.

Retargeting to a different rig: run `tools/DumpRig.lua` (select the rig in the
Explorer, paste into the command bar) and correct `Config.lua` from the output.

## Weapons

The gun welds to the right hand as normal. IK puts hands on the gun, not the
gun in the hands.

Put an `Attachment` named `LeftGrip` on the weapon where the support hand
belongs (and `RightGrip` plus `Config.Arms.DriveRightHand = true` if you want
both pinned). Equip it as a `Tool`, or parent it to the character with the
attribute `IsWeapon = true`.

## Tuning

The procedural gait is tuned live — press `]` in game, see **Tuning it**
below. Everything else is in `Config.lua`:

- `Aim.MaxYaw` — how far the torso twists before the legs have to turn.
- `FootIK.HipInfluence` — `0` stops the hips dipping entirely.
- `FootIK.SmoothTime` / `Aim.Responsiveness` — raise to smooth jitter, lower
  for snappier response.

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

## Two gaits, and `Config.Gait` picks one

`"animation"` plays authored clips with `FootIK.lua` correcting them onto the
ground. `"procedural"` hands the whole pose to `ProceduralWalk.lua` and leaves
the Animator silent. They are exclusive on purpose: running both means two
systems writing `Motor6D.Transform` with no agreement about who owns the
frame.

### The twitch, and where it actually was

Five rounds of fixes went into `FootIK.lua` chasing a twitch when walking onto
a step. Each one found a real bug. None of them was the twitch.

What settled it was `Config.Only = "none"` — and the twitch survived with the
entire IK system switched off. The clue had been in the logs for a while: the
correction reaching the rig was about **two hundredths of a stud**, which
cannot produce something you can see.

It was `CharacterAnimator`. Climbing a step drops the Humanoid into `Freefall`
for a handful of frames, and with `Fall` and `Jump` unset, `chooseState` fell
through to `Idle` — so stepping onto anything crossfaded Walk out over 0.2s
and straight back in. `Config.Only` never touched it, because the switch
gated aim and arms but had never been extended to cover the legs.

Two things worth keeping from that:

- **A bisect switch that does not cover the suspect is worse than none.** It
  reads as evidence and is not.
- **When the magnitude of a system's output cannot explain the symptom, stop
  tuning it.** That is a measurement, and it outranks any amount of plausible
  reasoning about the code in front of you.

### Procedural gait

`ProceduralWalk.lua` owns the pose outright, and because nothing else writes
these joints it writes them directly — no clean-base bookkeeping, no
composing onto another system's value, no reading its own output back a frame
later. That entire class of bug is absent by construction.

Everything solves against a pelvis the module computes itself, and the chest,
arms and feet chain off *that* rather than off the live parts. The live pelvis
is last frame's answer, and feeding it back is what makes a procedural leg
buzz.

**Feet are planted, not placed.** During stance a foot holds a fixed world
position and the hip travels away from it. That is the whole difference
between walking and waving your legs about while you slide: positioning the
foot relative to the hip every frame means it tracks the body perfectly and
never pushes against anything.

Swing interpolates from the lift-off anchor to a predicted landing. The body
covers `(1-duty)/duty` step lengths during one swing, a ratio that does not
depend on speed, and the remaining travel is recomputed every frame — so
turning mid-stride redirects the step instead of planting it where you used to
be going. When a planted foot runs out of reach — a reversal, a hard turn — it
**steps early rather than sliding**. Dragging the anchor onto the reach
circle bounds the problem and looks terrible: the circle moves with the hip,
so every frame re-clamps and the foot skates along at arm's length. Jumping
that leg's phase to the start of its swing costs nothing, because swing
begins at the current anchor and the foot does not move on the frame it
happens; everything after is an ordinary swing with a real arc and a real
plant. The resulting phase shift unwinds over the following strides, in the
air only, so the legs come back into alternation on their own.

Speed and direction both come from a **smoothed velocity vector**, never from
a separately smoothed magnitude. Held alternately, A and D cancel — you go
nowhere — but `|velocity|` never drops, so a gait reading the magnitude sees a
sprint and runs full strides back and forth over the same patch of ground.
Smoothing the vector cancels the way the movement does. Straight-line movement
is unaffected: with a steady direction the two are the same thing.

**Stride grows with speed, and cadence takes the rest.** A constant stride
splays the legs whenever direction alternates: the smoothed speed drops but
the feet still reach their full stride each way, so one plants hard left and
the other hard right. Real gait divides a change of pace between the two, and
`StrideExponent` sets the split — 0.5 shares it evenly, 1 puts it all in
stride and leaves cadence fixed.

**Never lift a foot while the other is up.** An early step is a convenience;
having something to stand on is not. A `DutyFactor` below 0.5 already designs
in a float phase — at 0.439 that is 12% of every cycle with both feet off the
ground — so early steps are suppressed while the other leg is airborne rather
than stacking on top of it.

**Phase advances with distance, not time**, so cadence rises with speed on its
own. Driving it off a clock means choosing a cadence, and then the feet skate
whenever the real speed disagrees with it. It keeps advancing while the gait
folds away, scaled by the blend: freezing it the instant you stop leaves the
legs stuck mid-stride while the stride shrinks around them, which is exactly
what "it freezes, then goes back to idle" looks like.

Idle is not a separate path. At blend zero the stride and lift both fall to
nothing and each foot sits under its own hip, which *is* the standing pose, so
there is no state to pop between. Stance width and forward bias survive the
blend, because those are posture and posture does not stop when you do.

### Direction

Steps go along the **velocity**, not the facing. A gait that only understands
forward marches the legs the wrong way when you walk backwards and side-steps
with a forward stride when you strafe; placing steps along travel gets
backwards, strafing and every diagonal from one expression.

Two things follow from it. Foot roll scales by travel · facing, so it is heel
first forwards, toe first backwards and neither sideways, passing smoothly
through zero on a diagonal. And lean tilts along travel, because leaning
forward while walking backwards is the wrong way round.

A **planted foot keeps the heading it landed on**. Taking foot orientation off
the body's facing means swinging the camera spins every foot on the spot,
including the one bearing weight. Only a foot in the air turns, and it turns
to meet the heading it is about to land on. At low blend it eases back to
facing anyway, so turning on the spot brings the feet round rather than
leaving them splayed.

**Strafing gets its own posture.** Side-stepping puts both feet on one line
across the body, where they read as a single mass with nothing to clear each
other by. So the feet stagger fore and aft — `StrafeStagger` puts the foot on
the side you are heading towards in front and the other behind, giving a clear
front leg and a clear back leg, which is what people do anyway. `StrafeCross` then swaps which
foot leads on every plant, so the legs pass each other — forward, then back,
then forward — which is the grapevine a real side-step falls into, and what
makes it read as stepping rather than as a pose being carried sideways.
`StrafeWidth` and `StrafeLift` add the clearance: a little more room across, a little more
height on the swing so the moving foot passes the planted one. All of it scales
with how sideways the travel is *and* with the gait blend, so forward walking
is untouched and there is no separate case for it. The blend term matters:
strafe posture belongs to the gait, not to standing, and without it the
stagger and spread survive into idle at full strength so the hips never settle
after a side-step.

The travel direction comes **straight from the smoothed velocity**, with no
angular rate limit. There was one, from when the direction came off raw
velocity and a reversal could make it thrash; smoothing the velocity *vector*
replaced the reason for it and left it behind, where it did real harm. Told to
go from left to right it rotates the long way round **through forward**, so a
third of a second into reversing a strafe the gait believes you are walking
forwards while you are still moving left at twelve studs a second — the strafe
posture collapses and returns, the stride pulses, and the lean axis swings a
half turn. Going from rest looks fine because it only travels ninety degrees
and arrives directly.

The smoothed vector already changes smoothly, and its direction flips at the
zero crossing, which is exactly when speed is lowest and the gait is folding.
That flip is what reversing *is*: slow, stop, go the other way.

**Side-steps are shorter, and have to be.** The feet are held apart *across*
the body, so sideways travel runs the stride along the very axis keeping them
apart. A step longer than twice the separation lands the trailing foot past
the leading one — with a 2.78 stride against 1.2 of hip separation, it
overshoots by 0.19 studs on every side-step. That is the leg intersection.

Clamping each foot to its own side stops the crossing and produces something
worse: the trailing foot hits the limit and *stops*, so the leg slides instead
of stepping. `SideStepRatio` scales the stride down as travel turns sideways
instead, which keeps both feet stepping.

**The idle stance is symmetric, but pinned to a frozen frame.** Two
requirements look contradictory here: feet must settle into an even stance
when you stop, *and* must not slide about when the body turns underneath them
— which in shift lock is every time you move the camera.

Leaving each foot where it last landed satisfies the second and fails the
first: the stance keeps whatever asymmetry the last step ended on, and a
deadzone means it stays there forever, one leg permanently out. So the stance
is computed symmetrically, under each hip, but against a **frozen copy of the
body frame**. Turning the camera moves nothing. Once the body has moved or
turned too far to stand in, that frame eases across and the feet shuffle with
it. For the same reason a planted foot never rotates except during a shuffle
or past the `MaxFootLag` pivot.

**The knee points where the foot points.** A planted foot holds the heading it
landed on, so handing the solver the body's facing as its pole means the knee
plane turns with the body while the foot stays put. Shin and foot then
disagree by up to `MaxFootLag`, and because the ankle is written to an
orientation of its own regardless of the shin, that whole mismatch lands in
the ankle joint as a visible twist — the leg deforming when you turn while
walking. Anatomically it is the wrong way round anyway: your knee tracks your
foot, which is why a planted foot must pivot before you can turn much further.

Foot heading is an **angle off the facing**, clamped by `MaxFootYaw`, not a
lerp between two direction vectors — that collapses to zero length when
travel opposes facing, and before that it points the feet backwards when
walking backwards. Folding the yaw difference into the front half discards
the reversal and keeps only how far off-axis the travel is. A planted foot
may lag the body by `MaxFootLag` before it pivots round, at `PivotRate` and
going all the way rather than stopping at the limit — which is what a pivot on
the ball of the foot does, and also avoids re-triggering on every frame the
body keeps turning. Doing that catch-up in a single frame is what made one leg
snap when adding A to a held W or S: with `AutoRotate` the character faces
wherever it is going, so the body swings the full 45° of the new input,
straight past the limit, on the turn's first frame.

What stays deliberately body-relative: stance width, the `FootAhead` posture,
the sway axis, the arm-swing plane, and the knee pole — knees bend forward
relative to the body whichever way it is travelling.

### Foot roll

The rig has an ankle plate, a foot block and a toe, and a walk that does not
use them lands flat and leaves flat. Real stance is four events:

| | |
|---|---|
| heel strike | toes up, heel only |
| foot flat | sole down, ~12% into stance |
| heel rise | ~58% in |
| toe off | toes down 15–20° |

Dorsiflexion through midstance is deliberately absent: the foot is held flat
on the surface and the shin comes down to meet it, so that angle falls out of
the IK on its own. Only what the geometry *cannot* produce is driven.

Plantarflexion pivots on the toe, so the ankle target rises by the measured
ankle-to-toe length times the sine of the angle. Without that the foot rotates
while the ankle stays put and the toe drives through the floor.

### Pelvis and arms

Pelvic list drops the swing-side hip, keeping the centre of mass on a flatter
path than the legs alone allow. The spine gives most of the pelvis yaw back —
pelvis and thorax counter-rotate when you walk, and that opposition is what
arm swing is actually driven by. Without it the torso yaws as one block and
reads as swivelling.

Arms swing against the leg on the same side, and **bend**. A shoulder rotating
on its own is what reads as a mannequin. `ElbowBend` is posture and survives
the blend, because a real arm never straightens even standing still;
`ElbowSwing` is the extra flexion as the arm comes forward.

### Tuning it

Press `]` in game for **WalkTuner**. It holds the same `Config` table the gait
reads, so a slider changes the walk on the next frame with no plumbing in
between. Typing in a readout box is not clamped to the slider's range — the
range is a guess at what is useful, not a limit on what is legal.

Nothing is saved. **Copy to Output** prints a paste-ready block for
`Config.Walk`; without that, the next session starts from the file again.

**Every range that could want either sign has one**, and that is load-bearing
rather than tidy: nothing here can know which way a given rig's joint axes
point, so `FootPitchScale`, `ArmSwing`, `ElbowBend`, `PelvisList` and
`LeanAngle` are all sign-discovered by dragging past zero. If something looks
wrong rather than merely too strong, try negative before you try smaller — a
foot rolling backwards at 5° and at 20° are the same mistake, just quieter.

Roughly the order that converges fastest:

1. `DutyFactor` and `StepLength` until the feet stop sliding and the overlap
   looks right. Above 0.5 both feet share the ground, which is what makes a
   walk a walk; below 0.5 there is a moment with neither down, which reads as
   a run. Reach for this before `StepLength` if steps feel like lunges.
2. `StepHeight` and `FootAhead` for the shape of the step.
3. The **Foot roll** group. Confirm `FootPitchScale`'s sign first — heel should
   touch first and the toe should be last to leave — because every other value
   in the group is applied through it.
4. `BobHeight` and `SwayWidth` for weight. These are small, a few hundredths,
   and overdoing them is the fastest way to look like a puppet.
5. `FootTurnToMove` while strafing. At 0 the feet stay square to the body and
   you get a proper side-step; at 1 they turn fully into the step. Neither is
   wrong, it is a style call.
6. Arms and pelvis last.

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

The correction is smoothed **only as far as the foot is planted**. Smoothing
exists to stop a weight-bearing foot snapping when the ground under it
changes; a foot in the air applies none of its correction, so there is
nothing there to snap, and lagging it does real harm — the raycast under a
swinging foot reads whatever it is passing over, and the smoothing carries
that stale value into touchdown, where the weight ramps in on top of it. A
foot crossing a step in mid-air would land still holding a tenth of a stud of
correction for a surface it only flew over. Tracking the ground exactly while
airborne means the correction arrives at touchdown already right, with
nothing left to unwind.

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
runs after animations are applied. That is why `IKSystem:UpdateLate` — which
is where both `ProceduralWalk` and `FootIK` live — is driven from `Stepped`,
while `IKSystem:Update` (which writes `C0`, not `Transform`, and sets
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
