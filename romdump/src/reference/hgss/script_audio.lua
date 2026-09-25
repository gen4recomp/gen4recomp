-- Frozen producer facts for HGSS script audio dependencies, normalized from
-- pret/pokeheartgold@dfdbbdf3273545ca35456d69bcb0ee3403f76450. The two
-- retail variable fanfare sites live in
-- files/fielddata/script/scr_seq/scr_seq_0148.s (two `PlayFanfare
-- VAR_SPECIAL_x8000` instructions immediately after `GetDexEvalResult`);
-- src/scrcmd_sound.c resolves the fanfare operand through ScriptGetVar for
-- PlayFanfare, src/scrcmd_c.c routes GetDexEvalResult through
-- GetOakJohtoDexRating/GetOakNationalDexRating, and asm/unk_0205BB1C.s shows
-- those rating writers emit SEQ_ME_HYOUKA1 normally and SEQ_ME_HYOUKA6 for
-- the completed-dex case.
-- Producer-only reference data: the runtime must never require this module.

return {
  repository = "pret/pokeheartgold",
  commit = "dfdbbdf3273545ca35456d69bcb0ee3403f76450",
  sourcePaths = {
    "files/fielddata/script/scr_seq/scr_seq_0148.s",
    "src/scrcmd_sound.c",
    "src/scrcmd_c.c",
    "asm/unk_0205BB1C.s",
  },
  variableFanfareMembers = { 148 },
  variableFanfareSequences = { "SEQ_ME_HYOUKA1", "SEQ_ME_HYOUKA6" },
}
