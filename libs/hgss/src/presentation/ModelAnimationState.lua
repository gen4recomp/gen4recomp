-- ModelAnimationState: the per-instance collection of playing attachments,
-- kept in the same two attachment groups NitroSystem uses because the
-- groups do not combine state identically:
--
--   joint        -- NSBCA-style node transforms (blended)
--   material     -- NSBTA/NSBTP/NSBMA material state (composed)
--
-- Field visibility animation does not exist (the corpus has no NSBVA
-- members), so there is no visibility group and the clip category
-- vocabulary is joint and material.
--
-- Attachments are attached by clip category into the matching group. One
-- attachment per clip kind: a second same-kind clip is rejected at attach
-- (the material priority arbitration is cut; the joint group's only kind is
-- trs, so it is single-attachment for the same reason). The binding comes
-- from the definition (the definition IS the model), so attach takes the
-- clip and playback opts only -- never a caller-supplied binding. Each
-- attach returns the LIVE attachment as the handle; detach(handle) removes
-- exactly that attachment. Storage is compact: each group is an array of
-- the active attachments in attach order, so attachments(category)
-- snapshots only what is active and detach never scans the other groups --
-- there is no token bookkeeping and no monotonically growing range. The
-- group evaluators (pose backends, material evaluator) read attachments()
-- at evaluation time.
--
-- Two instances of one model each own a state, so the same clip can play at
-- different frames on different instances. Pure domain module.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local AnimationClip = require("libs.assets.src.model.AnimationClip")
local AnimationPlayer = require("libs.hgss.src.presentation.AnimationPlayer")

local ModelAnimationState = {}
ModelAnimationState.__index = ModelAnimationState

ModelAnimationState.GROUPS = { AnimationClip.CATEGORIES.joint, AnimationClip.CATEGORIES.material }

function ModelAnimationState.new(definition)
  assert(type(definition) == "table" and definition.key ~= nil, "ModelAnimationState.new requires a ModelDefinition")
  return setmetatable({
    definition = definition,
    groups = {
      [AnimationClip.CATEGORIES.joint] = {},
      [AnimationClip.CATEGORIES.material] = {},
    },
  }, ModelAnimationState)
end

-- Attach a clip to the group its category selects, bound through the
-- definition's precomputed binding. `opts` may supply the player (defaults
-- to a fresh one). A clip whose binding resolves zero model elements is a
-- data failure and raises ANIM_STATE_ZERO_BINDING; a second attachment of
-- the same kind raises ANIM_STATE_SAME_KIND_IN_USE (one attachment per
-- kind). Returns the LIVE attachment as the handle.
function ModelAnimationState:attach(clip, opts)
  if not AnimationClip.CATEGORIES[clip.category] then
    Errors.raise(
      FieldErrors.ANIM_STATE_BAD_CATEGORY,
      "clip " .. clip.id .. " has unknown category " .. tostring(clip.category),
      {}
    )
  end
  local binding = self.definition:binding(clip)
  if next(binding.map) == nil then
    Errors.raise(
      FieldErrors.ANIM_STATE_ZERO_BINDING,
      "clip "
        .. clip.id
        .. " binds zero model elements of "
        .. self.definition.key
        .. "; the animation/model association is likely wrong",
      { clip = clip.id, modelKey = self.definition.key }
    )
  end

  local group = self.groups[clip.category]
  for _, attachment in ipairs(group) do
    if attachment.clip.kind == clip.kind then
      Errors.raise(
        FieldErrors.ANIM_STATE_SAME_KIND_IN_USE,
        "clip "
          .. clip.id
          .. " (kind "
          .. tostring(clip.kind)
          .. ") conflicts with the already-attached "
          .. attachment.clip.id
          .. " on "
          .. self.definition.key
          .. "; one attachment per kind",
        { clip = clip.id, kind = clip.kind, modelKey = self.definition.key }
      )
    end
  end

  local attachment = {
    clip = clip,
    binding = binding,
    player = (opts or {}).player or AnimationPlayer.new(clip),
  }
  group[#group + 1] = attachment
  return attachment
end

-- Detach exactly the given attachment, returning the number of attachments
-- removed (1 or 0). A handle that is not attached is a no-op (a double stop
-- removes nothing).
function ModelAnimationState:detach(handle)
  if type(handle) ~= "table" or not handle.clip then
    return 0
  end
  local group = self.groups[handle.clip.category]
  for i, attachment in ipairs(group) do
    if attachment == handle then
      table.remove(group, i)
      return 1
    end
  end
  return 0
end

-- A snapshot list of the active attachments in one group, in attach order
-- (the storage is already compact: only the active attachments live in the
-- array, so the snapshot is O(active), not O(ever-attached)).
function ModelAnimationState:attachments(category)
  local out = {}
  return self:attachmentsInto(category, out)
end

-- Fill a caller-owned list with the active attachments of one group, in
-- attach order, clearing any stale tail from a longer previous fill.
-- Returns the same `out` table; the internal group is never exposed.
function ModelAnimationState:attachmentsInto(category, out)
  assert(type(out) == "table", "attachmentsInto requires a caller-owned output table")
  local group = self.groups[category]
  assert(group ~= nil, "attachmentsInto requires a known attachment category")
  for i, attachment in ipairs(group) do
    out[i] = attachment
  end
  for i = #group + 1, #out do
    out[i] = nil
  end
  return out
end

-- Advance every player of every group by one fixed step.
function ModelAnimationState:updateFixed()
  for _, group in pairs(self.groups) do
    for _, attachment in ipairs(group) do
      attachment.player:updateFixed()
    end
  end
end

return ModelAnimationState
