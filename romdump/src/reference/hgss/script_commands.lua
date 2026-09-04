return {
  byOpcode = {
    [0] = {
      classification = "continue_same_tick",
      name = "ScrCmd_Nop",
      widths = {},
    },
    [1] = {
      classification = "continue_same_tick",
      name = "ScrCmd_Dummy",
      widths = {},
    },
    [2] = {
      classification = "stop",
      name = "ScrCmd_End",
      widths = {},
    },
    [3] = {
      classification = "native_wait",
      name = "ScrCmd_Wait",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [4] = {
      name = "ScrCmd_LoadByte",
      widths = {
        [1] = 1,
        [2] = 1,
      },
    },
    [5] = {
      name = "ScrCmd_LoadWord",
      widths = {
        [1] = 1,
        [2] = 4,
      },
    },
    [6] = {
      name = "ScrCmd_LoadByteFromAddr",
      widths = {
        [1] = 1,
        [2] = 4,
      },
    },
    [7] = {
      name = "ScrCmd_WriteByteToAddr",
      widths = {
        [1] = 4,
        [2] = 1,
      },
    },
    [8] = {
      name = "ScrCmd_SetPtrByte",
      widths = {
        [1] = 4,
        [2] = 1,
      },
    },
    [9] = {
      name = "ScrCmd_CopyLocal",
      widths = {
        [1] = 1,
        [2] = 1,
      },
    },
    [10] = {
      name = "ScrCmd_CopyByte",
      widths = {
        [1] = 4,
        [2] = 4,
      },
    },
    [11] = {
      name = "ScrCmd_CompareLocalToLocal",
      widths = {
        [1] = 1,
        [2] = 1,
      },
    },
    [12] = {
      name = "ScrCmd_CompareLocalToValue",
      widths = {
        [1] = 1,
        [2] = 1,
      },
    },
    [13] = {
      name = "ScrCmd_CompareLocalToAddr",
      widths = {
        [1] = 1,
        [2] = 4,
      },
    },
    [14] = {
      name = "ScrCmd_CompareAddrToLocal",
      widths = {
        [1] = 4,
        [2] = 1,
      },
    },
    [15] = {
      name = "ScrCmd_CompareAddrToValue",
      widths = {
        [1] = 4,
        [2] = 1,
      },
    },
    [16] = {
      name = "ScrCmd_CompareAddrToAddr",
      widths = {
        [1] = 4,
        [2] = 4,
      },
    },
    [17] = {
      classification = "continue_same_tick",
      name = "ScrCmd_CompareVarToValue",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [18] = {
      classification = "continue_same_tick",
      name = "ScrCmd_CompareVarToVar",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [19] = {
      name = "ScrCmd_RunScript",
      widths = {
        [1] = 2,
      },
    },
    [20] = {
      classification = "native_wait",
      name = "ScrCmd_CallStd",
      widths = {
        [1] = 2,
      },
    },
    [21] = {
      classification = "stop",
      name = "ScrCmd_RestartCurrentScript",
      widths = {},
    },
    [22] = {
      classification = "continue_same_tick",
      name = "ScrCmd_GoTo",
      widths = {
        [1] = 4,
      },
    },
    [23] = {
      classification = "continue_same_tick",
      name = "ScrCmd_ObjectGoTo",
      widths = {
        [1] = 1,
        [2] = 4,
      },
    },
    [24] = {
      classification = "continue_same_tick",
      name = "ScrCmd_BGGoTo",
      widths = {
        [1] = 1,
        [2] = 4,
      },
    },
    [25] = {
      classification = "continue_same_tick",
      name = "ScrCmd_DirectionGoTo",
      widths = {
        [1] = 1,
        [2] = 4,
      },
    },
    [26] = {
      classification = "continue_same_tick",
      name = "ScrCmd_Call",
      widths = {
        [1] = 4,
      },
    },
    [27] = {
      classification = "continue_same_tick",
      name = "ScrCmd_Return",
      widths = {},
    },
    [28] = {
      classification = "continue_same_tick",
      name = "ScrCmd_GoToIf",
      widths = {
        [1] = 1,
        [2] = 4,
      },
    },
    [29] = {
      classification = "continue_same_tick",
      name = "ScrCmd_CallIf",
      widths = {
        [1] = 1,
        [2] = 4,
      },
    },
    [30] = {
      classification = "continue_same_tick",
      name = "ScrCmd_SetFlag",
      widths = {
        [1] = 2,
      },
    },
    [31] = {
      classification = "continue_same_tick",
      name = "ScrCmd_ClearFlag",
      widths = {
        [1] = 2,
      },
    },
    [32] = {
      classification = "continue_same_tick",
      name = "ScrCmd_CheckFlag",
      widths = {
        [1] = 2,
      },
    },
    [33] = {
      classification = "continue_same_tick",
      name = "ScrCmd_SetFlagVar",
      widths = {
        [1] = 2,
      },
    },
    [34] = {
      classification = "continue_same_tick",
      name = "ScrCmd_ClearFlagVar",
      widths = {
        [1] = 2,
      },
    },
    [35] = {
      classification = "continue_same_tick",
      name = "ScrCmd_CheckFlagVar",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [36] = {
      name = "ScrCmd_SetTrainerFlag",
      widths = {
        [1] = 2,
      },
    },
    [37] = {
      name = "ScrCmd_ClearTrainerFlag",
      widths = {
        [1] = 2,
      },
    },
    [38] = {
      name = "ScrCmd_CheckTrainerFlag",
      widths = {
        [1] = 2,
      },
    },
    [39] = {
      classification = "continue_same_tick",
      name = "ScrCmd_AddVar",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [40] = {
      classification = "continue_same_tick",
      name = "ScrCmd_SubVar",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [41] = {
      classification = "continue_same_tick",
      name = "ScrCmd_SetVar",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [42] = {
      classification = "continue_same_tick",
      name = "ScrCmd_CopyVar",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [43] = {
      classification = "continue_same_tick",
      name = "ScrCmd_SetOrCopyVar",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [44] = {
      classification = "continue_same_tick",
      name = "ScrCmd_NonNPCMsg",
      widths = {
        [1] = 1,
      },
    },
    [45] = {
      classification = "native_wait",
      name = "ScrCmd_NPCMsg",
      widths = {
        [1] = 1,
      },
    },
    [46] = {
      classification = "continue_same_tick",
      name = "ScrCmd_NonNPCMsgVar",
      widths = {
        [1] = 2,
      },
    },
    [47] = {
      classification = "native_wait",
      name = "ScrCmd_NPCMsgVar",
      widths = {
        [1] = 2,
      },
    },
    [48] = {
      name = "ScrCmd_048",
      widths = {
        [1] = 1,
      },
    },
    [49] = {
      classification = "native_wait",
      name = "ScrCmd_WaitABPress",
      widths = {},
    },
    [50] = {
      classification = "native_wait",
      name = "ScrCmd_WaitButton",
      widths = {},
    },
    [51] = {
      classification = "native_wait",
      name = "ScrCmd_WaitButtonOrDpad",
      widths = {},
    },
    [52] = {
      classification = "continue_same_tick",
      name = "ScrCmd_OpenMsg",
      widths = {},
    },
    [53] = {
      classification = "continue_same_tick",
      name = "ScrCmd_CloseMsg",
      widths = {},
    },
    [54] = {
      classification = "continue_same_tick",
      name = "ScrCmd_HoldMsg",
      widths = {},
    },
    [55] = {
      classification = "yield_next_tick",
      name = "ScrCmd_DirectionSignpost",
      widths = {
        [1] = 1,
        [2] = 1,
        [3] = 2,
        [4] = 2,
      },
    },
    [56] = {
      classification = "yield_next_tick",
      name = "ScrCmd_SetSignpostMap",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [57] = {
      classification = "yield_next_tick",
      name = "ScrCmd_SetSignpostAction",
      widths = {
        [1] = 1,
      },
    },
    [58] = {
      classification = "native_wait",
      name = "ScrCmd_WaitSignpostAction",
      widths = {},
    },
    [59] = {
      classification = "native_wait",
      name = "ScrCmd_TrainerTips",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [60] = {
      classification = "native_wait",
      name = "ScrCmd_WaitSignpost",
      widths = {
        [1] = 2,
      },
    },
    [61] = {
      classification = "stop",
      name = "ScrCmd_061",
      widths = {},
    },
    [62] = {
      name = "ScrCmd_062",
      widths = {
        [1] = 1,
        [2] = 1,
        [3] = 1,
        [4] = 1,
        [5] = 1,
        [6] = 1,
      },
    },
    [63] = {
      classification = "native_wait",
      name = "ScrCmd_YesNo",
      widths = {
        [1] = 2,
      },
    },
    [64] = {
      name = "ScrCmd_064",
      widths = {
        [1] = 1,
        [2] = 1,
        [3] = 1,
        [4] = 1,
        [5] = 2,
      },
    },
    [65] = {
      name = "ScrCmd_065",
      widths = {
        [1] = 1,
        [2] = 1,
        [3] = 1,
        [4] = 1,
        [5] = 2,
      },
    },
    [66] = {
      name = "ScrCmd_066",
      widths = {
        [1] = 1,
        [2] = 1,
      },
    },
    [67] = {
      name = "ScrCmd_067",
      widths = {},
    },
    [68] = {
      name = "ScrCmd_068",
      widths = {
        [1] = 1,
        [2] = 1,
        [3] = 1,
        [4] = 1,
        [5] = 2,
      },
    },
    [69] = {
      name = "ScrCmd_069",
      widths = {
        [1] = 1,
        [2] = 1,
        [3] = 1,
        [4] = 1,
        [5] = 2,
      },
    },
    [70] = {
      name = "ScrCmd_070",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [71] = {
      name = "ScrCmd_071",
      widths = {},
    },
    [72] = {
      name = "ScrCmd_072",
      widths = {
        [1] = 1,
      },
    },
    [73] = {
      classification = "continue_same_tick",
      name = "ScrCmd_PlaySE",
      widths = {
        [1] = 2,
      },
    },
    [74] = {
      classification = "continue_same_tick",
      name = "ScrCmd_StopSE",
      widths = {
        [1] = 2,
      },
    },
    [75] = {
      classification = "native_wait",
      name = "ScrCmd_WaitSE",
      widths = {
        [1] = 2,
      },
    },
    [76] = {
      classification = "continue_same_tick",
      name = "ScrCmd_PlayCry",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [77] = {
      classification = "native_wait",
      name = "ScrCmd_WaitCry",
      widths = {},
    },
    [78] = {
      classification = "continue_same_tick",
      name = "ScrCmd_PlayFanfare",
      widths = {
        [1] = 2,
      },
    },
    [79] = {
      classification = "native_wait",
      name = "ScrCmd_WaitFanfare",
      widths = {},
    },
    [80] = {
      classification = "continue_same_tick",
      name = "ScrCmd_PlayBGM",
      widths = {
        [1] = 2,
      },
    },
    [81] = {
      classification = "continue_same_tick",
      name = "ScrCmd_StopBGM",
      widths = {
        [1] = 2,
      },
    },
    [82] = {
      classification = "continue_same_tick",
      name = "ScrCmd_ResetBGM",
      widths = {},
    },
    [83] = {
      name = "ScrCmd_083",
      widths = {
        [1] = 2,
      },
    },
    [84] = {
      classification = "native_wait",
      name = "ScrCmd_FadeOutBGM",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [85] = {
      classification = "native_wait",
      name = "ScrCmd_FadeInBGM",
      widths = {
        [1] = 2,
      },
    },
    [86] = {
      name = "ScrCmd_086",
      widths = {
        [1] = 1,
        [2] = 1,
      },
    },
    [87] = {
      classification = "continue_same_tick",
      name = "ScrCmd_TempBGM",
      widths = {
        [1] = 2,
      },
    },
    [88] = {
      name = "ScrCmd_088",
      widths = {
        [1] = 1,
      },
    },
    [89] = {
      name = "ScrCmd_ChatotHasCry",
      widths = {
        [1] = 2,
      },
    },
    [90] = {
      name = "ScrCmd_ChatotStartRecording",
      widths = {
        [1] = 2,
      },
    },
    [91] = {
      name = "ScrCmd_ChatotStopRecording",
      widths = {},
    },
    [92] = {
      name = "ScrCmd_ChatotSaveRecording",
      widths = {},
    },
    [93] = {
      name = "ScrCmd_093",
      widths = {},
    },
    [94] = {
      classification = "continue_same_tick",
      name = "ScrCmd_ApplyMovement",
      widths = {
        [1] = 2,
        [2] = 4,
      },
    },
    [95] = {
      classification = "native_wait",
      name = "ScrCmd_WaitMovement",
      widths = {},
    },
    [96] = {
      classification = "yield_next_tick",
      name = "ScrCmd_LockAll",
      widths = {},
    },
    [97] = {
      classification = "yield_next_tick",
      name = "ScrCmd_ReleaseAll",
      widths = {},
    },
    [98] = {
      classification = "continue_same_tick",
      name = "ScrCmd_Lock",
      widths = {
        [1] = 2,
      },
    },
    [99] = {
      classification = "continue_same_tick",
      name = "ScrCmd_Release",
      widths = {
        [1] = 2,
      },
    },
    [100] = {
      classification = "continue_same_tick",
      name = "ScrCmd_ShowPerson",
      widths = {
        [1] = 2,
      },
    },
    [101] = {
      classification = "continue_same_tick",
      name = "ScrCmd_HidePerson",
      widths = {
        [1] = 2,
      },
    },
    [102] = {
      name = "ScrCmd_102",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [103] = {
      name = "ScrCmd_103",
      widths = {},
    },
    [104] = {
      classification = "continue_same_tick",
      name = "ScrCmd_FacePlayer",
      widths = {},
    },
    [105] = {
      classification = "continue_same_tick",
      name = "ScrCmd_GetPlayerCoords",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [106] = {
      classification = "continue_same_tick",
      name = "ScrCmd_GetPersonCoords",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [107] = {
      name = "ScrCmd_107",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [108] = {
      name = "ScrCmd_108",
      widths = {
        [1] = 2,
        [2] = 1,
      },
    },
    [109] = {
      name = "ScrCmd_109",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [110] = {
      name = "ScrCmd_AddMoney",
      widths = {
        [1] = 4,
      },
    },
    [111] = {
      name = "ScrCmd_SubMoneyImmediate",
      widths = {
        [1] = 4,
      },
    },
    [112] = {
      name = "ScrCmd_HasEnoughMoneyImmediate",
      widths = {
        [1] = 2,
        [2] = 4,
      },
    },
    [113] = {
      name = "ScrCmd_ShowMoneyBox",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [114] = {
      name = "ScrCmd_HideMoneyBox",
      widths = {},
    },
    [115] = {
      name = "ScrCmd_UpdateMoneyBox",
      widths = {},
    },
    [116] = {
      name = "ScrCmd_116",
      widths = {
        [1] = 1,
        [2] = 2,
        [3] = 2,
      },
    },
    [117] = {
      name = "ScrCmd_117",
      widths = {},
    },
    [118] = {
      name = "ScrCmd_118",
      widths = {
        [1] = 1,
      },
    },
    [119] = {
      name = "ScrCmd_GetCoinAmount",
      widths = {
        [1] = 2,
      },
    },
    [120] = {
      name = "ScrCmd_GiveCoins",
      widths = {
        [1] = 2,
      },
    },
    [121] = {
      name = "ScrCmd_TakeCoins",
      widths = {
        [1] = 2,
      },
    },
    [122] = {
      name = "ScrCmd_GiveAthletePoints",
      widths = {
        [1] = 2,
      },
    },
    [123] = {
      name = "ScrCmd_TakeAthletePoints",
      widths = {
        [1] = 2,
      },
    },
    [124] = {
      name = "ScrCmd_CheckAthletePoints",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [125] = {
      name = "ScrCmd_GiveItem",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [126] = {
      name = "ScrCmd_TakeItem",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [127] = {
      name = "ScrCmd_HasSpaceForItem",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [128] = {
      name = "ScrCmd_HasItem",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [129] = {
      name = "ScrCmd_ItemIsTMOrHM",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [130] = {
      name = "ScrCmd_GetItemPocket",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [131] = {
      name = "ScrCmd_SetStarterChoice",
      feature = "starter",
      disposition = "deferred",
      deferredReason = "party_special_application",
      deferredNote = "setting the starter choice needs the starter application",
      widths = {
        [1] = 2,
      },
    },
    [132] = {
      classification = "native_wait",
      name = "ScrCmd_GenderMsgBox",
      widths = {
        [1] = 1,
        [2] = 1,
      },
    },
    [133] = {
      name = "ScrCmd_GetSealQuantity",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [134] = {
      name = "ScrCmd_GiveOrTakeSeal",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [135] = {
      name = "ScrCmd_GiveRandomSeal",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [136] = {
      name = "ScrCmd_136",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [137] = {
      name = "ScrCmd_GiveMon",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
        [5] = 2,
        [6] = 2,
      },
    },
    [138] = {
      name = "ScrCmd_GiveEgg",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "egg_daycare",
      deferredNote = "egg creation and hatching need the egg/daycare lifecycle",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [139] = {
      name = "ScrCmd_SetMonMove",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [140] = {
      name = "ScrCmd_MonHasMove",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [141] = {
      name = "ScrCmd_GetPartySlotWithMove",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [142] = {
      name = "ScrCmd_GetPhoneBookRematch",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [143] = {
      name = "ScrCmd_NameRival",
      widths = {
        [1] = 2,
      },
    },
    [144] = {
      classification = "continue_same_tick",
      name = "ScrCmd_GetFriendSprite",
      widths = {
        [1] = 2,
      },
    },
    [145] = {
      name = "ScrCmd_RegisterPokegearCard",
      widths = {
        [1] = 1,
      },
    },
    [146] = {
      name = "ScrCmd_RegisterGearNumber",
      widths = {
        [1] = 2,
      },
    },
    [147] = {
      name = "ScrCmd_CheckRegisteredPhoneNumber",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [148] = {
      name = "ScrCmd_148",
      widths = {
        [1] = 1,
        [2] = 1,
      },
    },
    [149] = {
      name = "UnsetPhoneCallTrigger",
      widths = {
        [1] = 1,
      },
    },
    [150] = {
      name = "ScrCmd_RestoreOverworld",
      widths = {},
    },
    [151] = {
      name = "ScrCmd_151",
      widths = {},
    },
    [152] = {
      name = "ScrCmd_152",
      widths = {},
    },
    [153] = {
      name = "ScrCmd_153",
      widths = {
        [1] = 2,
      },
    },
    [154] = {
      name = "ScrCmd_154",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [155] = {
      name = "ScrCmd_155",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [156] = {
      name = "ScrCmd_156",
      widths = {},
    },
    [157] = {
      name = "ScrCmd_TownMap",
      widths = {},
    },
    [158] = {
      name = "ScrCmd_158",
      widths = {
        [1] = 1,
      },
    },
    [159] = {
      name = "ScrCmd_159",
      widths = {},
    },
    [160] = {
      name = "ScrCmd_160",
      widths = {},
    },
    [161] = {
      name = "ScrCmd_161",
      widths = {},
    },
    [162] = {
      name = "ScrCmd_162",
      widths = {},
    },
    [163] = {
      name = "ScrCmd_HOFCredits",
      widths = {
        [1] = 2,
      },
    },
    [164] = {
      name = "ScrCmd_164",
      widths = {},
    },
    [165] = {
      name = "ScrCmd_165",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [166] = {
      name = "ScrCmd_166",
      widths = {
        [1] = 2,
      },
    },
    [167] = {
      name = "ScrCmd_ChooseStarter",
      feature = "starter",
      disposition = "supported",
      classification = "native_wait",
      widths = {},
    },
    [168] = {
      name = "ScrCmd_GetTrainerPathToPlayer",
      widths = {
        [1] = 2,
      },
    },
    [169] = {
      name = "ScrCmd_TrainerStepTowardsPlayer",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [170] = {
      name = "ScrCmd_GetTrainerEyeType",
      widths = {
        [1] = 2,
      },
    },
    [171] = {
      name = "ScrCmd_GetEyeTrainerNum",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [172] = {
      name = "ScrCmd_NamePlayer",
      widths = {
        [1] = 2,
      },
    },
    [173] = {
      name = "ScrCmd_NicknameInput",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [174] = {
      classification = "continue_same_tick",
      name = "ScrCmd_FadeScreen",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
      },
    },
    [175] = {
      classification = "native_wait",
      name = "ScrCmd_WaitFade",
      widths = {},
    },
    [176] = {
      classification = "native_wait",
      name = "ScrCmd_Warp",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
        [5] = 2,
      },
    },
    [177] = {
      name = "ScrCmd_RockClimb",
      widths = {
        [1] = 2,
      },
    },
    [178] = {
      name = "ScrCmd_Surf",
      widths = {
        [1] = 2,
      },
    },
    [179] = {
      name = "ScrCmd_Waterfall",
      widths = {
        [1] = 2,
      },
    },
    [180] = {
      name = "ScrCmd_180",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [181] = {
      name = "ScrCmd_FlashEffect",
      widths = {},
    },
    [182] = {
      name = "ScrCmd_Whirlpool",
      widths = {
        [1] = 2,
      },
    },
    [183] = {
      name = "ScrCmd_183",
      widths = {
        [1] = 2,
      },
    },
    [184] = {
      name = "ScrCmd_PlayerOnBikeCheck",
      widths = {
        [1] = 2,
      },
    },
    [185] = {
      name = "ScrCmd_PlayerOnBikeSet",
      widths = {
        [1] = 1,
      },
    },
    [186] = {
      name = "ScrCmd_SetBikeStateLock",
      widths = {
        [1] = 1,
      },
    },
    [187] = {
      name = "ScrCmd_GetPlayerState",
      widths = {
        [1] = 2,
      },
    },
    [188] = {
      name = "ScrCmd_SetAvatarBits",
      widths = {
        [1] = 2,
      },
    },
    [189] = {
      name = "ScrCmd_UpdateAvatarState",
      widths = {},
    },
    [190] = {
      classification = "continue_same_tick",
      name = "ScrCmd_BufferPlayersName",
      widths = {
        [1] = 1,
      },
    },
    [191] = {
      classification = "continue_same_tick",
      name = "ScrCmd_BufferRivalsName",
      widths = {
        [1] = 1,
      },
    },
    [192] = {
      classification = "continue_same_tick",
      name = "ScrCmd_BufferFriendsName",
      widths = {
        [1] = 1,
      },
    },
    [193] = {
      classification = "continue_same_tick",
      name = "ScrCmd_BufferMonSpeciesName",
      feature = "mons",
      disposition = "supported",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [194] = {
      classification = "continue_same_tick",
      name = "ScrCmd_BufferItemName",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [195] = {
      classification = "continue_same_tick",
      name = "ScrCmd_BufferPocketName",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [196] = {
      classification = "continue_same_tick",
      name = "ScrCmd_BufferTMHMMoveName",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [197] = {
      classification = "continue_same_tick",
      name = "ScrCmd_BufferMoveName",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [198] = {
      classification = "continue_same_tick",
      name = "ScrCmd_BufferInt",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [199] = {
      classification = "continue_same_tick",
      name = "ScrCmd_BufferPartyMonNick",
      feature = "mons",
      disposition = "supported",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [200] = {
      classification = "continue_same_tick",
      name = "ScrCmd_BufferTrainerClassName",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [201] = {
      name = "ScrCmd_BufferPlayerUnionAvatarClassName",
      widths = {
        [1] = 1,
      },
    },
    [202] = {
      classification = "continue_same_tick",
      name = "ScrCmd_BufferSpeciesName",
      feature = "mons",
      disposition = "supported",
      widths = {
        [1] = 1,
        [2] = 2,
        [3] = 2,
        [4] = 1,
      },
    },
    [203] = {
      classification = "continue_same_tick",
      name = "ScrCmd_BufferStarterSpeciesName",
      feature = "mons",
      disposition = "supported",
      widths = {
        [1] = 1,
      },
    },
    [204] = {
      name = "ScrCmd_BufferDPPtRivalStarterSpeciesName",
      widths = {
        [1] = 1,
      },
    },
    [205] = {
      name = "ScrCmd_BufferDPPtFriendStarterSpeciesName",
      widths = {
        [1] = 1,
      },
    },
    [206] = {
      name = "ScrCmd_GetStarterChoice",
      feature = "starter",
      disposition = "deferred",
      deferredReason = "party_special_application",
      deferredNote = "reading the starter choice needs the starter application",
      widths = {
        [1] = 2,
      },
    },
    [207] = {
      name = "ScrCmd_BufferDecorationName",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [208] = {
      name = "ScrCmd_208",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [209] = {
      name = "ScrCmd_209",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [210] = {
      classification = "continue_same_tick",
      name = "ScrCmd_BufferMapSecName",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [211] = {
      name = "ScrCmd_211",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [212] = {
      name = "ScrCmd_GetTrainerNum",
      widths = {
        [1] = 2,
      },
    },
    [213] = {
      name = "ScrCmd_TrainerBattle",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 1,
        [4] = 1,
      },
    },
    [214] = {
      name = "ScrCmd_TrainerMessage",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [215] = {
      name = "ScrCmd_GetTrainerMsgParams",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [216] = {
      name = "ScrCmd_GetRematchMsgParams",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [217] = {
      name = "ScrCmd_TrainerIsDoubleBattle",
      widths = {
        [1] = 2,
      },
    },
    [218] = {
      name = "ScrCmd_EncounterMusic",
      widths = {
        [1] = 2,
      },
    },
    [219] = {
      name = "ScrCmd_WhiteOut",
      widths = {},
    },
    [220] = {
      name = "ScrCmd_CheckBattleWon",
      widths = {
        [1] = 2,
      },
    },
    [221] = {
      name = "ScrCmd_StaticWildWonOrCaughtCheck",
      widths = {
        [1] = 2,
        [2] = 1,
      },
    },
    [222] = {
      name = "ScrCmd_PartyCheckForDouble",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "battle",
      deferredNote = "double-battle party rules need the battle engine",
      widths = {
        [1] = 2,
      },
    },
    [223] = {
      name = "ScrCmd_223",
      widths = {},
    },
    [224] = {
      name = "ScrCmd_224",
      widths = {},
    },
    [225] = {
      name = "ScrCmd_GoToIfTrainerDefeated",
      widths = {
        [1] = 4,
      },
    },
    [226] = {
      name = "ScrCmd_226",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
      },
    },
    [227] = {
      name = "ScrCmd_227",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
      },
    },
    [228] = {
      name = "ScrCmd_228",
      widths = {
        [1] = 2,
      },
    },
    [229] = {
      name = "ScrCmd_229",
      widths = {
        [1] = 2,
      },
    },
    [230] = {
      name = "ScrCmd_230",
      widths = {},
    },
    [231] = {
      name = "ScrCmd_231",
      widths = {},
    },
    [232] = {
      name = "ScrCmd_232",
      widths = {
        [1] = 2,
      },
    },
    [233] = {
      name = "ScrCmd_233",
      widths = {
        [1] = 2,
      },
    },
    [234] = {
      name = "ScrCmd_234",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
      },
    },
    [235] = {
      name = "ScrCmd_235",
      widths = {
        [1] = 2,
      },
    },
    [236] = {
      name = "ScrCmd_236",
      widths = {
        [1] = 2,
      },
    },
    [237] = {
      name = "ScrCmd_237",
      widths = {},
    },
    [238] = {
      name = "ScrCmd_PartyHasPokerus",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
      },
    },
    [239] = {
      name = "ScrCmd_MonGetGender",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [240] = {
      name = "ScrCmd_SetDynamicWarp",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
        [5] = 2,
      },
    },
    [241] = {
      name = "ScrCmd_GetDynamicWarpFloorNo",
      widths = {
        [1] = 2,
      },
    },
    [242] = {
      name = "ScrCmd_ElevatorCurFloorBox",
      widths = {
        [1] = 1,
        [2] = 1,
        [3] = 2,
        [4] = 2,
      },
    },
    [243] = {
      name = "ScrCmd_CountJohtoDexSeen",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "pokedex",
      deferredNote = "dex counts need persisted seen/caught state",
      widths = {
        [1] = 2,
      },
    },
    [244] = {
      name = "ScrCmd_CountJohtoDexOwned",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "pokedex",
      deferredNote = "dex counts need persisted seen/caught state",
      widths = {
        [1] = 2,
      },
    },
    [245] = {
      name = "ScrCmd_CountNationalDexSeen",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "pokedex",
      deferredNote = "dex counts need persisted seen/caught state",
      widths = {
        [1] = 2,
      },
    },
    [246] = {
      name = "ScrCmd_CountNationalDexOwned",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "pokedex",
      deferredNote = "dex counts need persisted seen/caught state",
      widths = {
        [1] = 2,
      },
    },
    [247] = {
      name = "ScrCmd_247",
      widths = {},
    },
    [248] = {
      name = "ScrCmd_GetDexEvalResult",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "pokedex",
      deferredNote = "dex evaluation needs persisted seen/caught state",
      widths = {
        [1] = 1,
        [2] = 2,
        [3] = 2,
      },
    },
    [249] = {
      name = "ScrCmd_RocketTrapBattle",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [250] = {
      name = "ScrCmd_250",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [251] = {
      name = "ScrCmd_CatchingTutorial",
      widths = {},
    },
    [252] = {
      name = "ScrCmd_252",
      widths = {},
    },
    [253] = {
      name = "ScrCmd_GetSaveFileState",
      widths = {
        [1] = 2,
      },
    },
    [254] = {
      name = "ScrCmd_SaveGameNormal",
      widths = {
        [1] = 2,
      },
    },
    [255] = {
      name = "ScrCmd_255",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [256] = {
      name = "ScrCmd_256",
      widths = {
        [1] = 2,
      },
    },
    [257] = {
      name = "ScrCmd_257",
      widths = {
        [1] = 2,
      },
    },
    [258] = {
      name = "ScrCmd_258",
      widths = {},
    },
    [259] = {
      name = "ScrCmd_259",
      widths = {
        [1] = 2,
      },
    },
    [260] = {
      name = "ScrCmd_260",
      widths = {
        [1] = 2,
      },
    },
    [261] = {
      name = "ScrCmd_261",
      widths = {
        [1] = 2,
      },
    },
    [262] = {
      name = "ScrCmd_262",
      widths = {},
    },
    [263] = {
      name = "ScrCmd_263",
      widths = {},
    },
    [264] = {
      name = "ScrCmd_264",
      widths = {
        [1] = 2,
      },
    },
    [265] = {
      name = "ScrCmd_265",
      widths = {},
    },
    [266] = {
      name = "ScrCmd_266",
      widths = {},
    },
    [267] = {
      name = "ScrCmd_267",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [268] = {
      name = "ScrCmd_268",
      widths = {
        [1] = 2,
      },
    },
    [269] = {
      name = "ScrCmd_269",
      widths = {
        [1] = 2,
      },
    },
    [270] = {
      name = "ScrCmd_270",
      widths = {},
    },
    [271] = {
      name = "ScrCmd_271",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [272] = {
      name = "ScrCmd_272",
      widths = {
        [1] = 2,
      },
    },
    [273] = {
      name = "ScrCmd_273",
      widths = {
        [1] = 2,
      },
    },
    [274] = {
      name = "ScrCmd_274",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [275] = {
      name = "ScrCmd_MartBuy",
      widths = {
        [1] = 2,
      },
    },
    [276] = {
      name = "ScrCmd_SpecialMartBuy",
      widths = {
        [1] = 2,
      },
    },
    [277] = {
      name = "ScrCmd_DecorationMart",
      widths = {
        [1] = 2,
      },
    },
    [278] = {
      name = "ScrCmd_SealMart",
      widths = {
        [1] = 2,
      },
    },
    [279] = {
      name = "ScrCmd_OverworldWhiteOut",
      widths = {},
    },
    [280] = {
      classification = "continue_same_tick",
      name = "ScrCmd_SetSpawn",
      widths = {
        [1] = 2,
      },
    },
    [281] = {
      classification = "continue_same_tick",
      name = "ScrCmd_GetPlayerGender",
      widths = {
        [1] = 2,
      },
    },
    [282] = {
      name = "ScrCmd_HealParty",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {},
    },
    [283] = {
      name = "ScrCmd_283",
      widths = {},
    },
    [284] = {
      name = "ScrCmd_284",
      widths = {},
    },
    [285] = {
      name = "ScrCmd_285",
      widths = {
        [1] = 2,
      },
    },
    [286] = {
      name = "ScrCmd_286",
      widths = {},
    },
    [287] = {
      name = "ScrCmd_BufferUnionRoomAvatarChoices",
      widths = {},
    },
    [288] = {
      name = "ScrCmd_UnionRoomAvatarIdxToTrainerClass",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [289] = {
      name = "ScrCmd_289",
      widths = {
        [1] = 2,
      },
    },
    [290] = {
      name = "ScrCmd_CheckPokedex",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "pokedex",
      deferredNote = "dex flags need persisted seen/caught state",
      widths = {
        [1] = 2,
      },
    },
    [291] = {
      name = "ScrCmd_GivePokedex",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "pokedex",
      deferredNote = "dex flags need persisted seen/caught state",
      widths = {},
    },
    [292] = {
      name = "ScrCmd_CheckRunningShoes",
      widths = {
        [1] = 2,
      },
    },
    [293] = {
      name = "ScrCmd_GiveRunningShoes",
      widths = {},
    },
    [294] = {
      classification = "continue_same_tick",
      name = "ScrCmd_CheckBadge",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [295] = {
      name = "ScrCmd_GiveBadge",
      widths = {
        [1] = 2,
      },
    },
    [296] = {
      name = "ScrCmd_CountBadges",
      widths = {
        [1] = 2,
      },
    },
    [297] = {
      name = "ScrCmd_297",
      widths = {
        [1] = 2,
      },
    },
    [298] = {
      name = "ScrCmd_298",
      widths = {},
    },
    [299] = {
      name = "ScrCmd_CheckEscortMode",
      widths = {
        [1] = 2,
      },
    },
    [300] = {
      name = "ScrCmd_SetEscortMode",
      widths = {},
    },
    [301] = {
      name = "ScrCmd_ClearEscortMode",
      widths = {},
    },
    [302] = {
      name = "ScrCmd_CheckStepTakenFlag",
      widths = {
        [1] = 2,
      },
    },
    [303] = {
      name = "ScrCmd_SetStepTakenFlag",
      widths = {},
    },
    [304] = {
      name = "ScrCmd_GetStepTakenFlag",
      widths = {},
    },
    [305] = {
      name = "ScrCmd_CheckGameClearFlag",
      widths = {
        [1] = 2,
      },
    },
    [306] = {
      name = "ScrCmd_SetGameClearFlag",
      widths = {},
    },
    [307] = {
      name = "ScrCmd_307",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
        [5] = 1,
      },
    },
    [308] = {
      name = "ScrCmd_308",
      widths = {
        [1] = 1,
      },
    },
    [309] = {
      name = "ScrCmd_309",
      widths = {
        [1] = 1,
      },
    },
    [310] = {
      name = "ScrCmd_310",
      widths = {
        [1] = 1,
      },
    },
    [311] = {
      name = "ScrCmd_311",
      widths = {
        [1] = 1,
      },
    },
    [312] = {
      name = "ScrCmd_BufferDaycareMonNicks",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "egg_daycare",
      deferredNote = "daycare state needs the egg/daycare lifecycle",
      widths = {},
    },
    [313] = {
      name = "ScrCmd_GetDaycareState",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "egg_daycare",
      deferredNote = "daycare state needs the egg/daycare lifecycle",
      widths = {
        [1] = 2,
      },
    },
    [314] = {
      name = "ScrCmd_EcruteakGymInit",
      widths = {},
    },
    [315] = {
      name = "ScrCmd_315",
      widths = {},
    },
    [316] = {
      name = "ScrCmd_316",
      widths = {},
    },
    [317] = {
      name = "ScrCmd_317",
      widths = {
        [1] = 1,
      },
    },
    [318] = {
      name = "ScrCmd_CianwoodGymInit",
      widths = {},
    },
    [319] = {
      name = "ScrCmd_CianwoodGymTurnWinch",
      widths = {
        [1] = 2,
      },
    },
    [320] = {
      name = "ScrCmd_VermilionGymInit",
      widths = {},
    },
    [321] = {
      name = "ScrCmd_VermilionGymLockAction",
      widths = {
        [1] = 1,
        [2] = 1,
      },
    },
    [322] = {
      name = "ScrCmd_VermilionGymCanCheck",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [323] = {
      name = "ScrCmd_ResampleVermilionGymCans",
      widths = {},
    },
    [324] = {
      name = "ScrCmd_VioletGymInit",
      widths = {},
    },
    [325] = {
      name = "ScrCmd_VioletGymElevator",
      widths = {},
    },
    [326] = {
      name = "ScrCmd_AzaleaGymInit",
      widths = {},
    },
    [327] = {
      name = "ScrCmd_AzaleaGymSpinarak",
      widths = {
        [1] = 1,
      },
    },
    [328] = {
      name = "ScrCmd_AzaleaGymSwitch",
      widths = {
        [1] = 1,
      },
    },
    [329] = {
      name = "ScrCmd_BlackthornGymInit",
      widths = {},
    },
    [330] = {
      name = "ScrCmd_FuchsiaGymInit",
      widths = {},
    },
    [331] = {
      name = "ScrCmd_ViridianGymInit",
      widths = {},
    },
    [332] = {
      name = "ScrCmd_GetPartyCount",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
      },
    },
    [333] = {
      name = "ScrCmd_333",
      widths = {
        [1] = 1,
      },
    },
    [334] = {
      name = "ScrCmd_334",
      widths = {
        [1] = 2,
      },
    },
    [335] = {
      name = "ScrCmd_335",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [336] = {
      name = "ScrCmd_BufferBerryName",
      widths = {
        [1] = 1,
        [2] = 2,
        [3] = 2,
      },
    },
    [337] = {
      name = "ScrCmd_BufferNatureName",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [338] = {
      classification = "continue_same_tick",
      name = "ScrCmd_MovePerson",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [339] = {
      classification = "continue_same_tick",
      name = "ScrCmd_MovePersonFacing",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
        [5] = 2,
      },
    },
    [340] = {
      classification = "continue_same_tick",
      name = "ScrCmd_SetObjectMovementType",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [341] = {
      classification = "continue_same_tick",
      name = "ScrCmd_SetObjectFacing",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [342] = {
      name = "ScrCmd_MoveWarp",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [343] = {
      name = "ScrCmd_MoveBGEvent",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [344] = {
      name = "ScrCmd_344",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [345] = {
      classification = "continue_same_tick",
      name = "ScrCmd_AddWaitingIcon",
      widths = {},
    },
    [346] = {
      classification = "continue_same_tick",
      name = "ScrCmd_RemoveWaitingIcon",
      widths = {},
    },
    [347] = {
      name = "ScrCmd_347",
      widths = {
        [1] = 2,
      },
    },
    [348] = {
      classification = "native_wait",
      name = "ScrCmd_WaitButtonOrDelay",
      widths = {
        [1] = 2,
      },
    },
    [349] = {
      classification = "native_wait",
      name = "ScrCmd_PartySelectUI",
      feature = "party_ui",
      disposition = "supported",
      widths = {},
    },
    [350] = {
      name = "ScrCmd_350",
      widths = {},
    },
    [351] = {
      classification = "continue_same_tick",
      name = "ScrCmd_GetPartySelection",
      feature = "party_ui",
      disposition = "supported",
      widths = {
        [1] = 2,
      },
    },
    [352] = {
      name = "ScrCmd_PokemonSummaryScreen",
      widths = {
        [1] = 1,
        [2] = 2,
        [3] = 2,
      },
    },
    [353] = {
      name = "ScrCmd_GetMoveSelection",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [354] = {
      name = "ScrCmd_GetPartyMonSpecies",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [355] = {
      name = "ScrCmd_PartyMonIsMine",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [356] = {
      name = "ScrCmd_PartyCountNotEgg",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
      },
    },
    [357] = {
      name = "ScrCmd_CountAliveMons",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [358] = {
      name = "ScrCmd_CountAliveMonsAndPC",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "pc_storage",
      deferredNote = "counts including PC boxes need box storage",
      widths = {
        [1] = 2,
      },
    },
    [359] = {
      name = "ScrCmd_PartyCountEgg",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
      },
    },
    [360] = {
      name = "ScrCmd_SubMoneyVar",
      widths = {
        [1] = 2,
      },
    },
    [361] = {
      name = "ScrCmd_RetrieveDaycareMon",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "egg_daycare",
      deferredNote = "daycare retrieval needs the egg/daycare lifecycle",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [362] = {
      name = "ScrCmd_GiveLoanMon",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "trade",
      deferredNote = "the loaned-mon table and NPC OT transfer need the trade application",
      classification = "continue_same_tick",
      widths = {
        [1] = 1,
        [2] = 1,
        [3] = 2,
      },
    },
    [363] = {
      name = "ScrCmd_CheckReturnLoanMon",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "trade",
      deferredNote = "the loaned-mon table and NPC OT transfer need the trade application",
      classification = "continue_same_tick",
      widths = {
        [1] = 1,
        [2] = 2,
        [3] = 2,
      },
    },
    [364] = {
      name = "ScrCmd_ReturnLoanMon",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
      },
    },
    [365] = {
      name = "ScrCmd_ResetDaycareEgg",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "egg_daycare",
      deferredNote = "daycare eggs need the egg/daycare lifecycle",
      widths = {},
    },
    [366] = {
      name = "ScrCmd_GiveDaycareEgg",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "egg_daycare",
      deferredNote = "daycare eggs need the egg/daycare lifecycle",
      widths = {},
    },
    [367] = {
      name = "ScrCmd_BufferDaycareWithdrawCost",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [368] = {
      name = "ScrCmd_HasEnoughMoneyVar",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [369] = {
      name = "ScrCmd_EggHatchAnim",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "egg_daycare",
      deferredNote = "egg hatching needs the egg/daycare lifecycle",
      widths = {},
    },
    [370] = {
      name = "ScrCmd_370",
      widths = {
        [1] = 1,
      },
    },
    [371] = {
      name = "ScrCmd_BufferDaycareMonGrowth",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [372] = {
      name = "ScrCmd_GetTailDaycareMonSpeciesAndNick",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "egg_daycare",
      deferredNote = "daycare state needs the egg/daycare lifecycle",
      widths = {
        [1] = 2,
      },
    },
    [373] = {
      name = "ScrCmd_PutMonInDaycare",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "egg_daycare",
      deferredNote = "daycare deposit needs the egg/daycare lifecycle",
      widths = {
        [1] = 2,
      },
    },
    [374] = {
      name = "ScrCmd_374",
      widths = {
        [1] = 2,
      },
    },
    [375] = {
      classification = "continue_same_tick",
      name = "ScrCmd_MakeObjectVisible",
      widths = {
        [1] = 2,
      },
    },
    [376] = {
      name = "ScrCmd_376",
      widths = {},
    },
    [377] = {
      name = "ScrCmd_377",
      widths = {
        [1] = 2,
      },
    },
    [378] = {
      name = "ScrCmd_ViewRankings",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [379] = {
      name = "ScrCmd_379",
      widths = {
        [1] = 2,
      },
    },
    [380] = {
      classification = "continue_same_tick",
      name = "ScrCmd_Random",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [381] = {
      name = "ScrCmd_381",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [382] = {
      name = "ScrCmd_MonGetFriendship",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [383] = {
      name = "ScrCmd_MonAddFriendship",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [384] = {
      name = "ScrCmd_MonSubtractFriendship",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [385] = {
      name = "ScrCmd_BufferDaycareMonStats",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
      },
    },
    [386] = {
      classification = "continue_same_tick",
      name = "ScrCmd_GetPlayerFacing",
      widths = {
        [1] = 2,
      },
    },
    [387] = {
      name = "ScrCmd_GetDaycareCompatibility",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "egg_daycare",
      deferredNote = "daycare compatibility needs the egg/daycare lifecycle",
      widths = {
        [1] = 2,
      },
    },
    [388] = {
      name = "ScrCmd_CheckDaycareEgg",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "egg_daycare",
      deferredNote = "daycare eggs need the egg/daycare lifecycle",
      widths = {
        [1] = 2,
      },
    },
    [389] = {
      name = "ScrCmd_PlayerHasSpecies",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [390] = {
      name = "ScrCmd_SizeRecordCompare",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [391] = {
      name = "ScrCmd_SizeRecordUpdate",
      widths = {
        [1] = 2,
      },
    },
    [392] = {
      name = "ScrCmd_BufferMonSize",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "contest_ribbon_application",
      deferredNote = "mon size records need the record application beyond direct fields",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [393] = {
      name = "ScrCmd_BufferRecordSize",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [394] = {
      name = "ScrCmd_394",
      widths = {
        [1] = 2,
      },
    },
    [395] = {
      name = "ScrCmd_395",
      widths = {
        [1] = 2,
      },
    },
    [396] = {
      name = "ScrCmd_CountMonMoves",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [397] = {
      name = "ScrCmd_MonForgetMove",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [398] = {
      name = "ScrCmd_MonGetMove",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [399] = {
      name = "ScrCmd_BufferPartyMonMoveName",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 1,
        [2] = 2,
        [3] = 2,
      },
    },
    [400] = {
      name = "ScrCmd_StrengthFlagAction",
      variants = {
        [1] = {
          extra = {
            [1] = 2,
          },
          when = {
            equal = 2,
          },
        },
      },
      widths = {
        [1] = 1,
      },
    },
    [401] = {
      name = "ScrCmd_FlashAction",
      variants = {
        [1] = {
          extra = {
            [1] = 2,
          },
          when = {
            equal = 2,
          },
        },
      },
      widths = {
        [1] = 1,
      },
    },
    [402] = {
      name = "ScrCmd_DefogAction",
      variants = {
        [1] = {
          extra = {
            [1] = 2,
          },
          when = {
            equal = 2,
          },
        },
      },
      widths = {
        [1] = 1,
      },
    },
    [403] = {
      name = "ScrCmd_403",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [404] = {
      name = "ScrCmd_404",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [405] = {
      name = "ScrCmd_405",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [406] = {
      name = "ScrCmd_406",
      widths = {
        [1] = 2,
      },
    },
    [407] = {
      name = "ScrCmd_407",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [408] = {
      name = "ScrCmd_408",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [409] = {
      name = "ScrCmd_409",
      widths = {},
    },
    [410] = {
      name = "ScrCmd_410",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [411] = {
      name = "ScrCmd_411",
      widths = {},
    },
    [412] = {
      name = "ScrCmd_412",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [413] = {
      name = "ScrCmd_413",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
      },
    },
    [414] = {
      name = "ScrCmd_414",
      widths = {
        [1] = 2,
      },
    },
    [415] = {
      name = "ScrCmd_415",
      widths = {
        [1] = 2,
      },
    },
    [416] = {
      name = "ScrCmd_416",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [417] = {
      name = "ScrCmd_417",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [418] = {
      name = "ScrCmd_418",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [419] = {
      name = "ScrCmd_419",
      widths = {
        [1] = 2,
      },
    },
    [420] = {
      name = "ScrCmd_420",
      widths = {
        [1] = 2,
      },
    },
    [421] = {
      name = "ScrCmd_421",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [422] = {
      name = "ScrCmd_422",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 1,
      },
    },
    [423] = {
      name = "ScrCmd_CheckJohtoDexComplete",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "pokedex",
      deferredNote = "dex completion needs persisted seen/caught state",
      widths = {
        [1] = 2,
      },
    },
    [424] = {
      name = "ScrCmd_CheckNationalDexComplete",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "pokedex",
      deferredNote = "dex completion needs persisted seen/caught state",
      widths = {
        [1] = 2,
      },
    },
    [425] = {
      name = "ScrCmd_ShowCertificate",
      widths = {
        [1] = 2,
      },
    },
    [426] = {
      name = "ScrCmd_KenyaCheck",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 1,
      },
    },
    [427] = {
      name = "ScrCmd_427",
      widths = {
        [1] = 2,
      },
    },
    [428] = {
      name = "ScrCmd_MonGiveMail",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "mail",
      deferredNote = "mail needs the mailbox structures and flows",
      widths = {
        [1] = 2,
      },
    },
    [429] = {
      name = "ScrCmd_CountFossils",
      widths = {
        [1] = 2,
      },
    },
    [430] = {
      name = "ScrCmd_SetPhoneCall",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [431] = {
      name = "ScrCmd_RunPhoneCall",
      widths = {},
    },
    [432] = {
      name = "ScrCmd_GetFossilPokemon",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [433] = {
      name = "ScrCmd_GetFossilMinimumAmount",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [434] = {
      name = "ScrCmd_PartyCountMonsAtOrBelowLevel",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [435] = {
      name = "ScrCmd_SurvivePoisoning",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [436] = {
      name = "ScrCmd_436",
      widths = {},
    },
    [437] = {
      name = "ScrCmd_DebugWatch",
      widths = {
        [1] = 2,
      },
    },
    [438] = {
      classification = "continue_same_tick",
      name = "ScrCmd_GetStdMsgNaix",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [439] = {
      classification = "continue_same_tick",
      name = "ScrCmd_NonNPCMsgExtern",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [440] = {
      classification = "native_wait",
      name = "ScrCmd_MsgBoxExtern",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [441] = {
      name = "ScrCmd_441",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
      },
    },
    [442] = {
      name = "ScrCmd_442",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
      },
    },
    [443] = {
      name = "ScrCmd_443",
      widths = {
        [1] = 1,
      },
    },
    [444] = {
      name = "ScrCmd_444",
      widths = {
        [1] = 1,
        [2] = 2,
        [3] = 2,
        [4] = 1,
      },
    },
    [445] = {
      name = "ScrCmd_445",
      widths = {
        [1] = 2,
      },
    },
    [446] = {
      name = "ScrCmd_446",
      widths = {
        [1] = 2,
      },
    },
    [447] = {
      name = "ScrCmd_SafariZoneAction",
      widths = {
        [1] = 1,
        [2] = 1,
      },
    },
    [448] = {
      name = "ScrCmd_448",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
        [5] = 2,
      },
    },
    [449] = {
      name = "ScrCmd_449",
      widths = {},
    },
    [450] = {
      name = "ScrCmd_450",
      widths = {},
    },
    [451] = {
      name = "ScrCmd_451",
      widths = {
        [1] = 2,
      },
    },
    [452] = {
      name = "ScrCmd_452",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [453] = {
      name = "ScrCmd_453",
      widths = {},
    },
    [454] = {
      name = "ScrCmd_454",
      widths = {},
    },
    [455] = {
      name = "ScrCmd_455",
      widths = {},
    },
    [456] = {
      name = "ScrCmd_456",
      widths = {
        [1] = 1,
      },
    },
    [457] = {
      name = "ScrCmd_MonGetNature",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [458] = {
      name = "ScrCmd_GetPartySlotWithNature",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [459] = {
      name = "ScrCmd_459",
      widths = {},
    },
    [460] = {
      name = "ScrCmd_LoadPhoneDat",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [461] = {
      name = "ScrCmd_GetPhoneContactMsgIds",
      widths = {
        [1] = 1,
        [2] = 2,
        [3] = 2,
      },
    },
    [462] = {
      name = "ScrCmd_462",
      widths = {
        [1] = 2,
      },
    },
    [463] = {
      name = "ScrCmd_EnableMassOutbreaks",
      widths = {},
    },
    [464] = {
      name = "ScrCmd_CreateRoamer",
      widths = {
        [1] = 1,
      },
    },
    [465] = {
      name = "ScrCmd_465",
      variants = {
        [1] = {
          extra = {
            [1] = 2,
            [2] = 2,
          },
          when = {
            max = 3,
          },
        },
        [2] = {
          extra = {
            [1] = 2,
          },
          when = {
            notEqual = 6,
          },
        },
      },
      widths = {
        [1] = 2,
      },
    },
    [466] = {
      name = "ScrCmd_466",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [467] = {
      name = "ScrCmd_MoveRelearnerInit",
      widths = {
        [1] = 2,
      },
    },
    [468] = {
      name = "ScrCmd_MoveTutorInit",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [469] = {
      name = "ScrCmd_MoveRelearnerGetResult",
      widths = {
        [1] = 2,
      },
    },
    [470] = {
      name = "ScrCmd_LoadNPCTrade",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "trade",
      deferredNote = "trade needs the trade application and OT transfer",
      widths = {
        [1] = 1,
      },
    },
    [471] = {
      name = "ScrCmd_GetOfferedSpecies",
      widths = {
        [1] = 2,
      },
    },
    [472] = {
      name = "ScrCmd_NPCTradeGetReqSpecies",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "trade",
      deferredNote = "trade needs the trade application and OT transfer",
      widths = {
        [1] = 2,
      },
    },
    [473] = {
      name = "ScrCmd_NPCTradeExec",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "trade",
      deferredNote = "trade needs the trade application and OT transfer",
      widths = {
        [1] = 2,
      },
    },
    [474] = {
      name = "ScrCmd_NPCTradeEnd",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "trade",
      deferredNote = "trade needs the trade application and OT transfer",
      widths = {},
    },
    [475] = {
      name = "ScrCmd_475",
      widths = {},
    },
    [476] = {
      name = "ScrCmd_EnablePokedexFormDetection",
      widths = {},
    },
    [477] = {
      name = "ScrCmd_NatDexFlagAction",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "pokedex",
      deferredNote = "dex flags need persisted seen/caught state",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [478] = {
      name = "ScrCmd_MonGetRibbonCount",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [479] = {
      name = "ScrCmd_GetPartyRibbonCount",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
      },
    },
    [480] = {
      name = "ScrCmd_MonHasRibbon",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "contest_ribbon_application",
      deferredNote = "ribbon identity to stored-bit mapping needs the ribbon application",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [481] = {
      name = "ScrCmd_GiveRibbon",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "contest_ribbon_application",
      deferredNote = "ribbon identity to stored-bit mapping needs the ribbon application",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [482] = {
      name = "ScrCmd_BufferRibbonName",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "contest_ribbon_application",
      deferredNote = "ribbon names need the ribbon application",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [483] = {
      name = "ScrCmd_GetEVTotal",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [484] = {
      name = "ScrCmd_GetWeekday",
      widths = {
        [1] = 2,
      },
    },
    [485] = {
      name = "ScrCmd_StartBattleRegulationMenuTask",
      widths = {
        [1] = 2,
      },
    },
    [486] = {
      name = "ScrCmd_Dummy",
      widths = {},
    },
    [487] = {
      name = "ScrCmd_PokeCenAnim",
      widths = {
        [1] = 2,
      },
    },
    [488] = {
      name = "ScrCmd_ElevatorAnim",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [489] = {
      name = "ScrCmd_MysteryGift",
      variants = {
        [1] = {
          extra = {
            [1] = 2,
          },
          when = {
            max = 3,
            min = 1,
          },
        },
        [2] = {
          extra = {
            [1] = 2,
            [2] = 2,
          },
          when = {
            values = {
              [1] = 5,
              [2] = 6,
            },
          },
        },
      },
      widths = {
        [1] = 2,
      },
    },
    [490] = {
      name = "ScrCmd_NopVar490",
      widths = {
        [1] = 2,
      },
    },
    [491] = {
      name = "ScrCmd_491",
      widths = {
        [1] = 2,
      },
    },
    [492] = {
      name = "ScrCmd_492",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [493] = {
      name = "ScrCmd_PromptEasyChat",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [494] = {
      name = "ScrCmd_494",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [495] = {
      name = "ScrCmd_GetGameVersion",
      widths = {
        [1] = 2,
      },
    },
    [496] = {
      name = "ScrCmd_GetPartyLead",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
      },
    },
    [497] = {
      name = "ScrCmd_GetMonTypes",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [498] = {
      name = "ScrCmd_PrimoPasswordCheck1",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
        [5] = 2,
      },
    },
    [499] = {
      name = "ScrCmd_PrimoPasswordCheck2",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
        [5] = 2,
      },
    },
    [500] = {
      name = "ScrCmd_500",
      widths = {
        [1] = 1,
      },
    },
    [501] = {
      name = "ScrCmd_501",
      widths = {
        [1] = 1,
      },
    },
    [502] = {
      name = "ScrCmd_502",
      widths = {
        [1] = 1,
      },
    },
    [503] = {
      name = "ScrCmd_LotoIDGet",
      widths = {
        [1] = 2,
      },
    },
    [504] = {
      name = "ScrCmd_LotoIDSearch",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
      },
    },
    [505] = {
      name = "ScrCmd_LotoIDSet",
      widths = {},
    },
    [506] = {
      name = "ScrCmd_BufferBoxMonNick",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "pc_storage",
      deferredNote = "box nicknames need box storage",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [507] = {
      name = "ScrCmd_CountPCEmptySpace",
      widths = {
        [1] = 2,
      },
    },
    [508] = {
      name = "ScrCmd_PalParkAction",
      widths = {
        [1] = 2,
      },
    },
    [509] = {
      name = "ScrCmd_509",
      widths = {
        [1] = 2,
      },
    },
    [510] = {
      name = "ScrCmd_510",
      widths = {},
    },
    [511] = {
      name = "ScrCmd_PalParkScoreGet",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [512] = {
      name = "ScrCmd_PlayerMovementSavingSet",
      widths = {},
    },
    [513] = {
      name = "ScrCmd_PlayerMovementSavingClear",
      widths = {},
    },
    [514] = {
      name = "ScrCmd_HallOfFameAnim",
      widths = {
        [1] = 2,
      },
    },
    [515] = {
      name = "ScrCmd_AddSpecialGameStat",
      widths = {
        [1] = 2,
      },
    },
    [516] = {
      name = "ScrCmd_BufferFashionName",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [517] = {
      name = "ScrCmd_517",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [518] = {
      name = "ScrCmd_518",
      widths = {
        [1] = 2,
      },
    },
    [519] = {
      name = "ScrCmd_519",
      widths = {
        [1] = 2,
      },
    },
    [520] = {
      name = "ScrCmd_520",
      widths = {},
    },
    [521] = {
      name = "ScrCmd_521",
      widths = {},
    },
    [522] = {
      name = "ScrCmd_522",
      widths = {
        [1] = 2,
      },
    },
    [523] = {
      name = "ScrCmd_523",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
        [5] = 2,
      },
    },
    [524] = {
      name = "ScrCmd_524",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [525] = {
      name = "ScrCmd_525",
      widths = {
        [1] = 2,
      },
    },
    [526] = {
      name = "ScrCmd_526",
      widths = {
        [1] = 2,
      },
    },
    [527] = {
      name = "ScrCmd_527",
      widths = {
        [1] = 2,
      },
    },
    [528] = {
      name = "ScrCmd_528",
      widths = {
        [1] = 2,
      },
    },
    [529] = {
      name = "ScrCmd_GetPartyLeadAlive",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
      },
    },
    [530] = {
      name = "ScrCmd_530",
      widths = {
        [1] = 2,
        [2] = 1,
      },
    },
    [531] = {
      name = "ScrCmd_BufferBackgroundName",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [532] = {
      name = "ScrCmd_CheckCoinsImmediate",
      widths = {
        [1] = 2,
        [2] = 4,
      },
    },
    [533] = {
      name = "ScrCmd_CheckGiveCoins",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [534] = {
      name = "ScrCmd_534",
      widths = {
        [1] = 2,
      },
    },
    [535] = {
      name = "ScrCmd_MonGetLevel",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [536] = {
      name = "ScrCmd_536",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [537] = {
      name = "ScrCmd_537",
      widths = {},
    },
    [538] = {
      name = "ScrCmd_538",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [539] = {
      name = "ScrCmd_539",
      widths = {
        [1] = 2,
      },
    },
    [540] = {
      name = "ScrCmd_540",
      widths = {
        [1] = 2,
      },
    },
    [541] = {
      name = "ScrCmd_BufferIntEx",
      widths = {
        [1] = 1,
        [2] = 2,
        [3] = 1,
        [4] = 1,
      },
    },
    [542] = {
      name = "ScrCmd_MonGetContestValue",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [543] = {
      name = "ScrCmd_543",
      widths = {
        [1] = 2,
      },
    },
    [544] = {
      name = "ScrCmd_544",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [545] = {
      name = "ScrCmd_545",
      widths = {
        [1] = 2,
      },
    },
    [546] = {
      name = "ScrCmd_546",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [547] = {
      name = "ScrCmd_547",
      widths = {
        [1] = 2,
      },
    },
    [548] = {
      name = "ScrCmd_548",
      widths = {},
    },
    [549] = {
      name = "ScrCmd_549",
      widths = {
        [1] = 2,
      },
    },
    [550] = {
      name = "ScrCmd_550",
      widths = {
        [1] = 2,
      },
    },
    [551] = {
      name = "ScrCmd_551",
      widths = {
        [1] = 2,
      },
    },
    [552] = {
      name = "ScrCmd_552",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [553] = {
      name = "ScrCmd_553",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [554] = {
      name = "ScrCmd_554",
      widths = {
        [1] = 2,
      },
    },
    [555] = {
      name = "ScrCmd_555",
      widths = {
        [1] = 2,
      },
    },
    [556] = {
      name = "ScrCmd_556",
      widths = {
        [1] = 2,
      },
    },
    [557] = {
      name = "ScrCmd_CheckBattlePoints",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [558] = {
      name = "ScrCmd_UnionRoomAvatarIdxToSprite",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [559] = {
      name = "ScrCmd_559",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [560] = {
      name = "ScrCmd_560",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [561] = {
      name = "ScrCmd_ScreenShake",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
      },
    },
    [562] = {
      name = "ScrCmd_MultiBattle",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 1,
      },
    },
    [563] = {
      name = "ScrCmd_563",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [564] = {
      name = "ScrCmd_564",
      widths = {
        [1] = 2,
      },
    },
    [565] = {
      name = "ScrCmd_565",
      widths = {
        [1] = 2,
      },
    },
    [566] = {
      name = "ScrCmd_566",
      widths = {},
    },
    [567] = {
      name = "ScrCmd_GetDPPlPrizeItemIDAndCost",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [568] = {
      name = "ScrCmd_568",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [569] = {
      name = "ScrCmd_569",
      widths = {
        [1] = 2,
      },
    },
    [570] = {
      name = "ScrCmd_CheckCoinsVar",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [571] = {
      name = "ScrCmd_571",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
        [5] = 2,
      },
    },
    [572] = {
      name = "ScrCmd_GetUniqueSealsQuantity",
      widths = {
        [1] = 2,
      },
    },
    [573] = {
      name = "ScrCmd_573",
      widths = {},
    },
    [574] = {
      name = "ScrCmd_574",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [575] = {
      name = "ScrCmd_575",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [576] = {
      name = "ScrCmd_576",
      widths = {
        [1] = 2,
      },
    },
    [577] = {
      name = "ScrCmd_577",
      widths = {},
    },
    [578] = {
      name = "ScrCmd_578",
      widths = {},
    },
    [579] = {
      name = "ScrCmd_579",
      widths = {},
    },
    [580] = {
      name = "ScrCmd_BufferSealName",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [581] = {
      classification = "native_wait",
      name = "ScrCmd_LockLastTalked",
      widths = {},
    },
    [582] = {
      name = "ScrCmd_582",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [583] = {
      name = "ScrCmd_583",
      widths = {
        [1] = 2,
        [2] = 1,
      },
    },
    [584] = {
      name = "ScrCmd_PartyLegalCheck",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
      },
    },
    [585] = {
      name = "ScrCmd_585",
      widths = {},
    },
    [586] = {
      name = "ScrCmd_586",
      widths = {
        [1] = 2,
      },
    },
    [587] = {
      name = "ScrCmd_587",
      widths = {},
    },
    [588] = {
      name = "ScrCmd_LatiCaughtCheck",
      widths = {
        [1] = 2,
      },
    },
    [589] = {
      name = "ScrCmd_WildBattle",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 1,
      },
    },
    [590] = {
      name = "ScrCmd_GetTrcardStars",
      widths = {
        [1] = 2,
      },
    },
    [591] = {
      name = "ScrCmd_591",
      widths = {},
    },
    [592] = {
      name = "ScrCmd_592",
      widths = {
        [1] = 2,
      },
    },
    [593] = {
      name = "ScrCmd_ShowSaveStats",
      widths = {},
    },
    [594] = {
      name = "ScrCmd_HideSaveStats",
      widths = {},
    },
    [595] = {
      name = "ScrCmd_595",
      feature = "following_mon",
      disposition = "deferred",
      deferredReason = "special_follower_event",
      deferredNote = "opcode 595 is unreached in the pinned corpus; it stays deferred pending a source trace",
      widths = {
        [1] = 1,
      },
    },
    [596] = {
      name = "ScrCmd_596",
      feature = "following_mon",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
      },
    },
    [597] = {
      name = "ScrCmd_597",
      feature = "following_mon",
      disposition = "deferred",
      deferredReason = "special_follower_event",
      deferredNote = "opcode 597 is an opaque follower neighbour off the default trail; it stays deferred pending a source trace",
      widths = {},
    },
    [598] = {
      name = "ScrCmd_598",
      feature = "following_mon",
      disposition = "deferred",
      deferredReason = "special_follower_event",
      deferredNote = "opcode 598 always carries the literal 1 and stays deferred pending a source trace",
      widths = {
        [1] = 2,
      },
    },
    [599] = {
      name = "ScrCmd_599",
      feature = "following_mon",
      disposition = "deferred",
      deferredReason = "special_follower_event",
      deferredNote = "opcode 599 is an opaque follower neighbour off the default trail; it stays deferred pending a source trace",
      widths = {},
    },
    [600] = {
      name = "ScrCmd_600",
      feature = "following_mon",
      disposition = "deferred",
      deferredReason = "special_follower_event",
      deferredNote = "opcode 600 runs only on the active-follower arm and needs the special follower reaction contract",
      widths = {},
    },
    [601] = {
      name = "ScrCmd_FollowMonFacePlayer",
      feature = "following_mon",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {},
    },
    [602] = {
      name = "ScrCmd_ToggleFollowingPokemonMovement",
      feature = "following_mon",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
      },
    },
    [603] = {
      name = "ScrCmd_WaitFollowingPokemonMovement",
      feature = "following_mon",
      disposition = "supported",
      classification = "native_wait",
      widths = {},
    },
    [604] = {
      name = "ScrCmd_FollowingPokemonMovement",
      feature = "following_mon",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
      },
    },
    [605] = {
      name = "ScrCmd_605",
      feature = "following_mon",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 1,
        [2] = 1,
      },
    },
    [606] = {
      name = "ScrCmd_606",
      feature = "following_mon",
      disposition = "deferred",
      deferredReason = "special_follower_event",
      deferredNote = "opcode 606 is an opaque follower neighbour off the default trail; it stays deferred pending a source trace",
      widths = {},
    },
    [607] = {
      name = "ScrCmd_607",
      feature = "following_mon",
      disposition = "deferred",
      deferredReason = "special_follower_event",
      deferredNote = "opcode 607 is an opaque follower neighbour off the default trail; it stays deferred pending a source trace",
      widths = {},
    },
    [608] = {
      name = "ScrCmd_608",
      feature = "following_mon",
      disposition = "deferred",
      deferredReason = "special_follower_event",
      deferredNote = "opcode 608 adjoins the Elm follow-up state operation and stays deferred pending a source trace",
      widths = {},
    },
    [609] = {
      name = "ScrCmd_609",
      feature = "following_mon",
      disposition = "supported",
      classification = "yield_next_tick",
      widths = {},
    },
    [610] = {
      name = "ScrCmd_610",
      widths = {
        [1] = 2,
      },
    },
    [611] = {
      name = "ScrCmd_Pokeathlon",
      widths = {
        [1] = 1,
        [2] = 1,
        [3] = 2,
        [4] = 2,
        [5] = 2,
        [6] = 2,
        [7] = 2,
      },
    },
    [612] = {
      name = "ScrCmd_GetNPCTradeUnusedFlag",
      widths = {
        [1] = 2,
      },
    },
    [613] = {
      name = "ScrCmd_GetPhoneContactRandomGiftBerry",
      widths = {
        [1] = 2,
      },
    },
    [614] = {
      name = "ScrCmd_GetPhoneContactGiftItem",
      widths = {
        [1] = 2,
      },
    },
    [615] = {
      name = "ScrCmd_CameronPhoto",
      widths = {
        [1] = 2,
      },
    },
    [616] = {
      name = "ScrCmd_CountSavedPhotos",
      widths = {
        [1] = 2,
      },
    },
    [617] = {
      name = "ScrCmd_OpenPhotoAlbum",
      widths = {},
    },
    [618] = {
      name = "ScrCmd_PhotoAlbumIsFull",
      widths = {
        [1] = 2,
      },
    },
    [619] = {
      name = "ScrCmd_RocketCostumeFlagCheck",
      widths = {
        [1] = 2,
      },
    },
    [620] = {
      name = "ScrCmd_RocketCostumeFlagAction",
      widths = {
        [1] = 1,
      },
    },
    [621] = {
      name = "ScrCmd_PlaceStarterBallsInElmsLab",
      feature = "starter",
      disposition = "deferred",
      deferredReason = "party_special_application",
      deferredNote = "placing the starter balls needs the starter application",
      widths = {},
    },
    [622] = {
      name = "ScrCmd_622",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [623] = {
      name = "ScrCmd_AnimApricornTree",
      widths = {
        [1] = 2,
      },
    },
    [624] = {
      name = "ScrCmd_ApricornTreeGetApricorn",
      widths = {
        [1] = 2,
      },
    },
    [625] = {
      name = "ScrCmd_GiveApricornFromTree",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [626] = {
      name = "ScrCmd_BufferApricornName",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [627] = {
      name = "ScrCmd_627",
      widths = {
        [1] = 1,
      },
    },
    [628] = {
      name = "ScrCmd_628",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [629] = {
      name = "ScrCmd_629",
      widths = {},
    },
    [630] = {
      name = "ScrCmd_630",
      widths = {
        [1] = 2,
      },
    },
    [631] = {
      name = "ScrCmd_631",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [632] = {
      name = "ScrCmd_CountPartyMonsOfSpecies",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [633] = {
      name = "ScrCmd_633",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [634] = {
      name = "ScrCmd_634",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [635] = {
      name = "ScrCmd_635",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [636] = {
      name = "ScrCmd_636",
      widths = {
        [1] = 2,
      },
    },
    [637] = {
      name = "ScrCmd_637",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [638] = {
      name = "ScrCmd_638",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [639] = {
      name = "ScrCmd_639",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [640] = {
      name = "ScrCmd_640",
      widths = {
        [1] = 2,
      },
    },
    [641] = {
      name = "ScrCmd_SaveWipeExtraChunks",
      widths = {},
    },
    [642] = {
      name = "ScrCmd_642",
      widths = {
        [1] = 2,
      },
    },
    [643] = {
      name = "ScrCmd_643",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [644] = {
      name = "ScrCmd_644",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [645] = {
      name = "ScrCmd_645",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [646] = {
      name = "ScrCmd_646",
      widths = {
        [1] = 2,
      },
    },
    [647] = {
      name = "ScrCmd_GetPartySlotWithSpecies",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [648] = {
      name = "ScrCmd_648",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
        [5] = 2,
      },
    },
    [649] = {
      name = "ScrCmd_ScratchOffCard",
      widths = {},
    },
    [650] = {
      name = "ScrCmd_ScratchOffCardEnd",
      widths = {},
    },
    [651] = {
      name = "ScrCmd_GetScratchOffPrize",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [652] = {
      name = "ScrCmd_652",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [653] = {
      name = "ScrCmd_MoveTutorChooseMove",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
      },
    },
    [654] = {
      name = "ScrCmd_TutorMoveTeachInSlot",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [655] = {
      name = "ScrCmd_TutorMoveGetPrice",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [656] = {
      name = "ScrCmd_656",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [657] = {
      name = "ScrCmd_StatJudge",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
      },
    },
    [658] = {
      name = "ScrCmd_BufferStatName",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [659] = {
      name = "ScrCmd_SetMonForm",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [660] = {
      name = "ScrCmd_BufferTrainerName",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [661] = {
      name = "ScrCmd_661",
      widths = {
        [1] = 1,
        [2] = 4,
        [3] = 1,
        [4] = 1,
      },
    },
    [662] = {
      name = "ScrCmd_662",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [663] = {
      name = "ScrCmd_663",
      widths = {
        [1] = 2,
      },
    },
    [664] = {
      name = "ScrCmd_664",
      widths = {},
    },
    [665] = {
      name = "ScrCmd_665",
      widths = {
        [1] = 2,
      },
    },
    [666] = {
      name = "ScrCmd_666",
      widths = {
        [1] = 2,
      },
    },
    [667] = {
      name = "ScrCmd_667",
      widths = {
        [1] = 2,
      },
    },
    [668] = {
      name = "ScrCmd_BufferTypeName",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [669] = {
      name = "ScrCmd_GetItemQuantity",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [670] = {
      name = "ScrCmd_GetHiddenPowerType",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [671] = {
      name = "ScrCmd_SetFavoriteMon",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "contest_ribbon_application",
      deferredNote = "favorite-mon presentation needs the contest application",
      widths = {},
    },
    [672] = {
      name = "ScrCmd_GetFavoriteMon",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [673] = {
      name = "ScrCmd_GetOwnedRotomForms",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
        [5] = 2,
      },
    },
    [674] = {
      name = "ScrCmd_CountTranformedRotomsInParty",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "item_flow",
      deferredNote = "Rotom form changes need the appliance item application",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [675] = {
      name = "ScrCmd_UpdateRotomForm",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
      },
    },
    [676] = {
      name = "ScrCmd_GetPartyMonForm",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [677] = {
      name = "ScrCmd_677",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [678] = {
      name = "ScrCmd_678",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [679] = {
      name = "ScrCmd_679",
      widths = {},
    },
    [680] = {
      name = "ScrCmd_AddSpecialGameStat2",
      widths = {
        [1] = 2,
      },
    },
    [681] = {
      name = "ScrCmd_681",
      widths = {
        [1] = 2,
      },
    },
    [682] = {
      name = "ScrCmd_682",
      widths = {
        [1] = 2,
      },
    },
    [683] = {
      name = "ScrCmd_GetStaticEncounterOutcome",
      widths = {
        [1] = 2,
      },
    },
    [684] = {
      name = "ScrCmd_684",
      widths = {
        [1] = 2,
      },
    },
    [685] = {
      name = "ScrCmd_GetPlayerXYZ",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [686] = {
      name = "ScrCmd_686",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [687] = {
      name = "ScrCmd_687",
      widths = {
        [1] = 2,
      },
    },
    [688] = {
      name = "ScrCmd_GetPartySlotWithFatefulEncounter",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [689] = {
      name = "ScrCmd_CommSanitizeParty",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "trade",
      deferredNote = "trade sanitizing needs the trade application and OT transfer",
      widths = {
        [1] = 2,
      },
    },
    [690] = {
      name = "ScrCmd_DaycareSanitizeMon",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "egg_daycare",
      deferredNote = "daycare state needs the egg/daycare lifecycle",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [691] = {
      name = "ScrCmd_691",
      widths = {
        [1] = 2,
      },
    },
    [692] = {
      name = "ScrCmd_BufferBattleHallStreak",
      widths = {
        [1] = 1,
        [2] = 1,
        [3] = 1,
        [4] = 1,
        [5] = 2,
        [6] = 2,
      },
    },
    [693] = {
      name = "ScrCmd_BattleHallCountUsedSpecies",
      widths = {
        [1] = 2,
      },
    },
    [694] = {
      name = "ScrCmd_BattleHallGetTotalStreak",
      widths = {
        [1] = 2,
      },
    },
    [695] = {
      name = "ScrCmd_695",
      widths = {
        [1] = 2,
      },
    },
    [696] = {
      name = "ScrCmd_696",
      widths = {
        [1] = 2,
      },
    },
    [697] = {
      name = "ScrCmd_697",
      widths = {
        [1] = 2,
      },
    },
    [698] = {
      name = "ScrCmd_FollowerPokeIsEventTrigger",
      feature = "following_mon",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 1,
        [2] = 2,
        [3] = 2,
      },
    },
    [699] = {
      name = "ScrCmd_699",
      widths = {},
    },
    [700] = {
      name = "ScrCmd_700",
      widths = {},
    },
    [701] = {
      name = "ScrCmd_MonHasItem",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [702] = {
      name = "ScrCmd_BattleTowerSetUpMultiBattle",
      widths = {},
    },
    [703] = {
      name = "ScrCmd_SetPlayerVolume",
      widths = {
        [1] = 2,
      },
    },
    [704] = {
      name = "ScrCmd_704",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [705] = {
      name = "ScrCmd_705",
      widths = {
        [1] = 2,
        [2] = 4,
      },
    },
    [706] = {
      name = "ScrCmd_706",
      widths = {
        [1] = 2,
      },
    },
    [707] = {
      name = "ScrCmd_CheckMonSeen",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "pokedex",
      deferredNote = "seen flags need persisted seen/caught state",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [708] = {
      name = "ScrCmd_708",
      widths = {
        [1] = 2,
      },
    },
    [709] = {
      name = "ScrCmd_709",
      widths = {},
    },
    [710] = {
      name = "ScrCmd_710",
      widths = {},
    },
    [711] = {
      name = "ScrCmd_FollowMonInteract",
      feature = "following_mon",
      disposition = "deferred",
      deferredReason = "special_follower_event",
      deferredNote = "follower interaction needs the following-mon controller",
      widths = {},
    },
    [712] = {
      name = "ScrCmd_712",
      widths = {
        [1] = 1,
      },
    },
    [713] = {
      name = "ScrCmd_AlphPuzzle",
      widths = {
        [1] = 1,
      },
    },
    [714] = {
      name = "ScrCmd_OpenAlphHiddenRoom",
      widths = {
        [1] = 1,
      },
    },
    [715] = {
      name = "ScrCmd_UpdateDaycareMonObjects",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "egg_daycare",
      deferredNote = "daycare objects need the egg/daycare lifecycle",
      widths = {},
    },
    [716] = {
      name = "ScrCmd_716",
      widths = {},
    },
    [717] = {
      name = "ScrCmd_717",
      widths = {
        [1] = 2,
      },
    },
    [718] = {
      name = "ScrCmd_718",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [719] = {
      name = "ScrCmd_719",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [720] = {
      name = "ScrCmd_720",
      widths = {
        [1] = 2,
      },
    },
    [721] = {
      name = "ScrCmd_721",
      widths = {
        [1] = 2,
      },
    },
    [722] = {
      name = "ScrCmd_722",
      widths = {
        [1] = 1,
        [2] = 1,
        [3] = 2,
        [4] = 2,
        [5] = 2,
      },
    },
    [723] = {
      name = "ScrCmd_723",
      widths = {
        [1] = 1,
        [2] = 1,
        [3] = 2,
        [4] = 2,
        [5] = 2,
      },
    },
    [724] = {
      name = "ScrCmd_724",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [725] = {
      name = "ScrCmd_725",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [726] = {
      classification = "continue_same_tick",
      name = "ScrCmd_ProcessSoundplate",
      widths = {},
    },
    [727] = {
      name = "ScrCmd_GetFollowPokePartyIndex",
      feature = "following_mon",
      disposition = "deferred",
      deferredReason = "special_follower_event",
      deferredNote = "follower party index needs the following-mon controller",
      widths = {
        [1] = 2,
      },
    },
    [728] = {
      name = "ScrCmd_728",
      widths = {
        [1] = 1,
        [2] = 1,
      },
    },
    [729] = {
      name = "ScrCmd_729",
      feature = "following_mon",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
      },
    },
    [730] = {
      name = "ScrCmd_730",
      widths = {
        [1] = 2,
      },
    },
    [731] = {
      name = "ScrCmd_731",
      widths = {},
    },
    [732] = {
      name = "ScrCmd_732",
      widths = {
        [1] = 1,
      },
    },
    [733] = {
      name = "ScrCmd_733",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [734] = {
      name = "ScrCmd_734",
      widths = {
        [1] = 1,
      },
    },
    [735] = {
      name = "ScrCmd_735",
      widths = {
        [1] = 2,
      },
    },
    [736] = {
      name = "ScrCmd_ClearKurtApricorn",
      widths = {},
    },
    [737] = {
      name = "ScrCmd_737",
      widths = {
        [1] = 2,
      },
    },
    [738] = {
      name = "ScrCmd_GetTotalApricornCount",
      widths = {
        [1] = 2,
      },
    },
    [739] = {
      name = "ScrCmd_739",
      widths = {},
    },
    [740] = {
      name = "ScrCmd_740",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [741] = {
      name = "ScrCmd_741",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
        [4] = 2,
      },
    },
    [742] = {
      name = "ScrCmd_742",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [743] = {
      name = "ScrCmd_743",
      widths = {
        [1] = 2,
      },
    },
    [744] = {
      name = "ScrCmd_CreatePokeathlonFriendshipRoomStatues",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "contest_ribbon_application",
      deferredNote = "friendship statues need the contest application",
      widths = {},
    },
    [745] = {
      name = "ScrCmd_BufferPokeathlonCourseName",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [746] = {
      name = "ScrCmd_TouchscreenMenuHide",
      widths = {},
    },
    [747] = {
      name = "ScrCmd_TouchscreenMenuShow",
      widths = {},
    },
    [748] = {
      classification = "native_wait",
      name = "ScrCmd_GetMenuChoice",
      widths = {
        [1] = 2,
      },
    },
    [749] = {
      classification = "yield_next_tick",
      name = "ScrCmd_MenuInitStdGmm",
      widths = {
        [1] = 1,
        [2] = 1,
        [3] = 1,
        [4] = 1,
        [5] = 2,
      },
    },
    [750] = {
      classification = "yield_next_tick",
      name = "ScrCmd_MenuInit",
      widths = {
        [1] = 1,
        [2] = 1,
        [3] = 1,
        [4] = 1,
        [5] = 2,
      },
    },
    [751] = {
      classification = "continue_same_tick",
      name = "ScrCmd_MenuItemAdd",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [752] = {
      classification = "native_wait",
      name = "ScrCmd_MenuExec",
      widths = {},
    },
    [753] = {
      name = "ScrCmd_RockSmashItemCheck",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [754] = {
      name = "ScrCmd_TryHeadbuttEncounter",
      widths = {
        [1] = 2,
      },
    },
    [755] = {
      name = "ScrCmd_LegendCutsceneClearBellAnimBegin",
      widths = {},
    },
    [756] = {
      name = "ScrCmd_LegendCutsceneClearBellAnimEnd",
      widths = {},
    },
    [757] = {
      name = "ScrCmd_LegendCutsceneClearBellRiseFromBag",
      widths = {},
    },
    [758] = {
      name = "ScrCmd_LegendCutsceneClearBellShimmer",
      widths = {
        [1] = 2,
      },
    },
    [759] = {
      name = "ScrCmd_LegendCutsceneLugiaEyeGlimmerEffect",
      widths = {},
    },
    [760] = {
      name = "ScrCmd_760",
      widths = {},
    },
    [761] = {
      name = "ScrCmd_LegendCutsceneMoveCameraTo",
      widths = {
        [1] = 2,
      },
    },
    [762] = {
      name = "ScrCmd_LegendCutscenePanCameraTo",
      widths = {
        [1] = 2,
      },
    },
    [763] = {
      name = "ScrCmd_LegendCutsceneWaitCameraPan",
      widths = {},
    },
    [764] = {
      name = "ScrCmd_LegendCutsceneBirdFinalApproach",
      widths = {},
    },
    [765] = {
      name = "ScrCmd_LegendCutsceneWavesOrLeavesEffectBegin",
      widths = {},
    },
    [766] = {
      name = "ScrCmd_LegendCutsceneWavesOrLeavesEffectEnd",
      widths = {},
    },
    [767] = {
      name = "ScrCmd_LegendCutsceneLugiaArrivesEffectBegin",
      widths = {},
    },
    [768] = {
      name = "ScrCmd_LegendCutsceneLugiaArrivesEffectEnd",
      widths = {},
    },
    [769] = {
      name = "ScrCmd_LegendCutsceneLugiaArrivesEffectCameraPan",
      widths = {},
    },
    [770] = {
      name = "ScrCmd_CheckSeenAllLetterUnown",
      widths = {
        [1] = 2,
      },
    },
    [771] = {
      name = "ScrCmd_771",
      widths = {},
    },
    [772] = {
      name = "ScrCmd_772",
      widths = {},
    },
    [773] = {
      name = "ScrCmd_Cinematic",
      widths = {
        [1] = 2,
      },
    },
    [774] = {
      name = "ScrCmd_ShowLegendaryWing",
      widths = {
        [1] = 2,
      },
    },
    [775] = {
      name = "ScrCmd_775",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [776] = {
      name = "ScrCmd_GiveTogepiEgg",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "egg_daycare",
      deferredNote = "egg gifts need the egg/daycare lifecycle",
      widths = {},
    },
    [777] = {
      name = "ScrCmd_777",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [778] = {
      name = "ScrCmd_GiveSpikyEarPichu",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "special_follower_event",
      deferredNote = "the event-locked Spiky-Ear form needs the special-event application",
      widths = {},
    },
    [779] = {
      name = "ScrCmd_RadioMusicIsPlaying",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [780] = {
      name = "ScrCmd_CasinoGame",
      widths = {
        [1] = 1,
        [2] = 1,
      },
    },
    [781] = {
      name = "ScrCmd_KenyaCheckPartyOrMailbox",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "mail",
      deferredNote = "mailbox checks need the mailbox structures and flows",
      widths = {
        [1] = 2,
      },
    },
    [782] = {
      name = "ScrCmd_MartSell",
      widths = {},
    },
    [783] = {
      name = "ScrCmd_SetFollowMonInhibitState",
      feature = "following_mon",
      disposition = "deferred",
      deferredReason = "special_follower_event",
      deferredNote = "follower inhibit state needs the following-mon controller",
      widths = {
        [1] = 1,
      },
    },
    [784] = {
      name = "ScrCmd_ScriptOverlayCmd",
      widths = {
        [1] = 1,
        [2] = 1,
      },
    },
    [785] = {
      name = "ScrCmd_BugContestAction",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "contest_ribbon_application",
      deferredNote = "bug contest rules need the contest application",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [786] = {
      name = "ScrCmd_BufferBugContestWinner",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "contest_ribbon_application",
      deferredNote = "bug contest results need the contest application",
      widths = {
        [1] = 1,
      },
    },
    [787] = {
      name = "ScrCmd_JudgeBugContest",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "contest_ribbon_application",
      deferredNote = "bug contest judging needs the contest application",
      widths = {
        [1] = 2,
        [2] = 2,
        [3] = 2,
      },
    },
    [788] = {
      name = "ScrCmd_BufferBugContestMonNick",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "contest_ribbon_application",
      deferredNote = "bug contest state needs the contest application",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [789] = {
      name = "ScrCmd_BugContestGetTimeLeft",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "contest_ribbon_application",
      deferredNote = "bug contest timing needs the contest application",
      widths = {
        [1] = 1,
      },
    },
    [790] = {
      name = "ScrCmd_IsBugContestantRegistered",
      feature = "mons",
      disposition = "deferred",
      deferredReason = "contest_ribbon_application",
      deferredNote = "bug contest registration needs the contest application",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [791] = {
      name = "ScrCmd_CheckSafariZoneChallengeCompleted",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [792] = {
      name = "ScrCmd_UpdateSafariZoneIGT",
      widths = {},
    },
    [793] = {
      name = "ScrCmd_BankTransaction",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [794] = {
      name = "ScrCmd_CheckBankBalance",
      widths = {
        [1] = 2,
        [2] = 4,
      },
    },
    [795] = {
      name = "ScrCmd_795",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [796] = {
      name = "ScrCmd_796",
      widths = {},
    },
    [797] = {
      name = "ScrCmd_797",
      widths = {},
    },
    [798] = {
      name = "ScrCmd_BufferRulesetName",
      widths = {
        [1] = 2,
      },
    },
    [799] = {
      name = "ScrCmd_799",
      widths = {
        [1] = 2,
      },
    },
    [800] = {
      name = "ScrCmd_800",
      widths = {
        [1] = 2,
      },
    },
    [801] = {
      name = "ScrCmd_801",
      widths = {
        [1] = 2,
      },
    },
    [802] = {
      name = "ScrCmd_802",
      widths = {},
    },
    [803] = {
      name = "ScrCmd_803",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [804] = {
      name = "ScrCmd_804",
      widths = {
        [1] = 1,
      },
    },
    [805] = {
      name = "ScrCmd_805",
      widths = {},
    },
    [806] = {
      name = "ScrCmd_806",
      widths = {},
    },
    [807] = {
      name = "ScrCmd_SetTrainerHouseSprite",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [808] = {
      name = "ScrCmd_808",
      widths = {
        [1] = 2,
      },
    },
    [809] = {
      name = "ScrCmd_ShowTrainerHouseIntroMessage",
      widths = {
        [1] = 2,
      },
    },
    [810] = {
      name = "ScrCmd_810",
      widths = {},
    },
    [811] = {
      name = "ScrCmd_811",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [812] = {
      name = "ScrCmd_812",
      widths = {},
    },
    [813] = {
      name = "ScrCmd_MomGiftCheck",
      widths = {
        [1] = 2,
      },
    },
    [814] = {
      name = "ScrCmd_814",
      widths = {},
    },
    [815] = {
      name = "ScrCmd_815",
      widths = {
        [1] = 2,
      },
    },
    [816] = {
      name = "ScrCmd_UnownCircle",
      widths = {},
    },
    [817] = {
      name = "ScrCmd_817",
      widths = {
        [1] = 1,
      },
    },
    [818] = {
      name = "ScrCmd_MystriStageGymmickInit",
      widths = {},
    },
    [819] = {
      name = "ScrCmd_819",
      widths = {},
    },
    [820] = {
      name = "ScrCmd_820",
      widths = {
        [1] = 1,
      },
    },
    [821] = {
      name = "ScrCmd_GetBuenasPassword",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [822] = {
      name = "ScrCmd_822",
      widths = {},
    },
    [823] = {
      name = "ScrCmd_823",
      widths = {
        [1] = 2,
      },
    },
    [824] = {
      name = "ScrCmd_824",
      widths = {
        [1] = 2,
      },
    },
    [825] = {
      name = "ScrCmd_GetShinyLeafCount",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [826] = {
      name = "ScrCmd_TryGiveShinyLeafCrown",
      widths = {
        [1] = 2,
      },
    },
    [827] = {
      name = "ScrCmd_GetPartyMonForm2",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [828] = {
      name = "ScrCmd_MonAddContestValue",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
        [2] = 1,
        [3] = 2,
      },
    },
    [829] = {
      name = "ScrCmd_829",
      widths = {
        [1] = 2,
      },
    },
    [830] = {
      name = "ScrCmd_830",
      widths = {
        [1] = 2,
      },
    },
    [831] = {
      name = "ScrCmd_831",
      widths = {
        [1] = 2,
      },
    },
    [832] = {
      name = "ScrCmd_832",
      widths = {
        [1] = 2,
      },
    },
    [833] = {
      name = "ScrCmd_833",
      widths = {
        [1] = 2,
      },
    },
    [834] = {
      name = "ScrCmd_834",
      widths = {
        [1] = 2,
      },
    },
    [835] = {
      name = "ScrCmd_835",
      widths = {
        [1] = 2,
      },
    },
    [836] = {
      name = "ScrCmd_CheckKyogreGroudonInParty",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 2,
      },
    },
    [837] = {
      name = "ScrCmd_837",
      widths = {
        [1] = 2,
      },
    },
    [838] = {
      name = "ScrCmd_BankOrWalletIsFull",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [839] = {
      name = "ScrCmd_SysSetSleepFlag",
      widths = {
        [1] = 2,
      },
    },
    [840] = {
      name = "ScrCmd_840",
      widths = {
        [1] = 2,
        [2] = 2,
      },
    },
    [841] = {
      name = "ScrCmd_841",
      widths = {
        [1] = 1,
      },
    },
    [842] = {
      name = "ScrCmd_842",
      widths = {
        [1] = 1,
      },
    },
    [843] = {
      name = "ScrCmd_BufferItemNameIndef",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [844] = {
      name = "ScrCmd_BufferItemNamePlural",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [845] = {
      name = "ScrCmd_BufferPartyMonSpeciesNameIndef",
      feature = "mons",
      disposition = "supported",
      classification = "continue_same_tick",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [846] = {
      name = "ScrCmd_BufferSpeciesNameIndef",
      widths = {
        [1] = 1,
        [2] = 2,
        [3] = 2,
        [4] = 1,
      },
    },
    [847] = {
      name = "ScrCmd_BufferDPPtFriendStarterSpeciesNameIndef",
      widths = {
        [1] = 1,
      },
    },
    [848] = {
      name = "ScrCmd_BufferFashionNameIndef",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [849] = {
      name = "ScrCmd_BufferTrainerClassNameIndef",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [850] = {
      name = "ScrCmd_BufferSealNamePlural",
      widths = {
        [1] = 1,
        [2] = 2,
      },
    },
    [851] = {
      name = "ScrCmd_Capitalize",
      widths = {
        [1] = 1,
      },
    },
    [852] = {
      name = "ScrCmd_BufferDeptStoreFloorNo",
      widths = {
        [1] = 1,
        [2] = 1,
      },
    },
  },
  schema = 1,
  source = {
    commit = "dfdbbdf3273545ca35456d69bcb0ee3403f76450",
    inputs = {
      [1] = {
        path = "src/data/fieldmap/script_cmd_table.h",
        sha256 = "62104e12b64cd52a089c257c21d438b306c4cc72e126d01ecfe1aa124b34d9a8",
      },
      [2] = {
        path = "asm/macros/script.inc",
        sha256 = "dfa7acaaaee22acece1c3850999e14fba442091d22f304cae57c43e12ec65b13",
      },
    },
    repo = "pret/pokeheartgold",
  },
}
