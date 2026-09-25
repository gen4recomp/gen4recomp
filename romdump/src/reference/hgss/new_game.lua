-- Frozen producer facts for the fresh-New-Game player-room start, normalized
-- from pret/pokeheartgold@dfdbbdf3273545ca35456d69bcb0ee3403f76450:
-- src/location_backup.c defines sLocation_PlayerRoom as
-- MAP_NEW_BARK_PLAYER_HOUSE_2F at x/y 0x6 facing 0x1;
-- include/constants/maps.h maps that symbol to id 64; and
-- include/constants/global_fieldmap.h defines DIR_SOUTH as 1.
-- Producer-only reference data: game and asset code must never require this
-- module; producers publish only the normalized facing downstream.

return {
  repository = "pret/pokeheartgold",
  commit = "dfdbbdf3273545ca35456d69bcb0ee3403f76450",
  sourcePaths = {
    "src/location_backup.c",
    "include/constants/maps.h",
    "include/constants/global_fieldmap.h",
  },
  playerRoom = {
    mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
    mapId = 64,
    fieldX = 6,
    fieldZ = 6,
    sourceDirection = 1,
    facing = "south",
  },
}
