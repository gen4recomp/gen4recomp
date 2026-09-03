-- HGSS script command catalog accessor: loads the pinned in-repo catalog
-- (romdump/src/reference/hgss/script_commands.lua) and exposes the opcode names,
-- operand widths, and execution classifications the translator uses
-- internally. The catalog is owned in-repo: the decomp's command table named
-- every opcode once; names may be adjusted here without touching the decomp.
-- Pure domain module: no love dependency.

local ScriptCommands = require("romdump.src.reference.hgss.script_commands")

local CommandCatalog = {}

CommandCatalog.SOURCE = ScriptCommands.source

-- Execution classifications.
CommandCatalog.CONTINUE = "continue_same_tick"
CommandCatalog.YIELD = "yield_next_tick"
CommandCatalog.NATIVE_WAIT = "native_wait"
CommandCatalog.STOP = "stop"
CommandCatalog.UNSUPPORTED = "unsupported"

CommandCatalog.NAMES = {}
CommandCatalog.CLASSIFICATION = {}
for opcode, entry in pairs(ScriptCommands.byOpcode) do
  CommandCatalog.NAMES[opcode] = entry.name
  if entry.classification ~= nil then
    CommandCatalog.CLASSIFICATION[opcode] = entry.classification
  end
end
-- ScrCmd_609 checks for a following Pokémon and returns FALSE when none is
-- present. The opening path has no follower, so its supported semantics are
-- one scheduler yield; active followers remain explicitly unsupported.
CommandCatalog.CLASSIFICATION[609] = CommandCatalog.YIELD

-- Opcode 582 (the special-spawn setter) and opcode 729 (the follower-active
-- query) have real supported semantics with no follower subsystem required:
-- 582 records a source location, 729 writes the no-follower false result.
-- Opcodes 596/600 are genuine active-follower behavior with no implemented
-- follower subsystem; they stay unclassified so they fall through to the
-- explicit unsupported default and fault loudly if a script ever reaches
-- them, instead of masquerading as a successful no-op.
for _, opcode in ipairs({ 582, 729 }) do
  CommandCatalog.CLASSIFICATION[opcode] = CommandCatalog.CONTINUE
end

-- The supported opcodes: every opcode with an explicit timing
-- descriptor; everything else decodes but stays an explicit unsupported node.
CommandCatalog.SUPPORTED = {}
for opcode in pairs(CommandCatalog.CLASSIFICATION) do
  CommandCatalog.SUPPORTED[opcode] = true
end

-- Resolve the classification for any opcode; unknown opcodes are unsupported.
---@param opcode integer
---@return string
function CommandCatalog.classification(opcode)
  return CommandCatalog.CLASSIFICATION[opcode] or CommandCatalog.UNSUPPORTED
end

---@param opcode integer
---@return string
function CommandCatalog.name(opcode)
  return CommandCatalog.NAMES[opcode] or ("ScrCmd_%03d"):format(opcode)
end

-- Operand widths for one opcode (binary decoder walk); nil when unknown.
---@param opcode integer
---@return integer[]|nil
function CommandCatalog.widths(opcode)
  local entry = ScriptCommands.byOpcode[opcode]
  return entry ~= nil and entry.widths or nil
end

-- Mon-family disposition metadata. The authoritative entries live in the
-- pinned reference table; these accessors are the single query path for
-- lowering and audits so no second disposition list can drift.
---@param opcode integer
---@return string|nil
function CommandCatalog.feature(opcode)
  local entry = ScriptCommands.byOpcode[opcode]
  return entry ~= nil and entry.feature or nil
end

---@param opcode integer
---@return string|nil
function CommandCatalog.disposition(opcode)
  local entry = ScriptCommands.byOpcode[opcode]
  return entry ~= nil and entry.disposition or nil
end

---@param opcode integer
---@return string|nil
function CommandCatalog.deferredReason(opcode)
  local entry = ScriptCommands.byOpcode[opcode]
  return entry ~= nil and entry.deferredReason or nil
end

---@param opcode integer
---@return string|nil
function CommandCatalog.deferredNote(opcode)
  local entry = ScriptCommands.byOpcode[opcode]
  return entry ~= nil and entry.deferredNote or nil
end

-- Arg-dependent width variants for one opcode (evaluated in order against
-- the base operand values; the first match adds `extra` widths); nil when
-- the opcode has a fixed width.
---@param opcode integer
---@return table[]|nil
function CommandCatalog.variants(opcode)
  local entry = ScriptCommands.byOpcode[opcode]
  return entry ~= nil and entry.variants or nil
end

-- Evaluate the width variants for an opcode against its already-decoded base
-- operands; returns the extra widths, or nil when no variant matches.
---@param opcode integer
---@param operands table[]
---@return integer[]|nil
function CommandCatalog.variantExtraWidths(opcode, operands)
  local variants = CommandCatalog.variants(opcode)
  if variants == nil then
    return nil
  end
  for _, variant in ipairs(variants) do
    local when = variant.when
    local value = operands[1] and operands[1].raw
    local matched = true
    if type(value) ~= "number" then
      matched = false
    end
    if matched and when.equal ~= nil then
      matched = value == when.equal
    end
    if matched and when.notEqual ~= nil then
      matched = value ~= when.notEqual
    end
    if matched and when.min ~= nil then
      matched = value >= when.min
    end
    if matched and when.max ~= nil then
      matched = value <= when.max
    end
    if matched and when.values ~= nil then
      matched = false
      for _, candidate in ipairs(when.values) do
        if value == candidate then
          matched = true
          break
        end
      end
    end
    if matched then
      return variant.extra
    end
  end
  return nil
end

return CommandCatalog
