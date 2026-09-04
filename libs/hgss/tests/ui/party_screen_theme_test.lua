-- Party-screen presentation semantics: the HP bar zone follows the source
-- 48-pixel bar thresholds (full, green above half, yellow above a fifth,
-- red otherwise, fainted at zero) and the persistent status key follows the
-- source status-icon order (faint, sleep, poison, burn, freeze, paralysis).
-- Labels reuse the source status-icon codes.

local Assert = require("tests.support.Assert")
local PartyScreenTheme = require("libs.hgss.src.ui.PartyScreenTheme")

local T = {}

function T.hp_zone_follows_the_source_bar_thresholds()
  Assert.equal(PartyScreenTheme.hpZone(35, 35), "full")
  Assert.equal(PartyScreenTheme.hpZone(25, 48), "green")
  Assert.equal(PartyScreenTheme.hpZone(10, 48), "yellow")
  Assert.equal(PartyScreenTheme.hpZone(9, 48), "red")
  Assert.equal(PartyScreenTheme.hpZone(1, 100), "red")
  Assert.equal(PartyScreenTheme.hpZone(0, 35), "fainted")
end

function T.hp_zone_quantizes_like_the_source_pixel_bar()
  -- 24 of 48 pixels is exactly half: green needs strictly more.
  Assert.equal(PartyScreenTheme.hpZone(24, 48), "yellow")
  Assert.equal(PartyScreenTheme.hpZone(25, 48), "green")
  -- Yellow needs strictly more than a fifth of the bar.
  Assert.equal(PartyScreenTheme.hpZone(9, 48), "red")
  Assert.equal(PartyScreenTheme.hpZone(10, 48), "yellow")
end

function T.status_key_follows_the_source_icon_priority()
  Assert.equal(PartyScreenTheme.statusKey(0, 35), "ok")
  Assert.equal(PartyScreenTheme.statusKey(0, 0), "faint")
  Assert.equal(PartyScreenTheme.statusKey(0x40, 35), "paralysis")
  Assert.equal(PartyScreenTheme.statusKey(0x20, 35), "freeze")
  Assert.equal(PartyScreenTheme.statusKey(0x03, 35), "sleep")
  Assert.equal(PartyScreenTheme.statusKey(0x08, 35), "poison")
  Assert.equal(PartyScreenTheme.statusKey(0x80, 35), "poison")
  Assert.equal(PartyScreenTheme.statusKey(0x10, 35), "burn")
  Assert.equal(PartyScreenTheme.statusKey(0x48, 35), "poison", "poison outranks paralysis")
  Assert.equal(PartyScreenTheme.statusKey(0x08, 0), "faint", "no HP outranks every status bit")
end

function T.status_labels_reuse_the_source_icon_codes()
  Assert.isNil(PartyScreenTheme.statusLabel("ok"), "a healthy mon shows no status label")
  Assert.equal(PartyScreenTheme.statusLabel("poison"), "PSN")
  Assert.equal(PartyScreenTheme.statusLabel("burn"), "BRN")
  Assert.equal(PartyScreenTheme.statusLabel("freeze"), "FRZ")
  Assert.equal(PartyScreenTheme.statusLabel("paralysis"), "PRZ")
  Assert.equal(PartyScreenTheme.statusLabel("sleep"), "SLP")
  Assert.equal(PartyScreenTheme.statusLabel("faint"), "FNT")
end

return { tests = T }
