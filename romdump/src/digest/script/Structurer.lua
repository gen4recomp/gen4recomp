-- Control-flow structuring : turns the lowered item list
-- (linear items plus if_cond/goto control items) into structured
-- `if`/`else` blocks where provable, retaining labels and gotos otherwise.
-- The algorithm peels the canonical conditional-skip pattern (a conditional
-- branch to a forward label whose fallthrough chain ends with an
-- unconditional goto to the region join); anything else falls back to
-- labels and gotos. A conditional call (`call_if`) is never a branch region:
-- its source semantics are "conditionally call target, then return to the
-- following instruction", so it always becomes a structured `if` wrapping
-- the call. Correctness beats readability. Pure domain module: no love
-- dependency.

local Structurer = {}

-- Negate a condition for the structured if (the fallthrough of a GoToIf
-- runs when the branch condition does not hold).
---@param condition table<string, unknown>
---@return table<string, unknown>
local function negate(condition)
  if condition.condition == "compare" then
    local flipped = { lt = "ge", ge = "lt", gt = "le", le = "gt", eq = "ne", ne = "eq" }
    local copy = {}
    for key, value in pairs(condition) do
      copy[key] = value
    end
    copy.operator = flipped[condition.operator] or condition.operator
    return copy
  elseif condition.condition == "flag" then
    local copy = {}
    for key, value in pairs(condition) do
      copy[key] = value
    end
    copy.expected = not condition.expected
    return copy
  elseif condition.condition == "not" then
    return condition.operand
  end
  return { condition = "not", operand = condition }
end

-- Collect the label positions in the item list (item index -> label name).
---@param items table[]
---@return table<string, integer>
local function labelPositions(items)
  local positions = {}
  for i, item in ipairs(items) do
    if item.op == "label" then
      positions[item.name] = i
    end
  end
  return positions
end

-- Count every control item that targets each label. A conditional's boundary
-- label is consumed by the structured peel; when another control item also
-- targets that label (a jump into the middle of the candidate region), the
-- peel must not run and the label/goto fallback is retained instead
-- (ambiguous branch ownership).
---@param items table[]
---@param positions table<string, integer>
---@return table<string, integer>
local function labelRefCounts(items, positions)
  local counts = {}
  for _, item in ipairs(items) do
    if item.op == "if_cond" or item.op == "goto" or item.op == "goto_if" then
      if positions[item.target] ~= nil then
        counts[item.target] = (counts[item.target] or 0) + 1
      end
    end
  end
  return counts
end

-- The join of a region: the first index not reachable from the region's
-- entry without passing through the exit label. For the peel we require
-- the fallthrough chain's terminal goto target to equal the else-chain
-- entry's join. Returns nil when the region cannot be proven structured.
-- `exit` is the enclosing region's exclusive bound: a join beyond it would
-- swallow items the enclosing structure still owns (duplicate labels).
---@param items table[]
---@param positions table<string, integer>
---@param entry integer
---@param exit integer|nil
---@return table<string, unknown>|nil { join: integer, terminal: integer }
local function findJoin(items, positions, entry, exit)
  -- entry is an if_cond item; the join is the target of the fallthrough
  -- chain's terminal goto, and the conditional target must lie between.
  -- A backward conditional target, a join at or before the entry, or a join
  -- beyond the enclosing region's bound is an irreducible loop or an
  -- ownership violation (the structured if/else peel cannot own the region);
  -- those fall back to labels and gotos.
  local conditionalTarget = positions[items[entry].target]
  if conditionalTarget == nil then
    return nil
  end
  if conditionalTarget < entry then
    return nil
  end
  if exit ~= nil and conditionalTarget >= exit then
    return nil
  end
  local cursor = entry + 1
  while cursor <= #items do
    local item = items[cursor]
    if item.op == "goto" then
      local join = positions[item.target]
      if join == nil then
        return nil
      end
      if join < conditionalTarget or join <= entry then
        return nil
      end
      if exit ~= nil and join >= exit then
        return nil
      end
      return { join = join, terminal = cursor }
    elseif item.op == "if_cond" or item.op == "stop" or item.op == "request_start_menu" or item.op == "return" then
      return nil
    end
    cursor = cursor + 1
  end
  return nil
end

-- Structure the linear item list recursively (forward declaration).
local structure

