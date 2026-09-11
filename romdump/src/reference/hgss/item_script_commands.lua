-- Source-family membership for the generic Bag/item script protocol, audited
-- against pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- (generic inventory in src/scrcmd_items.c, item text in src/scrcmd_strbuf.c
-- and src/message_format.c). This data is intentionally independent of the
-- implementation catalog: membership states which source commands the
-- Bag/item protocol owns, while the catalog states how each command
-- executes. Supported rows are exactly the generic inventory primitives,
-- item queries, and buffered item text; every other item-touching command
-- stays deferred under its owning gameplay system.
--
-- Explicitly not owned here:
-- - fossil count/restoration (fossil rows below);
-- - Mystery Gift delivery (mystery_gift row below);
-- - daycare/communication sanitization item transfer (opcodes 689 and 690,
--   owned by the mon family as deferred daycare/communication commands);
-- - mart/shop buy/sell (shop rows below);
-- - mail commands (opcodes 428 and 781, owned by the mon family as
--   deferred mail commands);
-- - battle item use, which has no field-script command in this table: battle
--   item handling lives outside the field script protocol, so there is no
--   battle row to claim (representative battle opcodes 213, 220, and 589
--   stay outside this inventory);
-- - phone/gift feature commands (phone_gift rows below);
-- - seal, apricorn, prize, and field rock-smash flows (rows below), whose
--   behavior is primarily another gameplay subsystem even when it reaches
--   inventory;
-- - opcode 757: its name mentions the Bag but it drives a cutscene prop,
--   never inventory, so a name match alone never confers membership.

local commands = {
  { opcode = 125, category = "items" },
  { opcode = 126, category = "items" },
  { opcode = 127, category = "items" },
  { opcode = 128, category = "items" },
  { opcode = 129, category = "items" },
  { opcode = 130, category = "items" },
  { opcode = 194, category = "items" },
  { opcode = 195, category = "items" },
  { opcode = 196, category = "items" },
  { opcode = 336, category = "items" },
  { opcode = 669, category = "items" },
  { opcode = 843, category = "items" },
  { opcode = 844, category = "items" },
  { opcode = 429, category = "fossil" },
  { opcode = 432, category = "fossil" },
  { opcode = 433, category = "fossil" },
  { opcode = 489, category = "mystery_gift" },
  { opcode = 275, category = "shop" },
  { opcode = 276, category = "shop" },
  { opcode = 277, category = "shop" },
  { opcode = 278, category = "shop" },
  { opcode = 782, category = "shop" },
  { opcode = 613, category = "phone_gift" },
  { opcode = 614, category = "phone_gift" },
  { opcode = 813, category = "phone_gift" },
  { opcode = 133, category = "seal" },
  { opcode = 134, category = "seal" },
  { opcode = 135, category = "seal" },
  { opcode = 572, category = "seal" },
  { opcode = 580, category = "seal" },
  { opcode = 850, category = "seal" },
  { opcode = 623, category = "apricorn" },
  { opcode = 624, category = "apricorn" },
  { opcode = 625, category = "apricorn" },
  { opcode = 626, category = "apricorn" },
  { opcode = 736, category = "apricorn" },
  { opcode = 738, category = "apricorn" },
  { opcode = 567, category = "prize" },
  { opcode = 651, category = "prize" },
  { opcode = 753, category = "field_item_check" },
}

local byOpcode = {}
for _, command in ipairs(commands) do
  byOpcode[command.opcode] = command
end

return {
  commands = commands,
  byOpcode = byOpcode,
}
