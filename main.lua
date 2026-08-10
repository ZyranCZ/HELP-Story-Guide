-- HELP - Story Guide
-- v1.0.4
-- Target: Gen1Recomp 0.1.75 / mod API 2 / Red + Blue
--
-- Design goals:
--   * derive progress from the authoritative game save; never maintain a parallel helpStage
--   * use only the public mod surface supplied by Gen1Recomp
--   * tolerate legitimate non-linear progression and downstream-completed states
--   * distinguish HM ownership from actual field usability, including HM Anywhere compatibility
--   * keep resolver logic independent of the HELP screen

return function(mod)
  ---------------------------------------------------------------------------
  -- Small save helpers
  ---------------------------------------------------------------------------

  local function truthyInventoryValue(v)
    if type(v) == "number" then return v > 0 end
    return v == true
  end

  local function hasFlag(save, name)
    return save
      and type(save.flags) == "table"
      and save.flags[name] == true
  end

  local function hasItem(save, name)
    if not save or type(save.inventory) ~= "table" then return false end
    return truthyInventoryValue(save.inventory[name])
  end

  local function hasPcItem(save, name)
    if not save or type(save.pcItems) ~= "table" then return false end
    return truthyInventoryValue(save.pcItems[name])
  end

  local function ownsItem(save, name)
    return hasItem(save, name) or hasPcItem(save, name)
  end

  local function partyKnows(save, moveId)
    if not save or type(save.party) ~= "table" then return false end
    for _, mon in ipairs(save.party) do
      if type(mon) == "table" and type(mon.moves) == "table" then
        for _, move in ipairs(mon.moves) do
          if type(move) == "table" and move.id == moveId then
            return true
          end
        end
      end
    end
    return false
  end

  local function mapIs(state, id)
    return state.location.map == id
  end

  local function mapContains(state, token)
    return type(state.location.map) == "string"
      and state.location.map:find(token, 1, true) ~= nil
  end

  local function mapContainsAny(state, tokens)
    for _, token in ipairs(tokens) do
      if mapContains(state, token) then return true end
    end
    return false
  end

  ---------------------------------------------------------------------------
  -- Route trainer metadata + existing-save compatibility
  --
  -- Gen1Recomp itself treats a trainer as defeated when EITHER the newer
  -- save.defeatedTrainers NPC id is present OR the original trainer-header
  -- event flag is set. Imported / already-progressed saves can legitimately
  -- contain only the latter, so HELP must mirror the engine's exact policy.
  --
  -- Registry access is valid in the entry chunk, which gives us trainer NPC
  -- ids immediately. game.ready is the sanctioned point where the live Game
  -- object exists; there we enrich every trainer with its original event flag
  -- via game.data:trainerHeader(...). No engine-internals permission needed.
  ---------------------------------------------------------------------------

  local ROUTE_TRAINERS = {}

  -- A few route battles are scripted outside the ordinary trainer-header
  -- table. They still have trainerClass map objects, so they belong in the
  -- route total, but old / imported saves can preserve their completion via
  -- a different carrier than ordinary trainer headers.
  --
  -- Route 24's Nugget Bridge recruiter is the important Red/Blue case. The
  -- v0.1.75 hand-port asks ow:trainerDefeated(npc), whose modern victory path
  -- writes save.defeatedTrainers[npc.id]. The original cartridge also has
  -- EVENT_BEAT_ROUTE24_ROCKET, but v0.1.75's hand-ported script does not set
  -- that flag. Some already-progressed saves instead carry the recruiter's
  -- hidden-object state. objectVisible() treats an explicit false toggle as
  -- authoritative, so HELP mirrors that evidence too.
  --
  -- Identify scripted trainers by stable object NAME, never by object index:
  -- generated/modified map data can legitimately change numeric positions.
  local SPECIAL_ROUTE_TRAINERS = {
    ROUTE_24 = {
      ROUTE24_COOLTRAINER_M1 = {
        legacyEvent = "EVENT_BEAT_ROUTE24_ROCKET",
        hiddenToggleMeansDefeated = true,
      },
    },
  }

  local function routeTrainerSpecial(mapId, objectName)
    local route = SPECIAL_ROUTE_TRAINERS[mapId]
    return route and objectName and route[objectName] or nil
  end

  local function seedRouteTrainerCacheFromRegistry()
    local maps = mod.content and mod.content.maps
    if not (maps and maps.get) then return end
    for n = 1, 25 do
      local mapId = "ROUTE_" .. n
      local ok, mapDef = pcall(function() return maps:get(mapId) end)
      if ok and type(mapDef) == "table" and type(mapDef.objects) == "table" then
        local trainers = {}
        for _, obj in ipairs(mapDef.objects) do
          if type(obj) == "table" and obj.trainerClass and obj.index then
            local special = routeTrainerSpecial(mapId, obj.name)
            trainers[#trainers + 1] = {
              key = mapId .. "_obj_" .. tostring(obj.index),
              index = obj.index,
              name = obj.name,
              event = special and special.legacyEvent or nil,
              hiddenToggleMeansDefeated = special
                and special.hiddenToggleMeansDefeated == true or false,
            }
          end
        end
        if #trainers > 0 then
          ROUTE_TRAINERS[mapId] = { total = #trainers, trainers = trainers }
        end
      end
    end
  end

  local function refreshRouteTrainerCache(game)
    local data = game and game.data
    local maps = data and data.maps
    if type(maps) ~= "table" then return end

    local fresh = {}
    for n = 1, 25 do
      local mapId = "ROUTE_" .. n
      local mapDef = maps[mapId]
      if type(mapDef) == "table" and type(mapDef.objects) == "table" then
        local trainers = {}
        for _, obj in ipairs(mapDef.objects) do
          if type(obj) == "table" and obj.trainerClass and obj.index then
            local special = routeTrainerSpecial(mapId, obj.name)
            local event = special and special.legacyEvent or nil
            if not event and type(data.trainerHeader) == "function" and mapDef.label then
              local ok, header = pcall(function()
                return data:trainerHeader(mapDef.label, obj.index)
              end)
              if ok and type(header) == "table" then event = header.event end
            end
            trainers[#trainers + 1] = {
              key = mapId .. "_obj_" .. tostring(obj.index),
              index = obj.index,
              name = obj.name,
              event = event,
              hiddenToggleMeansDefeated = special
                and special.hiddenToggleMeansDefeated == true or false,
            }
          end
        end
        if #trainers > 0 then
          fresh[mapId] = { total = #trainers, trainers = trainers }
        end
      end
    end

    for key in pairs(ROUTE_TRAINERS) do ROUTE_TRAINERS[key] = nil end
    for key, value in pairs(fresh) do ROUTE_TRAINERS[key] = value end
  end

  seedRouteTrainerCacheFromRegistry()

  mod.events:on("game.ready", function(ev)
    if type(ev) == "table" then refreshRouteTrainerCache(ev.game) end
  end)

  local function routeTrainerProgress(save, mapId)
    local meta = ROUTE_TRAINERS[mapId]
    if not meta then return nil end
    local defeated = type(save) == "table" and save.defeatedTrainers or nil
    defeated = type(defeated) == "table" and defeated or {}
    local flags = type(save) == "table" and save.flags or nil
    flags = type(flags) == "table" and flags or {}
    local objectToggles = type(save) == "table" and save.objectToggles or nil
    objectToggles = type(objectToggles) == "table" and objectToggles or {}
    local routeToggles = type(objectToggles[mapId]) == "table"
      and objectToggles[mapId] or {}
    local won = 0
    for _, trainer in ipairs(meta.trainers or {}) do
      local hiddenDefeat = trainer.hiddenToggleMeansDefeated
        and trainer.name
        and routeToggles[trainer.name] == false
      if defeated[trainer.key] == true
          or (trainer.event and flags[trainer.event] == true)
          or hiddenDefeat then
        won = won + 1
      end
    end
    return won, meta.total
  end

  ---------------------------------------------------------------------------
  -- Tiny route journal
  --
  -- Story progression remains authoritative/stateless. Route-entry evidence is
  -- used only to remember real accessibility/arrival facts that Gen1 does not
  -- persist for ordinary routes. Trainer completion itself comes directly from
  -- the authoritative save (defeatedTrainers OR original trainer event flags)
  -- and never from this journal.
  ---------------------------------------------------------------------------

  local JOURNAL_CYCLING_ROAD = "visitedCyclingRoad"
  local JOURNAL_EAST_FUCHSIA_ROUTE = "visitedEastFuchsiaRoute"
  local JOURNAL_CYCLING_ENTRY = "cyclingRoadEntrySide"
  local JOURNAL_EAST_ENTRY = "eastFuchsiaRouteEntrySide"
  local JOURNAL_SEEN_ROUTES = "seenRoutes"
  local JOURNAL_FUCHSIA_REACHED = "fuchsiaReached"

  local function inSet(value, set)
    for _, v in ipairs(set) do if value == v then return true end end
    return false
  end

  local function markRouteSeen(mapId)
    if type(mapId) ~= "string" or not mapId:match("^ROUTE_%d+$") then return end
    local old = mod.save:get(JOURNAL_SEEN_ROUTES, {})
    local seen = {}
    if type(old) == "table" then
      for k, v in pairs(old) do seen[k] = v end
    end
    if not seen[mapId] then
      seen[mapId] = true
      mod.save:set(JOURNAL_SEEN_ROUTES, seen)
    end
  end

  local function routeWasSeen(mapId)
    local seen = mod.save:get(JOURNAL_SEEN_ROUTES, {})
    return type(seen) == "table" and seen[mapId] == true
  end

  local function markRouteJournal(mapId, fromMapId)
    markRouteSeen(mapId)
    if mapId == "FUCHSIA_CITY" then
      mod.save:set(JOURNAL_FUCHSIA_REACHED, true)
    end
    -- Cycling Road: count completion only after crossing Route 17 from one
    -- end to the other. Entering Route 17 and immediately turning around is
    -- deliberately NOT enough to clear the HELP page.
    local cyclingEntry = mod.save:get(JOURNAL_CYCLING_ENTRY, nil)
    if mapId == "ROUTE_17" and fromMapId == "ROUTE_16" then
      mod.save:set(JOURNAL_CYCLING_ENTRY, "north")
    elseif mapId == "ROUTE_17" and fromMapId == "ROUTE_18" then
      mod.save:set(JOURNAL_CYCLING_ENTRY, "south")
    elseif mapId == "ROUTE_18" and fromMapId == "ROUTE_17" then
      if cyclingEntry == "north" then mod.save:set(JOURNAL_CYCLING_ROAD, true) end
      mod.save:set(JOURNAL_CYCLING_ENTRY, nil)
    elseif mapId == "ROUTE_16" and fromMapId == "ROUTE_17" then
      if cyclingEntry == "south" then mod.save:set(JOURNAL_CYCLING_ROAD, true) end
      mod.save:set(JOURNAL_CYCLING_ENTRY, nil)
    elseif not inSet(mapId, { "ROUTE_16", "ROUTE_17", "ROUTE_18" }) then
      mod.save:set(JOURNAL_CYCLING_ENTRY, nil)
    end

    -- Eastern Fuchsia route: north -> south is Route 12/13/14/15 -> Fuchsia;
    -- the reverse traversal also counts. We remember which end was entered
    -- and only complete when the opposite end is reached.
    local eastEntry = mod.save:get(JOURNAL_EAST_ENTRY, nil)
    if mapId == "ROUTE_13" and fromMapId == "ROUTE_12" then
      mod.save:set(JOURNAL_EAST_ENTRY, "north")
    elseif mapId == "ROUTE_15" and fromMapId == "FUCHSIA_CITY" then
      mod.save:set(JOURNAL_EAST_ENTRY, "south")
    elseif mapId == "FUCHSIA_CITY" and fromMapId == "ROUTE_15" then
      if eastEntry == "north" then mod.save:set(JOURNAL_EAST_FUCHSIA_ROUTE, true) end
      mod.save:set(JOURNAL_EAST_ENTRY, nil)
    elseif mapId == "ROUTE_12" and fromMapId == "ROUTE_13" then
      if eastEntry == "south" then mod.save:set(JOURNAL_EAST_FUCHSIA_ROUTE, true) end
      mod.save:set(JOURNAL_EAST_ENTRY, nil)
    elseif not inSet(mapId, {
        "LAVENDER_TOWN", "ROUTE_12", "ROUTE_13", "ROUTE_14", "ROUTE_15", "FUCHSIA_CITY"
      }) then
      mod.save:set(JOURNAL_EAST_ENTRY, nil)
    end
  end


  ---------------------------------------------------------------------------
  -- Optional HM Anywhere compatibility
  --
  -- mod.find is Gen1Recomp's supported inter-mod API. HM Anywhere's shipped
  -- archive uses the hm_anywhere naming convention; a couple of harmless
  -- aliases are accepted defensively for repacks. Detection is deliberately
  -- evaluated at resolve time because mod.find returns nil for a mod that has
  -- not finished loading yet.
  ---------------------------------------------------------------------------

  local HM_ANYWHERE_IDS = { "hm_anywhere", "hm-anywhere", "hm_anywhere_mod" }

  local function hmAnywhereActive()
    if type(mod.find) ~= "function" then return false end
    for _, id in ipairs(HM_ANYWHERE_IDS) do
      local ok, found = pcall(function() return mod.find(id) end)
      if ok and found ~= nil then return true end
    end
    return false
  end


  ---------------------------------------------------------------------------
  -- Normalized state
  --
  -- All Gen1Recomp representation details live here. The resolver below only
  -- consumes this stable shape, which gives us a clean seam for Yellow later.
  ---------------------------------------------------------------------------

  local BADGE_EVENT_FALLBACK = {
    boulder = "EVENT_BEAT_BROCK",
    cascade = "EVENT_BEAT_MISTY",
    thunder = "EVENT_BEAT_LT_SURGE",
    rainbow = "EVENT_BEAT_ERIKA",
    soul = "EVENT_BEAT_KOGA",
    marsh = "EVENT_BEAT_SABRINA",
    volcano = "EVENT_BEAT_BLAINE",
    earth = "EVENT_BEAT_GIOVANNI",
  }

  local BADGE_ITEM = {
    boulder = "BOULDERBADGE",
    cascade = "CASCADEBADGE",
    thunder = "THUNDERBADGE",
    rainbow = "RAINBOWBADGE",
    soul = "SOULBADGE",
    marsh = "MARSHBADGE",
    volcano = "VOLCANOBADGE",
    earth = "EARTHBADGE",
  }

  local function badgeOwned(save, key)
    -- Inventory is canonical because the live field-move/gate logic reads it.
    -- Event fallback makes the guide more defensive with imported/modded saves.
    local owned = hasItem(save, BADGE_ITEM[key])
      or hasFlag(save, BADGE_EVENT_FALLBACK[key])
    -- Keep the pokered-style specific name as a defensive imported/modded
    -- save fallback; the current Route 22 gate reads EVENT_BEAT_GIOVANNI.
    if key == "earth" then
      owned = owned or hasFlag(save, "EVENT_BEAT_VIRIDIAN_GYM_GIOVANNI")
    end
    return owned
  end

  local function normalize(save)
    save = type(save) == "table" and save or {}
    local player = type(save.player) == "table" and save.player or {}
    local visited = type(save.visited) == "table" and save.visited or {}

    local s = {
      version = save.version or "unknown",
      raw = save,
      location = {
        map = player.map or "UNKNOWN",
        x = player.x,
        y = player.y,
        lastHealMap = type(save.lastHeal) == "table" and save.lastHeal.map or nil,
      },
      badges = {},
      keyItems = {},      -- carried in the bag right now
      pcItems = {},       -- stored in the in-game PC right now
      ownedItems = {},    -- bag OR in-game PC
      hms = {},           -- HM awarded/owned at some point
      hmItems = {},       -- HM disc carried in the bag right now
      hmPcItems = {},     -- HM disc stored in the PC right now
      moves = {},
      abilities = {},
      hmAnywhere = hmAnywhereActive(),
      story = {},
    }

    for key, _ in pairs(BADGE_ITEM) do
      s.badges[key] = badgeOwned(save, key)
    end

    local keyItemIds = {
      ssTicket = "S_S_TICKET",
      silphScope = "SILPH_SCOPE",
      cardKey = "CARD_KEY",
      liftKey = "LIFT_KEY",
      goldTeeth = "GOLD_TEETH",
      secretKey = "SECRET_KEY",
      bicycle = "BICYCLE",
      pokeFlute = "POKE_FLUTE",
      oaksParcel = "OAKS_PARCEL",
    }
    for key, id in pairs(keyItemIds) do
      s.keyItems[key] = hasItem(save, id)
      s.pcItems[key] = hasPcItem(save, id)
      s.ownedItems[key] = ownsItem(save, id)
    end

    local guardDrinkIds = { "FRESH_WATER", "SODA_POP", "LEMONADE" }
    s.keyItems.guardDrink = false
    s.pcItems.guardDrink = false
    s.ownedItems.guardDrink = false
    for _, id in ipairs(guardDrinkIds) do
      s.keyItems.guardDrink = s.keyItems.guardDrink or hasItem(save, id)
      s.pcItems.guardDrink = s.pcItems.guardDrink or hasPcItem(save, id)
      s.ownedItems.guardDrink = s.ownedItems.guardDrink or ownsItem(save, id)
    end

    local hmIds = {
      cut = "HM_CUT", fly = "HM_FLY", surf = "HM_SURF",
      strength = "HM_STRENGTH", flash = "HM_FLASH",
    }
    local hmEvents = {
      cut = "EVENT_GOT_HM01", fly = "EVENT_GOT_HM02", surf = "EVENT_GOT_HM03",
      strength = "EVENT_GOT_HM04", flash = "EVENT_GOT_HM05",
    }
    for key, id in pairs(hmIds) do
      s.hmItems[key] = hasItem(save, id)
      s.hmPcItems[key] = hasPcItem(save, id)
      -- The event is the strongest normal-play signal that the HM was awarded;
      -- bag/PC fallbacks support imported and modded saves.
      s.hms[key] = hasFlag(save, hmEvents[key]) or ownsItem(save, id)
    end

    s.moves.cut = partyKnows(save, "CUT")
    s.moves.fly = partyKnows(save, "FLY")
    s.moves.surf = partyKnows(save, "SURF")
    s.moves.strength = partyKnows(save, "STRENGTH")
    s.moves.flash = partyKnows(save, "FLASH")

    -- HM Anywhere exposes field moves directly from an HM carried in the Bag;
    -- its documented Badge requirements remain the same as vanilla.
    s.abilities.cut = s.badges.cascade
      and (s.moves.cut or (s.hmAnywhere and s.hmItems.cut))
    s.abilities.fly = s.badges.thunder
      and (s.moves.fly or (s.hmAnywhere and s.hmItems.fly))
    s.abilities.surf = s.badges.soul
      and (s.moves.surf or (s.hmAnywhere and s.hmItems.surf))
    s.abilities.strength = s.badges.rainbow
      and (s.moves.strength or (s.hmAnywhere and s.hmItems.strength))
    s.abilities.flash = s.badges.boulder
      and (s.moves.flash or (s.hmAnywhere and s.hmItems.flash))

    local st = s.story
    st.followedOak = hasFlag(save, "EVENT_FOLLOWED_OAK_INTO_LAB")
    st.gotStarter = hasFlag(save, "EVENT_GOT_STARTER")
    st.gotParcel = hasFlag(save, "EVENT_GOT_OAKS_PARCEL") or s.ownedItems.oaksParcel
    st.gotPokedex = hasFlag(save, "EVENT_GOT_POKEDEX")

    st.ceruleanRival = hasFlag(save, "EVENT_BEAT_CERULEAN_RIVAL")
    st.gotNugget = hasFlag(save, "EVENT_GOT_NUGGET")
    st.gotSsTicket = hasFlag(save, "EVENT_GOT_SS_TICKET") or s.ownedItems.ssTicket

    -- Mt. Moon has one story-critical trainer immediately before the fossil
    -- choice. These flags let HELP distinguish "keep exploring" from the
    -- actual blocker and from the final exit after a fossil is chosen.
    st.mtMoonSuperNerd = hasFlag(save, "EVENT_BEAT_MT_MOON_EXIT_SUPER_NERD")
    st.mtMoonFossil = hasFlag(save, "EVENT_GOT_DOME_FOSSIL")
      or hasFlag(save, "EVENT_GOT_HELIX_FOSSIL")

    st.ssAnneRival = hasFlag(save, "EVENT_BEAT_SS_ANNE_RIVAL")

    st.foundRocketHideout = hasFlag(save, "EVENT_FOUND_ROCKET_HIDEOUT")
    st.rocketHideoutGiovanni = hasFlag(save, "EVENT_BEAT_ROCKET_HIDEOUT_GIOVANNI")
    st.towerRival = hasFlag(save, "EVENT_BEAT_POKEMON_TOWER_RIVAL")
    st.ghostMarowak = hasFlag(save, "EVENT_BEAT_GHOST_MAROWAK")
    st.towerRocket1 = hasFlag(save, "EVENT_BEAT_POKEMONTOWER_7_TRAINER_0")
    st.towerRocket2 = hasFlag(save, "EVENT_BEAT_POKEMONTOWER_7_TRAINER_1")
    st.towerRocket3 = hasFlag(save, "EVENT_BEAT_POKEMONTOWER_7_TRAINER_2")
    st.fujiRescued = hasFlag(save, "EVENT_RESCUED_MR_FUJI")
    st.gotPokeFlute = hasFlag(save, "EVENT_GOT_POKE_FLUTE") or s.ownedItems.pokeFlute

    st.route12Snorlax = hasFlag(save, "EVENT_BEAT_ROUTE12_SNORLAX")
    st.route16Snorlax = hasFlag(save, "EVENT_BEAT_ROUTE16_SNORLAX")

    -- Gen1Recomp normalizes the original Saffron guard status bit to this flag.
    st.gaveGuardsDrink = hasFlag(save, "EVENT_GAVE_GUARDS_DRINK")
    st.silphRival = hasFlag(save, "EVENT_BEAT_SILPH_CO_RIVAL")
    st.silphGiovanni = hasFlag(save, "EVENT_BEAT_SILPH_CO_GIOVANNI")
    st.mansionSwitchOn = hasFlag(save, "EVENT_MANSION_SWITCH_ON")

    -- Victory Road switch flags are intentionally contextual only. Some of
    -- these puzzle flags reset on map transitions, so they must never prove
    -- global story completion.
    st.vr1Switch = hasFlag(save, "EVENT_VICTORY_ROAD_1_BOULDER_ON_SWITCH")
    st.vr2Switch1 = hasFlag(save, "EVENT_VICTORY_ROAD_2_BOULDER_ON_SWITCH1")
    st.vr2Switch2 = hasFlag(save, "EVENT_VICTORY_ROAD_2_BOULDER_ON_SWITCH2")
    st.vr3Switch1 = hasFlag(save, "EVENT_VICTORY_ROAD_3_BOULDER_ON_SWITCH1")
    st.vr3Switch2 = hasFlag(save, "EVENT_VICTORY_ROAD_3_BOULDER_ON_SWITCH2")

    st.route22Rival2 = hasFlag(save, "EVENT_BEAT_ROUTE22_RIVAL_2ND_BATTLE")
    st.champion = hasFlag(save, "EVENT_BEAT_CHAMPION_RIVAL")
      or (type(save.hallOfFame) == "table" and #save.hallOfFame > 0)

    st.lorelei = hasFlag(save, "EVENT_BEAT_LORELEIS_ROOM_TRAINER_0")
    st.bruno = hasFlag(save, "EVENT_BEAT_BRUNOS_ROOM_TRAINER_0")
    st.agatha = hasFlag(save, "EVENT_BEAT_AGATHAS_ROOM_TRAINER_0")
    st.lance = hasFlag(save, "EVENT_BEAT_LANCE")
    st.championThisRun = hasFlag(save, "EVENT_BEAT_CHAMPION_RIVAL_THIS_RUN")

    -- Downstream proof is used only where the later state unambiguously makes
    -- an earlier main-story objective irrelevant. It is intentionally narrow.
    st.towerSolved = st.fujiRescued or st.gotPokeFlute
    st.scopeBranchSatisfied = s.ownedItems.silphScope
      or st.ghostMarowak or st.fujiRescued or st.gotPokeFlute
    local healMapForFuchsia = s.location.lastHealMap
    st.fuchsiaReachedProof = s.hms.surf or s.hms.strength or s.badges.soul
      or visited.FUCHSIA_CITY == true
      or mapContains(s, "FUCHSIA") or mapContains(s, "SAFARI_ZONE")
      or mod.save:get(JOURNAL_FUCHSIA_REACHED, false) == true
      or mod.save:get(JOURNAL_EAST_FUCHSIA_ROUTE, false) == true
      or (type(healMapForFuchsia) == "string"
          and healMapForFuchsia:find("FUCHSIA", 1, true) ~= nil)
    st.snorlaxCleared = st.route12Snorlax or st.route16Snorlax
    -- A cleared Snorlax or later Fuchsia state is unambiguous downstream
    -- proof that the Poke Flute branch no longer needs to be recommended,
    -- even on imported/modded saves where the original flute flag is absent.
    st.fluteBranchSatisfied = st.gotPokeFlute or st.snorlaxCleared
      or st.fuchsiaReachedProof
    st.silphSolved = st.silphGiovanni or s.badges.marsh
    st.saffronAccessSatisfied = st.gaveGuardsDrink or st.silphRival
      or st.silphGiovanni or s.badges.marsh
    local healMap = s.location.lastHealMap
    st.indigoReachedProof = mapContains(s, "INDIGO_PLATEAU")
      or (type(healMap) == "string" and healMap:find("INDIGO_PLATEAU", 1, true) ~= nil)
      or st.lorelei or st.bruno or st.agatha or st.lance
      or st.championThisRun or st.champion

    return s
  end

  -- Location-only evidence that the player has crossed Rock Tunnel and is
  -- already in the western/midgame side of Kanto. This prevents HELP from
  -- dragging a player back to Surge/Rock Tunnel after they legitimately
  -- chose to keep moving.
  local function pastRockTunnelLocation(s)
    return mapContainsAny(s, {
      "LAVENDER", "CELADON", "SAFFRON", "FUCHSIA", "CINNABAR",
      "POKEMON_TOWER", "ROCKET_HIDEOUT", "SILPH_CO", "SAFARI_ZONE",
      "POKEMON_MANSION", "ROUTE_7", "ROUTE_8", "ROUTE_12",
      "ROUTE_13", "ROUTE_14", "ROUTE_15", "ROUTE_16", "ROUTE_17",
      "ROUTE_18", "INDIGO_PLATEAU", "VICTORY_ROAD"
    })
  end

  local function routeTrainerAccessible(s, mapId)
    if not ROUTE_TRAINERS[mapId] then return false end
    local n = tonumber(mapId:match("^ROUTE_(%d+)$"))
    if not n then return false end

    -- Route 22's rival encounters and Route 23's progressive Badge gates are
    -- story-timed rather than ordinary optional route cleanup. Keep those in
    -- the dedicated story resolver instead of presenting a misleading total.
    if n == 4 or n == 22 or n == 23 then return false end

    local ceruleanReached = s.story.ceruleanRival or s.story.gotNugget
      or s.story.gotSsTicket or s.badges.cascade
      or mapContainsAny(s, { "CERULEAN", "ROUTE_24", "ROUTE_25" })
    local midgame = pastRockTunnelLocation(s)
      or s.badges.rainbow or s.story.foundRocketHideout
      or s.story.scopeBranchSatisfied or s.story.fuchsiaReachedProof
      or s.story.saffronAccessSatisfied or s.story.silphSolved
      or s.badges.volcano or s.badges.earth or s.story.champion

    -- These routes have hard traversal gates that can make large sections (or
    -- the entire route) unreachable. Evaluate the gate before visit-history.
    if n == 10 then return midgame end
    if n == 12 then
      return s.story.route12Snorlax or s.story.fuchsiaReachedProof
    end
    if n >= 13 and n <= 15 then
      return s.story.route12Snorlax or s.story.fuchsiaReachedProof
    end
    if n >= 16 and n <= 18 then
      return s.ownedItems.bicycle
        and (s.story.route16Snorlax or s.story.fuchsiaReachedProof or routeWasSeen(mapId))
    end
    if n >= 19 and n <= 21 then return s.abilities.surf end
    if n == 24 then return s.story.ceruleanRival end
    if n == 25 then return s.story.gotNugget end

    -- For ordinary walking routes, an observed visit is strong sequence-break
    -- evidence that the route is available even when the expected story flag
    -- is absent from an imported/modded save.
    if mapIs(s, mapId) or routeWasSeen(mapId) then return true end

    if n <= 2 then return s.story.gotPokedex end
    if n == 3 then return s.badges.boulder end
    if n == 5 or n == 6 then return s.story.gotSsTicket or midgame end
    if n == 7 or n == 8 then return midgame end
    if n == 9 then return s.abilities.cut or midgame end
    if n == 11 then return s.story.gotSsTicket or midgame end
    return false
  end

  ---------------------------------------------------------------------------
  -- Objective records
  ---------------------------------------------------------------------------

  local function objective(id, destination, summary, details, kind)
    return {
      id = id,
      destination = destination,
      summary = summary,
      details = details or summary,
      kind = kind or "MAIN",
    }
  end

  local function withdrawObjective(id, itemLabel, action, kind)
    local summary = "Withdraw " .. itemLabel .. " from PC"
    if type(action) == "string" and action ~= "" then
      summary = summary .. " and " .. action
    else
      summary = summary .. "."
    end
    return objective("WITHDRAW_" .. id, "PC ITEM STORAGE", summary, summary, kind)
  end

  local function withdrawTwoObjective(id, itemA, itemB, action, kind)
    local summary = "Withdraw " .. itemA .. " + " .. itemB .. " from PC"
    if type(action) == "string" and action ~= "" then
      summary = summary .. ", then " .. action
    else
      summary = summary .. "."
    end
    return objective("WITHDRAW_" .. id, "PC ITEM STORAGE", summary, summary, kind)
  end

  local function route12ToFuchsiaObjective(s, kind)
    if s.story.route12Snorlax then
      return objective("REACH_FUCHSIA_ROUTE12", "FUCHSIA CITY",
        "Continue south through Routes 13-15 to Fuchsia City.",
        "Continue south through Routes 13-15 to Fuchsia City.", kind)
    end
    if s.pcItems.pokeFlute and not s.keyItems.pokeFlute then
      return withdrawObjective("POKE_FLUTE_ROUTE12", "POKE FLUTE",
        "wake Snorlax south of Lavender Town; take Routes 13-15 to Fuchsia.", kind)
    end
    if s.keyItems.pokeFlute or s.story.gotPokeFlute then
      return objective("CLEAR_SNORLAX_ROUTE12", "ROUTE 12",
        "Wake the Snorlax south of Lavender Town, then follow Routes 13-15 to Fuchsia City.",
        "Use the POKE FLUTE on the Snorlax south of Lavender Town, then continue through Routes 13-15 to Fuchsia City.", kind)
    end
    return nil
  end

  local function cyclingToFuchsiaObjective(s, kind)
    if not s.ownedItems.bicycle then return nil end

    local needBike = s.pcItems.bicycle and not s.keyItems.bicycle
    local needFlute = not s.story.route16Snorlax
      and s.pcItems.pokeFlute and not s.keyItems.pokeFlute

    if needBike and needFlute then
      return withdrawTwoObjective("BICYCLE_POKE_FLUTE", "BICYCLE", "POKE FLUTE",
        "wake Snorlax west of Celadon City; take Cycling Road.", kind)
    end
    if needBike then
      local action = s.story.route16Snorlax
        and "take Cycling Road to Fuchsia."
        or "wake Snorlax west of Celadon City; take Cycling Road to Fuchsia."
      return withdrawObjective("BICYCLE", "BICYCLE", action, kind)
    end
    if needFlute then
      return withdrawObjective("POKE_FLUTE_ROUTE16", "POKE FLUTE",
        "wake Snorlax west of Celadon City; take Cycling Road to Fuchsia.", kind)
    end
    if s.story.route16Snorlax and s.keyItems.bicycle then
      return objective("REACH_FUCHSIA_ROUTE16", "FUCHSIA CITY",
        "Ride Cycling Road to Fuchsia City.",
        "Ride south through Routes 17 and 18 to Fuchsia City.", kind)
    end
    if s.keyItems.bicycle and (s.keyItems.pokeFlute or s.story.gotPokeFlute) then
      return objective("CLEAR_SNORLAX_ROUTE16", "ROUTE 16",
        "Wake the Snorlax west of Celadon City, then take Cycling Road to Fuchsia.",
        "Use the POKE FLUTE on the Snorlax west of Celadon City, then ride Routes 17-18 to Fuchsia City.", kind)
    end
    return nil
  end

  local function routeTrainerObjective(s, mapId)
    if not routeTrainerAccessible(s, mapId) then return nil end
    local won, total = routeTrainerProgress(s.raw, mapId)
    if not won or total <= 0 or won >= total then return nil end
    local n = tonumber(mapId:match("(%d+)$")) or 0
    local summary
    if n >= 16 and n <= 18 and s.pcItems.bicycle and not s.keyItems.bicycle then
      summary = ("Withdraw BICYCLE from PC to access this route. Trainers defeated: %d/%d."):format(won, total)
    else
      summary = ("Trainers defeated: %d/%d."):format(won, total)
    end
    return objective("ROUTE_TRAINERS_" .. tostring(n), "ROUTE " .. tostring(n),
      summary, summary, "ROUTE")
  end

  local function route4SurfLassObjective(s)
    -- Route 4 has one real trainer in Red/Blue: the Lass on the isolated
    -- highest hill. She cannot be reached during the normal first trip from
    -- Mt. Moon to Cerulean; the player must return later via the Route 24
    -- waterway, so do not count her as available until field SURF is usable.
    if not s.abilities.surf then return nil end
    local won, total = routeTrainerProgress(s.raw, "ROUTE_4")
    if not won or not total or total <= 0 or won >= total then return nil end
    return objective("ROUTE4_SURF_LASS", "ROUTE 4",
      "Return to Route 4 and defeat the Lass west of Cerulean Cave.",
      "Use SURF from Route 24 toward Cerulean Cave, then continue west to the isolated Lass on Route 4.",
      "ROUTE")
  end

  local function missingSevenBadges(s)
    local ordered = {
      { "boulder", "PEWTER GYM", "BROCK" },
      { "cascade", "CERULEAN GYM", "MISTY" },
      { "thunder", "VERMILION GYM", "LT. SURGE" },
      { "rainbow", "CELADON GYM", "ERIKA" },
      { "soul", "FUCHSIA GYM", "KOGA" },
      { "marsh", "SAFFRON GYM", "SABRINA" },
      { "volcano", "CINNABAR GYM", "BLAINE" },
    }
    local out = {}
    for _, row in ipairs(ordered) do
      if not s.badges[row[1]] then out[#out + 1] = row end
    end
    return out
  end

  ---------------------------------------------------------------------------
  -- High-priority contextual overrides
  ---------------------------------------------------------------------------

  local function resolveLeagueContext(s)
    if mapIs(s, "LORELEIS_ROOM") then
      if not s.story.lorelei then
        return objective("E4_LORELEI", "LORELEI'S ROOM",
          "Defeat Lorelei.",
          "Win the first Elite Four battle, then continue through the north door.")
      end
      return objective("E4_LEAVE_LORELEI", "LORELEI'S ROOM",
        "Continue through the north door.",
        "Lorelei is defeated. Move on to the next Elite Four room.", "CONTEXT")
    end

    if mapIs(s, "BRUNOS_ROOM") then
      if not s.story.bruno then
        return objective("E4_BRUNO", "BRUNO'S ROOM",
          "Defeat Bruno.",
          "Win the second Elite Four battle and continue onward.")
      end
      return objective("E4_LEAVE_BRUNO", "BRUNO'S ROOM",
        "Continue to the next room.",
        "Bruno is defeated. Move forward to the third Elite Four member.", "CONTEXT")
    end

    if mapIs(s, "AGATHAS_ROOM") then
      if not s.story.agatha then
        return objective("E4_AGATHA", "AGATHA'S ROOM",
          "Defeat Agatha.",
          "Win the third Elite Four battle and continue onward.")
      end
      return objective("E4_LEAVE_AGATHA", "AGATHA'S ROOM",
        "Continue to the next room.",
        "Agatha is defeated. Move forward to the final Elite Four member.", "CONTEXT")
    end

    if mapIs(s, "LANCES_ROOM") then
      if not s.story.lance then
        return objective("E4_LANCE", "LANCE'S ROOM",
          "Defeat Lance.",
          "Win the final Elite Four battle. One last opponent will remain.")
      end
      return objective("E4_LEAVE_LANCE", "LANCE'S ROOM",
        "Continue to the Champion.",
        "Lance is defeated. Follow the path ahead to the Champion.", "CONTEXT")
    end

    if mapIs(s, "CHAMPIONS_ROOM") then
      -- Historical Hall of Fame / champion completion must not suppress a
      -- later League rematch. The per-run flag is authoritative in this room.
      if not s.story.championThisRun then
        return objective("CHAMPION", "CHAMPION'S ROOM",
          "Defeat the Champion.",
          s.story.champion
            and "You have reached the Champion again. Win this rematch to complete the current Pokemon League run."
            or "Win the final battle to become the Pokemon League Champion.")
      end
      return objective("E4_LEAVE_CHAMPION", "CHAMPION'S ROOM",
        "Continue to the Hall of Fame.",
        "The Champion is defeated for this run. Continue forward to finish the Pokemon League sequence.", "CONTEXT")
    end

    return nil
  end

  local function resolveGymContext(s)
    -- If the player deliberately enters a Gym that can be fought out of the
    -- usual guide order, follow that choice instead of nagging about another
    -- branch. Final prerequisites are still enforced later by the main graph.
    if mapIs(s, "PEWTER_GYM") and not s.badges.boulder then
      return objective("BROCK", "PEWTER GYM", "Defeat Brock.",
        "Defeat Brock to earn the Boulder Badge.", "CONTEXT")
    end
    if mapIs(s, "CERULEAN_GYM") and not s.badges.cascade then
      return objective("MISTY", "CERULEAN GYM", "Defeat Misty.",
        "Defeat Misty to earn the Cascade Badge.", "CONTEXT")
    end
    if mapIs(s, "VERMILION_GYM") and not s.badges.thunder then
      return objective("SURGE", "VERMILION GYM", "Defeat Lt. Surge.",
        "Defeat Lt. Surge to earn the Thunder Badge.", "CONTEXT")
    end
    if mapIs(s, "CELADON_GYM") and not s.badges.rainbow then
      return objective("ERIKA", "CELADON GYM", "Defeat Erika.",
        "Defeat Erika to earn the Rainbow Badge.", "CONTEXT")
    end
    if mapIs(s, "FUCHSIA_GYM") and not s.badges.soul then
      return objective("KOGA", "FUCHSIA GYM", "Defeat Koga.",
        "Defeat Koga to earn the Soul Badge.", "CONTEXT")
    end
    if mapIs(s, "SAFFRON_GYM") and not s.badges.marsh then
      return objective("SABRINA", "SAFFRON GYM", "Defeat Sabrina.",
        "Defeat Sabrina to earn the Marsh Badge.", "CONTEXT")
    end
    if mapIs(s, "CINNABAR_GYM") and not s.badges.volcano then
      return objective("BLAINE", "CINNABAR GYM", "Defeat Blaine.",
        "Defeat Blaine to earn the Volcano Badge.", "CONTEXT")
    end
    if mapIs(s, "VIRIDIAN_GYM") and not s.badges.earth then
      return objective("VIRIDIAN_GIOVANNI", "VIRIDIAN GYM",
        "Defeat Giovanni for the final Badge.",
        "Defeat Giovanni to earn the Earth Badge.", "CONTEXT")
    end
    return nil
  end

  local function resolveDungeonContext(s)
    -- Mt. Moon: the only mandatory internal story gate is the Super Nerd +
    -- fossil choice on B2F. Earlier floors are navigation context only.
    if mapContains(s, "MT_MOON") and not s.story.ceruleanRival then
      if mapIs(s, "MT_MOON_B2F") then
        if not s.story.mtMoonSuperNerd then
          return objective("MT_MOON_SUPER_NERD", "MT. MOON B2F",
            "Defeat the Super Nerd guarding the fossils.",
            "Continue through B2F until the Super Nerd stops you near the two fossils. Defeat him to clear the final story barrier in Mt. Moon.", "CONTEXT")
        end
        if not s.story.mtMoonFossil then
          return objective("MT_MOON_CHOOSE_FOSSIL", "MT. MOON B2F",
            "Choose either fossil.",
            "After defeating the Super Nerd, pick either the DOME FOSSIL or HELIX FOSSIL. The other fossil will be taken and the route onward will clear.", "CONTEXT")
        end
        return objective("MT_MOON_EXIT", "MT. MOON B2F",
          "Take the exit leading to Route 4.",
          "The fossil encounter is complete. Continue through the remaining B2F passage and leave Mt. Moon toward Route 4 and Cerulean City.", "CONTEXT")
      end
      if mapIs(s, "MT_MOON_B1F") then
        return objective("MT_MOON_B1F_ROUTE", "MT. MOON B1F",
          "Use the connecting passages to reach B2F.",
          "B1F links separated sections of the cave. Follow the passages and ladders that take you deeper toward B2F and the fossil area.", "CONTEXT")
      end
      return objective("MT_MOON_1F_ROUTE", "MT. MOON 1F",
        "Explore 1F and take the ladders deeper into Mt. Moon.",
        "Work through the main 1F cave and use its ladders to reach the lower floors. Your eventual goal is the fossil area on B2F.", "CONTEXT")
    end

    -- Rock Tunnel has no mandatory story flag inside the cave, so HELP uses
    -- the current floor rather than pretending trainer flags equal progress.
    if mapContains(s, "ROCK_TUNNEL") then
      if mapIs(s, "ROCK_TUNNEL_B1F") then
        return objective("ROCK_TUNNEL_B1F_ROUTE", "ROCK TUNNEL B1F",
          "Use B1F to connect the separated parts of 1F.",
          "Follow the underground corridors and take the next ladder that advances you toward the far 1F exit. The destination is southern Route 10, near Lavender Town.", "CONTEXT")
      end
      return objective("ROCK_TUNNEL_1F_ROUTE", "ROCK TUNNEL 1F",
        "Find the ladder route toward the far exit.",
        "Rock Tunnel alternates between 1F and B1F. Keep using the ladder network until you reach the opposite 1F exit to southern Route 10. FLASH is helpful but not required.", "CONTEXT")
    end

    if mapContains(s, "ROCKET_HIDEOUT") and not s.story.scopeBranchSatisfied then
      if s.pcItems.liftKey and not s.keyItems.liftKey and not s.story.rocketHideoutGiovanni then
        return withdrawObjective("LIFT_KEY", "LIFT KEY",
          "use the elevator to reach Giovanni.", "CONTEXT")
      end
      if not s.keyItems.liftKey and not s.story.rocketHideoutGiovanni then
        return objective("ROCKET_LIFT_KEY", "ROCKET HIDEOUT",
          "Find the LIFT KEY.",
          "Explore the hideout and defeat the Rocket carrying the LIFT KEY.", "CONTEXT")
      end
      if not s.story.rocketHideoutGiovanni then
        return objective("ROCKET_GIOVANNI", "ROCKET HIDEOUT B4F",
          "Use the elevator and defeat Giovanni.",
          "Use the LIFT KEY to reach the lower floor and confront Giovanni.", "CONTEXT")
      end
      if not s.keyItems.silphScope then
        return objective("ROCKET_PICK_SCOPE", "ROCKET HIDEOUT B4F",
          "Pick up the SILPH SCOPE.",
          "Giovanni is defeated. Collect the SILPH SCOPE he left behind before leaving.", "CONTEXT")
      end
    end

    if mapContains(s, "POKEMON_TOWER") and not s.story.gotPokeFlute then
      if mapIs(s, "POKEMON_TOWER_2F") and not s.story.towerRival then
        return objective("TOWER_RIVAL", "POKEMON TOWER 2F",
          "Defeat your rival.",
          "Your rival blocks the early climb on 2F. Defeat him, then continue upward through the tower.", "CONTEXT")
      end
      if not s.story.ghostMarowak then
        if mapIs(s, "POKEMON_TOWER_6F") then
          if s.pcItems.silphScope and not s.keyItems.silphScope then
            return withdrawObjective("SILPH_SCOPE", "SILPH SCOPE",
              "identify the ghost on Pokemon Tower 6F.", "CONTEXT")
          end
          return objective("TOWER_MAROWAK", "POKEMON TOWER 6F",
            "Get past the ghost blocking the stairs.",
            s.keyItems.silphScope
              and "Reach the top of 6F. The SILPH SCOPE will reveal the ghost as Marowak; defeat it to open the way to 7F."
              or "Reach the top of 6F and get past the unidentified ghost. The normal solution is the SILPH SCOPE from Team Rocket's Celadon hideout.", "CONTEXT")
        end
        return objective("TOWER_CLIMB", "POKEMON TOWER",
          "Keep climbing toward 6F.",
          "Continue upward through the Channeler floors. The main story blocker waits near the top of 6F.", "CONTEXT")
      end
      if not s.story.fujiRescued then
        if mapIs(s, "POKEMON_TOWER_7F") then
          local remaining = 0
          if not s.story.towerRocket1 then remaining = remaining + 1 end
          if not s.story.towerRocket2 then remaining = remaining + 1 end
          if not s.story.towerRocket3 then remaining = remaining + 1 end
          if remaining > 0 then
            return objective("TOWER_7F_ROCKETS", "POKEMON TOWER 7F",
              "Defeat the remaining Team Rocket grunts.",
              "There are " .. remaining .. " Rocket grunt(s) still blocking Mr. Fuji. Defeat them and continue to the north end of the floor.", "CONTEXT")
          end
          return objective("TOWER_SPEAK_FUJI", "POKEMON TOWER 7F",
            "Speak with Mr. Fuji.",
            "The Rockets are gone. Talk to Mr. Fuji to rescue him and return to his house in Lavender Town.", "CONTEXT")
        end
        return objective("TOWER_RESCUE_FUJI", "POKEMON TOWER 7F",
          "Reach 7F and rescue Mr. Fuji.",
          "Marowak is no longer blocking the stairs. Continue to 7F, defeat Team Rocket and speak with Mr. Fuji.", "CONTEXT")
      end
    end

    if mapContains(s, "SAFARI_ZONE") then
      if not s.abilities.surf and not s.hms.surf and not s.moves.surf then
        return objective("SAFARI_SURF", "SAFARI ZONE SECRET HOUSE",
          "Find the SECRET HOUSE and receive HM03 SURF.",
          "Explore deep into the Safari Zone. The Secret House contains HM03 SURF.", "CONTEXT")
      end
      if s.pcItems.goldTeeth and not s.keyItems.goldTeeth and not s.hms.strength and not s.moves.strength then
        return withdrawObjective("GOLD_TEETH", "GOLD TEETH",
          "return them to the Safari Warden for HM04.", "CONTEXT")
      end
      if not s.ownedItems.goldTeeth and not s.hms.strength and not s.moves.strength then
        return objective("SAFARI_TEETH", "SAFARI ZONE",
          "Find the GOLD TEETH.",
          "Search the Safari Zone for the Warden's GOLD TEETH, then return them in Fuchsia City.", "CONTEXT")
      end
    end

    if mapContains(s, "SILPH_CO") and not s.story.silphSolved then
      if s.pcItems.cardKey and not s.keyItems.cardKey then
        return withdrawObjective("CARD_KEY", "CARD KEY",
          "open Silph Co.'s locked offices.", "CONTEXT")
      end
      if not s.keyItems.cardKey then
        if mapIs(s, "SILPH_CO_5F") then
          return objective("SILPH_CARD_KEY", "SILPH CO. 5F",
            "Find and pick up the CARD KEY.",
            "The CARD KEY is on 5F. Search the floor's corridors for the item ball; it opens the locked office doors throughout Silph Co.", "CONTEXT")
        end
        return objective("SILPH_GO_5F", "SILPH CO. 5F",
          "Go to 5F and find the CARD KEY.",
          "Before chasing the warp maze, obtain the CARD KEY on 5F. It unlocks the doors needed for the reliable route to your rival and Giovanni.", "CONTEXT")
      end
      if not s.story.silphRival then
        if mapIs(s, "SILPH_CO_3F") then
          return objective("SILPH_3F_WARP", "SILPH CO. 3F",
            "Unlock the left-side office and use its warp tile.",
            "Use the CARD KEY on 3F to open the locked office route, then step on the warp tile that sends you to the 7F rival area.", "CONTEXT")
        end
        if mapIs(s, "SILPH_CO_7F") then
          return objective("SILPH_RIVAL", "SILPH CO. 7F",
            "Reach and defeat your rival.",
            "You are on the correct floor. Follow the protected warp-area corridor and defeat your rival before continuing toward Giovanni.", "CONTEXT")
        end
        return objective("SILPH_RETURN_3F", "SILPH CO. 3F",
          "Return to 3F and use the CARD KEY route.",
          "With the CARD KEY obtained, the clean story route starts on 3F: unlock the office passage there and use its warp tile to reach your rival on 7F.", "CONTEXT")
      end
      if mapIs(s, "SILPH_CO_7F") then
        return objective("SILPH_7F_TO_11F", "SILPH CO. 7F",
          "Use the nearby warp route to reach 11F.",
          "Your rival is defeated. Continue through the warp route in this protected area to reach the President's section on 11F.", "CONTEXT")
      end
      if mapIs(s, "SILPH_CO_11F") then
        return objective("SILPH_GIOVANNI", "SILPH CO. 11F",
          "Defeat Giovanni.",
          "You have reached the President's floor. Defeat the Rocket guarding the route if necessary, then confront Giovanni in the President's room.", "CONTEXT")
      end
      return objective("SILPH_RETURN_7F", "SILPH CO. 7F",
        "Return to the 7F rival area and take the warp onward.",
        "The rival is already defeated. Return to the protected 7F warp area and use the onward warp route to reach Giovanni on 11F.", "CONTEXT")
    end

    if mapContains(s, "POKEMON_MANSION") and s.pcItems.secretKey and not s.keyItems.secretKey then
      return withdrawObjective("SECRET_KEY", "SECRET KEY",
        "enter Cinnabar Gym and challenge Blaine.", "CONTEXT")
    end

    if mapContains(s, "POKEMON_MANSION") and not s.ownedItems.secretKey then
      if mapIs(s, "POKEMON_MANSION_1F") then
        return objective("MANSION_1F", "POKEMON MANSION 1F",
          "Use the stairs and statue switches to work upward.",
          "The mansion's statues toggle groups of doors. Use them as needed and continue toward the upper floors; the SECRET KEY is ultimately reached through the basement route.", "CONTEXT")
      end
      if mapIs(s, "POKEMON_MANSION_2F") then
        return objective("MANSION_2F", "POKEMON MANSION 2F",
          "Use the statue switch to open the route onward.",
          "Toggle the nearby Mewtwo statue when a gate blocks you, then continue toward 3F. Statue switches can close one passage while opening another.", "CONTEXT")
      end
      if mapIs(s, "POKEMON_MANSION_3F") then
        return objective("MANSION_3F_DROP", "POKEMON MANSION 3F",
          "Use the correct ledge drop to reach the basement route.",
          "After arranging the statue doors, use the 3F ledge/drop route that leads deeper into the mansion rather than simply returning toward the entrance.", "CONTEXT")
      end
      if mapIs(s, "POKEMON_MANSION_B1F") then
        return objective("MANSION_B1F_KEY", "POKEMON MANSION B1F",
          "Search B1F for the SECRET KEY.",
          s.story.mansionSwitchOn
            and "The mansion switch is currently ON. Follow the open basement passages and collect the SECRET KEY item ball before leaving."
            or "Use the basement statue switch if a gate blocks the route, then search the open passages for the SECRET KEY item ball.", "CONTEXT")
      end
      return objective("MANSION_SECRET_KEY", "POKEMON MANSION",
        "Find the SECRET KEY in the basement route.",
        "Use Mewtwo statue switches to change which gates are open, work through the upper floors, then reach the basement and collect the SECRET KEY.", "CONTEXT")
    end

    if mapContains(s, "VICTORY_ROAD") and not s.story.champion then
      if not s.abilities.strength then
        if not s.hms.strength and not s.moves.strength then
          if s.pcItems.goldTeeth and not s.keyItems.goldTeeth then
            return withdrawObjective("GOLD_TEETH", "GOLD TEETH",
              "get HM04 from the Safari Warden before Victory Road.")
          end
          if s.keyItems.goldTeeth then
            return objective("WARDEN_HM04", "FUCHSIA CITY",
              "Return the GOLD TEETH to the Safari Warden.",
              "Victory Road requires STRENGTH. Return the GOLD TEETH to receive HM04.")
          end
          return objective("SAFARI_GOLD_TEETH", "SAFARI ZONE",
            "Find the GOLD TEETH.",
            "Victory Road requires STRENGTH. Find the GOLD TEETH and return them to the Safari Warden.")
        end
        if s.hms.strength and not s.moves.strength then
          if s.hmPcItems.strength and not s.hmItems.strength then
            if s.hmAnywhere then
              return withdrawObjective("HM04", "HM04 STRENGTH",
                "use STRENGTH to continue through Victory Road.")
            end
            return withdrawObjective("HM04", "HM04 STRENGTH",
              "teach STRENGTH before continuing through Victory Road.")
          end
          return objective("TEACH_STRENGTH", "PARTY",
            "Teach STRENGTH to a Pokemon.",
            "Victory Road requires STRENGTH. You have HM04 and the Rainbow Badge, but no party member currently knows the move.")
        end
      end

      if mapIs(s, "VICTORY_ROAD_1F") then
        if not s.story.vr1Switch then
          return objective("VICTORY_ROAD_1F_SWITCH", "VICTORY ROAD 1F",
            "Push a boulder onto the floor switch.",
            "Use STRENGTH to move a boulder onto the switch. The switch controls the barriers blocking your route upward.", "CONTEXT")
        end
        return objective("VICTORY_ROAD_1F_CONTINUE", "VICTORY ROAD 1F",
          "Continue through the opened passage.",
          "The 1F switch is active. Follow the opened route deeper into Victory Road.", "CONTEXT")
      end

      if mapIs(s, "VICTORY_ROAD_2F") then
        if not s.story.vr2Switch1 and not s.story.vr2Switch2 then
          return objective("VICTORY_ROAD_2F_SWITCH1", "VICTORY ROAD 2F",
            "Use STRENGTH to activate the first required switch.",
            "Move the available boulder onto a floor switch to remove the first barrier controlling this floor's route.", "CONTEXT")
        end
        if s.story.vr2Switch1 and not s.story.vr2Switch2 then
          return objective("VICTORY_ROAD_2F_SWITCH2", "VICTORY ROAD 2F",
            "Continue and solve the second switch puzzle.",
            "The first 2F switch is active. Follow the opened passage and use STRENGTH again when the next boulder/barrier puzzle blocks progress.", "CONTEXT")
        end
        return objective("VICTORY_ROAD_2F_CONTINUE", "VICTORY ROAD 2F",
          "Continue through the opened route.",
          "The relevant 2F switch route is open. Continue through the accessible stairs/passages toward the upper section of Victory Road.", "CONTEXT")
      end

      if mapIs(s, "VICTORY_ROAD_3F") then
        if not s.story.vr3Switch1 and not s.story.vr3Switch2 then
          return objective("VICTORY_ROAD_3F_SWITCH1", "VICTORY ROAD 3F",
            "Solve the first boulder switch on 3F.",
            "Use STRENGTH to move the accessible boulder onto its switch and open the next part of the floor.", "CONTEXT")
        end
        if s.story.vr3Switch1 and not s.story.vr3Switch2 then
          return objective("VICTORY_ROAD_3F_SWITCH2", "VICTORY ROAD 3F",
            "Finish the remaining 3F switch route.",
            "One 3F switch is active. Continue through the opened section and complete the remaining boulder-switch step needed for the route onward.", "CONTEXT")
        end
        return objective("VICTORY_ROAD_3F_CONTINUE", "VICTORY ROAD 3F",
          "Follow the opened route toward the exit.",
          "The 3F switch route is open. Follow the available passages and stairs toward the final descent and Indigo Plateau exit.", "CONTEXT")
      end

      return objective("VICTORY_ROAD", "VICTORY ROAD",
        "Use STRENGTH puzzles to reach Indigo Plateau.",
        "Push boulders onto switches to open the route through Victory Road. Keep moving toward Indigo Plateau.", "CONTEXT")
    end

    return nil
  end

  ---------------------------------------------------------------------------
  -- Main progression resolver (recommended normal-play route)
  ---------------------------------------------------------------------------

  local function resolve(save)
    local s = normalize(save)

    -- If an existing save is already inside the League or a key dungeon,
    -- current location outranks the global recommended route.
    local contextual = resolveLeagueContext(s) or resolveDungeonContext(s)
      or resolveGymContext(s)
    if contextual then return contextual, s end

    if s.story.champion then
      return objective("POSTGAME_CERULEAN_CAVE", "CERULEAN CAVE",
        "Main adventure complete. Explore Cerulean Cave.",
        "You are the Pokemon League Champion. Optional postgame: explore Cerulean Cave northwest of Cerulean City.", "POSTGAME"), s
    end

    -- Opening
    if not s.story.gotStarter then
      if s.story.followedOak or mapIs(s, "OAKS_LAB") then
        return objective("CHOOSE_STARTER", "OAK'S LAB",
          "Choose your first Pokemon.",
          "Choose one of the three Pokemon on Professor Oak's table."), s
      end
      return objective("MEET_OAK", "PALLET TOWN",
        "Leave home and walk north toward Route 1.",
        "Head for the tall grass north of Pallet Town. Professor Oak will stop you and take you to his lab."), s
    end

    if not s.story.gotPokedex then
      if s.story.gotParcel then
        if s.pcItems.oaksParcel and not s.keyItems.oaksParcel then
          return withdrawObjective("OAKS_PARCEL", "OAK'S PARCEL",
            "return it to Professor Oak."), s
        end
        return objective("RETURN_OAK_PARCEL", "OAK'S LAB",
          "Return to Professor Oak with his Parcel.",
          "Travel back to Pallet Town and deliver OAK'S PARCEL to Professor Oak."), s
      end
      return objective("GET_OAK_PARCEL", "VIRIDIAN CITY",
        "Visit the Poke Mart and collect Oak's Parcel.",
        "Travel north to Viridian City. The Poke Mart clerk has a delivery for Professor Oak."), s
    end

    -- Pewter / Cerulean
    if not s.badges.boulder then
      return objective("BROCK", "PEWTER GYM",
        "Reach Pewter City and defeat Brock.",
        "Travel through Viridian Forest to Pewter City, then challenge Brock for the Boulder Badge."), s
    end

    if not s.story.gotSsTicket then
      if not s.story.ceruleanRival then
        if mapContains(s, "MT_MOON") then
          return objective("CROSS_MT_MOON", "MT. MOON",
            "Find the eastern exit to Route 4.",
            "Cross Mt. Moon to reach Route 4 and Cerulean City."), s
        end
        return objective("CERULEAN_RIVAL", "CERULEAN CITY",
          "Reach Cerulean City, then head north and defeat your rival.",
          "Travel east from Pewter through Route 3 and Mt. Moon. In Cerulean City, head north toward Nugget Bridge."), s
      end
      if not s.story.gotNugget then
        return objective("NUGGET_BRIDGE", "ROUTE 24",
          "Fight your way across Nugget Bridge.",
          "Defeat the trainers on Nugget Bridge and continue north/east toward Bill."), s
      end
      return objective("BILL", "ROUTE 25 / BILL'S HOUSE",
        "Find Bill and receive the S.S. Ticket.",
        "Continue east across Route 25, help Bill in his house and receive the S.S. Ticket."), s
    end

    if not s.badges.cascade then
      return objective("MISTY", "CERULEAN GYM",
        "Defeat Misty.",
        "Challenge Misty in Cerulean Gym to earn the Cascade Badge."), s
    end

    -- Vermilion / Cut. Field progression cares about the usable move, not
    -- ownership of HM01 itself: a traded Pokemon may already know CUT.
    local pastEarlyCutGate = pastRockTunnelLocation(s)
      or s.badges.rainbow or s.story.foundRocketHideout
      or s.story.scopeBranchSatisfied or s.story.fuchsiaReachedProof
      or s.story.saffronAccessSatisfied or s.story.silphSolved or s.badges.volcano
      or s.badges.earth
    if not s.hms.cut and not s.abilities.cut and not pastEarlyCutGate then
      if s.pcItems.ssTicket and not s.keyItems.ssTicket then
        return withdrawObjective("S_S_TICKET", "S.S. TICKET",
          "board the S.S. Anne in Vermilion City."), s
      end
      return objective("SS_ANNE_HM01", "S.S. ANNE",
        "Board the S.S. Anne and find the captain.",
        "Use the S.S. Ticket in Vermilion City, explore the ship and speak with the captain to receive HM01 CUT."), s
    end

    -- Do not nag about teaching CUT if the save proves the player is already
    -- beyond the early Cut gate.
    if not pastEarlyCutGate and not s.abilities.cut and s.hms.cut then
      if not s.moves.cut then
        if s.hmPcItems.cut and not s.hmItems.cut then
          if s.hmAnywhere then
            return withdrawObjective("HM01", "HM01 CUT",
              "use CUT to reach Vermilion Gym."), s
          end
          return withdrawObjective("HM01", "HM01 CUT",
            "teach CUT to a Pokemon."), s
        end
        return objective("TEACH_CUT", "PARTY",
          "Teach CUT to a Pokemon.",
          "You have HM01 and the Cascade Badge. Teach CUT to a party member so you can clear small trees."), s
      end
    end

    -- Surge is the recommended route immediately after S.S. Anne, though the
    -- wider resolver still accepts saves that reached later areas first.
    if not s.badges.thunder and not (pastRockTunnelLocation(s)
        or s.badges.rainbow or s.story.foundRocketHideout
        or s.story.scopeBranchSatisfied or s.story.fuchsiaReachedProof
        or s.story.saffronAccessSatisfied or s.story.silphSolved
        or s.badges.volcano or s.badges.earth) then
      return objective("SURGE", "VERMILION GYM",
        "Use CUT to reach the Gym and defeat Lt. Surge.",
        "Clear the tree blocking Vermilion Gym and earn the Thunder Badge from Lt. Surge."), s
    end

    -- Route 9 / Rock Tunnel is only suggested if the save has no clear proof
    -- that the player has already entered the Celadon/Lavender midgame.
    local midgameProof = pastRockTunnelLocation(s)
      or s.badges.rainbow or s.story.foundRocketHideout
      or s.story.scopeBranchSatisfied or s.story.fuchsiaReachedProof
      or s.story.saffronAccessSatisfied or s.story.silphSolved
      or s.badges.volcano or s.badges.earth
    if not midgameProof then
      return objective("ROCK_TUNNEL", "ROCK TUNNEL",
        "Head east from Cerulean and cross Rock Tunnel.",
        "Use CUT east of Cerulean City, travel along Routes 9 and 10, then cross Rock Tunnel to Lavender Town."), s
    end

    -- Celadon: Erika is the default recommendation, but a save that already
    -- progressed the Rocket/Tower/Fuchsia branches is never forced backward.
    local pastErikaRecommendation = s.story.foundRocketHideout
      or s.story.scopeBranchSatisfied or s.story.towerRival
      or s.story.ghostMarowak or s.story.fujiRescued
      or s.story.fluteBranchSatisfied or s.story.fuchsiaReachedProof
      or s.story.saffronAccessSatisfied or s.story.silphSolved
      or s.badges.soul or s.badges.marsh or s.badges.volcano or s.badges.earth
    if not s.badges.rainbow and not pastErikaRecommendation then
      return objective("ERIKA", "CELADON GYM",
        "Defeat Erika.",
        "Challenge Erika in Celadon Gym to earn the Rainbow Badge. It will later allow STRENGTH outside battle."), s
    end

    -- Rocket Hideout / Silph Scope. Downstream Tower completion satisfies this
    -- branch, including legitimate/legacy oddities such as the Poke Doll skip.
    if not s.story.scopeBranchSatisfied then
      if not s.story.foundRocketHideout then
        return objective("FIND_ROCKET_HIDEOUT", "CELADON GAME CORNER",
          "Investigate Team Rocket in the Game Corner.",
          "Find the hidden switch behind the Rocket poster to reveal the Rocket Hideout."), s
      end
      return objective("ENTER_ROCKET_HIDEOUT", "ROCKET HIDEOUT",
        "Explore the Rocket Hideout and obtain the SILPH SCOPE.",
        "Enter the hidden base beneath the Game Corner. Find the LIFT KEY, defeat Giovanni and collect the SILPH SCOPE."), s
    end

    -- Pokemon Tower / Poke Flute
    if not s.story.fluteBranchSatisfied then
      if s.pcItems.silphScope and not s.keyItems.silphScope and not s.story.ghostMarowak then
        return withdrawObjective("SILPH_SCOPE", "SILPH SCOPE",
          "identify the ghost on Pokemon Tower 6F."), s
      end
      if s.story.fujiRescued then
        return objective("GET_POKE_FLUTE", "MR. FUJI'S HOUSE",
          "Speak with Mr. Fuji and receive the POKE FLUTE.",
          "Mr. Fuji is safe. Speak with him in Lavender Town to receive the POKE FLUTE."), s
      end
      return objective("POKEMON_TOWER", "POKEMON TOWER",
        "Climb Pokemon Tower and rescue Mr. Fuji.",
        "Return to Lavender Town with the SILPH SCOPE, identify the ghost, defeat Team Rocket and rescue Mr. Fuji."), s
    end

    -- Fuchsia access: Route 12 and Cycling Road are parallel choices. PC
    -- prerequisites are folded into the route objective itself so HELP always
    -- explains WHY an item should be withdrawn instead of presenting a naked
    -- inventory-management task.
    if not s.story.fuchsiaReachedProof then
      local onRoute12Path = mapContainsAny(s, { "ROUTE_12", "ROUTE_13", "ROUTE_14", "ROUTE_15" })
      local onRoute16Path = mapContainsAny(s, { "ROUTE_16", "ROUTE_17", "ROUTE_18" })
      local east = route12ToFuchsiaObjective(s)
      local cycling = cyclingToFuchsiaObjective(s)

      if onRoute12Path and east then return east, s end
      if onRoute16Path and cycling then return cycling, s end
      -- If one route is already physically open, finish that route before
      -- recommending that the player wake the other Snorlax. With neither
      -- route open, a carried Bicycle keeps Cycling Road as the preferred
      -- first page; resolveAll() still exposes the alternative.
      if s.story.route12Snorlax and east then return east, s end
      if s.story.route16Snorlax and s.keyItems.bicycle and cycling then return cycling, s end
      if s.keyItems.bicycle and cycling then return cycling, s end
      if east then return east, s end
      if cycling then return cycling, s end
    end

    -- Midgame branches after the Poke Flute are intentionally non-linear.
    -- Fuchsia, Saffron and Cinnabar can be tackled in different orders. HELP
    -- follows a branch the player has clearly started, and only pulls an
    -- earlier deferred requirement back in when it actually gates progress.
    local fuchsiaActive = mapContains(s, "FUCHSIA") or mapContains(s, "SAFARI_ZONE")
    local saffronActive = mapContains(s, "SAFFRON") or mapContains(s, "SILPH_CO")
    local cinnabarActive = mapContains(s, "CINNABAR") or mapContains(s, "POKEMON_MANSION")
    local saffronStarted = s.story.saffronAccessSatisfied or s.story.silphSolved
      or s.badges.marsh or saffronActive
    local cinnabarStarted = s.ownedItems.secretKey or s.badges.volcano or cinnabarActive

    local function fuchsiaRequiredObjective()
      if s.abilities.surf then return nil end
      -- A traded Pokemon can already know SURF. In that case the only missing
      -- gate is Koga's Soul Badge; HM03 itself is not required.
      if s.moves.surf and not s.badges.soul then
        return objective("KOGA", "FUCHSIA GYM",
          "Defeat Koga.",
          "Earn the Soul Badge so your Pokemon can use SURF outside battle.")
      end
      if not s.hms.surf and not s.moves.surf then
        return objective("SAFARI_HM03", "SAFARI ZONE",
          "Find the Secret House and obtain HM03 SURF.",
          "Enter the Safari Zone and reach the Secret House to receive HM03 SURF.")
      end
      if not s.badges.soul then
        return objective("KOGA", "FUCHSIA GYM",
          "Defeat Koga.",
          "Challenge Koga for the Soul Badge. The badge allows SURF outside battle.")
      end
      -- Teaching SURF can also be postponed. Only require the move when the
      -- player actually starts the Cinnabar water branch.
      return nil
    end

    local function saffronRequiredObjective()
      if not s.story.saffronAccessSatisfied then
        if s.pcItems.guardDrink and not s.keyItems.guardDrink then
          return withdrawObjective("SAFFRON_DRINK", "DRINK",
            "give it to a Saffron guard.")
        end
        return objective("OPEN_SAFFRON", "SAFFRON CITY GATE",
          "Bring a drink from Celadon to a Saffron guard.",
          "Buy FRESH WATER, SODA POP or LEMONADE in Celadon Department Store and give it to a Saffron guard.")
      end
      if not s.story.silphSolved then
        return objective("SILPH_CO", "SILPH CO.",
          "Drive Team Rocket out of Silph Co.",
          "Enter Silph Co., work your way through the building and defeat Giovanni.")
      end
      if not s.badges.marsh then
        return objective("SABRINA", "SAFFRON GYM",
          "Defeat Sabrina.",
          "With Team Rocket gone, challenge Sabrina in Saffron Gym for the Marsh Badge.")
      end
      return nil
    end

    local function cinnabarRequiredObjective()
      if s.badges.volcano then return nil end
      -- Cinnabar requires the field capability SURF, not ownership of HM03
      -- specifically. This also supports traded Pokemon that already know it.
      if not s.abilities.surf then
        if s.moves.surf and not s.badges.soul then
          return objective("KOGA", "FUCHSIA GYM",
            "Defeat Koga.",
            "Earn the Soul Badge so SURF can be used outside battle.")
        end
        if not s.hms.surf and not s.moves.surf then
          return objective("SAFARI_HM03", "SAFARI ZONE",
            "Find the Secret House and obtain HM03 SURF.",
            "Get a Pokemon that can use SURF outside battle. The normal route is HM03 from the Safari Zone Secret House.")
        end
        if not s.badges.soul then
          return objective("KOGA", "FUCHSIA GYM",
            "Defeat Koga.",
            "Earn the Soul Badge so SURF can be used outside battle.")
        end
        if not s.moves.surf then
          if s.hmPcItems.surf and not s.hmItems.surf then
            if s.hmAnywhere then
              return withdrawObjective("HM03", "HM03 SURF",
                "use SURF to travel to Cinnabar Island.")
            end
            return withdrawObjective("HM03", "HM03 SURF",
              "teach SURF before going to Cinnabar Island.")
          end
          return objective("TEACH_SURF", "PARTY",
            "Teach SURF to a Pokemon.",
            "You have HM03 and the Soul Badge. Teach SURF to a party member before travelling by water.")
        end
      end
      if s.pcItems.secretKey and not s.keyItems.secretKey then
        return withdrawObjective("SECRET_KEY", "SECRET KEY",
          "enter Cinnabar Gym and challenge Blaine.")
      end
      if not s.ownedItems.secretKey then
        return objective("CINNABAR_MANSION", "POKEMON MANSION",
          "Explore Pokemon Mansion and find the SECRET KEY.",
          "Surf to Cinnabar Island, enter Pokemon Mansion and find the SECRET KEY that opens the Gym.")
      end
      return objective("BLAINE", "CINNABAR GYM",
        "Use the SECRET KEY and defeat Blaine.",
        "Open Cinnabar Gym with the SECRET KEY and challenge Blaine for the Volcano Badge.")
    end

    -- Current location wins among the three valid branches.
    if fuchsiaActive then
      local o = fuchsiaRequiredObjective()
      if o then return o, s end
    elseif saffronActive then
      local o = saffronRequiredObjective()
      if o then return o, s end
    elseif cinnabarActive then
      local o = cinnabarRequiredObjective()
      if o then return o, s end
    end

    -- Away from those towns, preserve a branch the player has clearly begun.
    -- Cinnabar is the deepest optional-order branch, so finishing a started
    -- Cinnabar task takes precedence over dragging the player back to Saffron.
    if cinnabarStarted and not s.badges.volcano then
      local o = cinnabarRequiredObjective()
      if o then return o, s end
    end
    if saffronStarted then
      local o = saffronRequiredObjective()
      if o then return o, s end
    end

    -- Default recommendation after opening a route to Fuchsia: get Surf and
    -- Koga, but DO NOT force GOLD TEETH/HM04 yet. STRENGTH is not required
    -- until Victory Road and can legitimately be postponed for hours.
    local fuchsiaObjective = fuchsiaRequiredObjective()
    if fuchsiaObjective then return fuchsiaObjective, s end

    -- With Fuchsia's actual Cinnabar prerequisites ready, Saffron is the
    -- default recommendation, followed by Cinnabar.
    local saffronObjective = saffronRequiredObjective()
    if saffronObjective then return saffronObjective, s end

    local cinnabarObjective = cinnabarRequiredObjective()
    if cinnabarObjective then return cinnabarObjective, s end

    -- Catch any legitimately skipped required Gym before Viridian opens.
    local missing = missingSevenBadges(s)
    if #missing > 0 then
      local row = missing[1]
      return objective("MISSING_BADGE_" .. string.upper(row[1]), row[2],
        "Defeat " .. row[3] .. " and earn the missing Badge.",
        "Viridian Gym requires the other seven Kanto Badges. Return to " .. row[2] .. " and defeat " .. row[3] .. "."), s
    end

    if not s.badges.earth then
      return objective("VIRIDIAN_GIOVANNI", "VIRIDIAN GYM",
        "Defeat Giovanni for the final Badge.",
        "All seven earlier Badges are secured. Return to Viridian Gym and defeat Giovanni for the Earth Badge."), s
    end

    if not s.story.route22Rival2 then
      return objective("ROUTE22_RIVAL", "ROUTE 22",
        "Defeat your rival on the way to the Pokemon League.",
        "Head west from Viridian City toward Route 22. Your rival will challenge you before the League route."), s
    end

    if not s.abilities.strength then
      -- As with CUT/SURF, a traded Pokemon may already know STRENGTH. With
      -- Rainbow Badge that is sufficient; HM04 ownership is not a story gate.
      if not s.hms.strength and not s.moves.strength then
        if s.pcItems.goldTeeth and not s.keyItems.goldTeeth then
          return withdrawObjective("GOLD_TEETH", "GOLD TEETH",
            "get HM04 from the Safari Warden before Victory Road."), s
        end
        if s.keyItems.goldTeeth then
          return objective("WARDEN_HM04", "FUCHSIA CITY",
            "Return the GOLD TEETH to the Safari Warden.",
            "Victory Road requires STRENGTH. Return the GOLD TEETH to the Warden in Fuchsia City to receive HM04."), s
        end
        return objective("SAFARI_GOLD_TEETH", "SAFARI ZONE",
          "Find the GOLD TEETH.",
          "Victory Road requires STRENGTH. Find the Warden's GOLD TEETH in the Safari Zone, then return them in Fuchsia City."), s
      end
      if s.hms.strength and not s.moves.strength then
        if s.hmPcItems.strength and not s.hmItems.strength then
          if s.hmAnywhere then
            return withdrawObjective("HM04", "HM04 STRENGTH",
              "use STRENGTH in Victory Road."), s
          end
          return withdrawObjective("HM04", "HM04 STRENGTH",
            "teach STRENGTH before Victory Road."), s
        end
        return objective("TEACH_STRENGTH", "PARTY",
          "Teach STRENGTH to a Pokemon.",
          "Victory Road requires STRENGTH. Teach HM04 to a party member before entering the cave."), s
      end
    end

    if mapIs(s, "INDIGO_PLATEAU_LOBBY") then
      return objective("START_ELITE_FOUR", "INDIGO PLATEAU",
        "Prepare your team and challenge the Elite Four.",
        "Heal, stock up on supplies, then enter the first room to challenge Lorelei."), s
    end

    if s.story.indigoReachedProof then
      return objective("RETURN_INDIGO", "INDIGO PLATEAU",
        "Return to Indigo Plateau and challenge the Elite Four.",
        "You have already reached Indigo Plateau. Return there and begin the Pokemon League challenge."), s
    end

    return objective("REACH_INDIGO", "INDIGO PLATEAU",
      "Reach Indigo Plateau and challenge the Elite Four.",
      "Pass the Route 23 Badge checks and cross Victory Road to reach Indigo Plateau for the first time."), s
  end

  ---------------------------------------------------------------------------
  -- Multi-objective collector
  --
  -- resolve() remains the conservative single "best next" resolver. This
  -- layer adds other actions that are currently valid and keeps explicitly
  -- optional/unexplored experiences visible until their own completion proof
  -- exists. One objective == one HELP page; text itself is never paginated.
  ---------------------------------------------------------------------------

  local OBJECTIVE_DEDUPE_KEY = {
    MISSING_BADGE_BOULDER = "BROCK",
    MISSING_BADGE_CASCADE = "MISTY",
    MISSING_BADGE_THUNDER = "SURGE",
    MISSING_BADGE_RAINBOW = "ERIKA",
    MISSING_BADGE_SOUL = "KOGA",
    MISSING_BADGE_MARSH = "SABRINA",
    MISSING_BADGE_VOLCANO = "BLAINE",
    WITHDRAW_S_S_TICKET = "SS_ANNE_HM01",
    SAFARI_SURF = "SAFARI_HM03",
    SAFARI_TEETH = "SAFARI_GOLD_TEETH",
    CLEAR_SNORLAX_ROUTE12 = "ROUTE12_PATH",
    REACH_FUCHSIA_ROUTE12 = "ROUTE12_PATH",
    WITHDRAW_POKE_FLUTE_ROUTE12 = "ROUTE12_PATH",
    CLEAR_SNORLAX_ROUTE16 = "ROUTE16_PATH",
    REACH_FUCHSIA_ROUTE16 = "ROUTE16_PATH",
    WITHDRAW_POKE_FLUTE_ROUTE16 = "ROUTE16_PATH",
    WITHDRAW_BICYCLE = "ROUTE16_PATH",
    WITHDRAW_BICYCLE_POKE_FLUTE = "ROUTE16_PATH",

    MT_MOON_SUPER_NERD = "MT_MOON",
    MT_MOON_CHOOSE_FOSSIL = "MT_MOON",
    MT_MOON_EXIT = "MT_MOON",
    MT_MOON_B1F_ROUTE = "MT_MOON",
    MT_MOON_1F_ROUTE = "MT_MOON",
    CROSS_MT_MOON = "MT_MOON",
    ROCK_TUNNEL_B1F_ROUTE = "ROCK_TUNNEL",
    ROCK_TUNNEL_1F_ROUTE = "ROCK_TUNNEL",

    ROCKET_LIFT_KEY = "ROCKET_HIDEOUT",
    ROCKET_GIOVANNI = "ROCKET_HIDEOUT",
    ROCKET_PICK_SCOPE = "ROCKET_HIDEOUT",
    ENTER_ROCKET_HIDEOUT = "ROCKET_HIDEOUT",
    OPTIONAL_FIND_ROCKET_HIDEOUT = "ROCKET_HIDEOUT",
    OPTIONAL_ROCKET_HIDEOUT = "ROCKET_HIDEOUT",
    WITHDRAW_LIFT_KEY = "ROCKET_HIDEOUT",

    WITHDRAW_SILPH_SCOPE = "POKEMON_TOWER",
    TOWER_RIVAL = "POKEMON_TOWER",
    TOWER_MAROWAK = "POKEMON_TOWER",
    TOWER_CLIMB = "POKEMON_TOWER",
    TOWER_7F_ROCKETS = "POKEMON_TOWER",
    TOWER_SPEAK_FUJI = "POKEMON_TOWER",
    TOWER_RESCUE_FUJI = "POKEMON_TOWER",

    WITHDRAW_CARD_KEY = "SILPH_CO",
    SILPH_CARD_KEY = "SILPH_CO",
    SILPH_GO_5F = "SILPH_CO",
    SILPH_3F_WARP = "SILPH_CO",
    SILPH_RIVAL = "SILPH_CO",
    SILPH_RETURN_3F = "SILPH_CO",
    SILPH_7F_TO_11F = "SILPH_CO",
    SILPH_GIOVANNI = "SILPH_CO",
    SILPH_RETURN_7F = "SILPH_CO",

    MANSION_1F = "CINNABAR_MANSION",
    MANSION_2F = "CINNABAR_MANSION",
    MANSION_3F_DROP = "CINNABAR_MANSION",
    MANSION_B1F_KEY = "CINNABAR_MANSION",
    MANSION_SECRET_KEY = "CINNABAR_MANSION",

    VICTORY_ROAD_1F_SWITCH = "VICTORY_ROAD",
    VICTORY_ROAD_1F_CONTINUE = "VICTORY_ROAD",
    VICTORY_ROAD_2F_SWITCH1 = "VICTORY_ROAD",
    VICTORY_ROAD_2F_SWITCH2 = "VICTORY_ROAD",
    VICTORY_ROAD_2F_CONTINUE = "VICTORY_ROAD",
    VICTORY_ROAD_3F_SWITCH1 = "VICTORY_ROAD",
    VICTORY_ROAD_3F_SWITCH2 = "VICTORY_ROAD",
    VICTORY_ROAD_3F_CONTINUE = "VICTORY_ROAD",
  }

  local function addPage(pages, seen, obj, pageRole)
    if not obj then return end
    local key = OBJECTIVE_DEDUPE_KEY[obj.id] or obj.id
    if seen[key] then return end
    obj.pageRole = pageRole or (obj.kind == "CONTEXT" and "CONTEXT" or "OPTION")
    seen[key] = true
    pages[#pages + 1] = obj
  end

  local function resolveAll(save)
    local primary, s = resolve(save)
    local pages, seen = {}, {}
    addPage(pages, seen, primary,
      primary.kind == "CONTEXT" and "CONTEXT" or "PRIMARY")

    -- Before Oak/Pokedex/Brock there is deliberately no parallel guidance.
    -- The first meaningful choice in ordinary Red/Blue is Cerulean: Misty
    -- versus continuing north toward Bill.
    local ceruleanReached = s.story.ceruleanRival or s.story.gotNugget
      or s.story.gotSsTicket or s.badges.cascade
      or mapContainsAny(s, { "CERULEAN", "ROUTE_24", "ROUTE_25" })

    if s.story.gotPokedex and s.badges.boulder and ceruleanReached then
      if not s.badges.cascade then
        addPage(pages, seen, objective("MISTY", "CERULEAN GYM",
          "Defeat Misty.",
          "Challenge Misty in Cerulean Gym to earn the Cascade Badge."), "OPTION")
      end
      if not s.story.gotSsTicket then
        if not s.story.ceruleanRival then
          addPage(pages, seen, objective("CERULEAN_RIVAL", "CERULEAN CITY",
            "Head north and defeat your rival.",
            "Head north from Cerulean toward Nugget Bridge and defeat your rival."), "OPTION")
        elseif not s.story.gotNugget then
          addPage(pages, seen, objective("NUGGET_BRIDGE", "ROUTE 24",
            "Fight your way across Nugget Bridge.",
            "Defeat the trainers on Nugget Bridge and continue toward Bill."), "OPTION")
        else
          addPage(pages, seen, objective("BILL", "ROUTE 25 / BILL'S HOUSE",
            "Find Bill and receive the S.S. Ticket.",
            "Continue across Route 25, help Bill and receive the S.S. Ticket."), "OPTION")
        end
      end
    end

    -- S.S. Anne is an actual unfinished event even when a traded Pokemon let
    -- the player bypass HM01 entirely. Keep it in the journal until HM01 was
    -- really awarded, but classify it as UNFINISHED once the main route has
    -- clearly moved beyond the early Cut gate.
    local midgameProof = pastRockTunnelLocation(s)
      or s.badges.rainbow or s.story.foundRocketHideout
      or s.story.scopeBranchSatisfied or s.story.fuchsiaReachedProof
      or s.story.saffronAccessSatisfied or s.story.silphSolved
      or s.badges.volcano or s.badges.earth or s.story.champion
    if s.story.gotSsTicket and not s.hms.cut then
      addPage(pages, seen, objective("SS_ANNE_HM01", "S.S. ANNE",
        "Board the S.S. Anne and find the captain.",
        "Explore the ship and speak with the captain to receive HM01 CUT."),
        midgameProof and "UNFINISHED" or "OPTION")
    end

    if s.story.gotSsTicket and s.abilities.cut then
      if not s.badges.thunder then
        addPage(pages, seen, objective("SURGE", "VERMILION GYM",
          "Use CUT to reach the Gym and defeat Lt. Surge.",
          "Clear the tree blocking Vermilion Gym and defeat Lt. Surge."),
          midgameProof and "UNFINISHED" or "OPTION")
      end
      if not midgameProof then
        addPage(pages, seen, objective("ROCK_TUNNEL", "ROCK TUNNEL",
          "Head east from Cerulean and cross Rock Tunnel.",
          "Travel through Routes 9 and 10 and cross Rock Tunnel to Lavender Town."), "OPTION")
      end
    end

    -- Celadon opens several legitimate parallel branches.
    if midgameProof then
      if not s.badges.rainbow then
        addPage(pages, seen, objective("ERIKA", "CELADON GYM",
          "Defeat Erika.",
          "Challenge Erika for the Rainbow Badge."), "OPTION")
      end

      if not s.story.scopeBranchSatisfied then
        if not s.story.foundRocketHideout then
          addPage(pages, seen, objective("FIND_ROCKET_HIDEOUT", "CELADON GAME CORNER",
            "Investigate Team Rocket in the Game Corner.",
            "Find the hidden switch behind the Rocket poster."), "OPTION")
        else
          addPage(pages, seen, objective("ENTER_ROCKET_HIDEOUT", "ROCKET HIDEOUT",
            "Explore the Rocket Hideout and obtain the SILPH SCOPE.",
            "Find the LIFT KEY, defeat Giovanni and collect the SILPH SCOPE."), "OPTION")
        end
      elseif not s.ownedItems.silphScope then
        -- Poke Doll / imported downstream saves can satisfy Tower progression
        -- without ever completing the intended Rocket Hideout event. Keep the
        -- exact remaining sub-step visible instead of pretending it happened.
        if not s.story.foundRocketHideout then
          addPage(pages, seen, objective("OPTIONAL_FIND_ROCKET_HIDEOUT", "CELADON GAME CORNER",
            "Team Rocket's Game Corner secret is still unfinished.",
            "Optional unfinished event: reveal the Rocket Hideout beneath the Game Corner."), "UNFINISHED")
        elseif not s.story.rocketHideoutGiovanni then
          addPage(pages, seen, objective("OPTIONAL_ROCKET_HIDEOUT", "ROCKET HIDEOUT",
            "Team Rocket's Celadon hideout is still unfinished.",
            "Optional unfinished event: clear the Rocket Hideout beneath the Game Corner."), "UNFINISHED")
        else
          addPage(pages, seen, objective("ROCKET_PICK_SCOPE", "ROCKET HIDEOUT B4F",
            "Pick up the SILPH SCOPE.",
            "Giovanni is defeated. Pick up the SILPH SCOPE he left behind."), "UNFINISHED")
        end
      end

      if s.story.scopeBranchSatisfied and not s.story.fluteBranchSatisfied then
        if s.story.fujiRescued then
          addPage(pages, seen, objective("GET_POKE_FLUTE", "MR. FUJI'S HOUSE",
            "Speak with Mr. Fuji and receive the POKE FLUTE.",
            "Speak with Mr. Fuji in Lavender Town."), "OPTION")
        else
          addPage(pages, seen, objective("POKEMON_TOWER", "POKEMON TOWER",
            "Climb Pokemon Tower and rescue Mr. Fuji.",
            "Climb the tower, get past Marowak and rescue Mr. Fuji."), "OPTION")
        end
      end

      if not s.story.saffronAccessSatisfied then
        if s.pcItems.guardDrink and not s.keyItems.guardDrink then
          addPage(pages, seen, withdrawObjective("SAFFRON_DRINK", "DRINK",
            "give it to a Saffron guard."), "OPTION")
        else
          addPage(pages, seen, objective("OPEN_SAFFRON", "SAFFRON CITY GATE",
            "Bring a drink from Celadon to a Saffron guard.",
            "Give FRESH WATER, SODA POP or LEMONADE to a Saffron gate guard."), "OPTION")
        end
      end
    end

    -- Before Fuchsia is reached, expose both legitimate routes as separate
    -- pages. After Fuchsia is reached these navigation pages disappear; route
    -- cleanup is represented by concrete per-route trainer progress below.
    if not s.story.fuchsiaReachedProof then
      addPage(pages, seen, route12ToFuchsiaObjective(s), "OPTION")
      addPage(pages, seen, cyclingToFuchsiaObjective(s), "OPTION")
    end

    if s.story.fuchsiaReachedProof then
      -- Reaching Fuchsia by one route does not silently mark the other
      -- Snorlax encounter complete. Keep each sleeping Snorlax as a small
      -- unfinished event, with PC withdrawal folded into the purpose.
      if s.story.gotPokeFlute and not s.story.route12Snorlax then
        if s.pcItems.pokeFlute and not s.keyItems.pokeFlute then
          addPage(pages, seen, withdrawObjective("POKE_FLUTE_SNORLAX12", "POKE FLUTE",
            "wake the Snorlax south of Lavender Town."), "UNFINISHED")
        else
          addPage(pages, seen, objective("OPTIONAL_SNORLAX_ROUTE12", "ROUTE 12",
            "Wake the Snorlax south of Lavender Town.",
            "Use the POKE FLUTE to wake the Snorlax on Route 12, south of Lavender Town."), "UNFINISHED")
        end
      end
      if s.story.gotPokeFlute and not s.story.route16Snorlax then
        if s.pcItems.pokeFlute and not s.keyItems.pokeFlute then
          addPage(pages, seen, withdrawObjective("POKE_FLUTE_SNORLAX16", "POKE FLUTE",
            "wake the Snorlax west of Celadon City."), "UNFINISHED")
        else
          addPage(pages, seen, objective("OPTIONAL_SNORLAX_ROUTE16", "ROUTE 16",
            "Wake the Snorlax west of Celadon City.",
            "Use the POKE FLUTE to wake the Snorlax on Route 16, west of Celadon City."), "UNFINISHED")
        end
      end

      if not s.badges.soul then
        addPage(pages, seen, objective("KOGA", "FUCHSIA GYM",
          "Defeat Koga.", "Challenge Koga for the Soul Badge."), "OPTION")
      end
      -- EVENT_GOT_HM03 itself is worth keeping as an unfinished Safari event
      -- even when a traded Pokemon already supplies SURF.
      if not s.hms.surf then
        addPage(pages, seen, objective("SAFARI_HM03", "SAFARI ZONE",
          "Find the Secret House and obtain HM03 SURF.",
          "Reach the Secret House inside the Safari Zone."),
          s.moves.surf and "UNFINISHED" or "OPTION")
      end
      if not s.hms.strength then
        if s.pcItems.goldTeeth and not s.keyItems.goldTeeth then
          addPage(pages, seen, withdrawObjective("GOLD_TEETH", "GOLD TEETH",
            "return them to the Safari Warden for HM04."), "UNFINISHED")
        elseif s.keyItems.goldTeeth then
          addPage(pages, seen, objective("WARDEN_HM04", "FUCHSIA CITY",
            "Return the GOLD TEETH to the Safari Warden.",
            "Return the GOLD TEETH to receive HM04 STRENGTH."), "UNFINISHED")
        else
          addPage(pages, seen, objective("SAFARI_GOLD_TEETH", "SAFARI ZONE",
            "Find the GOLD TEETH.",
            "Optional unfinished event: find the Warden's GOLD TEETH in the Safari Zone."), "UNFINISHED")
        end
      end
    end

    -- Saffron branch: only its next serial step is actionable at a time.
    if s.story.saffronAccessSatisfied then
      if not s.story.silphSolved then
        addPage(pages, seen, objective("SILPH_CO", "SILPH CO.",
          "Drive Team Rocket out of Silph Co.",
          "Work through Silph Co. and defeat Giovanni."), "OPTION")
      elseif not s.badges.marsh then
        addPage(pages, seen, objective("SABRINA", "SAFFRON GYM",
          "Defeat Sabrina.", "Challenge Sabrina for the Marsh Badge."), "OPTION")
      end
    end

    -- Cinnabar becomes an independent branch as soon as SURF is actually
    -- usable, or if the save proves the player already started that island.
    local cinnabarStarted = s.ownedItems.secretKey or s.badges.volcano
      or mapContainsAny(s, { "CINNABAR", "POKEMON_MANSION" })
    if (s.abilities.surf or cinnabarStarted) and not s.badges.volcano then
      if s.pcItems.secretKey and not s.keyItems.secretKey then
        addPage(pages, seen, withdrawObjective("SECRET_KEY", "SECRET KEY",
          "enter Cinnabar Gym and challenge Blaine."), "OPTION")
      elseif not s.ownedItems.secretKey then
        addPage(pages, seen, objective("CINNABAR_MANSION", "POKEMON MANSION",
          "Explore Pokemon Mansion and find the SECRET KEY.",
          "Find the SECRET KEY that opens Cinnabar Gym."), "OPTION")
      else
        addPage(pages, seen, objective("BLAINE", "CINNABAR GYM",
          "Use the SECRET KEY and defeat Blaine.",
          "Open Cinnabar Gym and defeat Blaine."), "OPTION")
      end
    end

    -- Once the player is clearly in the late game, expose every missing Gym
    -- as its own page instead of picking only the first missing badge.
    local lateGame = s.story.fuchsiaReachedProof or s.story.saffronAccessSatisfied
      or s.story.silphSolved or s.badges.soul or s.badges.marsh
      or s.badges.volcano or s.badges.earth or s.story.champion
    if lateGame then
      for _, row in ipairs(missingSevenBadges(s)) do
        addPage(pages, seen,
          objective("MISSING_BADGE_" .. string.upper(row[1]), row[2],
            "Defeat " .. row[3] .. " and earn the missing Badge.",
            "Return to " .. row[2] .. " and defeat " .. row[3] .. "."),
          "OPTION")
      end
    end

    -- The final linear chain remains represented by resolve() as page 1. Add
    -- these only when actionable so no future objective leaks early.
    if #missingSevenBadges(s) == 0 and not s.badges.earth then
      addPage(pages, seen, objective("VIRIDIAN_GIOVANNI", "VIRIDIAN GYM",
        "Defeat Giovanni for the final Badge.",
        "Defeat Giovanni to earn the Earth Badge."), "OPTION")
    end
    if s.badges.earth and not s.story.route22Rival2 then
      addPage(pages, seen, objective("ROUTE22_RIVAL", "ROUTE 22",
        "Defeat your rival on the way to the Pokemon League.",
        "Head west from Viridian City and defeat your rival."), "OPTION")
    end

    -- Route 4's sole trainer is isolated behind the Route 24 waterway.
    -- Present her as a distinct late cleanup task only after field SURF is
    -- actually usable, rather than making early Route 4 look incomplete.
    addPage(pages, seen, route4SurfLassObjective(s), "UNFINISHED")

    -- Optional route cleanup: only routes currently accessible at this story
    -- state are exposed, and only while at least one generic trainer remains.
    -- Totals come from the live merged map registry cached at mod init.
    for n = 1, 25 do
      local routeObj = routeTrainerObjective(s, "ROUTE_" .. n)
      addPage(pages, seen, routeObj, "ROUTE")
    end

    return pages, s
  end

  -- Export both APIs: existing integrations can keep resolve(), while callers
  -- interested in the journal-style UI can inspect all current pages.
  mod.exports.normalize = normalize
  mod.exports.resolve = resolve
  mod.exports.resolveAll = resolveAll

  ---------------------------------------------------------------------------
  -- HELP screen
  --
  -- dev3.7 UX rules:
  --   * one concise objective per screen; multiple objectives become pages
  --   * page 1 is resolve()'s recommended/current step
  --   * other valid paths and unfinished optional events follow
  --   * A / SELECT / Right = next, Left = previous, B = close
  --   * SELECT-open uses a release latch so the opening press cannot also
  --     advance immediately to page 2
  ---------------------------------------------------------------------------

  local HELP_MAX_COLS = 18
  local HELP_SUMMARY_LINES = 6
  local pendingSelectOpen = false

  local function wrappedLines(text, maxCols)
    local TextBox = mod.ui.TextBox
    local wrappedPages = TextBox.paginate(tostring(text or ""), maxCols or HELP_MAX_COLS)
    local lines = {}
    for _, wrappedPage in ipairs(wrappedPages or {}) do
      for _, line in ipairs(wrappedPage or {}) do
        lines[#lines + 1] = line
      end
    end
    if #lines == 0 then lines[1] = "" end
    return lines
  end

  local function drawTextLines(Font, lines, x, y, step)
    for i, line in ipairs(lines or {}) do
      Font.draw(line, x, y + (i - 1) * step)
    end
  end

  local function buildHelpView(result)
    local destination = wrappedLines(result.destination or "UNKNOWN", HELP_MAX_COLS)
    local summary = wrappedLines(result.summary or "", HELP_MAX_COLS)
    while #summary > HELP_SUMMARY_LINES do table.remove(summary) end

    local heading = "OTHER OPTION"
    if result.pageRole == "CONTEXT" then heading = "CURRENT STEP"
    elseif result.pageRole == "PRIMARY" then heading = "NEXT OBJECTIVE"
    elseif result.pageRole == "UNFINISHED" then heading = "UNFINISHED"
    elseif result.pageRole == "ROUTE" then heading = "ROUTE TRAINERS"
    end

    return { heading = heading, destination = destination, summary = summary }
  end

  local function openHelp(game, viaSelect)
    pendingSelectOpen = viaSelect == true
    mod.ui.push(game, "HelpStoryGuide")
  end

  mod.content.screens:register("HelpStoryGuide", {
    new = function(game)
      local results = resolveAll(game.save)
      if type(results) ~= "table" or #results == 0 then
        local fallback = resolve(game.save)
        fallback.pageRole = fallback.kind == "CONTEXT" and "CONTEXT" or "PRIMARY"
        results = { fallback }
      end

      local openedBySelect = pendingSelectOpen
      pendingSelectOpen = false
      local self = {
        isOpaque = true,
        results = results,
        index = 1,
        selectArmed = not openedBySelect,
      }

      local function stepPage(dir)
        local n = #self.results
        if n <= 1 then return end
        self.index = ((self.index - 1 + dir) % n) + 1
      end

      function self:update(dt)
        local input = game.input
        if not self.selectArmed and not input:isDown("select") then
          self.selectArmed = true
        end

        if input:wasPressed("b") then
          game.stack:pop()
        elseif input:wasPressed("left") then
          stepPage(-1)
        elseif input:wasPressed("right") or input:wasPressed("a")
            or (self.selectArmed and input:wasPressed("select")) then
          stepPage(1)
        end
      end

      function self:draw()
        local Font = mod.ui.Font
        local result = self.results[self.index]
        local view = buildHelpView(result)

        Font.drawBox(0, 0, 20, 18)
        if love and love.graphics and love.graphics.setColor then
          love.graphics.setColor(0, 0, 0, 1)
        end

        Font.draw("HELP", 8, 8)
        if #self.results > 1 then
          local counter = ('%d/%d'):format(self.index, #self.results)
          Font.draw(counter, 152 - #counter * 8, 8)
        end
        Font.draw(view.heading, 8, 24)
        drawTextLines(Font, view.destination, 8, 40, 8)

        local summaryY = #view.destination > 1 and 64 or 56
        drawTextLines(Font, view.summary, 8, summaryY, 8)

        if #self.results > 1 then
          Font.draw("A/SEL:NEXT", 8, 128)
          Font.draw("B:BACK", 104, 128)
        else
          Font.draw("B:BACK", 104, 128)
        end

        if love and love.graphics and love.graphics.setColor then
          love.graphics.setColor(1, 1, 1, 1)
        end
      end

      return self
    end,
  })

  ---------------------------------------------------------------------------
  -- START menu integration
  ---------------------------------------------------------------------------

  -- Important: run the downstream chain FIRST, then decorate its returned
  -- list. This is the reference pattern used by Gen1Recomp's example_dexnav
  -- and prevents another START-menu wrapper from discarding our row.
  mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
    local out = next(game, items)
    if type(out) ~= "table" then return out end
    return mod.ui.insertBefore(out, "OPTION", {
      id = "HELP",
      label = "HELP",
      onSelect = function()
        openHelp(game, false)
      end,
    })
  end, 100)

  ---------------------------------------------------------------------------
  -- MOD SETTINGS: SELECT HELP
  --
  -- Keep HELP-specific preferences out of the crowded global OPTIONS menu.
  -- Gen1Recomp renders mod.options rows inside this mod's own manager detail
  -- and persists them under options.modOptions[mod.id].
  ---------------------------------------------------------------------------

  mod.options:define({
    {
      key = "select_help",
      type = "toggle",
      label = "SELECT HELP",
      default = false,
    },
  })

  local function selectHelpEnabled(_game)
    return mod.options:get("select_help") == true
  end

  ---------------------------------------------------------------------------
  -- SELECT shortcut + route-visit evidence
  ---------------------------------------------------------------------------

  local selectWasDown = false

  local function canOpenSelectHelp(game)
    if not game or not game.stack or not game.overworld then return false end
    if game.stack:top() ~= game.overworld then return false end
    local ow = game.overworld
    if ow.transitioning then return false end
    if ow.runner and ow.runner.isRunning and ow.runner:isRunning() then return false end
    if ow.scriptMoves and #ow.scriptMoves > 0 then return false end
    if ow.engaging or ow.emote then return false end
    return true
  end

  -- Exact route visitation is best recorded on map entry. The game's own
  -- save.visited deliberately covers fly towns only, not ordinary routes.
  mod.events:on("map.entered", function(ev)
    if type(ev) == "table" then markRouteJournal(ev.mapId, ev.fromMapId) end
  end)

  mod.hooks:wrap("input.step", function(next, game, dt)
    local ret = next(game, dt)
    local input = game and game.input
    local down = input and input:isDown("select") or false
    local rising = down and not selectWasDown
    selectWasDown = down

    if rising and selectHelpEnabled(game) and canOpenSelectHelp(game) then
      -- Game:step invokes input.step BEFORE Input:step promotes wasPressed.
      -- HelpStoryGuide therefore starts disarmed and waits for SELECT release
      -- before that button may advance pages.
      openHelp(game, true)
    end
    return ret
  end, 100)
end