-- Peel one conditional region: `if <condition> then <fallthrough> else
-- <target..join>`. Returns the steps plus the new cursor.
---@param items table[]
---@param entry integer
---@param join integer
---@param terminal integer
---@param refCounts table<string, integer>
---@param positions table<string, integer>
---@return table[] steps
local function peelConditional(items, entry, join, terminal, positions, refCounts)
  local item = items[entry]
  local target = positions[item.target]
  assert(target ~= nil, "conditional target must have a label")
  -- A target label immediately before the fallthrough terminal goto names a
  -- shared source prefix. Keep that prefix after the conditional so the goto
  -- is represented once while both paths still reach it.
  local sharedPrefix = target == terminal - 1
  local yes = structure(items, entry + 1, sharedPrefix and terminal - 1 or terminal, positions, refCounts)
  -- The items between the fallthrough terminal and the conditional target
  -- are skipped by both branch paths, but their labels can be branch
  -- targets from elsewhere; they are appended inside the then-region after
  -- the terminal goto (so both branch paths still skip them) and every
  -- referenced label resolves in the final program.
  local skipped = structure(items, terminal + 1, positions[item.target] - 1, positions, refCounts)
  for _, step in ipairs(skipped) do
    yes[#yes + 1] = step
  end
  local result = {
    {
      op = "if",
      condition = negate(item.condition),
      provenance = item.provenance,
      -- The then-region is the fallthrough chain through its terminal goto
      -- (the goto is retained so the source instruction stays covered),
      -- unless that goto is shared by both paths and is emitted after the
      -- conditional; the else-region is the conditional target's chain.
      yes = yes,
      no = sharedPrefix and {} or structure(items, target + 1, join - 1, positions, refCounts),
    },
  }
  if sharedPrefix then
    local shared = structure(items, terminal, join - 1, positions, refCounts)
    for _, step in ipairs(shared) do
      result[#result + 1] = step
    end
  end
  return result
end

function structure(items, entry, exit, positions, refCounts)
  local steps = {}
  local cursor = entry
  while cursor <= (exit or #items) do
    local item = items[cursor]
    if item.op == "label" then
      steps[#steps + 1] = { op = "label", name = item.name }
      cursor = cursor + 1
    elseif item.op == "call_if" then
      -- A conditional call is never a branch region: it conditionally calls
      -- the target and returns to the following instruction, so the
      -- structured `if` wrapping the call is the only faithful shape.
      steps[#steps + 1] = {
        op = "if",
        condition = item.condition,
        provenance = item.provenance,
        yes = { { op = "call", target = item.target } },
        no = {},
      }
      cursor = cursor + 1
    elseif item.op == "if_cond" then
      local region = findJoin(items, positions, cursor, exit)
      -- The conditional target label must be owned by exactly this
      -- conditional; a second referent means the label is a region entry
      -- from outside, and the peel would consume a label the retained
      -- fallback gotos still need.
      if region ~= nil and (refCounts[item.target] or 0) <= 1 then
        local regionShape = region --[[@as { join: integer, terminal: integer }]]
        local peeled = peelConditional(items, cursor, regionShape.join, regionShape.terminal, positions, refCounts)
        for _, step in ipairs(peeled) do
          steps[#steps + 1] = step
        end
        cursor = regionShape.join
      else
        -- Irreducible or ambiguous: retain the label/goto fallback.
        steps[#steps + 1] = {
          op = "goto_if",
          condition = item.condition,
          target = item.target,
          provenance = item.provenance,
        }
        cursor = cursor + 1
      end
    elseif item.op == "goto" then
      -- Every goto is retained with its provenance: a region-terminal goto
      -- whose target falls through is a provable no-op, but dropping it
      -- would leave the source instruction uncovered by the final program.
      steps[#steps + 1] = {
        op = "goto",
        target = item.target,
        provenance = item.provenance,
      }
      cursor = cursor + 1
    elseif item.op == "stop" or item.op == "return" or item.op == "next" then
      local copy = {}
      for key, value in pairs(item) do
        copy[key] = value
      end
      steps[#steps + 1] = copy
      cursor = cursor + 1
    else
      local copy = {}
      for key, value in pairs(item) do
        copy[key] = value
      end
      steps[#steps + 1] = copy
      cursor = cursor + 1
    end
  end
  return steps
end

-- Structure a lowered script into a steps array.
---@param lowered table<string, unknown>
---@param _ integer
---@return table<string, unknown> steps
function Structurer.structure(lowered, _)
  local items = lowered.items
  -- Label markers are inserted where if_cond/goto targets land.
  local positions = labelPositions(items)
  -- The lowering resolves every branch target (SemanticLowering
  -- resolveControlTargets turns unresolvable targets into explicit
  -- unsupported nodes), so an unresolved target here is an invariant
  -- violation, not a synthesizable fallback.
  for _, item in ipairs(items) do
    if (item.op == "if_cond" or item.op == "goto_if" or item.op == "goto") and positions[item.target] == nil then
      assert(false, "unresolved branch target " .. tostring(item.target))
    end
  end
  local refCounts = labelRefCounts(items, positions)
  return structure(items, 1, nil, positions, refCounts)
end

return Structurer
