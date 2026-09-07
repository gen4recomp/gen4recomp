-- Standard-script catalog accessor: loads the pinned in-repo std catalog
-- (romdump/src/reference/hgss/std_script_catalog.lua, derived once from the
-- decomp's std_script.h and sScriptBankMapping) and resolves a CallStd
-- operand (numeric id in binary mode, `std_*` symbol in decomp mode) to the
-- public `common.<name>` script id and to the physical member/script index
-- the runtime would load. Pure domain module: no love dependency.

local StdCatalog = require("romdump.src.reference.hgss.std_script_catalog")

local SourceCatalog = {}

SourceCatalog.SOURCE = StdCatalog.source

---@return table<string, unknown> catalog
function SourceCatalog.catalog()
  ---@param stdId integer
  ---@return table<string, unknown>|nil { member: integer, scriptIndex: integer }
  local function locate(stdId)
    local groups = StdCatalog.groups
    for i = #groups, 1, -1 do
      local group = groups[i]
      if stdId >= group.threshold then
        return { member = group.member, scriptIndex = stdId - group.threshold }
      end
    end
    return nil
  end
  return {
    namesById = StdCatalog.namesById,
    groups = StdCatalog.groups,
    locate = locate,
  }
end

-- The public `common.<name>` id for a CallStd operand (numeric id or `std_*`
-- symbol). Known names lose the `std_` prefix; unknown operands stay
-- mechanical (`common.std_<id>`).
---@param catalog table<string, unknown>
---@param operand unknown
---@return string publicId
function SourceCatalog.commonPublicId(catalog, operand)
  local name
  if type(operand) == "number" then
    name = catalog.namesById[operand]
    if name == nil then
      return "common.std_" .. tostring(operand)
    end
  else
    local symbol = tostring(operand)
    if symbol:match("^std_") then
      name = symbol:sub(5)
      if name == "" then
        return "common.std_" .. symbol
      end
    else
      return "common.std_" .. symbol
    end
  end
  return "common." .. name
end

return SourceCatalog
