-- Domain-facing accessor over the frozen pokeheartgold map-header reference.
-- Pure domain module: no love dependency. Records are immutable by convention;
-- callers must not mutate them.

local Errors = require("libs.errors.src.Errors")
local reference = require("romdump.src.reference.hgss.maps")

local MapCatalog = {}
local COUNT = 540
local byId = {}
local bySymbol = {}

assert(reference.schema == 2, "unsupported HGSS map reference schema")
assert(reference.count == COUNT, "HGSS map reference must contain 540 records")

MapCatalog.VERSION = "hgss-map-catalog-v1:" .. reference.source.commit

for id = 0, COUNT - 1 do
  local source = assert(reference.byId[id], "missing HGSS map reference id " .. id)
  assert(source.id == id, "HGSS map reference id mismatch at " .. id)
  assert(not bySymbol[source.symbol], "duplicate HGSS map symbol " .. source.symbol)

  byId[id] = source
  bySymbol[source.symbol] = id
end

-- Resolve a numeric ROM id or a MAP_* symbol to its record. Returns
-- (record | nil, err) so callers can branch without pcall.
function MapCatalog.get(idOrSymbol)
  local id = idOrSymbol
  if type(idOrSymbol) == "string" then
    id = bySymbol[idOrSymbol]
  end
  local record = id ~= nil and byId[id] or nil
  if not record then
    return nil,
      Errors.new("MAP_CATALOG_UNKNOWN", "no catalog record for " .. tostring(idOrSymbol), { key = idOrSymbol })
  end
  return record
end

function MapCatalog.require(idOrSymbol)
  local record, err = MapCatalog.get(idOrSymbol)
  if not record then
    error(err)
  end
  return record
end

-- Resolve a decoded map-header id to its complete catalog record. Callers that
-- render neighboring cells consume only its symbol and areaDataMemberId.
function MapCatalog.areaForMapHeader(mapHeaderId)
  return byId[mapHeaderId]
end

function MapCatalog.idForSymbol(symbol)
  return bySymbol[symbol]
end

function MapCatalog.symbolForId(mapId)
  local record = byId[mapId]
  return record and record.symbol or nil
end

-- Stateless iterator over every record, ascending by numeric id, so callers get
-- deterministic ordering.
function MapCatalog.all()
  local id = -1
  local function nextRecord()
    id = id + 1
    if id == COUNT then
      return nil
    end
    return byId[id]
  end
  return nextRecord
end

return MapCatalog
