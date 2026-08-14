-- HELP - Story Guide
-- v2.0.3
-- Target: Gen1Recomp v0.1.86 mod API 2 / Gen 1 (Red/Blue/Yellow) + Gold;
-- no engine-version pin
--
-- Design goals:
--   * derive progress from the authoritative game save; never maintain a parallel helpStage
--   * use only the public mod surface supplied by Gen1Recomp
--   * tolerate legitimate non-linear progression and downstream-completed states
--   * distinguish HM ownership from actual field usability, including HM Anywhere compatibility
--   * keep resolver logic independent of the HELP screen

return function(mod)
  -- Live game reference is a service pointer only.  It is never progression
  -- state; pure/headless resolvers continue to accept explicit save snapshots.
  local liveGame = nil

  -- Assigned after the read-only diagnostic layer is defined.  Event/UI hooks
  -- may call it conditionally, but normal players pay only one nil/active check.
  -- The live-certification recorder is transient process memory: it never
  -- writes mod.save or the game save and never participates in resolution.
  local auditRecord = nil

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
    if type(ev) == "table" then
      liveGame = ev.game
      refreshRouteTrainerCache(ev.game)
      if auditRecord then auditRecord("GAME_READY", ev.game and ev.game.save, ev.game) end
    end
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

  local function normalizeGen1(save)
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

  local function resolveGen1(save)
    local s = normalizeGen1(save)

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

  local function resolveAllGen1(save)
    local primary, s = resolveGen1(save)
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

  ---------------------------------------------------------------------------
  -- GOLD / GEN 2 backend
  --
  -- This is intentionally separate from the frozen v1.0.5 Gen1 resolver.
  -- Symbol ids below are a mod-local generated/audited subset of current
  -- upstream tests/drivers/gold/flag_names.lua (re-audited through dev 49d094b1, 2026-08-12).
  -- Objective code never contains numeric event ids directly.
  ---------------------------------------------------------------------------

  local GOLD_EVENT_IDS = {
    EVENT_GOT_A_POKEMON_FROM_ELM = 26,
    EVENT_GOT_MYSTERY_EGG_FROM_MR_POKEMON = 30,
    EVENT_GAVE_MYSTERY_EGG_TO_ELM = 31,
    EVENT_GOT_TOGEPI_EGG_FROM_ELMS_AIDE = 45,
    EVENT_ELMS_AIDE_IN_VIOLET_POKEMON_CENTER = 1792,
    EVENT_GOT_SQUIRTBOTTLE = 92,
    EVENT_CLEARED_SLOWPOKE_WELL = 43,
    EVENT_AZALEA_TOWN_SLOWPOKETAIL_ROCKET = 1786,
    EVENT_HERDED_FARFETCHD = 41,
    EVENT_FOUGHT_SUDOWOODO = 42,
    EVENT_RELEASED_THE_BEASTS = 123,
    EVENT_JASMINE_EXPLAINED_AMPHYS_SICKNESS = 55,
    EVENT_GOT_SECRETPOTION_FROM_PHARMACY = 35,
    EVENT_JASMINE_RETURNED_TO_GYM = 32,
    EVENT_LAKE_OF_RAGE_RED_GYARADOS = 1873,
    EVENT_DECIDED_TO_HELP_LANCE = 96,
    EVENT_UNCOVERED_STAIRCASE_IN_MAHOGANY_MART = 738,
    EVENT_LEARNED_SLOWPOKETAIL = 769,
    EVENT_LEARNED_RATICATE_TAIL = 770,
    EVENT_LEARNED_HAIL_GIOVANNI = 767,
    EVENT_CLEARED_ROCKET_HIDEOUT = 34,
    EVENT_CLEARED_RADIO_TOWER = 33,
    EVENT_GOT_HM01_CUT = 16,
    EVENT_GOT_HM02_FLY = 17,
    EVENT_GOT_HM03_SURF = 18,
    EVENT_GOT_HM04_STRENGTH = 19,
    EVENT_GOT_HM05_FLASH = 20,
    EVENT_GOT_HM06_WHIRLPOOL = 21,
    EVENT_GOT_HM07_WATERFALL = 1672,
    EVENT_BEAT_FALKNER = 1213,
    EVENT_BEAT_BUGSY = 1214,
    EVENT_BEAT_WHITNEY = 1215,
    EVENT_BEAT_JASMINE = 1217,
    EVENT_BEAT_CHUCK = 1218,
    EVENT_BEAT_CLAIR = 1220,
    EVENT_BEAT_ELITE_4_WILL = 1464,
    EVENT_BEAT_ELITE_4_KOGA = 1465,
    EVENT_BEAT_ELITE_4_BRUNO = 1466,
    EVENT_BEAT_ELITE_4_KAREN = 1467,
    EVENT_BEAT_CHAMPION_LANCE = 1468,
    EVENT_BEAT_ELITE_FOUR = 68,
    EVENT_RIVAL_VICTORY_ROAD = 1730,
    EVENT_GOT_SS_TICKET_FROM_ELM = 36,
    EVENT_FAST_SHIP_FIRST_TIME = 48,
    EVENT_FAST_SHIP_HAS_ARRIVED = 49,
    EVENT_FAST_SHIP_FOUND_GIRL = 50,
    EVENT_FAST_SHIP_LAZY_SAILOR = 51,
    EVENT_FAST_SHIP_INFORMED_ABOUT_LAZY_SAILOR = 52,
    EVENT_BEAT_SAILOR_STANLY = 1405,
    EVENT_FAST_SHIP_CABINS_SE_SSE_CAPTAINS_CABIN_TWIN_2 = 1842,
    EVENT_MET_MANAGER_AT_POWER_PLANT = 202,
    EVENT_MET_ROCKET_GRUNT_AT_CERULEAN_GYM = 203,
    EVENT_ROUTE_24_ROCKET = 1900,
    EVENT_FOUND_MACHINE_PART_IN_CERULEAN_GYM = 251,
    EVENT_RETURNED_MACHINE_PART = 201,
    EVENT_RESTORED_POWER_TO_KANTO = 205,
    EVENT_FOUGHT_SNORLAX = 1872,
    EVENT_BEAT_RIVAL_IN_MT_MOON = 793,
    EVENT_TALKED_TO_OAK_IN_KANTO = 225,
    EVENT_ROUTE_25_MISTY_BOYFRIEND = 1902,
    EVENT_TRAINERS_IN_CERULEAN_GYM = 1903,
    EVENT_BLUE_IN_CINNABAR = 1909,
    EVENT_VIRIDIAN_GYM_BLUE = 1910,
    EVENT_OPENED_MT_SILVER = 1871,
    EVENT_RED_IN_MT_SILVER = 1890,
    EVENT_GOT_RAINBOW_WING = 120,
    EVENT_GOT_SILVER_WING = 121,
    EVENT_FOUGHT_HO_OH = 791,
    EVENT_FOUGHT_LUGIA = 792,
    EVENT_GOT_MASTER_BALL_FROM_ELM = 124,
    EVENT_GOT_TYROGUE_FROM_KIYO = 97,
    EVENT_GOT_BLACKGLASSES_IN_DARK_CAVE = 114,
    EVENT_MET_COPYCAT_FOUND_OUT_ABOUT_LOST_ITEM = 207,
    EVENT_RETURNED_LOST_ITEM_TO_COPYCAT = 208,
    EVENT_GOT_PASS_FROM_COPYCAT = 209,
    EVENT_GOT_LOST_ITEM_FROM_FAN_CLUB = 210,
    EVENT_MADE_UNOWN_APPEAR_IN_RUINS = 46,
    EVENT_SOLVED_HO_OH_PUZZLE = 672,
    EVENT_SOLVED_KABUTO_PUZZLE = 673,
    EVENT_SOLVED_OMANYTE_PUZZLE = 674,
    EVENT_SOLVED_AERODACTYL_PUZZLE = 675,
  }

  -- Every Gold EVENT_* bit has cartridge-specific semantics.  Most story
  -- events are monotonic completion flags, but object_event flags use the
  -- opposite visibility convention: SET hides the object.  Several of those
  -- bits are already SET by InitializeEventsScript on New Game and some are
  -- toggled clear->set again during a quest.  Never infer completion from a
  -- raw event bit without consulting this registry.
  local GOLD_EVENT_SEMANTICS = {}
  for name in pairs(GOLD_EVENT_IDS) do
    local class, rawTrue = "story_completion", "story milestone completed"
    if name:match("^EVENT_BEAT_") then
      class, rawTrue = "battle_completion", "the named battle has been won"
    elseif name:match("^EVENT_GOT_") then
      class, rawTrue = "reward_completion", "the named one-time reward/item has been obtained"
    elseif name:match("^EVENT_CLEARED_") then
      class, rawTrue = "story_completion", "the named story area/incident has been cleared"
    elseif name:match("^EVENT_FOUGHT_") then
      class, rawTrue = "encounter_completion", "the named one-time encounter has been completed"
    elseif name:match("^EVENT_SOLVED_") then
      class, rawTrue = "puzzle_completion", "the named puzzle has been solved"
    elseif name:match("^EVENT_MET_") then
      class, rawTrue = "conversation_completion", "the named story conversation/meeting has occurred"
    elseif name:match("^EVENT_LEARNED_") then
      class, rawTrue = "knowledge_completion", "the named password/story knowledge has been learned"
    end
    GOLD_EVENT_SEMANTICS[name] = {
      class = class, fresh = false, rawCompletion = true, rawTrue = rawTrue,
      source = "pret/pokegold EVENT_* lifecycle; monotonic unless explicitly overridden below",
    }
  end
  local function goldEventSemantic(name, class, fresh, rawCompletion, rawTrue, source)
    GOLD_EVENT_SEMANTICS[name] = {
      class = class, fresh = fresh == true, rawCompletion = rawCompletion == true,
      rawTrue = rawTrue, source = source,
    }
  end

  -- Object-backed events can still be completion-safe when they start CLEAR
  -- and are only SET by the one-time disappear/pickup script.  Record those
  -- explicitly so the catalogue does not conflate them with fresh hide masks.
  goldEventSemantic("EVENT_LAKE_OF_RAGE_RED_GYARADOS", "object_hide_completion", false, true,
    "the Red Gyarados encounter is complete and its overworld object is hidden", "RedGyarados disappear; clear at InitializeEventsScript")
  goldEventSemantic("EVENT_FOUGHT_SNORLAX", "object_hide_completion", false, true,
    "the Vermilion Snorlax encounter is complete and the roadblock is gone", "Vermilion Snorlax one-time encounter")
  goldEventSemantic("EVENT_GOT_HM07_WATERFALL", "item_ball_completion", false, true,
    "the Ice Path HM07 item ball has been collected", "Ice Path HM07 item ball event")
  goldEventSemantic("EVENT_FAST_SHIP_FIRST_TIME", "voyage_completion", false, true,
    "the maiden S.S. Aqua crossing has been completed", "VermilionPortLeaveShipScript")
  goldEventSemantic("EVENT_FAST_SHIP_FOUND_GIRL", "voyage_progress", false, true,
    "the maiden-voyage granddaughter search has been completed", "S.S. Aqua granddaughter/docking script")
  goldEventSemantic("EVENT_FAST_SHIP_LAZY_SAILOR", "voyage_progress", false, true,
    "the lazy sailor has returned to duty", "FastShipLazySailorScript")
  goldEventSemantic("EVENT_FAST_SHIP_INFORMED_ABOUT_LAZY_SAILOR", "voyage_progress", false, true,
    "the on-duty sailor has asked the player to find his buddy", "FastShipB1FSailorScript")
  goldEventSemantic("EVENT_OPENED_MT_SILVER", "access_unlock", false, true,
    "Professor Oak has opened the Mt. Silver route", "OaksLab 16-badge conversation")

  -- New Game object masks / cyclic visibility flags audited against current
  -- pokegold scripts and upstream Gold asm-walk documentation.
  goldEventSemantic("EVENT_ELMS_AIDE_IN_VIOLET_POKEMON_CENTER", "object_hide_gate", true, false,
    "Elm's aide is hidden", "InitializeEventsScript; Elm's assistant call clears it")
  goldEventSemantic("EVENT_AZALEA_TOWN_SLOWPOKETAIL_ROCKET", "object_hide_progress", false, true,
    "the Slowpoke Well guard is hidden after Kurt leaves", "Kurt's first-visit script")
  goldEventSemantic("EVENT_RIVAL_VICTORY_ROAD", "object_hide_cycle", true, false,
    "the Victory Road rival object is hidden", "InitializeEventsScript; appear/disappear during the exit ambush")
  goldEventSemantic("EVENT_FAST_SHIP_HAS_ARRIVED", "transient_voyage", false, false,
    "the current S.S. Aqua voyage has arrived", "cleared on boarding; set again on arrival")
  goldEventSemantic("EVENT_FAST_SHIP_CABINS_SE_SSE_CAPTAINS_CABIN_TWIN_2", "object_hide_progress", false, true,
    "the granddaughter's captain-cabin object has disappeared", "SSAquaGranddaughterBefore")
  goldEventSemantic("EVENT_FOUND_MACHINE_PART_IN_CERULEAN_GYM", "availability_cycle", true, false,
    "the hidden Machine Part is inactive/consumed", "InitializeEventsScript; Manager clears it; pickup sets it")
  goldEventSemantic("EVENT_ROUTE_24_ROCKET", "object_hide_cycle", true, false,
    "the Route 24 Rocket object is hidden", "InitializeEventsScript; Cerulean scene clears it; defeat/disappear sets it")
  goldEventSemantic("EVENT_ROUTE_25_MISTY_BOYFRIEND", "object_hide_cycle", true, false,
    "Misty/date actors are hidden", "InitializeEventsScript; Cerulean scene clears them; date cutscene hides them")
  goldEventSemantic("EVENT_TRAINERS_IN_CERULEAN_GYM", "object_hide_gate", true, false,
    "Misty and Cerulean Gym trainers are hidden", "InitializeEventsScript; Route 25 date clears it")
  goldEventSemantic("EVENT_BLUE_IN_CINNABAR", "object_hide_completion", false, true,
    "Blue has left Cinnabar after his speech", "CinnabarIslandBlue disappear")
  goldEventSemantic("EVENT_VIRIDIAN_GYM_BLUE", "object_hide_gate", true, false,
    "Blue and the Viridian Gym guide are hidden", "InitializeEventsScript; Cinnabar Blue speech clears it")
  goldEventSemantic("EVENT_RED_IN_MT_SILVER", "object_hide_cycle", true, false,
    "Red is hidden", "InitializeEventsScript; Hall of Fame clears it; Red defeat/disappear sets it")

  local GOLD_RED_EVER_KEY = "gold_red_ever_defeated"

  local GOLD_ENGINE_IDS = {
    ENGINE_RADIO_CARD = 0,
    ENGINE_MAP_CARD = 1,
    ENGINE_PHONE_CARD = 2,
    ENGINE_EXPN_CARD = 3,
    ENGINE_POKEGEAR = 4,
    ENGINE_POKEDEX = 11,
    ENGINE_UNOWN_DEX = 12,
    ENGINE_ROCKETS_IN_RADIO_TOWER = 18,
    ENGINE_REACHED_GOLDENROD = 21,
    ENGINE_ROCKETS_IN_MAHOGANY = 22,
    ENGINE_ZEPHYRBADGE = 26,
    ENGINE_HIVEBADGE = 27,
    ENGINE_PLAINBADGE = 28,
    ENGINE_FOGBADGE = 29,
    ENGINE_MINERALBADGE = 30,
    ENGINE_STORMBADGE = 31,
    ENGINE_GLACIERBADGE = 32,
    ENGINE_RISINGBADGE = 33,
    ENGINE_BOULDERBADGE = 34,
    ENGINE_CASCADEBADGE = 35,
    ENGINE_THUNDERBADGE = 36,
    ENGINE_RAINBOWBADGE = 37,
    ENGINE_SOULBADGE = 38,
    ENGINE_MARSHBADGE = 39,
    ENGINE_VOLCANOBADGE = 40,
    ENGINE_EARTHBADGE = 41,
    ENGINE_UNLOCKED_UNOWNS_A_TO_K = 42,
    ENGINE_UNLOCKED_UNOWNS_L_TO_R = 43,
    ENGINE_UNLOCKED_UNOWNS_S_TO_W = 44,
    ENGINE_UNLOCKED_UNOWNS_X_TO_Z = 45,
    ENGINE_UNION_CAVE_LAPRAS = 88,
  }

  local GOLD_JOHTO_BADGES = {
    "ZEPHYR", "HIVE", "PLAIN", "FOG", "MINERAL", "STORM", "GLACIER", "RISING",
  }
  local GOLD_KANTO_BADGES = {
    "BOULDER", "CASCADE", "THUNDER", "RAINBOW", "SOUL", "MARSH", "VOLCANO", "EARTH",
  }
  local GOLD_BADGE_ENGINE = {
    ENGINE_ZEPHYRBADGE = { region = "johto", name = "ZEPHYR", index = 1 },
    ENGINE_HIVEBADGE = { region = "johto", name = "HIVE", index = 2 },
    ENGINE_PLAINBADGE = { region = "johto", name = "PLAIN", index = 3 },
    ENGINE_FOGBADGE = { region = "johto", name = "FOG", index = 4 },
    ENGINE_MINERALBADGE = { region = "johto", name = "MINERAL", index = 5 },
    ENGINE_STORMBADGE = { region = "johto", name = "STORM", index = 6 },
    ENGINE_GLACIERBADGE = { region = "johto", name = "GLACIER", index = 7 },
    ENGINE_RISINGBADGE = { region = "johto", name = "RISING", index = 8 },
    ENGINE_BOULDERBADGE = { region = "kanto", name = "BOULDER", index = 1 },
    ENGINE_CASCADEBADGE = { region = "kanto", name = "CASCADE", index = 2 },
    ENGINE_THUNDERBADGE = { region = "kanto", name = "THUNDER", index = 3 },
    ENGINE_RAINBOWBADGE = { region = "kanto", name = "RAINBOW", index = 4 },
    ENGINE_SOULBADGE = { region = "kanto", name = "SOUL", index = 5 },
    ENGINE_MARSHBADGE = { region = "kanto", name = "MARSH", index = 6 },
    ENGINE_VOLCANOBADGE = { region = "kanto", name = "VOLCANO", index = 7 },
    ENGINE_EARTHBADGE = { region = "kanto", name = "EARTH", index = 8 },
  }

  -- Gold inventory is a flat numeric item-id -> count map.  Keep the
  -- symbolic names in resolver code and translate them in one audited table
  -- rather than scattering cartridge item numbers through objectives.
  local GOLD_ITEM_IDS = {
    SECRETPOTION = 0x43,
    S_S_TICKET = 0x44,
    CARD_KEY = 0x7f,
    MACHINE_PART = 0x80,
    BASEMENT_KEY = 0x85,
    PASS = 0x86,
    METAL_COAT = 0x8f,
    RAINBOW_WING = 0xb2,
  }

  local GOLD_MOVE_IDS = {
    CUT = 15, FLY = 19, SURF = 57, STRENGTH = 70,
    WATERFALL = 127, FLASH = 148, WHIRLPOOL = 250,
  }

  local function generationFromSave(save)
    if type(save) ~= "table" then return nil end
    if tonumber(save.generation) == 2 then return 2 end
    if type(save.version) == "string" and save.version:lower() == "gold" then
      return 2
    end
    if tonumber(save.generation) == 1 then return 1 end
    return nil
  end

  -- The live Game object is the authority for generation selection.  Save
  -- metadata is deliberately only a fallback: old/imported/in-progress Gold
  -- saves can temporarily lack version/generation, and defaulting such a live
  -- Gen 2 session to Gen 1 is exactly how guides from the two games leaked
  -- into each other.
  --
  -- Gen 1 exposes `overworld`; Game2 exposes its class methods (`startWorld`,
  -- `currentLandmark`) even before `world` is created.  The gen2 data markers
  -- are a final runtime capability check after Game2's generated data load.
  local function generationFromGame(game)
    if type(game) ~= "table" then return nil end

    if game.overworld ~= nil then return 1 end
    if type(game.startWorld) == "function"
        or type(game.currentLandmark) == "function"
        or game.world ~= nil then
      return 2
    end

    local data = game.data
    if type(data) == "table"
        and (data.gen2Text ~= nil
          or data.gen2InitialEvents ~= nil
          or data.gen2EventTables ~= nil) then
      return 2
    end

    return generationFromSave(game.save)
  end

  local function generationForContext(save, game)
    return generationFromGame(game) or generationFromSave(save) or 1
  end

  local function goldSerializedEvent(save, id)
    if type(save) ~= "table" or type(save.events) ~= "table" or type(id) ~= "number" then
      return false
    end
    local byteIndex = math.floor(id / 8)
    local bitIndex = id % 8
    local byte = tonumber(save.events[byteIndex] or save.events[tostring(byteIndex)]) or 0
    return math.floor(byte / (2 ^ bitIndex)) % 2 == 1
  end

  local function goldLiveEvent(id, save, game)
    -- A live World event bit may be newer than the last serialized save.events.
    -- Use the public WorldAPI only for the live save; pure snapshots stay pure.
    local sameLiveSave = game and liveGame and game == liveGame and game.save == save
    if sameLiveSave and mod.world and type(mod.world.getFlag) == "function" then
      local ok, value = pcall(function() return mod.world:getFlag(id) end)
      if ok and type(value) == "boolean" then return value end
    end
    return goldSerializedEvent(save, id)
  end

  local function goldEvent(save, game, name)
    local id = GOLD_EVENT_IDS[name]
    if not id then return false end
    return goldLiveEvent(id, save, game)
  end

  local function goldBadgeOwned(save, region, name, index)
    local player = type(save) == "table" and save.player or nil
    player = type(player) == "table" and player or {}
    local store = region == "kanto" and player.kantoBadges or player.badges
    if type(store) ~= "table" then return false end
    if store[name] == true or store[name:lower()] == true then return true end
    if store[index] == true then return true end
    return false
  end

  local function goldEngine(save, name)
    local badge = GOLD_BADGE_ENGINE[name]
    if badge then return goldBadgeOwned(save, badge.region, badge.name, badge.index) end
    local id = GOLD_ENGINE_IDS[name]
    if not id or type(save) ~= "table" then return false end
    local flags = save.engineFlags
    if type(flags) == "table" then
      return flags[id] == true or flags[tostring(id)] == true
    end
    return false
  end

  local function goldItemCount(store, itemId)
    if type(store) ~= "table" then return 0 end
    local numericId = type(itemId) == "string" and GOLD_ITEM_IDS[itemId] or itemId
    local function directCount(key)
      if key == nil then return 0 end
      local direct = store[key]
      if direct == true then return 1 end
      if tonumber(direct) then return math.max(0, tonumber(direct)) end
      return 0
    end
    local direct = math.max(directCount(itemId), directCount(numericId))
    if direct > 0 then return direct end
    -- Tolerate imported/modded snapshots that serialize pockets as rows rather
    -- than the engine's normal flat numeric id->count table.  This is read-only
    -- and does not force Gold into a Gen 1 bag shape.
    for _, row in ipairs(store) do
      if row == itemId or row == numericId then return 1 end
      if type(row) == "table" then
        local id = row.id or row.item
        if id == itemId or id == numericId then
          return math.max(1, tonumber(row.count or row.qty or row.quantity) or 1)
        end
      end
    end
    return 0
  end

  local function goldHasItem(save, itemId)
    if type(save) ~= "table" then return false end
    return goldItemCount(save.inventory, itemId) > 0
      or goldItemCount(save.pcItems, itemId) > 0
  end

  local function goldPartyKnows(save, moveName)
    local wanted = GOLD_MOVE_IDS[moveName]
    local party = type(save) == "table" and type(save.party) == "table" and save.party or {}
    for _, mon in ipairs(party) do
      if type(mon) == "table" and not mon.egg and not mon.isEgg then
        for _, move in ipairs(type(mon.moves) == "table" and mon.moves or {}) do
          local id = type(move) == "table" and move.id or move
          local name = type(move) == "table" and (move.name or move.key) or nil
          if id == wanted or id == moveName or name == moveName then return true end
        end
      end
    end
    return false
  end

  local function goldLocation(save, game)
    local position = type(save) == "table" and save.position or nil
    local out = {
      map = type(position) == "table" and (position.mapId or position.map) or "UNKNOWN",
      x = type(position) == "table" and position.x or nil,
      y = type(position) == "table" and position.y or nil,
      facing = type(position) == "table" and position.facing or nil,
    }
    local sameLiveSave = game and liveGame and game == liveGame and game.save == save
    if sameLiveSave and mod.world and type(mod.world.current) == "function" then
      local ok, current = pcall(function() return mod.world:current() end)
      if ok and type(current) == "table" then
        out.map = current.mapId or out.map
        out.x = current.x
        out.y = current.y
        out.facing = current.facing
      end
    end
    return out
  end

  local function goldSavedMapScene(save, mapId)
    if type(save) ~= "table" or type(save.mapScenes) ~= "table" then return nil end
    local value = save.mapScenes[mapId] or save.mapScenes[tostring(mapId)]
    return tonumber(value)
  end

  local function countTrue(t)
    local n = 0
    for _, v in pairs(t or {}) do if v == true then n = n + 1 end end
    return n
  end

  local function normalizeGold(save, game)
    save = type(save) == "table" and save or {}
    local s = {
      generation = 2,
      version = "gold",
      raw = save,
      location = goldLocation(save, game),
      badges = { johto = {}, kanto = {} },
      items = { inventory = save.inventory or {}, pc = save.pcItems or {} },
      hms = {}, moves = {}, abilities = {},
      hmAnywhere = { detected = hmAnywhereActive(), effective = false },
      story = {}, optional = {}, access = {},
    }

    for i, name in ipairs(GOLD_JOHTO_BADGES) do
      s.badges.johto[name:lower()] = goldBadgeOwned(save, "johto", name, i)
    end
    for i, name in ipairs(GOLD_KANTO_BADGES) do
      s.badges.kanto[name:lower()] = goldBadgeOwned(save, "kanto", name, i)
    end
    s.badges.johtoCount = countTrue(s.badges.johto)
    s.badges.kantoCount = countTrue(s.badges.kanto)
    s.badges.totalCount = s.badges.johtoCount + s.badges.kantoCount

    local hmEvents = {
      cut = "EVENT_GOT_HM01_CUT", fly = "EVENT_GOT_HM02_FLY",
      surf = "EVENT_GOT_HM03_SURF", strength = "EVENT_GOT_HM04_STRENGTH",
      flash = "EVENT_GOT_HM05_FLASH", whirlpool = "EVENT_GOT_HM06_WHIRLPOOL",
      waterfall = "EVENT_GOT_HM07_WATERFALL",
    }
    local hmItems = {
      cut = "HM_CUT", fly = "HM_FLY", surf = "HM_SURF",
      strength = "HM_STRENGTH", flash = "HM_FLASH",
      whirlpool = "HM_WHIRLPOOL", waterfall = "HM_WATERFALL",
    }
    for key, ev in pairs(hmEvents) do
      -- The story event is the strongest historical proof.  Bag/PC ownership
      -- is an additive fallback for imported/modded saves whose historical
      -- event bytes were stripped while the actual HM item survived.
      s.hms[key] = goldEvent(save, game, ev) or goldHasItem(save, hmItems[key])
    end
    for key, moveName in pairs({
      cut = "CUT", fly = "FLY", surf = "SURF", strength = "STRENGTH",
      flash = "FLASH", whirlpool = "WHIRLPOOL", waterfall = "WATERFALL",
    }) do s.moves[key] = goldPartyKnows(save, moveName) end

    -- Current HM Anywhere Gold semantics are deliberately NOT guessed.  Until
    -- a Gold-capable export/capability is verified, actual party moves remain
    -- the only alternate source of field usability.
    s.abilities.flash = s.badges.johto.zephyr and s.moves.flash
    s.abilities.cut = s.badges.johto.hive and s.moves.cut
    s.abilities.strength = s.badges.johto.plain and s.moves.strength
    s.abilities.surf = s.badges.johto.fog and s.moves.surf
    s.abilities.fly = s.badges.johto.storm and s.moves.fly
    s.abilities.whirlpool = s.badges.johto.glacier and s.moves.whirlpool
    s.abilities.waterfall = s.badges.johto.rising and s.moves.waterfall

    local st = s.story
    local function ev(name) return goldEvent(save, game, name) end
    -- Preserve raw bits for diagnostics/catalogue purposes, but derive story
    -- meaning explicitly below.  This prevents New Game hide masks from being
    -- mistaken for completed story milestones.
    s.rawEvents = {}
    for name in pairs(GOLD_EVENT_IDS) do s.rawEvents[name] = ev(name) end
    st.gotStarter = ev("EVENT_GOT_A_POKEMON_FROM_ELM")
    st.gotMysteryEgg = ev("EVENT_GOT_MYSTERY_EGG_FROM_MR_POKEMON")
    st.gaveMysteryEgg = ev("EVENT_GAVE_MYSTERY_EGG_TO_ELM")
    st.gotPokedex = goldEngine(save, "ENGINE_POKEDEX")
    st.gotTogepiEgg = ev("EVENT_GOT_TOGEPI_EGG_FROM_ELMS_AIDE")
    st.elmsAideHidden = ev("EVENT_ELMS_AIDE_IN_VIOLET_POKEMON_CENTER")
    st.kurtOpenedWell = ev("EVENT_AZALEA_TOWN_SLOWPOKETAIL_ROCKET")
    st.clearedSlowpokeWell = ev("EVENT_CLEARED_SLOWPOKE_WELL")
    st.herdedFarfetchd = ev("EVENT_HERDED_FARFETCHD")
    st.foughtSudowoodo = ev("EVENT_FOUGHT_SUDOWOODO")
    st.releasedBeasts = ev("EVENT_RELEASED_THE_BEASTS")
    st.jasmineExplained = ev("EVENT_JASMINE_EXPLAINED_AMPHYS_SICKNESS")
    st.gotSecretPotion = ev("EVENT_GOT_SECRETPOTION_FROM_PHARMACY")
    st.jasmineReturned = ev("EVENT_JASMINE_RETURNED_TO_GYM")
    st.foughtRedGyarados = ev("EVENT_LAKE_OF_RAGE_RED_GYARADOS")
    st.helpingLance = ev("EVENT_DECIDED_TO_HELP_LANCE")
    st.rocketStaircase = ev("EVENT_UNCOVERED_STAIRCASE_IN_MAHOGANY_MART")
    st.rocketPasswordSlowpoketail = ev("EVENT_LEARNED_SLOWPOKETAIL")
    st.rocketPasswordRaticateTail = ev("EVENT_LEARNED_RATICATE_TAIL")
    st.rocketPasswordHailGiovanni = ev("EVENT_LEARNED_HAIL_GIOVANNI")
    st.clearedRocketHideout = ev("EVENT_CLEARED_ROCKET_HIDEOUT")
    st.rocketsInRadioTower = goldEngine(save, "ENGINE_ROCKETS_IN_RADIO_TOWER")
    st.clearedRadioTower = ev("EVENT_CLEARED_RADIO_TOWER")
    st.beatClair = ev("EVENT_BEAT_CLAIR")
    st.beatEliteFour = ev("EVENT_BEAT_ELITE_FOUR")
      or (type(save.hallOfFame) == "table" and (tonumber(save.hallOfFame.count) or 0) > 0)
    st.victoryRoadRivalHidden = ev("EVENT_RIVAL_VICTORY_ROAD")
    local vrScene = goldSavedMapScene(save, "VICTORY_ROAD")
    local vrMap = tostring(s.location.map or "")
    local vrDownstream = vrMap == "ROUTE_23" or vrMap:find("INDIGO", 1, true) ~= nil
      or st.beatEliteFour
    -- Scene 1 is the durable NOOP scene after the unavoidable exit ambush.
    -- The raw rival event is NOT proof: it is already set on New Game.
    st.victoryRoadRival = vrScene == 1 or vrDownstream
    st.gotSsTicket = ev("EVENT_GOT_SS_TICKET_FROM_ELM")
    st.fastShipFirstTime = ev("EVENT_FAST_SHIP_FIRST_TIME")
    st.fastShipArrived = ev("EVENT_FAST_SHIP_HAS_ARRIVED")
    st.fastShipFoundGirl = ev("EVENT_FAST_SHIP_FOUND_GIRL")
    st.fastShipInformedLazySailor = ev("EVENT_FAST_SHIP_INFORMED_ABOUT_LAZY_SAILOR")
    st.fastShipLazySailor = ev("EVENT_FAST_SHIP_LAZY_SAILOR")
      or ev("EVENT_BEAT_SAILOR_STANLY")
    st.fastShipGirlMoved = ev("EVENT_FAST_SHIP_CABINS_SE_SSE_CAPTAINS_CABIN_TWIN_2")
    st.hasBasementKey = goldHasItem(save, "BASEMENT_KEY")
    st.hasCardKey = goldHasItem(save, "CARD_KEY")
    st.metPowerPlantManager = ev("EVENT_MET_MANAGER_AT_POWER_PLANT")
    st.metCeruleanRocket = ev("EVENT_MET_ROCKET_GRUNT_AT_CERULEAN_GYM")
    st.machinePartHidden = ev("EVENT_FOUND_MACHINE_PART_IN_CERULEAN_GYM")
    st.route24RocketHidden = ev("EVENT_ROUTE_24_ROCKET")
    st.mistyActorsHidden = ev("EVENT_ROUTE_25_MISTY_BOYFRIEND")
    st.ceruleanGymTrainersHidden = ev("EVENT_TRAINERS_IN_CERULEAN_GYM")
    st.returnedMachinePart = ev("EVENT_RETURNED_MACHINE_PART")
    st.restoredPower = ev("EVENT_RESTORED_POWER_TO_KANTO")
    st.hasMachinePart = goldHasItem(save, "MACHINE_PART")
    -- The Machine Part flag is SET on New Game, CLEARED by the Manager, then
    -- SET again by the actual pickup.  Manager proof is therefore required
    -- before a re-set raw bit can mean "found".
    st.foundMachinePart = st.hasMachinePart or st.returnedMachinePart or st.restoredPower
      or (st.metPowerPlantManager and st.metCeruleanRocket and st.machinePartHidden)
    -- Route 24 Rocket follows the same hide-cycle: it starts hidden, appears
    -- after the Cerulean Gym escape scene, and is hidden again after defeat.
    st.route24RocketDefeated = st.metCeruleanRocket and st.route24RocketHidden
    -- The Route 25 date is complete only once that scene has repopulated the
    -- Cerulean Gym.  The boyfriend/Misty object flag alone starts SET and is
    -- therefore unusable as completion evidence.
    st.mistyDateComplete = st.metCeruleanRocket and not st.ceruleanGymTrainersHidden
    st.mistyDateTriggered = st.mistyDateComplete -- backwards-compatible semantic alias
    st.hasExpnCard = goldEngine(save, "ENGINE_EXPN_CARD")
    st.foughtSnorlax = ev("EVENT_FOUGHT_SNORLAX")
    st.beatRivalMtMoon = ev("EVENT_BEAT_RIVAL_IN_MT_MOON")
    st.talkedOakKanto = ev("EVENT_TALKED_TO_OAK_IN_KANTO")
    st.talkedBlueCinnabar = ev("EVENT_BLUE_IN_CINNABAR")
    st.openedMtSilver = ev("EVENT_OPENED_MT_SILVER")
    st.redHidden = ev("EVENT_RED_IN_MT_SILVER")
    local hofCount = type(save.hallOfFame) == "table" and (tonumber(save.hallOfFame.count) or 0) or 0
    local redLifecycleProof = st.openedMtSilver and st.beatEliteFour and hofCount > 0 and st.redHidden
    local persistedRed = type(save.modData) == "table"
      and type(save.modData.help_story_guide) == "table"
      and save.modData.help_story_guide[GOLD_RED_EVER_KEY] == true
    st.redDefeated = persistedRed or redLifecycleProof
    -- Persist the semantic proof only for the actual live save.  Pure snapshot
    -- normalization stays read-only and deterministic.
    local sameLiveSave = game and liveGame and game == liveGame and game.save == save
    if sameLiveSave and redLifecycleProof then pcall(function() mod.save:set(GOLD_RED_EVER_KEY, true) end) end
    st.gotRainbowWing = ev("EVENT_GOT_RAINBOW_WING")
    st.gotSilverWing = ev("EVENT_GOT_SILVER_WING")
    st.foughtHoOh = ev("EVENT_FOUGHT_HO_OH")
    st.foughtLugia = ev("EVENT_FOUGHT_LUGIA")
    st.gotMasterBall = ev("EVENT_GOT_MASTER_BALL_FROM_ELM")
    st.gotTyrogue = ev("EVENT_GOT_TYROGUE_FROM_KIYO")
    st.gotBlackglassesDarkCave = ev("EVENT_GOT_BLACKGLASSES_IN_DARK_CAVE")
    st.metCopycatLostItem = ev("EVENT_MET_COPYCAT_FOUND_OUT_ABOUT_LOST_ITEM")
    st.gotLostItem = ev("EVENT_GOT_LOST_ITEM_FROM_FAN_CLUB")
    st.returnedLostItem = ev("EVENT_RETURNED_LOST_ITEM_TO_COPYCAT")
    st.gotMagnetTrainPass = ev("EVENT_GOT_PASS_FROM_COPYCAT")
    st.unionCaveLaprasUsed = goldEngine(save, "ENGINE_UNION_CAVE_LAPRAS")
    st.bugContestActive = type(save.bugContest) == "table"
      and save.bugContest.active == true

    -- Ruins of Alph has native durable state for every sliding-tile puzzle and
    -- for the Research Center's UNOWN DEX upgrade.  Accept either the puzzle's
    -- historical EVENT_* or its downstream ENGINE_UNLOCKED_UNOWNS_* bit so an
    -- imported/modded save that lost event history does not get sent backwards.
    st.ruinsKabutoSolved = ev("EVENT_SOLVED_KABUTO_PUZZLE")
      or goldEngine(save, "ENGINE_UNLOCKED_UNOWNS_A_TO_K")
    st.ruinsOmanyteSolved = ev("EVENT_SOLVED_OMANYTE_PUZZLE")
      or goldEngine(save, "ENGINE_UNLOCKED_UNOWNS_L_TO_R")
    st.ruinsAerodactylSolved = ev("EVENT_SOLVED_AERODACTYL_PUZZLE")
      or goldEngine(save, "ENGINE_UNLOCKED_UNOWNS_S_TO_W")
    st.ruinsHoOhSolved = ev("EVENT_SOLVED_HO_OH_PUZZLE")
      or goldEngine(save, "ENGINE_UNLOCKED_UNOWNS_X_TO_Z")
    st.ruinsMadeUnownAppear = ev("EVENT_MADE_UNOWN_APPEAR_IN_RUINS")
      or st.ruinsKabutoSolved or st.ruinsOmanyteSolved
      or st.ruinsAerodactylSolved or st.ruinsHoOhSolved
    st.unownDexUnlocked = goldEngine(save, "ENGINE_UNOWN_DEX")
    st.unownCount = type(save.unownDex) == "table" and #save.unownDex or 0
    st.ruinsPuzzleCount = 0
    for _, solved in ipairs({
      st.ruinsKabutoSolved, st.ruinsOmanyteSolved,
      st.ruinsAerodactylSolved, st.ruinsHoOhSolved,
    }) do
      if solved then st.ruinsPuzzleCount = st.ruinsPuzzleCount + 1 end
    end
    st.ruinsComplete = st.ruinsPuzzleCount == 4 and st.unownDexUnlocked

    -- Current Gold keeps all three roaming beasts in save.roamers. A retired
    -- slot has neither species nor map. Keep nil when the record is absent so
    -- older/imported saves remain unknown rather than being guessed complete.
    st.roamersRemaining = nil
    if type(save.roamers) == "table" then
      local remaining = 0
      for i = 1, 3 do
        local slot = save.roamers[i]
        if type(slot) == "table" and slot.species ~= nil and slot.map ~= nil then
          remaining = remaining + 1
        end
      end
      st.roamersRemaining = remaining
    end
    s.access.partySpace = #(type(save.party) == "table" and save.party or {}) < 6

    local map = s.location.map or "UNKNOWN"
    local kantoMapTokens = {
      "VERMILION", "SAFFRON", "CELADON", "FUCHSIA", "LAVENDER", "CERULEAN",
      "POWER_PLANT", "ROCK_TUNNEL", "PEWTER", "PALLET", "CINNABAR",
      "SEAFOAM", "VIRIDIAN", "SILVER_CAVE",
    }
    s.access.kantoReached = s.badges.kantoCount > 0 or st.fastShipArrived
    if type(map) == "string" then
      for _, token in ipairs(kantoMapTokens) do
        if map:find(token, 1, true) then s.access.kantoReached = true break end
      end
      -- Route ids must be parsed numerically.  A substring search makes
      -- Johto's ROUTE_29 match Kanto's ROUTE_2 (and ROUTE_30..39 match
      -- ROUTE_3, ROUTE_40..46 match ROUTE_4), which prematurely exposes the
      -- entire Kanto Gym journal during the Johto story.
      local route = tonumber(map:match("^ROUTE_(%d+)"))
      local kantoRoute = route and ((route >= 1 and route <= 22)
        or route == 24 or route == 25 or route == 28)
      if kantoRoute then s.access.kantoReached = true end
    end
    s.access.mtSilver = st.openedMtSilver
    return s
  end

  local function goldMapIs(s, id) return s.location.map == id end
  local function goldMapHas(s, token)
    return type(s.location.map) == "string" and s.location.map:find(token, 1, true) ~= nil
  end
  local function goldMapHasAny(s, tokens)
    for _, token in ipairs(tokens) do if goldMapHas(s, token) then return true end end
    return false
  end

  ---------------------------------------------------------------------------
  -- Gold route trainer metadata
  --
  -- Gen 2's ROM extractor already decodes OBJECTTYPE_TRAINER into
  -- map.objects[*].trainer and exposes the original first-win event id.  That
  -- is a much stronger source than a hand-maintained list: every Johto/Kanto
  -- route uses the same generated cartridge data, scripted story battles stay
  -- excluded because they are OBJECTTYPE_SCRIPT, and phone rematch flags never
  -- replace the first-win event carried by the map object.
  ---------------------------------------------------------------------------

  local function goldRouteMapData(game, mapId)
    local data = game and game.data
    local maps = data and data.gen2Maps
    local map = type(maps) == "table" and maps[mapId] or nil
    if type(map) ~= "table" or type(map.objects) ~= "table" then return nil end
    return map
  end

  local function goldRouteTrainerMeta(game, mapId)
    local map = goldRouteMapData(game, mapId)
    if not map then return nil end
    local trainers = {}
    for _, obj in ipairs(map.objects) do
      local trainer = type(obj) == "table" and obj.trainer or nil
      -- Scripted rivals, Rockets and other story fights do not carry the
      -- extractor's trainer struct on the object and therefore cannot leak
      -- into this generic cleanup total.
      if type(trainer) == "table" and type(trainer.event) == "number" then
        trainers[#trainers + 1] = {
          event = trainer.event,
          class = trainer.class,
          member = trainer.member,
          objectName = obj.name,
        }
      end
    end
    if #trainers == 0 then return nil end
    return { total = #trainers, trainers = trainers }
  end

  local function goldRouteTrainerProgress(save, game, mapId)
    local meta = goldRouteTrainerMeta(game, mapId)
    if not meta then return nil end
    local won = 0
    for _, trainer in ipairs(meta.trainers) do
      if goldLiveEvent(trainer.event, save, game) then won = won + 1 end
    end
    return won, meta.total
  end

  local function goldRouteTrainerAccessible(s, game, mapId)
    if not goldRouteTrainerMeta(game, mapId) then return false end
    -- A live/current route or an actually observed visit is conservative,
    -- sequence-break-safe accessibility evidence.  Do not infer story
    -- completion from this journal.
    return goldMapIs(s, mapId) or routeWasSeen(mapId)
  end

  local function goldRouteTrainerObjective(s, game, mapId)
    if not goldRouteTrainerAccessible(s, game, mapId) then return nil end
    local won, total = goldRouteTrainerProgress(s.raw, game, mapId)
    if won == nil or total == nil or total <= 0 or won >= total then return nil end
    local n = tonumber(mapId:match("^ROUTE_(%d+)$")) or 0
    local summary = ("Trainers defeated: %d/%d."):format(won, total)
    return objective("GOLD_ROUTE_TRAINERS_" .. tostring(n), "ROUTE " .. tostring(n),
      summary, summary, "ROUTE")
  end

  local function goldRadioTowerStep(s)
    local st = s.story
    if st.clearedRadioTower then return nil end

    -- Card Key is downstream proof that the Basement Key/fake-Director half is
    -- obsolete even if an imported/modded save lost the older item.
    if st.hasCardKey then
      if goldMapIs(s, "RADIO_TOWER_3F") then
        return objective("GOLD_RADIO_TOWER_CARD_KEY_DOOR", "RADIO TOWER 3F",
          "Use the CARD KEY on the locked shutter.",
          "Open the 3F Card Key slot and continue into the secured side of the Radio Tower.", "CONTEXT")
      end
      if goldMapIs(s, "RADIO_TOWER_4F") then
        return objective("GOLD_RADIO_TOWER_EXECUTIVES", "RADIO TOWER 4F",
          "Defeat the remaining Rocket Executives and continue upstairs.",
          "You already have the Card Key. Clear the secured 4F battles and keep climbing.", "CONTEXT")
      end
      if goldMapIs(s, "RADIO_TOWER_5F") then
        return objective("GOLD_RADIO_TOWER_FINAL_EXECUTIVES", "RADIO TOWER 5F",
          "Defeat the final Rocket Executive and clear the takeover.",
          "Finish the last secured-floor battle. The Radio Tower clear event is the completion proof.", "CONTEXT")
      end
      if goldMapHas(s, "RADIO_TOWER") then
        return objective("GOLD_RADIO_TOWER_CARD_KEY_RETURN", "RADIO TOWER 3F",
          "Return to 3F and use the CARD KEY.",
          "The Director gave you the Card Key. Use it on the locked 3F shutter to reach the remaining Rockets.", "CONTEXT")
      end
      return objective("GOLD_RADIO_TOWER_CARD_KEY_RETURN", "GOLDENROD RADIO TOWER",
        "Return to the Radio Tower and use the CARD KEY on 3F.",
        "The Underground rescue is complete; the Card Key opens the secured side of Radio Tower 3F.")
    end

    if st.hasBasementKey then
      if goldMapIs(s, "GOLDENROD_UNDERGROUND_WAREHOUSE") then
        return objective("GOLD_RADIO_TOWER_DIRECTOR", "UNDERGROUND WAREHOUSE",
          "Rescue the real Director and receive the CARD KEY.",
          "Reach the Director in the warehouse. His Card Key is the next load-bearing progression item.", "CONTEXT")
      end
      if goldMapHas(s, "GOLDENROD_UNDERGROUND_SWITCH_ROOM") then
        return objective("GOLD_RADIO_TOWER_SWITCH_ROOM", "UNDERGROUND SWITCH ROOM",
          "Push through the switch room and reach the Underground Warehouse.",
          "Defeat the local Rockets, handle the shutters, and continue to the warehouse where the Director is held.", "CONTEXT")
      end
      if goldMapIs(s, "GOLDENROD_UNDERGROUND") then
        return objective("GOLD_RADIO_TOWER_BASEMENT_DOOR", "GOLDENROD UNDERGROUND",
          "Use the BASEMENT KEY on the locked basement door.",
          "Open the locked Underground door and enter the switch-room section.", "CONTEXT")
      end
      if goldMapHas(s, "RADIO_TOWER") then
        return objective("GOLD_RADIO_TOWER_UNDERGROUND", "GOLDENROD UNDERGROUND",
          "Take the BASEMENT KEY to the Goldenrod Underground.",
          "Leave the Radio Tower and use the Basement Key at the locked Underground door.", "CONTEXT")
      end
      return objective("GOLD_RADIO_TOWER_UNDERGROUND", "GOLDENROD UNDERGROUND",
        "Use the BASEMENT KEY in the Goldenrod Underground.",
        "The fake Director has been handled. Open the locked Underground door and continue the rescue.")
    end

    if goldMapIs(s, "RADIO_TOWER_5F") then
      return objective("GOLD_RADIO_TOWER_FAKE_DIRECTOR", "RADIO TOWER 5F",
        "Defeat the fake Director and take the BASEMENT KEY.",
        "This is the current takeover step; the key reveals where to go next.", "CONTEXT")
    end
    if goldMapHas(s, "RADIO_TOWER") then
      return objective("GOLD_RADIO_TOWER_CLIMB", "GOLDENROD RADIO TOWER",
        "Climb the occupied Radio Tower toward the Director's office.",
        "Defeat the Rockets blocking the upper floors. HELP will update when you reach the fake Director.", "CONTEXT")
    end
    return objective("GOLD_RADIO_TOWER_CLIMB", "GOLDENROD RADIO TOWER",
      "Enter the occupied Radio Tower and climb toward the Director.",
      "The Rocket takeover is active. Start at the Radio Tower; HELP will reveal only the current local step.")
  end

  local function goldFastShipStep(s)
    local st = s.story
    if not goldMapHas(s, "FAST_SHIP") or st.fastShipFirstTime then return nil end
    if st.fastShipArrived then
      return objective("GOLD_FAST_SHIP_DISEMBARK", "S.S. AQUA",
        "The S.S. Aqua has arrived. Disembark in Vermilion City.",
        "Use the exit sailor on 1F and leave through Vermilion Port.", "CONTEXT")
    end
    if not st.fastShipInformedLazySailor then
      return objective("GOLD_FAST_SHIP_ON_DUTY_SAILOR", "S.S. AQUA B1F",
        "Speak with the on-duty sailor blocking the lower deck.",
        "He will tell you about the missing crew member and reveal the next required ship step.", "CONTEXT")
    end
    if not st.fastShipLazySailor then
      return objective("GOLD_FAST_SHIP_LAZY_SAILOR", "S.S. AQUA CABINS",
        "Find the lazy sailor Stanly and defeat him.",
        "He is in the northern cabins. Finishing his scripted battle removes the B1F blocker.", "CONTEXT")
    end
    if not st.fastShipGirlMoved then
      return objective("GOLD_FAST_SHIP_FIND_GIRL", "CAPTAIN'S CABIN",
        "Find the missing girl in the Captain's cabin.",
        "With B1F unblocked, reach the Captain's cabin and speak with the granddaughter there.", "CONTEXT")
    end
    return objective("GOLD_FAST_SHIP_RETURN_GRANDDAUGHTER", "S.S. AQUA CABINS",
      "Return with the granddaughter to her grandfather.",
      "Complete the reunion in the grandfather's cabin; that sequence finishes the maiden-voyage quest and docks the ship.", "CONTEXT")
  end

  local function goldRuinsContext(s)
    if not goldMapHas(s, "RUINS_OF_ALPH") then return nil end
    local st = s.story

    local chambers = {
      RUINS_OF_ALPH_KABUTO_CHAMBER = {
        solved = st.ruinsKabutoSolved, id = "KABUTO", name = "Kabuto",
      },
      RUINS_OF_ALPH_OMANYTE_CHAMBER = {
        solved = st.ruinsOmanyteSolved, id = "OMANYTE", name = "Omanyte",
      },
      RUINS_OF_ALPH_AERODACTYL_CHAMBER = {
        solved = st.ruinsAerodactylSolved, id = "AERODACTYL", name = "Aerodactyl",
      },
      RUINS_OF_ALPH_HO_OH_CHAMBER = {
        solved = st.ruinsHoOhSolved, id = "HO_OH", name = "Ho-Oh",
      },
    }
    local chamber = chambers[s.location.map]
    if chamber then
      if not chamber.solved then
        return objective("GOLD_RUINS_PUZZLE_" .. chamber.id, "RUINS OF ALPH",
          "Solve the " .. chamber.name .. " sliding-tile puzzle.",
          "Use the puzzle panel on the chamber wall. Solving it permanently opens this chamber and unlocks another group of Unown forms.", "CONTEXT")
      end
      return objective("GOLD_RUINS_PUZZLE_DONE_" .. chamber.id, "RUINS OF ALPH",
        "This chamber's " .. chamber.name .. " puzzle is already solved.",
        "The floor openings now lead back into the Inner Chamber. Continue exploring only if you want to work on the optional Ruins content.", "CONTEXT")
    end

    if goldMapIs(s, "RUINS_OF_ALPH_INNER_CHAMBER") then
      if st.ruinsMadeUnownAppear and not st.unownDexUnlocked and st.unownCount < 3 then
        return objective("GOLD_RUINS_CATCH_UNOWN", "RUINS OF ALPH",
          ("Catch different Unown forms for the researchers (%d/3)."):format(st.unownCount),
          "After at least three different forms are recorded, a researcher outside can guide you to the Research Center for the UNOWN DEX upgrade.", "CONTEXT")
      end
      if st.ruinsMadeUnownAppear and not st.unownDexUnlocked and st.unownCount >= 3 then
        return objective("GOLD_RUINS_GET_UNOWN_DEX", "RUINS OF ALPH",
          "You have enough different Unown. Return outside to meet the researcher.",
          "The researcher appears after at least three different Unown forms are recorded and will lead you to the Research Center for the UNOWN DEX upgrade.", "CONTEXT")
      end
      if st.ruinsComplete then
        return objective("GOLD_RUINS_COMPLETE_CONTEXT", "RUINS OF ALPH",
          "The tracked Ruins of Alph milestones are complete.",
          "All four picture puzzles are solved and the UNOWN DEX upgrade is unlocked. The remaining Unown collection is exploration/completionist content, not a Story Guide objective.", "CONTEXT")
      end
      return objective("GOLD_RUINS_INNER", "RUINS OF ALPH",
        ("Explore the Inner Chamber; %d of 4 picture puzzles are solved."):format(st.ruinsPuzzleCount),
        "The Ruins are optional. HELP tracks the four picture puzzles and the UNOWN DEX milestone, but not every individual Unown form.", "CONTEXT")
    end

    if goldMapIs(s, "RUINS_OF_ALPH_RESEARCH_CENTER") then
      if st.unownDexUnlocked then
        return objective("GOLD_RUINS_RESEARCH_COMPLETE", "RUINS OF ALPH RESEARCH CENTER",
          "The UNOWN DEX upgrade is already unlocked.",
          "Continue the picture puzzles if any remain, or return to the main adventure whenever you like.", "CONTEXT")
      end
      if st.unownCount >= 3 then
        return objective("GOLD_RUINS_GET_UNOWN_DEX", "RUINS OF ALPH RESEARCH CENTER",
          "Receive the UNOWN DEX upgrade from the researcher.",
          "You have recorded at least three different Unown forms, which satisfies the Research Center milestone.", "CONTEXT")
      end
      return objective("GOLD_RUINS_RESEARCH_NEEDS_UNOWN", "RUINS OF ALPH RESEARCH CENTER",
        ("Record at least three different Unown forms first (%d/3)."):format(st.unownCount),
        "Return to the Inner Chamber after solving a picture puzzle, catch different Unown forms, then come back for the Research Center upgrade.", "CONTEXT")
    end

    if goldMapIs(s, "RUINS_OF_ALPH_OUTSIDE") then
      if not st.ruinsKabutoSolved then
        return objective("GOLD_RUINS_FIRST_PUZZLE", "RUINS OF ALPH",
          "Optional: enter the first puzzle chamber and solve the Kabuto picture.",
          "This is the first immediately accessible Ruins milestone. It is optional and never blocks the route toward Azalea Town.", "CONTEXT")
      end
      if not st.unownDexUnlocked and st.unownCount < 3 then
        return objective("GOLD_RUINS_CATCH_UNOWN", "RUINS OF ALPH",
          ("Optional: catch different Unown forms in the Inner Chamber (%d/3)."):format(st.unownCount),
          "Three different recorded forms are enough to trigger the Research Center's UNOWN DEX upgrade.", "CONTEXT")
      end
      if not st.unownDexUnlocked and st.unownCount >= 3 then
        return objective("GOLD_RUINS_GET_UNOWN_DEX", "RUINS OF ALPH",
          "Look for the researcher outside and follow him to the Research Center.",
          "You have recorded enough different Unown forms to unlock the UNOWN DEX milestone.", "CONTEXT")
      end
      if st.ruinsComplete then
        return objective("GOLD_RUINS_COMPLETE_CONTEXT", "RUINS OF ALPH",
          "The tracked Ruins of Alph milestones are complete.",
          "All four picture puzzles and the UNOWN DEX milestone are complete; any remaining Unown collection is optional exploration.", "CONTEXT")
      end
      return objective("GOLD_RUINS_CONTINUE", "RUINS OF ALPH",
        ("Optional: continue the Ruins picture puzzles (%d/4 solved)."):format(st.ruinsPuzzleCount),
        "Explore the chambers that are currently reachable with your field moves. HELP will give a specific instruction when you enter a puzzle chamber.", "CONTEXT")
    end

    return objective("GOLD_OPTION_RUINS_CONTEXT", "RUINS OF ALPH",
      "Explore the current Ruins of Alph chamber at your own pace.",
      "Ruins of Alph is optional and never blocks the main story. HELP only tracks its major puzzle/research milestones.", "CONTEXT")
  end

  local function goldContextObjective(s)
    local st, b = s.story, s.badges
    if goldMapIs(s, "WILLS_ROOM") and not goldEvent(s.raw, liveGame, "EVENT_BEAT_ELITE_4_WILL") then
      return objective("GOLD_E4_WILL", "WILL'S ROOM", "Defeat Will.",
        "Win the first Elite Four battle, then continue to the next room.", "CONTEXT")
    end
    if goldMapIs(s, "KOGAS_ROOM") and not goldEvent(s.raw, liveGame, "EVENT_BEAT_ELITE_4_KOGA") then
      return objective("GOLD_E4_KOGA", "KOGA'S ROOM", "Defeat Koga.",
        "Win the second Elite Four battle and continue onward.", "CONTEXT")
    end
    if goldMapIs(s, "BRUNOS_ROOM") and not goldEvent(s.raw, liveGame, "EVENT_BEAT_ELITE_4_BRUNO") then
      return objective("GOLD_E4_BRUNO", "BRUNO'S ROOM", "Defeat Bruno.",
        "Win the third Elite Four battle and continue onward.", "CONTEXT")
    end
    if goldMapIs(s, "KARENS_ROOM") and not goldEvent(s.raw, liveGame, "EVENT_BEAT_ELITE_4_KAREN") then
      return objective("GOLD_E4_KAREN", "KAREN'S ROOM", "Defeat Karen.",
        "Win the fourth Elite Four battle and continue onward.", "CONTEXT")
    end
    if goldMapIs(s, "LANCES_ROOM") and not goldEvent(s.raw, liveGame, "EVENT_BEAT_CHAMPION_LANCE") then
      return objective("GOLD_CHAMPION_LANCE", "LANCE'S ROOM", "Defeat Champion Lance.",
        "Win the final Pokemon League battle to enter the Hall of Fame.", "CONTEXT")
    end

    -- Gold Victory Road is one vertically stacked map, not three separate
    -- floors. Use the live/snapshot Y coordinate only for coarse orientation;
    -- optional item detours never become prerequisites.
    if goldMapIs(s, "VICTORY_ROAD") and not st.beatEliteFour then
      local y = tonumber(s.location and s.location.y)
      if st.victoryRoadRival then
        return objective("GOLD_VICTORY_ROAD_EXIT", "VICTORY ROAD",
          "The rival ambush is complete. Continue to the north exit for Indigo Plateau.",
          "Optional item pockets do not block the exit; follow the main corridor toward Route 23.", "CONTEXT")
      end
      if y and y >= 48 then
        return objective("GOLD_VICTORY_ROAD_LOWER", "VICTORY ROAD",
          "Continue through the lower region toward the ladder in the northwest.",
          "Gold's Victory Road is one large map. Keep progressing upward through its self-warp ladders; optional items are never required.", "CONTEXT")
      end
      if y and y >= 32 then
        return objective("GOLD_VICTORY_ROAD_MIDDLE", "VICTORY ROAD",
          "Continue through the middle region toward the next ladder upward.",
          "Stay on the main route toward the upper region. Side item pockets can be skipped safely.", "CONTEXT")
      end
      if y and y >= 22 then
        return objective("GOLD_VICTORY_ROAD_RETURN_ROUTE", "VICTORY ROAD",
          "Return from this lower shelf/item pocket to the main upward route.",
          "This region is an optional detour. Rejoin the central path and continue upward toward the exit.", "CONTEXT")
      end
      return objective("GOLD_VICTORY_ROAD_RIVAL", "VICTORY ROAD",
        "Continue toward the north exit and defeat your rival when he ambushes you.",
        "The rival trip-wire spans the exit corridor, so the final Johto rival battle cannot be bypassed on the normal route.", "CONTEXT")
    end

    local ruinsContext = goldRuinsContext(s)
    if ruinsContext then return ruinsContext end

    if st.bugContestActive and goldMapHas(s, "NATIONAL_PARK") then
      return objective("GOLD_OPTION_BUG_CONTEST_ACTIVE", "NATIONAL PARK",
        "The Bug-Catching Contest is active. Catch the best Bug Pokemon you can before time expires.",
        "The contest is optional and temporarily replaces your normal party/Pack rules. When you are satisfied with your catch, return to a gate officer for judging.", "CONTEXT")
    end

    -- Optional-area context must win once the player voluntarily enters the
    -- area.  This does not make the legendary/weekly content mandatory; it
    -- only prevents HELP from answering with a distant story objective while
    -- the player is already exploring the side area.
    if goldMapHas(s, "TIN_TOWER") or goldMapHas(s, "ECRUTEAK_TIN_TOWER") then
      if st.foughtHoOh then
        return objective("GOLD_OPTION_HO_OH_DONE_CONTEXT", "TIN TOWER",
          "Ho-Oh's one-time encounter here is already complete.",
          "Continue exploring for optional items or leave whenever you like; Tin Tower never blocks the main adventure.", "CONTEXT")
      end
      if st.gotRainbowWing then
        return objective("GOLD_OPTION_HO_OH_CONTEXT", "TIN TOWER",
          "Climb Tin Tower toward the roof and encounter Ho-Oh.",
          "The Rainbow Wing opens Gold's Ho-Oh route. The encounter is optional and does not block the Pokemon League or Mt. Silver.", "CONTEXT")
      end
      return objective("GOLD_OPTION_TIN_TOWER_CONTEXT", "TIN TOWER",
        "Explore the accessible part of Tin Tower, or return to the main adventure.",
        "The deeper Ho-Oh route needs its own later access evidence. HELP will not treat this optional visit as a story gate.", "CONTEXT")
    end

    if goldMapHas(s, "WHIRL_ISLAND") then
      if st.foughtLugia then
        return objective("GOLD_OPTION_LUGIA_DONE_CONTEXT", "WHIRL ISLANDS",
          "Lugia's one-time encounter here is already complete.",
          "The islands remain optional exploration; leave whenever you are ready to continue the main adventure.", "CONTEXT")
      end
      if st.gotSilverWing then
        return objective("GOLD_OPTION_LUGIA_CONTEXT", "WHIRL ISLANDS",
          "Navigate the Whirl Islands toward Lugia's chamber.",
          "The Silver Wing is the encounter access evidence. WHIRLPOOL and the islands' cave routes are part of this optional trip, not a main-story gate.", "CONTEXT")
      end
      return objective("GOLD_OPTION_WHIRL_ISLANDS_CONTEXT", "WHIRL ISLANDS",
        "Explore the Whirl Islands at your own pace, or return to the main adventure.",
        "HELP will not reveal the later legendary objective before its own access evidence exists.", "CONTEXT")
    end

    if goldMapIs(s, "UNION_CAVE_B2F") and s.abilities.surf and not st.unionCaveLaprasUsed then
      return objective("GOLD_OPTION_FRIDAY_LAPRAS_CONTEXT", "UNION CAVE B2F",
        "Optional: check the water's edge for the Friday Lapras encounter.",
        "Lapras appears here on Friday. If it is not present today, continue the main adventure and return on Friday.", "CONTEXT")
    end

    if st.metCopycatLostItem and not st.gotMagnetTrainPass then
      if goldMapIs(s, "POKEMON_FAN_CLUB") and not st.gotLostItem then
        return objective("GOLD_OPTION_COPYCAT_LOST_ITEM_CONTEXT", "VERMILION FAN CLUB",
          "Recover Copycat's LOST ITEM from the Fan Club.",
          "Copycat has already told you about the missing doll. This side quest is optional and leads to the Magnet Train Pass.", "CONTEXT")
      end
      if goldMapHas(s, "COPYCATS_HOUSE") and st.gotLostItem then
        return objective("GOLD_OPTION_COPYCAT_RETURN_CONTEXT", "COPYCAT'S HOUSE",
          "Return the LOST ITEM to Copycat.",
          "Finish the reward conversation here to receive the Magnet Train Pass. This remains optional utility content.", "CONTEXT")
      end
    end

    local shipContext = goldFastShipStep(s)
    if shipContext then return shipContext end

    if st.rocketsInRadioTower and not st.clearedRadioTower
        and goldMapHasAny(s, { "RADIO_TOWER", "GOLDENROD_UNDERGROUND" }) then
      return goldRadioTowerStep(s)
    end

    if goldMapHas(s, "TEAM_ROCKET_BASE") and not st.clearedRocketHideout then
      if not st.rocketPasswordSlowpoketail or not st.rocketPasswordRaticateTail then
        local missing = 0
        if not st.rocketPasswordSlowpoketail then missing = missing + 1 end
        if not st.rocketPasswordRaticateTail then missing = missing + 1 end
        return objective("GOLD_ROCKET_BASE_PASSWORDS", "TEAM ROCKET BASE B3F",
          missing == 2 and "Find the two passwords for the boss-room door."
            or "Find the remaining password for the boss-room door.",
          "Explore B3F and defeat/talk to the Rocket members who know the required passwords. HELP will update after both are learned.", "CONTEXT")
      end
      if not st.rocketPasswordHailGiovanni then
        return objective("GOLD_ROCKET_BASE_MURKROW", "TEAM ROCKET BASE B3F",
          "Open the boss room, defeat the Executive, then talk to Murkrow.",
          "Both door passwords are known. The Murkrow in the office gives the final HAIL GIOVANNI password for the transmitter room.", "CONTEXT")
      end
      return objective("GOLD_ROCKET_BASE_TRANSMITTER", "TEAM ROCKET BASE B2F",
        "Return to the transmitter room and shut it down.",
        "Use HAIL GIOVANNI at the transmitter door, finish the Rocket ambush and clear the Electrode sequence. Lance gives HM06 afterward.", "CONTEXT")
    end
    if goldMapHas(s, "ICE_PATH") and not b.johto.rising then
      if not s.abilities.strength then
        local summary = s.hms.strength
          and "Teach STRENGTH to a Pokemon before the B1F boulder puzzle."
          or "You need HM04 STRENGTH before the B1F boulder puzzle."
        return objective("GOLD_ICE_PATH_STRENGTH_CONTEXT", "ICE PATH", summary,
          "Ice Path B1F has a required boulder-into-hole puzzle. A current party STRENGTH user with the Plain Badge is required; HM04 alone is not enough.", "CONTEXT")
      end
      if not s.hms.waterfall then
        return objective("GOLD_ICE_PATH_HM07", "ICE PATH",
          "Pick up HM07 WATERFALL and continue toward Blackthorn.",
          "HM07 is mandatory later at Tohjo Falls. Do not leave Ice Path without it.", "CONTEXT")
      end
      return objective("GOLD_ICE_PATH_EXIT", "ICE PATH",
        "Continue through Ice Path to Blackthorn City.",
        "Work through the ice and boulder puzzles and take the Blackthorn-side exit.", "CONTEXT")
    end
    if goldMapHas(s, "DRAGONS_DEN") and not b.johto.rising then
      if not s.abilities.surf then
        return objective("GOLD_DRAGONS_DEN_SURF_CONTEXT", "DRAGON'S DEN",
          "You need a current party Pokemon that can use SURF here.",
          "The required route through Dragon's Den crosses water. HM03 ownership alone does not make SURF usable.", "CONTEXT")
      end
      if not s.abilities.whirlpool then
        return objective("GOLD_DRAGONS_DEN_WHIRLPOOL_CONTEXT", "DRAGON'S DEN",
          "You need a current party Pokemon that can use WHIRLPOOL here.",
          "The route to the Dragon Fang crosses a whirlpool. HM06, the Glacier Badge and a current party user are required.", "CONTEXT")
      end
      return objective("GOLD_DRAGONS_DEN", "DRAGON'S DEN",
        "Complete Clair's Dragon's Den requirement.",
        "Retrieve the required Dragon Fang / finish the Den sequence so Clair awards the Rising Badge.", "CONTEXT")
    end
    if goldMapHas(s, "DARK_CAVE") and not st.gotBlackglassesDarkCave then
      return objective("GOLD_OPTION_DARK_CAVE_CONTEXT", "DARK CAVE",
        "Explore Dark Cave and look for the Blackglasses gift.",
        "This cave is optional. FLASH can make navigation easier; the Blackglasses pickup is the tracked optional milestone here.", "CONTEXT")
    end
    if goldMapHas(s, "MOUNT_MORTAR") and not st.gotTyrogue then
      local summary = s.access.partySpace
        and "Explore Mt. Mortar and find Blackbelt Kiyo."
        or "Make room in your party before finishing Blackbelt Kiyo's challenge."
      return objective("GOLD_OPTION_TYROGUE_CONTEXT", "MT. MORTAR", summary,
        "Defeat Kiyo for the one-time Tyrogue gift. The gift requires an open party slot and does not block the main story.", "CONTEXT")
    end
    if goldMapHas(s, "SILVER_CAVE") and st.openedMtSilver and not st.redDefeated then
      return objective("GOLD_RED", "MT. SILVER",
        "Climb Mt. Silver and defeat Red.",
        "Continue through Silver Cave toward the summit and challenge Red.", "CONTEXT")
    end
    return nil
  end

  local function goldOlivineBranch(s)
    local st, b, map = s.story, s.badges.johto, s.location.map

    -- Route to Olivine is part of the instruction, not an implied teleport.
    if not b.mineral and not st.jasmineExplained then
      if map == "ECRUTEAK_CITY" then
        return objective("GOLD_OLIVINE_ROUTE38", "ECRUTEAK CITY",
          "Leave Ecruteak to the west through the Route 38 gate.",
          "The Olivine branch begins west of Ecruteak. Pass the gate, follow Route 38 west and continue onto Route 39.")
      end
      if map == "ROUTE_38_ECRUTEAK_GATE" then
        return objective("GOLD_OLIVINE_ROUTE38_GATE", "ROUTE 38 GATE",
          "Continue west through the gate onto Route 38.",
          "Nothing in the gate blocks progress. Keep heading west toward Route 39 and Olivine City.")
      end
      if map == "ROUTE_38" then
        return objective("GOLD_OLIVINE_ROUTE39", "ROUTE 38",
          "Follow Route 38 west onto Route 39.",
          "Route 39 is at the west end. Trainers and the Berry tree are optional stops; keep moving toward Olivine.")
      end
      if map == "ROUTE_39" then
        return objective("GOLD_OLIVINE_CITY_ROUTE", "ROUTE 39",
          "Follow Route 39 south into Olivine City.",
          "Moomoo Farm is optional. The main route continues south to Olivine, where the Lighthouse story begins.")
      end
      if goldMapHas(s, "LIGHTHOUSE") then
        return objective("GOLD_LIGHTHOUSE_CLIMB", "OLIVINE LIGHTHOUSE",
          "Keep climbing the Lighthouse until you reach Jasmine and Amphy on 6F.",
          "Use the ladders and the broken-floor drop route to reach the top. Speak with Jasmine beside the sick Ampharos to unlock the Cianwood pharmacy step.")
      end
      if map == "OLIVINE_CITY" then
        if not s.hms.strength and not b.storm then
          return objective("GOLD_HM04_STRENGTH", "OLIVINE CAFE",
            "Before leaving Olivine, get HM04 STRENGTH from the sailor in the Cafe.",
            "The Cafe is in Olivine City. HM04 is needed for Cianwood Gym and later Ice Path, so collecting it now avoids a forced backtrack.")
        end
        return objective("GOLD_LIGHTHOUSE", "OLIVINE LIGHTHOUSE",
          "Enter the Lighthouse in southeast Olivine and climb to Jasmine.",
          "Work upward through the Lighthouse to 6F. Speaking with Jasmine beside Amphy is the story trigger for the SecretPotion in Cianwood.")
      end
      return objective("GOLD_TO_OLIVINE", "ROUTES 38-39 / OLIVINE",
        "Travel west from Ecruteak through Routes 38 and 39 to Olivine City.",
        "In Olivine, collect HM04 Strength, then climb the Lighthouse and speak with Jasmine beside Amphy.")
    end

    if not b.mineral and not st.gotSecretPotion then
      if map == "OLIVINE_CITY" then
        return objective("GOLD_CIANWOOD_ROUTE40", "OLIVINE CITY",
          "Leave Olivine to the west onto Route 40 and Surf south.",
          "The pharmacy is in Cianwood. From Olivine take Route 40 south, then cross Route 41 west by Surf.")
      end
      if map == "ROUTE_40" then
        return objective("GOLD_CIANWOOD_ROUTE40_SURF", "ROUTE 40",
          "Surf south from Route 40 into Route 41.",
          "Continue through the sea route. The Whirl Islands are optional detours; Cianwood is to the west.")
      end
      if map == "ROUTE_41" then
        return objective("GOLD_CIANWOOD_ROUTE41_WEST", "ROUTE 41",
          "Keep Surfing west through Route 41 to Cianwood City.",
          "Ignore the Whirl Islands for the mandatory story. Reach the landmass at the west end and enter Cianwood.")
      end
      if map == "CIANWOOD_PHARMACY" then
        return objective("GOLD_SECRET_POTION", "CIANWOOD PHARMACY",
          "Talk to the pharmacist and receive the SECRET POTION.",
          "Jasmine's Lighthouse request is active, so the pharmacist will provide the medicine for Amphy.")
      end
      if map == "CIANWOOD_CITY" then
        return objective("GOLD_SECRET_POTION_ROUTE", "CIANWOOD CITY",
          "Go to the Cianwood Pharmacy and get the SECRET POTION.",
          "Get the medicine before leaving Cianwood. You will bring it back to Jasmine at the top of Olivine Lighthouse.")
      end
      return objective("GOLD_SECRET_POTION", "CIANWOOD PHARMACY",
        "Surf from Olivine through Routes 40 and 41 to Cianwood and get the SECRET POTION.",
        "Jasmine's request unlocks the pharmacy medicine. Reach Cianwood and speak with the pharmacist.")
    end

    if not b.storm then
      if not s.hms.strength then
        return objective("GOLD_HM04_STRENGTH", "OLIVINE CAFE",
          "Get HM04 STRENGTH before challenging Chuck.",
          "Cianwood Gym's boulder puzzle requires Strength. If you skipped the Olivine Cafe, return there for HM04.")
      end
      if not s.abilities.strength then
        return objective("GOLD_TEACH_STRENGTH", "PARTY",
          "Teach STRENGTH to a Pokemon before challenging Chuck.",
          "The Plain Badge and a current non-Egg party user are required to move the Gym boulders; owning HM04 alone is not enough.")
      end
      if map == "CIANWOOD_GYM" then
        return objective("GOLD_CHUCK", "CIANWOOD GYM",
          "Move the Strength boulders and defeat Chuck.",
          "Complete the Gym puzzle, defeat Chuck and receive the Storm Badge.")
      end
      return objective("GOLD_CHUCK_ROUTE", "CIANWOOD GYM",
        "Go to Cianwood Gym and defeat Chuck.",
        "With the SecretPotion secured and Strength usable, clear the Gym and earn the Storm Badge.")
    end

    -- The woman outside Cianwood Gym gives HM02 immediately after Chuck. It is
    -- not a hard cartridge gate, but it is the intended route utility and the
    -- cleanest way back to Olivine, so HELP treats the one-time pickup as the
    -- next recommended story step unless downstream Jasmine proof makes it moot.
    if not b.mineral and not st.jasmineReturned and not s.hms.fly then
      return objective("GOLD_GET_FLY_CIANWOOD", "CIANWOOD CITY",
        "Talk to the woman outside Cianwood Gym and receive HM02 FLY.",
        "Do this before leaving Cianwood. The Storm Badge you just earned makes FLY usable once a current party Pokemon knows it.")
    end

    if not b.mineral and not st.jasmineReturned then
      if map == "CIANWOOD_CITY" or map == "ROUTE_41" or map == "ROUTE_40" then
        return objective("GOLD_RETURN_OLIVINE", "OLIVINE CITY",
          "Return to Olivine City with the SECRET POTION.",
          "Use FLY if you taught it, or Surf east through Routes 41 and 40. Then re-enter the Lighthouse and climb back to Jasmine on 6F.")
      end
      if map == "OLIVINE_CITY" then
        return objective("GOLD_CURE_AMPHY_LIGHTHOUSE", "OLIVINE LIGHTHOUSE",
          "Return to the top of Olivine Lighthouse with the SECRET POTION.",
          "Climb back to 6F and speak with Jasmine beside Amphy to hand over the medicine.")
      end
      if goldMapHas(s, "LIGHTHOUSE") then
        return objective("GOLD_CURE_AMPHY", "OLIVINE LIGHTHOUSE",
          "Reach Jasmine on 6F and give her the SECRET POTION.",
          "Finish the Lighthouse return climb. Curing Amphy makes Jasmine leave for Olivine Gym.")
      end
      return objective("GOLD_CURE_AMPHY", "OLIVINE LIGHTHOUSE",
        "Return to Olivine Lighthouse and give Jasmine the SECRET POTION.",
        "Cure Amphy on 6F; Jasmine then returns to her Gym.")
    end

    if not b.mineral then
      if map == "OLIVINE_GYM" then
        return objective("GOLD_JASMINE", "OLIVINE GYM",
          "Defeat Jasmine and earn the Mineral Badge.",
          "Amphy is cured and Jasmine has returned. Defeat her to complete the Olivine branch.")
      end
      return objective("GOLD_JASMINE_ROUTE", "OLIVINE GYM",
        "Go to Olivine Gym and challenge Jasmine.",
        "Jasmine is back from the Lighthouse. Enter the Gym and earn the Mineral Badge.")
    end
    return nil
  end

  local function goldMahoganyBranch(s)
    local st, b, map = s.story, s.badges.johto, s.location.map
    if b.glacier then return nil end

    if not st.foughtRedGyarados then
      if map == "ECRUTEAK_CITY" then
        return objective("GOLD_MAHOGANY_ROUTE42", "ECRUTEAK CITY",
          "Leave Ecruteak to the east onto Route 42.",
          "The Mahogany branch runs east. Follow Route 42 past the Mt. Mortar entrances until you reach Mahogany Town.")
      end
      if map == "ROUTE_42" then
        return objective("GOLD_MAHOGANY_TOWN_ROUTE", "ROUTE 42",
          "Continue east on Route 42 to Mahogany Town.",
          "Mt. Mortar is optional for the main story. Stay on the overworld road and keep heading east.")
      end
      if map == "MAHOGANY_TOWN" then
        return objective("GOLD_LAKE_ROUTE43", "MAHOGANY TOWN",
          "Leave Mahogany to the north onto Route 43.",
          "Pryce's Gym is not the first task here. Head north through Route 43 to investigate the Lake of Rage.")
      end
      if map == "ROUTE_43" then
        return objective("GOLD_LAKE_ROUTE43_NORTH", "ROUTE 43",
          "Continue north through Route 43 to the Lake of Rage.",
          "Use either Route 43 path and keep moving north. The Red Gyarados encounter at the lake is the next mandatory trigger.")
      end
      if map == "LAKE_OF_RAGE" then
        return objective("GOLD_RED_GYARADOS", "LAKE OF RAGE",
          "Surf to the Red Gyarados and finish the encounter.",
          "Catching it is optional; completing the battle is the story requirement. Afterward, speak with Lance on shore.")
      end
      return objective("GOLD_TO_MAHOGANY", "ECRUTEAK / ROUTE 42",
        "Return toward Ecruteak, then travel east on Route 42 to Mahogany and north on Route 43.",
        "Reach the Lake of Rage and complete the Red Gyarados encounter.")
    end

    if not st.helpingLance then
      if map == "LAKE_OF_RAGE" then
        return objective("GOLD_HELP_LANCE", "LAKE OF RAGE",
          "Return to shore, speak with Lance and agree to help him.",
          "Accept Lance's investigation request. He heads to Mahogany and opens the Team Rocket Base sequence.")
      end
      return objective("GOLD_HELP_LANCE", "LAKE OF RAGE",
        "Speak with Lance at the Lake of Rage and agree to investigate Team Rocket.",
        "The Red Gyarados encounter is complete, but Lance's conversation is the next story trigger.")
    end

    if not st.clearedRocketHideout then
      if map == "LAKE_OF_RAGE" or map == "ROUTE_43" then
        return objective("GOLD_RETURN_MAHOGANY_LANCE", "MAHOGANY TOWN",
          "Return south to Mahogany Town and meet Lance at the suspicious shop.",
          "Lance has gone ahead. Follow Route 43 south and enter the Mahogany shop to uncover the hidden staircase.")
      end
      if map == "MAHOGANY_TOWN" then
        return objective("GOLD_ROCKET_HIDEOUT_ENTER", "MAHOGANY TOWN",
          "Enter the suspicious Mahogany shop and follow Lance into the hidden base.",
          "The staircase under the shop begins Team Rocket's hideout. Clear that base before Pryce's Gym is the recommended next step.")
      end
      return objective("GOLD_ROCKET_HIDEOUT", "MAHOGANY / TEAM ROCKET BASE",
        "Enter Team Rocket's hidden base and shut down the transmitter.",
        "Find both boss-room passwords, use Murkrow's final password and finish the Electrode transmitter sequence. Lance gives HM06 afterward.")
    end

    if map == "MAHOGANY_GYM" then
      return objective("GOLD_PRYCE", "MAHOGANY GYM",
        "Cross the ice puzzle and defeat Pryce.",
        "Defeat Pryce to earn the Glacier Badge. This also enables WHIRLPOOL outside battle once a party Pokemon knows it.")
    end
    return objective("GOLD_PRYCE_ROUTE", "MAHOGANY GYM",
      "Return to Mahogany Town and challenge Pryce.",
      "Team Rocket's hideout is cleared. Enter Mahogany Gym, solve the ice floor and earn the Glacier Badge.")
  end

  local function goldKantoGymObjective(key)
    local defs = {
      thunder = { "GOLD_SURGE", "VERMILION GYM", "Defeat Lt. Surge and earn the Thunder Badge." },
      marsh = { "GOLD_SABRINA", "SAFFRON GYM", "Defeat Sabrina and earn the Marsh Badge." },
      rainbow = { "GOLD_ERIKA", "CELADON GYM", "Defeat Erika and earn the Rainbow Badge." },
      soul = { "GOLD_JANINE", "FUCHSIA GYM", "Defeat Janine and earn the Soul Badge." },
      cascade = { "GOLD_MISTY", "CERULEAN / ROUTE 25", "Find Misty on Route 25, then defeat her in Cerulean Gym for the Cascade Badge." },
      boulder = { "GOLD_BROCK", "PEWTER GYM", "Defeat Brock and earn the Boulder Badge." },
      volcano = { "GOLD_BLAINE", "SEAFOAM GYM", "Reach Blaine's Seafoam Gym and earn the Volcano Badge." },
      earth = { "GOLD_BLUE", "VIRIDIAN GYM", "Defeat Blue and earn the Earth Badge." },
    }
    local d = defs[key]
    return objective(d[1], d[2], d[3], d[3])
  end

  local function goldMistyObjective(s)
    local st = s.story
    -- This helper is exposed only after the Cerulean Rocket scene has happened
    -- (resolveAllGold gates it on st.metCeruleanRocket).  Earlier Power Plant
    -- and Gym-trigger steps live in the PRIMARY Kanto route helper, so keeping
    -- unreachable pre-trigger branches here would create dead objective IDs.
    if not st.route24RocketDefeated then
      return objective("GOLD_MISTY_ROUTE24_ROCKET", "ROUTE 24",
        "Follow the fleeing Rocket north and defeat him on Route 24.",
        "Leave Cerulean Gym, head north through Cerulean City onto Route 24 and defeat the Rocket Grunt on the old Nugget Bridge. This fight comes before Misty's Route 25 scene.")
    end
    if not st.mistyDateComplete then
      return objective("GOLD_MISTY_ROUTE25", "ROUTE 25",
        "Continue north to Route 25 and interrupt Misty's date.",
        "After defeating the Rocket on Route 24, continue north/east along Route 25. The date cutscene sends Misty back to Cerulean Gym and repopulates the Gym.")
    end
    return goldKantoGymObjective("cascade")
  end

  ---------------------------------------------------------------------------
  -- Gold thin-route guidance
  --
  -- Durable flags answer "what has happened"; the current map answers "what
  -- should I do next from HERE".  These helpers deliberately split the first
  -- half of Johto into route-sized steps instead of jumping from Gym to Gym.
  ---------------------------------------------------------------------------

  local function goldOpeningObjective(s)
    if goldMapIs(s, "PLAYERS_HOUSE_2F") then
      return objective("GOLD_OPENING_DOWNSTAIRS", "YOUR HOUSE",
        "Go downstairs and finish the opening with Mom.",
        "Leave your bedroom, go downstairs, talk to Mom as required, then head outside into New Bark Town.")
    end
    if goldMapIs(s, "PLAYERS_HOUSE_1F") then
      return objective("GOLD_OPENING_MOM", "YOUR HOUSE",
        "Finish the opening conversation with Mom, then leave the house.",
        "Once the required Pokegear/time opening is complete, exit into New Bark Town and visit Professor Elm's Lab.")
    end
    if goldMapIs(s, "ELMS_LAB") then
      return objective("GOLD_CHOOSE_STARTER", "ELM'S LAB",
        "Choose your starter Pokemon.",
        "Choose Chikorita, Cyndaquil or Totodile from Professor Elm.")
    end
    return objective("GOLD_NEW_BARK_OPENING", "NEW BARK TOWN",
      "Go to Professor Elm's Lab in New Bark Town.",
      "Elm's Lab is your first mandatory destination. Enter it and choose a starter before trying to leave town to the west.")
  end

  local function goldMrPokemonRouteObjective(s)
    local map = s.location.map
    if map == "ELMS_LAB" then
      return objective("GOLD_MR_POKEMON_LEAVE_ELM", "ELM'S LAB",
        "Leave Elm's Lab and start west toward Cherrygrove City.",
        "Elm has sent you to Mr. Pokemon. Exit the Lab, then leave New Bark Town from its west side onto Route 29.")
    end
    if map == "NEW_BARK_TOWN" then
      return objective("GOLD_MR_POKEMON_ROUTE29", "ROUTE 29",
        "Leave New Bark Town to the west onto Route 29.",
        "Follow Route 29 west. Your next town is Cherrygrove City; Mr. Pokemon is farther north beyond it.")
    end
    if map == "ROUTE_29" then
      return objective("GOLD_MR_POKEMON_CHERRYGROVE", "ROUTE 29",
        "Follow Route 29 west to Cherrygrove City.",
        "Keep following the road west. Optional grass/items can be explored, but Cherrygrove is the mandatory way forward.")
    end
    if map == "CHERRYGROVE_CITY" then
      return objective("GOLD_MR_POKEMON_ROUTE30", "CHERRYGROVE CITY",
        "Leave Cherrygrove from the north side onto Route 30.",
        "The Guide Gent/Map Card is useful but optional. The story route continues north to Route 30 and Mr. Pokemon's house.")
    end
    if map == "ROUTE_30" then
      return objective("GOLD_MR_POKEMON_ROUTE30_NORTH", "ROUTE 30",
        "Continue north on Route 30 to Mr. Pokemon's house.",
        "On this first trip the western trainer fork is blocked by a battle, so stay on the path that reaches the house in the north.")
    end
    if map == "MR_POKEMONS_HOUSE" then
      return objective("GOLD_MR_POKEMON_TALK", "MR. POKEMON'S HOUSE",
        "Talk to Mr. Pokemon and Professor Oak.",
        "Receive the Mystery Egg and Pokedex. Those two conversations are the reason for this trip.")
    end
    return objective("GOLD_MR_POKEMON", "MR. POKEMON'S HOUSE",
      "Travel west through Route 29 to Cherrygrove, then north on Route 30.",
      "Mr. Pokemon's house is at the north end of Route 30. Talk to him and Professor Oak for the Mystery Egg and Pokedex.")
  end

  local function goldReturnElmRouteObjective(s)
    local map = s.location.map
    if map == "MR_POKEMONS_HOUSE" or map == "ROUTE_30" then
      return objective("GOLD_RETURN_ELM_SOUTH", "ROUTE 30",
        "Head south back to Cherrygrove City.",
        "You now have the Mystery Egg. Retrace Route 30 south; Elm's emergency call means the next mandatory destination is his Lab in New Bark Town.")
    end
    if map == "CHERRYGROVE_CITY" then
      return objective("GOLD_RETURN_ELM_RIVAL", "CHERRYGROVE CITY",
        "Leave Cherrygrove to the east toward Route 29.",
        "Your rival will stop you on this return trip. Finish that encounter, then continue east toward New Bark Town.")
    end
    if map == "ROUTE_29" then
      return objective("GOLD_RETURN_ELM_NEW_BARK", "ROUTE 29",
        "Follow Route 29 east back to New Bark Town.",
        "Continue east until you re-enter New Bark, then go straight to Professor Elm's Lab.")
    end
    if map == "NEW_BARK_TOWN" then
      return objective("GOLD_RETURN_ELM_LAB", "NEW BARK TOWN",
        "Enter Professor Elm's Lab with the Mystery Egg.",
        "The officer/rival-name scene and Elm's Egg hand-off happen in the Lab before the journey to Violet can begin.")
    end
    if map == "ELMS_LAB" then
      return objective("GOLD_RETURN_ELM_EGG", "ELM'S LAB",
        "Give the Mystery Egg to Professor Elm.",
        "Complete the required officer/rival-name scene if it is still running, then hand the Mystery Egg to Elm.")
    end
    return objective("GOLD_RETURN_ELM_EGG", "ELM'S LAB",
      "Return through Cherrygrove and Route 29 to Professor Elm.",
      "Fight the rival on the return trip, reach New Bark Town and deliver the Mystery Egg to Elm.")
  end

  local function goldVioletRouteObjective(s)
    local map = s.location.map
    if not s.hms.flash then
      if map == "NEW_BARK_TOWN" then
        return objective("GOLD_TO_VIOLET_ROUTE29", "ROUTE 29",
          "Leave New Bark west and return to Cherrygrove.",
          "With the Mystery Egg delivered, begin the real journey: Route 29 west, then north through Routes 30 and 31 to Violet City.")
      end
      if map == "ROUTE_29" then
        return objective("GOLD_TO_VIOLET_CHERRYGROVE", "ROUTE 29",
          "Continue west to Cherrygrove City.",
          "Pass through Cherrygrove and leave from the north side for Route 30.")
      end
      if map == "CHERRYGROVE_CITY" then
        return objective("GOLD_TO_VIOLET_ROUTE30", "CHERRYGROVE CITY",
          "Leave north onto Route 30.",
          "This time the western Route 30 path is open. Follow it toward Route 31 and Violet City.")
      end
      if map == "ROUTE_30" then
        return objective("GOLD_TO_VIOLET_ROUTE31", "ROUTE 30",
          "Take the western/northern path toward Route 31.",
          "Fight or pass the Route 30 trainers, then continue northwest to Route 31.")
      end
      if map == "ROUTE_31" then
        return objective("GOLD_TO_VIOLET_CITY", "ROUTE 31",
          "Continue west through the gate into Violet City.",
          "Violet is immediately west of Route 31. Once there, visit Sprout Tower before the Gym.")
      end
      if map == "VIOLET_CITY" then
        return objective("GOLD_SPROUT_TOWER_ENTER", "VIOLET CITY",
          "Enter Sprout Tower in the north part of Violet City.",
          "Climb the tower, defeat Sage Li on the top floor and receive HM05 FLASH before heading to Violet Gym.")
      end
      if map == "SPROUT_TOWER_1F" then
        return objective("GOLD_SPROUT_TOWER_1F", "SPROUT TOWER 1F",
          "Work upward through Sprout Tower toward the next ladder.",
          "Follow the tower's central wooden paths and ladders. Your goal is the top floor and Sage Li; optional items do not block the climb.")
      end
      if map == "SPROUT_TOWER_2F" then
        return objective("GOLD_SPROUT_TOWER_2F", "SPROUT TOWER 2F",
          "Continue across 2F and take the next ladder upward.",
          "Keep climbing through the sages toward 3F. The tower is a short required/recommended detour before Falkner in this guide.")
      end
      if map == "SPROUT_TOWER_3F" then
        return objective("GOLD_SPROUT_TOWER_3F", "SPROUT TOWER 3F",
          "Reach Sage Li, defeat him and receive HM05 FLASH.",
          "Finish the rival/Sage sequence on the top floor. Once HM05 is received, return to Violet City for the Gym.")
      end
      return objective("GOLD_SPROUT_TOWER", "VIOLET CITY / SPROUT TOWER",
        "Reach Violet City and complete Sprout Tower.",
        "From Cherrygrove go north through Routes 30 and 31. In Violet, climb Sprout Tower and receive HM05 FLASH.")
    end

    if goldMapHas(s, "SPROUT_TOWER") then
      return objective("GOLD_FALKNER_LEAVE_TOWER", "SPROUT TOWER",
        "Leave Sprout Tower and return to Violet City.",
        "HM05 FLASH is secured. Go back outside and head to Violet Gym for Falkner.")
    end
    if map == "VIOLET_GYM" then
      return objective("GOLD_FALKNER", "VIOLET GYM",
        "Defeat Falkner and earn the Zephyr Badge.",
        "Fight through Violet Gym and defeat Falkner. The Zephyr Badge is the first Johto badge.")
    end
    return objective("GOLD_FALKNER_ROUTE", "VIOLET CITY",
      "Go to Violet Gym and challenge Falkner.",
      "Sprout Tower is complete. Enter Violet Gym, defeat Falkner and collect the Zephyr Badge.")
  end

  local function goldTogepiEggObjective(s)
    if goldMapIs(s, "VIOLET_POKECENTER_1F") then
      return objective("GOLD_TOGEPI_EGG_TAKE", "VIOLET POKEMON CENTER",
        "Talk to Elm's aide and take the Togepi Egg.",
        "This is mandatory progression in Gold: taking the Egg changes Route 32 to its non-blocking scene. Make sure you actually receive it before leaving Violet.")
    end
    return objective("GOLD_TOGEPI_EGG", "VIOLET POKEMON CENTER",
      "Go to Violet Pokemon Center and receive the Togepi Egg from Elm's aide.",
      "Do this immediately after Falkner. The Egg is not merely an optional gift here; its hand-off is the story trigger that opens the normal Route 32 progression.")
  end

  local function goldAzaleaRouteObjective(s)
    local map, st = s.location.map, s.story
    if map == "VIOLET_CITY" then
      return objective("GOLD_ROUTE32_FROM_VIOLET", "VIOLET CITY",
        "Leave Violet City to the south onto Route 32.",
        "The main story now heads south. Ruins of Alph is an optional detour; the mandatory road to Azalea continues down Route 32.")
    end
    if map == "ROUTE_32" then
      return objective("GOLD_ROUTE32_SOUTH", "ROUTE 32",
        "Follow Route 32 south to Union Cave.",
        "Keep heading south. The Pokemon Center near the cave is a useful heal/Old Rod stop, then enter Union Cave at the south end of the route.")
    end
    if map == "ROUTE_32_POKECENTER_1F" then
      return objective("GOLD_ROUTE32_PC_EXIT", "ROUTE 32 POKEMON CENTER",
        "Heal if needed, then go back outside and continue south into Union Cave.",
        "The Old Rod is optional. The mandatory route is the cave entrance just south of this Pokemon Center.")
    end
    if map == "UNION_CAVE_1F" then
      return objective("GOLD_UNION_CAVE_1F_ROUTE", "UNION CAVE 1F",
        "Follow Union Cave's main path toward the southern exit.",
        "Work through the 1F/B1F route and keep progressing south. Side items and deeper Surf areas are optional on this first visit.")
    end
    if map == "UNION_CAVE_B1F" then
      return objective("GOLD_UNION_CAVE_B1F_ROUTE", "UNION CAVE B1F",
        "Follow B1F back up toward the southern part of 1F.",
        "Stay on the through-route rather than the later Surf detours. The exit on the far side of Union Cave leads to Route 33.")
    end
    if map == "ROUTE_33" then
      return objective("GOLD_ROUTE33_AZALEA", "ROUTE 33",
        "Head west from Route 33 into Azalea Town.",
        "Azalea is immediately west. Team Rocket is blocking the Slowpoke Well, so your first stop in town is Kurt's house.")
    end
    if map == "KURTS_HOUSE" then
      if not st.kurtOpenedWell then
        return objective("GOLD_AZALEA_KURT_TALK", "KURT'S HOUSE",
          "Talk to Kurt about the Slowpoke problem.",
          "Kurt will rush to the Well. That removes the Rocket guard and opens the next mandatory step.")
      end
      return objective("GOLD_AZALEA_WELL_FROM_KURT", "KURT'S HOUSE",
        "Leave Kurt's house and go east to Slowpoke Well.",
        "The guard has moved. Cross Azalea toward the Well on the east side and climb down after Kurt.")
    end
    if map == "AZALEA_TOWN" then
      if not st.kurtOpenedWell then
        return objective("GOLD_AZALEA_FIND_KURT", "AZALEA TOWN",
          "Go west, then north to Kurt's house before trying the Gym.",
          "The Slowpoke Well is still guarded. Speak with Kurt in his house; he is the trigger that opens the Well.")
      end
      return objective("GOLD_AZALEA_ENTER_WELL", "AZALEA TOWN",
        "Go east to Slowpoke Well and enter it.",
        "Kurt has moved the guard. The Gym remains story-blocked until Team Rocket is cleared from the Well.")
    end
    if goldMapHas(s, "SLOWPOKE_WELL") then
      return objective("GOLD_SLOWPOKE_WELL", "SLOWPOKE WELL",
        "Fight through Slowpoke Well and defeat the Rocket group.",
        "Clear the mandatory B1F Rocket sequence. The final victory warps you back to Kurt and unlocks Azalea Gym.")
    end
    return objective("GOLD_ROUTE_TO_AZALEA", "ROUTE 32 / UNION CAVE",
      "From Violet, head south on Route 32, through Union Cave and west on Route 33.",
      "Reach Azalea Town, talk to Kurt, then clear Team Rocket from Slowpoke Well before challenging Bugsy.")
  end

  local function goldBugsyObjective(s)
    if goldMapIs(s, "KURTS_HOUSE") then
      return objective("GOLD_BUGSY_FROM_KURT", "AZALEA TOWN",
        "Leave Kurt's house and go to Azalea Gym.",
        "Slowpoke Well is clear, so the Gym is open. Heal if needed, then enter the Gym and challenge Bugsy.")
    end
    if goldMapIs(s, "AZALEA_GYM") then
      return objective("GOLD_BUGSY", "AZALEA GYM",
        "Defeat Bugsy and earn the Hive Badge.",
        "Clear the Gym trainers and defeat Bugsy. The Hive Badge enables CUT outside battle once a party Pokemon knows it.")
    end
    return objective("GOLD_BUGSY_ROUTE", "AZALEA GYM",
      "Go to Azalea Gym and challenge Bugsy.",
      "Team Rocket has been cleared from Slowpoke Well. Return to the Gym in Azalea and earn the Hive Badge.")
  end

  local function goldIlexObjective(s)
    local map, st = s.location.map, s.story
    if not st.herdedFarfetchd or not s.hms.cut then
      if map == "AZALEA_TOWN" then
        return objective("GOLD_ILEX_LEAVE_AZALEA", "AZALEA TOWN",
          "Heal if needed, then walk west toward Ilex Forest.",
          "Your rival ambushes you on the west side of Azalea before the forest gate. Win that battle and continue through the gate.")
      end
      if map == "ILEX_FOREST_AZALEA_GATE" then
        return objective("GOLD_ILEX_ENTER", "ILEX FOREST GATE",
          "Continue west through the gate into Ilex Forest.",
          "The charcoal apprentice's Farfetch'd is the next mandatory puzzle.")
      end
      if map == "ILEX_FOREST" then
        if not st.herdedFarfetchd then
          return objective("GOLD_ILEX_FARFETCHD", "ILEX FOREST",
            "Herd the missing Farfetch'd back to the charcoal apprentice.",
            "Approach it from the correct sides to drive it through the forest. Once it is returned, the charcoal boss rewards you with HM01 CUT.")
        end
        return objective("GOLD_ILEX_GET_CUT", "ILEX FOREST",
          "Talk to the charcoal worker and receive HM01 CUT.",
          "The Farfetch'd is back. Collect HM01 before trying to pass the cuttable tree farther north.")
      end
      return objective("GOLD_ILEX_FARFETCHD", "ILEX FOREST",
        "Leave Azalea west, defeat the rival ambush and solve the Farfetch'd quest.",
        "Return the Farfetch'd to receive HM01 CUT, which is required to continue toward Goldenrod.")
    end

    if not s.abilities.cut then
      return objective("GOLD_TEACH_CUT", "PARTY",
        "Teach CUT to a Pokemon before continuing through Ilex Forest.",
        "You have HM01 and the Hive Badge, but a current non-Egg party Pokemon still needs to know CUT.")
    end

    if map == "ILEX_FOREST" then
      return objective("GOLD_ILEX_CUT_NORTH", "ILEX FOREST",
        "Use CUT on the tree and continue north through Ilex Forest.",
        "After the tree, keep following the forest route toward the northern gate. Headbutt and side items are optional.")
    end
    if map == "ROUTE_34_ILEX_FOREST_GATE" then
      return objective("GOLD_ROUTE34_GATE", "ILEX FOREST GATE",
        "Pass north through the gate onto Route 34.",
        "The teacher's TM is optional. The main road continues straight north toward Goldenrod City.")
    end
    if map == "ROUTE_34" then
      return objective("GOLD_ROUTE34_GOLDENROD", "ROUTE 34",
        "Follow Route 34 north to Goldenrod City.",
        "The Day-Care and trainers are optional stops. Goldenrod City is the mandatory destination at the north end.")
    end
    if map == "GOLDENROD_CITY" or map == "GOLDENROD_GYM" then
      return objective("GOLD_WHITNEY", "GOLDENROD GYM",
        "Go to Goldenrod Gym and defeat Whitney.",
        "After winning, speak with Whitney again after she stops crying so she actually awards the Plain Badge.")
    end
    return objective("GOLD_TO_GOLDENROD", "ROUTE 34 / GOLDENROD",
      "Continue north out of Ilex Forest and follow Route 34 to Goldenrod City.",
      "Once in Goldenrod, challenge Whitney for the Plain Badge.")
  end

  local function goldSudowoodoRouteObjective(s)
    local map = s.location.map
    if map == "GOLDENROD_CITY" then
      return objective("GOLD_ROUTE35_FROM_GOLDENROD", "GOLDENROD CITY",
        "Leave Goldenrod from the north side for Route 35.",
        "With the SquirtBottle in hand, head north through the Route 35 gate toward Route 36.")
    end
    if map == "ROUTE_35_GOLDENROD_GATE" then
      return objective("GOLD_ROUTE35_GATE_NORTH", "ROUTE 35 GATE",
        "Continue north through the gate onto Route 35.",
        "Kenya the Spearow is an optional side quest. Your main route continues north.")
    end
    if map == "ROUTE_35" then
      return objective("GOLD_ROUTE35_NORTH", "ROUTE 35",
        "Continue north toward Route 36.",
        "National Park and the Bug-Catching Contest are optional detours. Keep progressing north until you reach the strange tree on Route 36.")
    end
    if goldMapHas(s, "NATIONAL_PARK") then
      return objective("GOLD_NATIONAL_PARK_TO_ROUTE36", "NATIONAL PARK",
        "Leave the park from its northern side and continue to Route 36.",
        "The park is optional story-wise. Use the north gate to rejoin Route 36 and the Sudowoodo roadblock.")
    end
    if map == "ROUTE_36" then
      return objective("GOLD_SUDOWOODO", "ROUTE 36",
        "Use the SQUIRTBOTTLE on Sudowoodo and finish the encounter.",
        "The tree blocks the road junction. Catching Sudowoodo is optional; completing the encounter is what permanently opens the route.")
    end
    return objective("GOLD_SUDOWOODO_ROUTE", "ROUTE 35 / ROUTE 36",
      "Head north from Goldenrod through Route 35 to the Sudowoodo roadblock on Route 36.",
      "Use the SquirtBottle on Sudowoodo to open the route toward Ecruteak.")
  end

  local function goldEcruteakEarlyObjective(s)
    local map, st = s.location.map, s.story
    if not s.hms.surf then
      if map == "ROUTE_36" then
        return objective("GOLD_ROUTE36_TO_ROUTE37", "ROUTE 36",
          "Continue north from Route 36 onto Route 37.",
          "Sudowoodo is gone. The main road to Ecruteak now runs north through Route 37.")
      end
      if map == "ROUTE_37" then
        return objective("GOLD_ROUTE37_ECRUTEAK", "ROUTE 37",
          "Follow Route 37 north into Ecruteak City.",
          "Continue past the trainers/apricorn trees. Ecruteak is directly north.")
      end
      if map == "ECRUTEAK_CITY" then
        return objective("GOLD_KIMONO_GIRLS_ROUTE", "ECRUTEAK CITY",
          "Enter the Dance Theater and defeat all five Kimono Girls.",
          "After all five battles, speak with the gentleman in the theater to receive HM03 SURF.")
      end
      if map == "DANCE_THEATER" then
        return objective("GOLD_KIMONO_GIRLS", "ECRUTEAK DANCE THEATER",
          "Defeat all five Kimono Girls, then collect HM03 SURF.",
          "Beat each Kimono Girl and speak with the gentleman afterward. Make sure HM03 is actually received before leaving.")
      end
      return objective("GOLD_TO_ECRUTEAK", "ROUTE 36 / ROUTE 37",
        "From Route 36 head north through Route 37 to Ecruteak City.",
        "In Ecruteak, clear the five Kimono Girls in the Dance Theater and receive HM03 SURF.")
    end

    if not st.releasedBeasts then
      if goldMapHas(s, "BURNED_TOWER") then
        return objective("GOLD_BURNED_TOWER_BEASTS", "BURNED TOWER",
          "Explore Burned Tower, defeat the rival and reach the beasts on B1F.",
          "Use the tower's broken floors/rocks to descend. Reaching Raikou, Entei and Suicune releases them and completes this Ecruteak story beat.")
      end
      return objective("GOLD_BURNED_TOWER", "ECRUTEAK CITY",
        "Go to Burned Tower and release the legendary beasts.",
        "Visit Burned Tower in northwest Ecruteak before Morty. Defeat the rival and descend to B1F until the three beasts flee.")
    end

    if not s.badges.johto.fog then
      if map == "ECRUTEAK_GYM" then
        return objective("GOLD_MORTY", "ECRUTEAK GYM",
          "Cross the invisible-floor puzzle and defeat Morty.",
          "Defeat Morty for the Fog Badge. That badge is what makes SURF usable outside battle.")
      end
      return objective("GOLD_MORTY_ROUTE", "ECRUTEAK CITY",
        "Go to Ecruteak Gym and challenge Morty.",
        "The Burned Tower story beat is complete. Enter the Gym, cross its invisible floor and earn the Fog Badge.")
    end
    return nil
  end

  local function goldKantoRouteObjective(s)
    local st, k, map = s.story, s.badges.kanto, s.location.map

    -- A late/current proof may make a historical walkthrough beat impossible
    -- to reconstruct (imported/modded saves can lose old event bits).  Never
    -- make such history reclaim PRIMARY once a stronger downstream state says
    -- the player has already moved beyond it.  Current missing badges remain
    -- authoritative: only all eight Kanto badge bits retire the whole Kanto
    -- walkthrough and hand control back to the final Oak/Mt. Silver resolver.
    local allKantoBadges = k.boulder and k.cascade and k.thunder and k.rainbow
      and k.soul and k.marsh and k.volcano and k.earth
    if allKantoBadges then return nil end

    -- These are genuine dependency proofs, not badge-count guesses.  EXPN CARD
    -- can only be obtained after Kanto power is restored; waking Snorlax needs
    -- that card.  They therefore retire a missing historical restored-power
    -- flag without pretending that unrelated Kanto badges prove the plant was
    -- fixed.
    local powerStorySatisfied = st.restoredPower or st.hasExpnCard or st.foughtSnorlax
    local managerStorySatisfied = st.metPowerPlantManager or powerStorySatisfied
    local ceruleanRocketStorySatisfied = st.metCeruleanRocket or powerStorySatisfied

    -- Mt. Moon and Oak's first Kanto check-in are canonical route beats, but
    -- neither is a permanent movement gate.  Once the save has demonstrably
    -- reached the later Pallet/Cinnabar half, missing historical bits are
    -- treated as stale history rather than instructions to backtrack.
    local mtMoonHistoryObsolete = st.beatRivalMtMoon or st.talkedOakKanto
      or st.talkedBlueCinnabar or k.volcano or k.earth
    local oakKantoHistoryObsolete = st.talkedOakKanto
      or st.talkedBlueCinnabar or k.volcano or k.earth

    -- 1. Vermilion / Lt. Surge is the first canonical Kanto beat after the
    -- maiden S.S. Aqua crossing.  Do not send a new arrival to Power Plant.
    if not k.thunder then
      if map == "VERMILION_GYM" then
        return objective("GOLD_SURGE", "VERMILION GYM",
          "Defeat Lt. Surge and earn the Thunder Badge.",
          "Clear the Vermilion Gym trainers and defeat Lt. Surge for your first Kanto badge.")
      end
      return objective("GOLD_SURGE_ROUTE", "VERMILION CITY",
        "Go to Vermilion Gym and challenge Lt. Surge.",
        "After leaving the S.S. Aqua, explore/heal if needed, then enter Vermilion Gym for the Thunder Badge before heading north to Saffron.")
    end

    -- 2. Vermilion -> Route 6 -> Saffron -> Sabrina.
    if not k.marsh then
      if map == "VERMILION_CITY" then
        return objective("GOLD_SAFFRON_ROUTE6", "VERMILION CITY",
          "Leave Vermilion to the north onto Route 6.",
          "Follow Route 6 north to the Saffron gate. The Underground Path door may be blocked; the checkpoint road to Saffron is the intended route.")
      end
      if map == "ROUTE_6" then
        return objective("GOLD_SAFFRON_ROUTE6_NORTH", "ROUTE 6",
          "Continue north through the Route 6 gate into Saffron City.",
          "Use the checkpoint house at the north end of Route 6. Saffron Gym is your next main objective.")
      end
      if map == "ROUTE_6_SAFFRON_GATE" then
        return objective("GOLD_SAFFRON_GATE", "SAFFRON GATE",
          "Walk north through the gate into Saffron City.",
          "Nothing here blocks entry. Once in Saffron, head for Sabrina's Gym in the northeast.")
      end
      if map == "SAFFRON_GYM" then
        return objective("GOLD_SABRINA", "SAFFRON GYM",
          "Navigate the warp panels and defeat Sabrina.",
          "Finish Saffron Gym and earn the Marsh Badge.")
      end
      return objective("GOLD_SABRINA_ROUTE", "SAFFRON CITY",
        "Go to Saffron Gym and challenge Sabrina.",
        "From Vermilion travel north through Route 6. In Saffron, enter the Gym and earn the Marsh Badge.")
    end

    -- 3. Power Plant -> Cerulean Rocket -> Route 24 -> Misty date -> Machine
    -- Part -> Misty -> return the part.  These are separate lifecycle checks.
    if not powerStorySatisfied or not k.cascade then
      if not managerStorySatisfied then
        if map == "SAFFRON_CITY" then
          return objective("GOLD_POWER_ROUTE5", "SAFFRON CITY",
            "Leave Saffron north through the Route 5 gate toward Cerulean.",
            "Pass Route 5 north into Cerulean City. From there the Power Plant route continues east on Route 9.")
        end
        if map == "ROUTE_5" or map == "ROUTE_5_SAFFRON_GATE" then
          return objective("GOLD_POWER_CERULEAN", "ROUTE 5",
            "Continue north from Route 5 into Cerulean City.",
            "Once in Cerulean, leave east onto Route 9. The empty Gym is not ready yet; Power Plant comes first.")
        end
        if map == "CERULEAN_CITY" then
          return objective("GOLD_POWER_ROUTE9", "CERULEAN CITY",
            "Leave Cerulean to the east onto Route 9.",
            "Use CUT at the west entrance if needed, then follow Route 9 east and drop south into Route 10 North.")
        end
        if map == "ROUTE_9" then
          return objective("GOLD_POWER_ROUTE10", "ROUTE 9",
            "Follow Route 9 east, then continue south onto Route 10 North.",
            "At Route 10, Surf down the river to the Power Plant entrance.")
        end
        if map == "ROUTE_10_NORTH" then
          return objective("GOLD_POWER_SURF_RIVER", "ROUTE 10 NORTH",
            "Surf down the river and enter the Power Plant.",
            "The Power Plant door is reached from the river on Route 10 North. Speak with the Manager inside.")
        end
        if map == "POWER_PLANT" then
          return objective("GOLD_POWER_PLANT_MANAGER", "POWER PLANT",
            "Find the Manager and hear his missing Machine Part report.",
            "Talking to the Manager arms the Cerulean Rocket scene and activates the hidden Machine Part pickup.")
        end
        return objective("GOLD_POWER_PLANT_ROUTE", "CERULEAN / ROUTES 9-10",
          "Travel through Cerulean, Route 9 and Route 10 North to the Power Plant.",
          "Speak with the Manager to begin the Machine Part investigation.")
      end

      if not ceruleanRocketStorySatisfied then
        if map == "POWER_PLANT" then
          return objective("GOLD_CERULEAN_RETURN_FROM_POWER", "CERULEAN CITY",
            "Leave the Power Plant and return to Cerulean City.",
            "After the Manager's report, go back to Cerulean and enter its Gym. The fleeing Rocket scene triggers on entry.")
        end
        if map == "CERULEAN_GYM" then
          return objective("GOLD_CERULEAN_ROCKET", "CERULEAN GYM",
            "Enter the Gym and let the fleeing Rocket Grunt scene play.",
            "This cutscene sends the Rocket to Route 24 and activates Misty's Route 25 sequence.")
        end
        return objective("GOLD_CERULEAN_ROCKET_ROUTE", "CERULEAN GYM",
          "Return to Cerulean City and enter the Gym.",
          "The Manager's report has armed a one-time Rocket escape scene inside Cerulean Gym.")
      end

      if not st.route24RocketDefeated then
        if map == "ROUTE_24" then
          return objective("GOLD_MISTY_ROUTE24_ROCKET", "ROUTE 24",
            "Find and defeat the Rocket Grunt on Route 24.",
            "Continue north from Cerulean onto the old Nugget Bridge and defeat the fleeing Grunt before looking for Misty.")
        end
        return objective("GOLD_MISTY_ROUTE24_ROCKET", "ROUTE 24",
          "Leave Cerulean north and defeat the fleeing Rocket on Route 24.",
          "The Route 24 battle is a separate mandatory checkpoint. Misty's date should not be targeted until this Grunt is defeated.")
      end

      if not st.mistyDateComplete then
        if map == "ROUTE_25" then
          return objective("GOLD_MISTY_ROUTE25", "ROUTE 25",
            "Continue east along Route 25 until you trigger Misty's date scene.",
            "Reach Misty near the far east side. The cutscene sends her back to Cerulean Gym and makes the Gym trainers appear.")
        end
        return objective("GOLD_MISTY_ROUTE25", "ROUTE 25",
          "Continue north from Route 24 onto Route 25 and find Misty.",
          "Follow Route 25 east until the date cutscene plays. That is the durable gate for Misty's return to her Gym.")
      end

      if not powerStorySatisfied and not st.foundMachinePart then
        if map == "CERULEAN_GYM" then
          return objective("GOLD_MACHINE_PART", "CERULEAN GYM",
            "Recover the hidden MACHINE PART from the Gym pool.",
            "Face the hidden-item tile in the pool area and press A. The Manager has already armed this pickup; make sure the Machine Part enters your Pack.")
        end
        return objective("GOLD_MACHINE_PART_RETURN_GYM", "CERULEAN GYM",
          "Return to Cerulean Gym and recover the hidden MACHINE PART.",
          "Misty's date is complete and the Gym is populated. Search the pool area for the hidden Machine Part before leaving this story arc.")
      end

      if not k.cascade then
        if map == "CERULEAN_GYM" then
          return objective("GOLD_MISTY", "CERULEAN GYM",
            "Defeat Misty and earn the Cascade Badge.",
            "The Route 25 date has returned Misty to the Gym. Defeat her after recovering the Machine Part.")
        end
        return objective("GOLD_MISTY_RETURN_GYM", "CERULEAN GYM",
          "Return to Cerulean Gym and defeat Misty.",
          "Misty is back from Route 25. Earn the Cascade Badge before continuing the Kanto route.")
      end

      if not powerStorySatisfied then
        if map == "POWER_PLANT" then
          return objective("GOLD_RETURN_MACHINE_PART", "POWER PLANT",
            "Give the MACHINE PART back to the Manager.",
            "Returning it restores Kanto's power and unlocks the Lavender radio expansion needed for Snorlax later.")
        end
        return objective("GOLD_RETURN_MACHINE_PART", "POWER PLANT",
          "Return the MACHINE PART to the Power Plant Manager.",
          "Travel back through Route 9/10 and hand over the part to restore Kanto's power.")
      end
    end

    -- 4. Restored power -> Rock Tunnel -> Lavender -> EXPN Card.
    if not st.hasExpnCard then
      if map == "POWER_PLANT" then
        return objective("GOLD_EXPN_LEAVE_POWER", "ROCK TUNNEL",
          "Leave the Power Plant and return toward the Rock Tunnel entrance.",
          "Go back to Route 10 North/Route 9 and enter Rock Tunnel. The through-route exits on Route 10 South above Lavender.")
      end
      if map == "ROUTE_9" or map == "ROUTE_10_NORTH" then
        return objective("GOLD_EXPN_ROCK_TUNNEL", "ROCK TUNNEL",
          "Enter Rock Tunnel and travel through to its southern exit.",
          "FLASH is useful inside. Follow the cave through to Route 10 South, then continue south to Lavender Town.")
      end
      if goldMapHas(s, "ROCK_TUNNEL") then
        return objective("GOLD_EXPN_ROCK_TUNNEL_INSIDE", "ROCK TUNNEL",
          "Continue through Rock Tunnel toward Route 10 South.",
          "Work through 1F/B1F until you reach the southern exit. Optional item loops are not required for the story route.")
      end
      if map == "ROUTE_10_SOUTH" then
        return objective("GOLD_EXPN_LAVENDER", "ROUTE 10 SOUTH",
          "Follow Route 10 South into Lavender Town.",
          "Lavender is directly south. Enter its Radio Tower after arriving.")
      end
      if map == "LAV_RADIO_TOWER_1F" then
        return objective("GOLD_EXPN_CARD", "LAVENDER RADIO TOWER",
          "Talk to the Radio Director and receive the EXPN CARD.",
          "Restored power makes this reward available. The EXPN Card unlocks the Kanto Poke Flute radio channel.")
      end
      return objective("GOLD_EXPN_CARD_ROUTE", "LAVENDER TOWN",
        "Reach Lavender through Rock Tunnel and visit the Radio Tower.",
        "With power restored, talk to the Radio Director on 1F for the EXPN Card.")
    end

    -- 5. Lavender/Saffron/Route 7 -> Celadon -> Erika.
    if not k.rainbow then
      if map == "LAVENDER_TOWN" then
        return objective("GOLD_CELADON_ROUTE8", "LAVENDER TOWN",
          "Leave Lavender to the west onto Route 8.",
          "Follow Route 8 west through the Saffron gate, cross Saffron, then use the Route 7 west gate toward Celadon.")
      end
      if map == "ROUTE_8" or map == "ROUTE_8_SAFFRON_GATE" then
        return objective("GOLD_CELADON_SAFFRON", "ROUTE 8",
          "Continue west through the gate into Saffron City.",
          "Cross Saffron from east to west and take the Route 7 gate on the opposite side.")
      end
      if map == "SAFFRON_CITY" then
        return objective("GOLD_CELADON_ROUTE7", "SAFFRON CITY",
          "Leave Saffron to the west through the Route 7 gate.",
          "Route 7 is a short connector. Continue west from it into Celadon City.")
      end
      if map == "ROUTE_7" or map == "ROUTE_7_SAFFRON_GATE" then
        return objective("GOLD_CELADON_CITY_ROUTE", "ROUTE 7",
          "Continue west into Celadon City.",
          "Once in Celadon, head to the Gym in the southwest part of town.")
      end
      if map == "CELADON_GYM" then
        return objective("GOLD_ERIKA", "CELADON GYM",
          "Defeat Erika and earn the Rainbow Badge.",
          "Clear the Grass-type Gym and defeat Erika for the Rainbow Badge.")
      end
      return objective("GOLD_ERIKA_ROUTE", "CELADON CITY",
        "Go to Celadon Gym and challenge Erika.",
        "From Lavender travel west through Saffron and Route 7. In Celadon, defeat Erika for the Rainbow Badge.")
    end

    -- 6. Canonical road to Fuchsia uses Lavender -> Routes 12-15; it does not
    -- require assuming the player picked up the Bicycle in Goldenrod.
    if not k.soul then
      if map == "CELADON_CITY" then
        return objective("GOLD_FUCHSIA_RETURN_LAVENDER", "LAVENDER TOWN",
          "Return to Lavender Town to start the southern road to Fuchsia.",
          "Use FLY if available, or travel back east through Route 7/Saffron/Route 8. From Lavender the route runs south along Route 12.")
      end
      if map == "LAVENDER_TOWN" then
        return objective("GOLD_FUCHSIA_ROUTE12", "LAVENDER TOWN",
          "Leave Lavender to the south onto Route 12.",
          "Follow the long fishing route south. Continue through Routes 13, 14 and 15 toward Fuchsia City.")
      end
      if map == "ROUTE_12" then
        return objective("GOLD_FUCHSIA_ROUTE13", "ROUTE 12",
          "Continue south along Route 12 into Route 13.",
          "The Super Rod house and items are optional. Keep following the main road south.")
      end
      if map == "ROUTE_13" then
        return objective("GOLD_FUCHSIA_ROUTE14", "ROUTE 13",
          "Continue south into Route 14.",
          "Follow the fence maze/trainer route south. Route 14 turns west toward Route 15.")
      end
      if map == "ROUTE_14" then
        return objective("GOLD_FUCHSIA_ROUTE15", "ROUTE 14",
          "Follow Route 14 west onto Route 15.",
          "Keep moving west. Route 15 ends at the Fuchsia checkpoint gate.")
      end
      if map == "ROUTE_15" or map == "ROUTE_15_FUCHSIA_GATE" then
        return objective("GOLD_FUCHSIA_CITY_ROUTE", "ROUTE 15",
          "Continue west through the gate into Fuchsia City.",
          "Once in Fuchsia, heal if needed and head to the Gym.")
      end
      if map == "FUCHSIA_GYM" then
        return objective("GOLD_JANINE", "FUCHSIA GYM",
          "Find the real Janine and defeat her for the Soul Badge.",
          "The Gym uses Janine look-alikes. Defeat the real Leader to earn the Soul Badge.")
      end
      return objective("GOLD_JANINE_ROUTE", "FUCHSIA CITY",
        "Go to Fuchsia Gym and challenge Janine.",
        "The southern Kanto route is complete. Enter Fuchsia Gym and earn the Soul Badge.")
    end

    -- 7. EXPN Card finally pays off at Vermilion Snorlax.
    if not st.foughtSnorlax then
      if map == "VERMILION_CITY" then
        return objective("GOLD_SNORLAX", "VERMILION CITY",
          "Tune the Poke Flute radio channel and wake Snorlax by Diglett's Cave.",
          "Use the Pokegear Radio with the EXPN Card, tune the Poke Flute station and interact with Snorlax. Catching it is optional; the encounter must finish.")
      end
      return objective("GOLD_SNORLAX_ROUTE", "VERMILION CITY",
        "Return to Vermilion City and wake the Snorlax outside Diglett's Cave.",
        "The EXPN Card is ready. Use the Poke Flute radio channel at the Snorlax blocking the cave entrance.")
    end

    -- 8. Diglett's Cave -> Route 2 -> Pewter -> Brock.
    if not k.boulder then
      if map == "VERMILION_CITY" then
        return objective("GOLD_DIGLETTS_CAVE_ENTER", "VERMILION CITY",
          "Enter Diglett's Cave now that Snorlax is gone.",
          "The cave entrance is immediately beyond the former Snorlax roadblock. Follow the cave all the way to Route 2.")
      end
      if map == "DIGLETTS_CAVE" then
        return objective("GOLD_DIGLETTS_CAVE_ROUTE2", "DIGLETT'S CAVE",
          "Continue through Diglett's Cave to the Route 2 exit.",
          "Follow the long cave northward and leave through the far door onto Route 2.")
      end
      if map == "ROUTE_2" then
        return objective("GOLD_PEWTER_ROUTE2", "ROUTE 2",
          "Follow Route 2 north into Pewter City.",
          "Use CUT on the route trees if needed. Pewter is directly north; the Nugget house and item balls are optional.")
      end
      if map == "PEWTER_GYM" then
        return objective("GOLD_BROCK", "PEWTER GYM",
          "Defeat Brock and earn the Boulder Badge.",
          "Defeat Camper Jerry, then Brock for the Boulder Badge.")
      end
      return objective("GOLD_BROCK_ROUTE", "PEWTER CITY",
        "Go to Pewter Gym and challenge Brock.",
        "After Diglett's Cave and Route 2, enter Pewter Gym and earn the Boulder Badge.")
    end

    -- 9. The Mt. Moon rival is the last mandatory rival battle and a useful
    -- thin checkpoint before the Pallet/Cinnabar half of Kanto.
    if not mtMoonHistoryObsolete then
      if map == "PEWTER_CITY" then
        return objective("GOLD_MT_MOON_ROUTE3", "PEWTER CITY",
          "Leave Pewter to the east onto Route 3.",
          "Follow Route 3 east to Mt. Moon. The next mandatory rival encounter triggers inside the cave.")
      end
      if map == "ROUTE_3" then
        return objective("GOLD_MT_MOON_ENTRANCE", "ROUTE 3",
          "Continue east on Route 3 and enter Mt. Moon.",
          "The cave entrance is at the east end of the route. Save/heal first if desired; your rival is waiting inside.")
      end
      if map == "MOUNT_MOON" then
        return objective("GOLD_MT_MOON_RIVAL", "MT. MOON",
          "Defeat your rival in Mt. Moon.",
          "The rival encounter is triggered on entry and cannot be skipped on the normal through-route.")
      end
      return objective("GOLD_MT_MOON_ROUTE", "ROUTE 3 / MT. MOON",
        "Travel east from Pewter through Route 3 and enter Mt. Moon.",
        "Defeat the mandatory rival encounter inside before continuing Kanto.")
    end

    -- 10. Oak's first Kanto conversation is not the final Mt. Silver unlock,
    -- but tracking it gives the player the intended Route 1/Pallet hand-off.
    if not oakKantoHistoryObsolete then
      if map == "VIRIDIAN_CITY" then
        return objective("GOLD_PALLET_ROUTE1", "VIRIDIAN CITY",
          "Leave Viridian to the south onto Route 1.",
          "Follow Route 1 south to Pallet Town and visit Professor Oak's Lab.")
      end
      if map == "ROUTE_1" then
        return objective("GOLD_PALLET_ROUTE1_SOUTH", "ROUTE 1",
          "Continue south on Route 1 to Pallet Town.",
          "Pallet is at the south end. Enter Professor Oak's Lab once you arrive.")
      end
      if map == "PALLET_TOWN" or map == "OAKS_LAB" then
        return objective("GOLD_OAK_KANTO", "PROF. OAK'S LAB",
          "Talk to Professor Oak in Pallet Town.",
          "This is Oak's Kanto-badge check-in. It is distinct from the later 16-badge conversation that actually opens Mt. Silver.")
      end
      return objective("GOLD_OAK_KANTO_ROUTE", "PALLET TOWN",
        "Travel to Viridian, then follow Route 1 south to Pallet Town and visit Oak.",
        "If FLY is available, Viridian is the quickest starting point. Oak's Lab is in Pallet Town at the south end of Route 1.")
    end

    -- 11. Pallet -> Route 21 -> Cinnabar.  Blue's speech should be done before
    -- leaving the island for Blaine because it is the Viridian Gym unlock.
    if not st.talkedBlueCinnabar or not k.volcano then
      if map == "PALLET_TOWN" then
        return objective("GOLD_CINNABAR_ROUTE21", "PALLET TOWN",
          "Surf south from Pallet Town onto Route 21.",
          "Follow Route 21 south through the swimmers until you reach Cinnabar Island.")
      end
      if map == "ROUTE_21" then
        return objective("GOLD_CINNABAR_ROUTE21_SOUTH", "ROUTE 21",
          "Continue Surfing south to Cinnabar Island.",
          "Cinnabar is directly south. Once there, speak with Blue before continuing east to Blaine.")
      end
      if map == "CINNABAR_ISLAND" and not st.talkedBlueCinnabar then
        return objective("GOLD_TALK_BLUE_CINNABAR", "CINNABAR ISLAND",
          "Find Blue on Cinnabar Island and speak with him.",
          "This one-time speech makes Blue leave Cinnabar and unlocks him in Viridian Gym. Do it before moving on to Seafoam Gym.")
      end
      if not st.talkedBlueCinnabar then
        return objective("GOLD_TALK_BLUE_CINNABAR_ROUTE", "CINNABAR ISLAND",
          "Return to Cinnabar Island and speak with Blue.",
          "Blue's speech is still missing. Reach Cinnabar from Pallet via Route 21, find Blue on the island and talk to him before attempting Viridian Gym.")
      end
      if not k.volcano then
        if map == "CINNABAR_ISLAND" then
          return objective("GOLD_BLAINE_ROUTE20", "CINNABAR ISLAND",
            "Leave Cinnabar to the east onto Route 20 and Surf toward Seafoam Gym.",
            "Blaine's relocated Gym is in the Seafoam cave on Route 20. Continue east over the water.")
        end
        if map == "ROUTE_20" then
          return objective("GOLD_BLAINE_SEAFOAM", "ROUTE 20",
            "Surf east along Route 20 and enter Seafoam Gym.",
            "The Gym entrance is on the route's cave island. Enter and challenge Blaine.")
        end
        if map == "SEAFOAM_GYM" then
          return objective("GOLD_BLAINE", "SEAFOAM GYM",
            "Defeat Blaine and earn the Volcano Badge.",
            "Blaine is the only Leader in this small relocated Gym. Defeat him for the Volcano Badge.")
        end
        return objective("GOLD_BLAINE_ROUTE", "CINNABAR / ROUTE 20",
          "Reach Cinnabar from Pallet/Route 21, then Surf east on Route 20 to Seafoam Gym.",
          "Speak with Blue on Cinnabar if you have not already, then defeat Blaine.")
      end
    end

    -- 12. Viridian Gym / Blue.
    if not k.earth then
      if map == "VIRIDIAN_GYM" then
        return objective("GOLD_BLUE", "VIRIDIAN GYM",
          "Defeat Blue and earn the Earth Badge.",
          "Blue is present because you spoke with him on Cinnabar. Defeat him for your 16th badge.")
      end
      return objective("GOLD_BLUE_ROUTE", "VIRIDIAN CITY",
        "Travel to Viridian City and enter Viridian Gym.",
        "After Blue's Cinnabar speech and Blaine's badge, return to Viridian and defeat Blue for the Earth Badge.")
    end

    return nil
  end

  local function resolveGoldNormalized(s)
    local st, j, k = s.story, s.badges.johto, s.badges.kanto
    local contextual = goldContextObjective(s)
    if contextual then return contextual, s end

    -- Durable downstream proofs suppress obsolete HISTORY, but never invent a
    -- missing current resource/badge.  These are explicit implications rather
    -- than a global stage or badge-count heuristic.
    local violetHistoryObsolete = j.zephyr or j.hive or j.plain or j.fog
      or j.mineral or j.storm or j.glacier or j.rising
      or st.clearedSlowpokeWell or st.herdedFarfetchd or st.foughtSudowoodo
      or st.clearedRocketHideout or st.clearedRadioTower or st.beatEliteFour
      or st.gotSsTicket or st.fastShipFirstTime or st.openedMtSilver or st.redDefeated
    local wellHistoryObsolete = st.clearedSlowpokeWell or j.hive or j.plain or j.fog
      or j.mineral or j.storm or j.glacier or j.rising
      or st.herdedFarfetchd or st.foughtSudowoodo or st.clearedRocketHideout
      or st.clearedRadioTower or st.beatEliteFour or st.openedMtSilver or st.redDefeated
    local ilexHistoryObsolete = j.plain or j.fog or j.mineral or j.storm
      or j.glacier or j.rising or st.foughtSudowoodo or st.clearedRocketHideout
      or st.clearedRadioTower or st.beatEliteFour or st.openedMtSilver or st.redDefeated
    local sudowoodoHistoryObsolete = st.foughtSudowoodo or j.fog or j.mineral
      or j.storm or j.glacier or j.rising or st.clearedRocketHideout
      or st.clearedRadioTower or st.beatEliteFour or st.openedMtSilver or st.redDefeated
    local anyKantoBadge = k.boulder or k.cascade or k.thunder or k.rainbow
      or k.soul or k.marsh or k.volcano or k.earth
    local hardKantoProof = st.fastShipFirstTime or anyKantoBadge
      or st.metPowerPlantManager or st.metCeruleanRocket or st.foundMachinePart
      or st.restoredPower or st.hasExpnCard or st.foughtSnorlax
      or st.talkedBlueCinnabar or st.openedMtSilver or st.redDefeated
    local postLeagueProof = st.beatEliteFour or st.gotSsTicket or hardKantoProof

    -- Final downstream proof dominates every missing historical flag.
    if st.redDefeated then
      return objective("GOLD_MAIN_COMPLETE", "MT. SILVER",
        "Main adventure complete: Red has been defeated.",
        "Explore freely or use the following HELP pages for tracked optional content you have not completed.", "POSTGAME"), s
    end
    if st.openedMtSilver then
      return objective("GOLD_RED", "MT. SILVER",
        "Travel to Mt. Silver, climb Silver Cave and defeat Red.",
        "Mt. Silver access is already unlocked, so the earlier 16-badge and Oak steps are complete."), s
    end

    if not postLeagueProof then
    if not st.gotStarter and not violetHistoryObsolete then
      return goldOpeningObjective(s), s
    end

    if not st.gotMysteryEgg and not violetHistoryObsolete then
      return goldMrPokemonRouteObjective(s), s
    end
    if not st.gaveMysteryEgg and not violetHistoryObsolete then
      return goldReturnElmRouteObjective(s), s
    end

    if not j.zephyr then
      return goldVioletRouteObjective(s), s
    end

    -- Unlike the old R3 model, Elm's aide Egg is a mandatory Gold story
    -- transition: taking it changes Route 32 out of its blocking scene.
    local togepiHistoryObsolete = st.gotTogepiEgg or j.hive or j.plain or j.fog
      or j.mineral or j.storm or j.glacier or j.rising or st.clearedSlowpokeWell
      or st.beatEliteFour or st.openedMtSilver or st.redDefeated
    if not togepiHistoryObsolete then
      return goldTogepiEggObjective(s), s
    end

    if not wellHistoryObsolete then
      return goldAzaleaRouteObjective(s), s
    end
    if not j.hive then
      return goldBugsyObjective(s), s
    end

    if not ilexHistoryObsolete and (not st.herdedFarfetchd or not s.hms.cut or not s.abilities.cut or not j.plain) then
      return goldIlexObjective(s), s
    end

    if not j.plain then
      return objective("GOLD_WHITNEY", "GOLDENROD GYM",
        "Defeat Whitney and obtain the Plain Badge.",
        "Challenge Whitney in Goldenrod. Speak with her again after she stops crying so the badge is actually awarded."), s
    end
    if not goldEvent(s.raw, liveGame, "EVENT_GOT_SQUIRTBOTTLE") and not sudowoodoHistoryObsolete then
      return objective("GOLD_SQUIRTBOTTLE", "GOLDENROD FLOWER SHOP",
        "Visit the Goldenrod Flower Shop and get the SQUIRTBOTTLE.",
        "After Whitney, talk to the teacher in the Flower Shop. The SquirtBottle is the key item needed for the Route 36 tree."), s
    end
    if not sudowoodoHistoryObsolete then
      return goldSudowoodoRouteObjective(s), s
    end

    if not j.fog then
      return goldEcruteakEarlyObjective(s), s
    end
    if not j.rising and not st.beatClair and not s.abilities.surf then
      return objective("GOLD_TEACH_SURF", "PARTY",
        "Teach SURF to a Pokemon before taking the water routes west of Ecruteak.",
        "HM03 and the Fog Badge are present, but a current non-Egg party member still needs to know SURF."), s
    end

    -- Midgame is a dependency graph, not a stage.  Follow whichever legitimate
    -- branch the player's current location shows they already chose.
    local olivine = goldOlivineBranch(s)
    local mahogany = goldMahoganyBranch(s)
    if olivine or mahogany then
      local inMahogany = goldMapHasAny(s, { "MAHOGANY", "ROUTE_42", "ROUTE_43", "LAKE_OF_RAGE", "TEAM_ROCKET_BASE" })
      local inOlivine = goldMapHasAny(s, { "OLIVINE", "CIANWOOD", "ROUTE_38", "ROUTE_39", "ROUTE_40", "ROUTE_41", "LIGHTHOUSE" })
      if inMahogany and mahogany then return mahogany, s end
      if inOlivine and olivine then return olivine, s end
      if olivine then return olivine, s end
      return mahogany, s
    end

    if not st.clearedRadioTower and not j.rising then
      if st.rocketsInRadioTower then
        return goldRadioTowerStep(s), s
      end
      return objective("GOLD_RADIO_TOWER_TRIGGER", "JOHTO",
        "Continue until Prof. Elm's Rocket takeover call triggers.",
        "With seven Johto badges complete, leave the current area and follow the actual Rocket takeover trigger. HELP will not reveal the Radio Tower arc before that flag is active."), s
    end

    if not j.rising then
      -- Ice Path B1F has a mandatory Strength boulder-into-hole puzzle in the
      -- audited Gold route.  Do not confuse owning HM04 with having a usable
      -- field move; imported saves may preserve either side independently.
      if not s.abilities.strength then
        if not s.hms.strength then
          return objective("GOLD_HM04_STRENGTH_ICE_PATH", "OLIVINE CAFE",
            "Get HM04 STRENGTH before crossing Ice Path.",
            "Ice Path B1F requires a usable STRENGTH user for its boulder puzzle. HM04 is obtained in the Olivine Cafe."), s
        end
        return objective("GOLD_TEACH_STRENGTH_ICE_PATH", "PARTY",
          "Teach STRENGTH to a Pokemon before crossing Ice Path.",
          "You have HM04 and the Plain Badge, but no current non-Egg party member knows STRENGTH. Ice Path B1F needs it."), s
      end
      if not s.hms.waterfall then
        return objective("GOLD_ICE_PATH", "ROUTE 44 / ICE PATH",
          "Cross Ice Path and pick up HM07 WATERFALL.",
          "HM07 is mandatory for the later road to the Pokemon League; continue through Ice Path to Blackthorn City."), s
      end
      if not st.beatClair then
        return objective("GOLD_CLAIR", "BLACKTHORN GYM", "Defeat Clair.",
          "Defeating Clair does not award the Rising Badge yet; her required Dragon's Den sequence follows."), s
      end
      if not s.abilities.surf then
        return objective("GOLD_TEACH_SURF_DRAGONS_DEN", "PARTY",
          "Make sure a Pokemon can use SURF before entering Dragon's Den.",
          "The required Dragon Fang route uses water. HM03, the Fog Badge and a current party SURF user are all needed."), s
      end
      if not s.abilities.whirlpool then
        if not s.hms.whirlpool then
          return objective("GOLD_HM06_WHIRLPOOL", "MAHOGANY / TEAM ROCKET BASE",
            "Recover HM06 WHIRLPOOL before finishing Dragon's Den.",
            "The normal Gold route awards HM06 after clearing the Team Rocket Base. Dragon's Den needs WHIRLPOOL on the route to the Dragon Fang."), s
        end
        return objective("GOLD_TEACH_WHIRLPOOL", "PARTY",
          "Teach WHIRLPOOL to a Pokemon before finishing Dragon's Den.",
          "You have HM06 and the Glacier Badge, but no current non-Egg party member knows WHIRLPOOL."), s
      end
      return objective("GOLD_DRAGONS_DEN", "DRAGON'S DEN",
        "Complete Clair's Dragon's Den requirement and receive the Rising Badge.",
        "Finish the required Den sequence. The Rising Badge, not the Clair battle flag alone, is the authority for eight-badge completion."), s
    end

    if not postLeagueProof then
      if not s.abilities.surf then
        if not s.hms.surf then
          return objective("GOLD_KIMONO_GIRLS_LEAGUE", "ECRUTEAK DANCE THEATER",
            "Get HM03 SURF before taking the road to the Pokemon League.",
            "The route east of New Bark begins with water. A current party SURF user is mandatory."), s
        end
        return objective("GOLD_TEACH_SURF_LEAGUE", "PARTY",
          "Teach SURF to a Pokemon before taking the road to the Pokemon League.",
          "HM03 ownership alone is not enough; the Fog Badge and a current party SURF user are required east of New Bark."), s
      end
      if not s.abilities.waterfall then
        if not s.hms.waterfall then
          return objective("GOLD_ICE_PATH_HM07_LEAGUE", "ICE PATH",
            "Return for HM07 WATERFALL before crossing Tohjo Falls.",
            "HM07 is a mandatory pickup in Ice Path for the League road."), s
        end
        return objective("GOLD_TEACH_WATERFALL", "PARTY",
          "Teach WATERFALL to a Pokemon before crossing Tohjo Falls.",
          "You have HM07 and the Rising Badge, but no current non-Egg party member knows WATERFALL."), s
      end
      if not st.victoryRoadRival and goldMapHas(s, "VICTORY_ROAD") then
        return objective("GOLD_VICTORY_ROAD_RIVAL", "VICTORY ROAD",
          "Reach the exit and defeat your rival.",
          "Continue through Victory Road; the final Johto rival encounter is the last story battle before Indigo Plateau."), s
      end
      return objective("GOLD_POKEMON_LEAGUE", "INDIGO PLATEAU",
        "Cross Tohjo Falls and Victory Road, then challenge the Pokemon League.",
        "Use SURF and WATERFALL east of New Bark, follow Routes 27 and 26, pass the eight-badge gate and reach Indigo Plateau."), s
    end

    end -- not postLeagueProof: every Johto historical objective is obsolete afterward

    -- Kanto boundary: never leak Kanto objectives before Hall of Fame proof.
    if not s.access.kantoReached and not hardKantoProof then
      if not st.gotSsTicket then
        return objective("GOLD_SS_TICKET", "ELM'S LAB",
          "Return to Professor Elm and receive the S.S. Ticket.",
          "After entering the Hall of Fame, Elm gives the ticket that opens the route to Kanto."), s
      end
      return objective("GOLD_BOARD_SS_AQUA", "OLIVINE PORT",
        "Board the S.S. Aqua for Vermilion City.",
        "Take the S.S. Ticket to Olivine Port and complete the maiden voyage's required ship quest."), s
    end

    local kantoObjective = goldKantoRouteObjective(s)
    if kantoObjective then return kantoObjective, s end

    if not st.openedMtSilver then
      return objective("GOLD_OPEN_MT_SILVER", "PROF. OAK'S LAB",
        "Return to Prof. Oak after collecting all 16 badges.",
        "Speak with Oak in Pallet Town to open the route to Mt. Silver."), s
    end
    if not st.redDefeated then
      return objective("GOLD_RED", "MT. SILVER",
        "Travel to Mt. Silver, climb Silver Cave and defeat Red.",
        "Use the newly opened western route from the Victory Road Gate and climb Mt. Silver for the final main-story battle."), s
    end

    return objective("GOLD_MAIN_COMPLETE", "MT. SILVER",
      "Main adventure complete: Red has been defeated.",
      "Explore freely or use the following HELP pages for tracked optional content you have not completed.", "POSTGAME"), s
  end

  local function resolveGold(save, game)
    local s = normalizeGold(save, game)
    return resolveGoldNormalized(s)
  end

  local function addGoldPage(pages, seen, obj, role)
    if not obj or seen[obj.id] then return end
    obj.pageRole = role or (obj.kind == "CONTEXT" and "CONTEXT" or "OPTION")
    seen[obj.id] = true
    pages[#pages + 1] = obj
  end

  local function resolveAllGold(save, game)
    local primary, s = resolveGold(save, game)
    local pages, seen = {}, {}
    addGoldPage(pages, seen, primary, primary.kind == "CONTEXT" and "CONTEXT" or "PRIMARY")

    local st, j, k = s.story, s.badges.johto, s.badges.kanto
    -- Johto midgame: explicitly surface the other legitimate branch.
    if j.fog and not st.clearedRadioTower then
      local olivine, mahogany = goldOlivineBranch(s), goldMahoganyBranch(s)
      addGoldPage(pages, seen, olivine, "OPTION")
      addGoldPage(pages, seen, mahogany, "OPTION")
    end

    -- Significant optional content only after its own access evidence exists.
    if j.zephyr and not st.ruinsComplete then
      local summary, details
      if st.ruinsPuzzleCount == 0 then
        summary = "Optional: explore the Ruins of Alph and try the first picture puzzle."
        details = "The Kabuto chamber is available during the early Johto route. The Ruins never block the main story."
      elseif not st.unownDexUnlocked and st.unownCount < 3 then
        summary = ("Optional: continue the Ruins and record different Unown forms (%d/3)."):format(st.unownCount)
        details = ("%d of 4 picture puzzles are solved. Three different Unown forms unlock the Research Center milestone; the remaining puzzles can be revisited later."):format(st.ruinsPuzzleCount)
      elseif not st.unownDexUnlocked then
        summary = "Optional: visit the Ruins researcher for the UNOWN DEX upgrade."
        details = ("You have recorded %d different Unown forms and solved %d of 4 picture puzzles."):format(st.unownCount, st.ruinsPuzzleCount)
      else
        summary = ("Optional: continue the remaining Ruins of Alph picture puzzles (%d/4 solved)."):format(st.ruinsPuzzleCount)
        details = "The UNOWN DEX milestone is already complete. HELP does not require catching all 26 forms; that is completionist content."
      end
      addGoldPage(pages, seen, objective("GOLD_OPTION_RUINS", "RUINS OF ALPH",
        summary, details, "OPTIONAL"), "OPTION")
    end

    if st.releasedBeasts and st.roamersRemaining ~= 0 then
      local detail = st.roamersRemaining and
        ("Raikou, Entei and Suicune roam Johto; %d of 3 remain. HELP does not reveal live positions."):format(st.roamersRemaining)
        or "Raikou, Entei and Suicune roam Johto after their release. HELP does not reveal live positions."
      addGoldPage(pages, seen, objective("GOLD_OPTION_ROAMERS", "JOHTO",
        "Optional: search for the roaming legendary beasts.", detail, "OPTIONAL"), "OPTION")
    end
    if j.rising and not st.gotMasterBall then
      addGoldPage(pages, seen, objective("GOLD_OPTION_MASTER_BALL", "ELM'S LAB",
        "Optional reward: return to Elm for the MASTER BALL.",
        "Elm offers this reward after the Rising Badge. It is useful but never blocks the road to the Pokemon League.", "OPTIONAL"), "OPTION")
    end
    if s.abilities.surf and not st.unionCaveLaprasUsed then
      addGoldPage(pages, seen, objective("GOLD_OPTION_FRIDAY_LAPRAS", "UNION CAVE B2F",
        "Optional: on Friday, visit Union Cave B2F for the Lapras encounter.",
        "Lapras appears at the water's edge on Friday. This page hides after the current weekly encounter has been used.", "OPTIONAL"), "OPTION")
    end
    if j.rising and not st.gotTyrogue then
      local summary = s.access.partySpace
        and "Optional: explore Mt. Mortar and defeat Blackbelt Kiyo for Tyrogue."
        or "Optional: make room in your party, then return to Mt. Mortar for Kiyo's Tyrogue."
      addGoldPage(pages, seen, objective("GOLD_OPTION_TYROGUE", "MT. MORTAR",
        summary, "Tyrogue is a one-time gift and requires an open party slot. Mt. Mortar is not part of the mandatory story.", "OPTIONAL"), "OPTION")
    end
    if j.rising and not st.gotBlackglassesDarkCave then
      addGoldPage(pages, seen, objective("GOLD_OPTION_DARK_CAVE", "DARK CAVE",
        "Optional: explore Dark Cave from the Blackthorn side.",
        "The tracked optional milestone is the Blackglasses gift. This route does not gate the Pokemon League.", "OPTIONAL"), "OPTION")
    end
    if st.gotRainbowWing and not st.foughtHoOh then
      addGoldPage(pages, seen, objective("GOLD_OPTION_HO_OH", "TIN TOWER",
        "Optional: climb Tin Tower and encounter Ho-Oh.",
        "The Rainbow Wing unlocks Gold's main legendary route; it is not required for the Pokemon League.", "OPTIONAL"), "OPTION")
    end
    if st.gotSilverWing and not st.foughtLugia then
      addGoldPage(pages, seen, objective("GOLD_OPTION_LUGIA", "WHIRL ISLANDS",
        "Optional: explore Whirl Islands and encounter Lugia.",
        "Show this only after the Silver Wing access evidence exists; it never blocks Mt. Silver.", "OPTIONAL"), "OPTION")
    end

    -- Kanto gyms are a set, not a stage.  Show currently valid alternatives
    -- without demoting them to UNFINISHED while the main Kanto graph continues.
    if s.access.kantoReached then
      if not k.thunder then addGoldPage(pages, seen, goldKantoGymObjective("thunder"), "OPTION") end
      if not k.marsh then addGoldPage(pages, seen, goldKantoGymObjective("marsh"), "OPTION") end
      if not k.rainbow then addGoldPage(pages, seen, goldKantoGymObjective("rainbow"), "OPTION") end
      if not k.soul then addGoldPage(pages, seen, goldKantoGymObjective("soul"), "OPTION") end
      if st.metCeruleanRocket and not k.cascade then addGoldPage(pages, seen, goldMistyObjective(s), "OPTION") end
      if st.foughtSnorlax and not k.boulder then addGoldPage(pages, seen, goldKantoGymObjective("boulder"), "OPTION") end
      if not k.volcano then addGoldPage(pages, seen, goldKantoGymObjective("volcano"), "OPTION") end
      if st.talkedBlueCinnabar and not k.earth then addGoldPage(pages, seen, goldKantoGymObjective("earth"), "OPTION") end
    end

    -- A contradictory/imported save may already have Snorlax downstream proof
    -- while retaining an unfinished Power Plant chain.  That chain must never
    -- block main Kanto progression again, but if the player actually started
    -- it we may preserve it as an explicit OPTION.
    if s.access.kantoReached and st.foughtSnorlax and not st.restoredPower
        and st.metPowerPlantManager then
      local summary, details
      if not st.metCeruleanRocket then
        summary = "Optional cleanup: continue the Power Plant investigation in Cerulean Gym."
        details = "Snorlax is already resolved, so this no longer gates main progression. The started Machine Part chain can still be finished for consistency."
      elseif not st.foundMachinePart then
        summary = "Optional cleanup: finish the Route 24 Rocket step and recover the MACHINE PART."
        details = "This started chain is historically unfinished, but downstream Snorlax proof means HELP will not block Kanto on it."
      else
        summary = "Optional cleanup: return the MACHINE PART to the Power Plant."
        details = "Complete the started restoration chain if you want; downstream Snorlax proof already satisfies the main access dependency."
      end
      addGoldPage(pages, seen, objective("GOLD_OPTION_POWER_PLANT_UNFINISHED", "POWER PLANT",
        summary, details, "OPTIONAL"), "OPTION")
    end

    -- Copycat / Magnet Train is a utility side-chain.  Do not spoil it until
    -- the player has actually learned about Copycat's lost item.
    if s.access.kantoReached and st.metCopycatLostItem and not st.gotMagnetTrainPass then
      if not st.gotLostItem then
        addGoldPage(pages, seen, objective("GOLD_OPTION_COPYCAT_LOST_ITEM", "VERMILION FAN CLUB",
          "Optional: recover Copycat's LOST ITEM from the Vermilion Fan Club.",
          "Copycat has already told you what is missing. Retrieve the doll from Vermilion, then take it back to Saffron.", "OPTIONAL"), "OPTION")
      elseif not st.returnedLostItem then
        addGoldPage(pages, seen, objective("GOLD_OPTION_COPYCAT_RETURN", "COPYCAT'S HOUSE",
          "Optional: return the LOST ITEM to Copycat in Saffron.",
          "Returning the doll completes the side quest and awards the Magnet Train Pass.", "OPTIONAL"), "OPTION")
      else
        addGoldPage(pages, seen, objective("GOLD_OPTION_COPYCAT_PASS", "COPYCAT'S HOUSE",
          "Optional: finish Copycat's reward conversation and receive the PASS.",
          "The returned-item proof exists but the Pass proof does not; finish the conversation before leaving.", "OPTIONAL"), "OPTION")
      end
    end

    -- Gold route cleanup is generated from the live Gen 2 map data.  Johto
    -- routes 29-46 and the Kanto routes present in Gold share one path; only
    -- current/observed routes are surfaced, and completed totals disappear.
    for n = 1, 28 do
      addGoldPage(pages, seen, goldRouteTrainerObjective(s, game, "ROUTE_" .. n), "ROUTE")
    end
    for n = 29, 46 do
      addGoldPage(pages, seen, goldRouteTrainerObjective(s, game, "ROUTE_" .. n), "ROUTE")
    end

    return pages, s
  end

  ---------------------------------------------------------------------------
  -- Generation dispatch
  ---------------------------------------------------------------------------

  local function normalizeForGame(save, game)
    if generationForContext(save, game) == 2 then
      return normalizeGold(save, game)
    end
    return normalizeGen1(save)
  end

  local function normalize(save)
    return normalizeForGame(save, liveGame)
  end

  local function resolveForGame(save, game)
    if generationForContext(save, game) == 2 then
      return resolveGold(save, game)
    end
    return resolveGen1(save)
  end

  local function resolve(save)
    return resolveForGame(save, liveGame)
  end

  local function resolveAllForGame(save, game)
    if generationForContext(save, game) == 2 then
      return resolveAllGold(save, game)
    end
    return resolveAllGen1(save)
  end

  local function resolveAll(save)
    return resolveAllForGame(save, liveGame)
  end

  -- Read-only test/debug snapshot for one-shot live triage.  This deliberately
  -- does not write mod.save, story state or any game state, and it has no UI
  -- entry.  A tester/developer can capture one compact answer instead of
  -- reconstructing the resolver inputs manually after a surprising HELP page.
  local function diagnostics(save, game)
    game = game or liveGame
    save = save or (game and game.save) or {}

    local generation = generationForContext(save, game)
    local pages, normalized
    if generation == 2 then
      pages, normalized = resolveAllGold(save, game)
    else
      pages, normalized = resolveAllGen1(save)
    end
    pages = type(pages) == "table" and pages or {}
    normalized = type(normalized) == "table" and normalized or {}

    local candidates = {}
    for index, obj in ipairs(pages) do
      candidates[#candidates + 1] = {
        index = index,
        id = obj.id,
        role = obj.pageRole,
        kind = obj.kind,
        destination = obj.destination,
        summary = obj.summary,
      }
    end

    local badgeCounts
    if generation == 2 then
      local b = normalized.badges or {}
      badgeCounts = {
        johto = tonumber(b.johtoCount) or countTrue(b.johto),
        kanto = tonumber(b.kantoCount) or countTrue(b.kanto),
        total = tonumber(b.totalCount)
          or ((tonumber(b.johtoCount) or countTrue(b.johto))
            + (tonumber(b.kantoCount) or countTrue(b.kanto))),
      }
    else
      badgeCounts = { total = countTrue(normalized.badges) }
    end

    local function diagnosticBoolMap(value)
      local out = {}
      if type(value) ~= "table" then return out end
      for key, flag in pairs(value) do
        if type(key) == "string" and type(flag) == "boolean" then out[key] = flag end
      end
      return out
    end

    local function diagnosticModStack(currentGame)
      local out = {}
      local loader = currentGame and currentGame.mods
      local ok, status = false, nil
      if loader and type(loader.status) == "function" then
        ok, status = pcall(loader.status, loader)
      end
      if ok and type(status) == "table" then
        for _, row in ipairs(status.available or {}) do
          if type(row) == "table" and type(row.id) == "string" then
            out[#out + 1] = {
              id = row.id,
              version = row.version,
              state = row.state,
              enabled = row.enabled == true,
              forcedGen2 = row.forcedGen2 == true,
              error = type(row.error) == "string" and row.error or nil,
            }
          end
        end
      end
      table.sort(out, function(a, b) return a.id < b.id end)
      return out
    end

    local first = candidates[1]
    local location = normalized.location or {}
    local hmAnywhere = normalized.hmAnywhere
    if type(hmAnywhere) == "table" then
      hmAnywhere = {
        detected = hmAnywhere.detected == true,
        effective = hmAnywhere.effective == true,
      }
    else
      hmAnywhere = { detected = hmAnywhere == true, effective = hmAnywhere == true }
    end

    return {
      format = "HELPDIAG/1",
      auditAnchor = "49d094b14d9e3986313a1f02126db08ac0dc43e9",
      generation = generation,
      version = normalized.version or save.version,
      currentMap = location.map or location.mapId or "UNKNOWN",
      position = { x = location.x, y = location.y, facing = location.facing },
      progressionRegion = generation == 2
        and ((normalized.access and normalized.access.kantoReached) and "kanto" or "johto")
        or "kanto",
      badgeCounts = badgeCounts,
      selectedPrimary = first,
      activeContext = first and first.role == "CONTEXT" and first.id or nil,
      candidates = candidates,
      proofs = diagnosticBoolMap(normalized.story),
      access = diagnosticBoolMap(normalized.access),
      fieldMoves = {
        owned = diagnosticBoolMap(normalized.hms),
        learned = diagnosticBoolMap(normalized.moves),
        usable = diagnosticBoolMap(normalized.abilities),
      },
      abilities = diagnosticBoolMap(normalized.abilities), -- compatibility alias
      hmAnywhere = hmAnywhere,
      modStack = diagnosticModStack(game),
      liveWorldRead = game ~= nil and liveGame ~= nil
        and game == liveGame and game.save == save,
    }
  end

  ---------------------------------------------------------------------------
  -- Opt-in live certification recorder (transient, read-only)
  --
  -- This is deliberately NOT a gameplay feature and NOT a second source of
  -- story truth.  It is dormant until a tester explicitly calls
  -- mod.exports.startLiveAudit().  While active it records only derived HELP
  -- observations in process memory so one long certification playthrough can
  -- be diagnosed without hand-copying every state.  It never writes mod.save,
  -- the game save, options, files, or network state.
  ---------------------------------------------------------------------------

  local liveAudit = {
    active = false,
    sequence = 0,
    generation = nil,
    start = nil,
    lastPrimary = nil,
    lastProofs = {},
    lastFieldUsable = {},
    helpOpenCount = 0,
    pageViewCount = 0,
    mapVisits = {},
    objectiveSeen = {},
    trace = {},
    warnings = {},
  }
  local LIVE_AUDIT_MAX_TRACE = 1200

  local function copyPlain(value, depth)
    depth = depth or 0
    if depth > 5 or type(value) ~= "table" then return value end
    local out = {}
    for key, child in pairs(value) do
      local kt = type(key)
      local vt = type(child)
      if (kt == "string" or kt == "number")
          and (vt == "string" or vt == "number" or vt == "boolean"
            or vt == "table" or vt == "nil") then
        out[key] = copyPlain(child, depth + 1)
      end
    end
    return out
  end

  local function auditWarn(message)
    if type(message) ~= "string" or message == "" then return end
    for _, existing in ipairs(liveAudit.warnings) do
      if existing == message then return end
    end
    liveAudit.warnings[#liveAudit.warnings + 1] = message
  end

  local function auditDiag(save, game)
    local ok, value = pcall(diagnostics, save, game)
    if not ok or type(value) ~= "table" then
      auditWarn("diagnostics failed while live audit was active: " .. tostring(value))
      return nil
    end
    if liveAudit.generation and value.generation ~= liveAudit.generation then
      auditWarn(("generation changed during one audit session: %s -> %s")
        :format(tostring(liveAudit.generation), tostring(value.generation)))
    end
    local seen = {}
    for _, candidate in ipairs(value.candidates or {}) do
      if seen[candidate.id] then
        auditWarn("duplicate HELP candidate during live audit: " .. tostring(candidate.id))
      end
      seen[candidate.id] = true
      for _, text in ipairs({ candidate.destination, candidate.summary }) do
        if type(text) == "string"
            and (text:find("EVENT_", 1, true) or text:find("ENGINE_", 1, true)) then
          auditWarn("internal engine token leaked into HELP candidate: " .. tostring(candidate.id))
        end
      end
    end
    return value
  end

  local function auditTrace(kind, diag, extra)
    liveAudit.sequence = liveAudit.sequence + 1
    local row = {
      seq = liveAudit.sequence,
      kind = kind,
      map = diag and diag.currentMap or "UNKNOWN",
      primary = diag and diag.selectedPrimary and diag.selectedPrimary.id or nil,
    }
    if type(extra) == "table" then
      for key, value in pairs(extra) do row[key] = copyPlain(value) end
    end
    liveAudit.trace[#liveAudit.trace + 1] = row
    if #liveAudit.trace > LIVE_AUDIT_MAX_TRACE then
      table.remove(liveAudit.trace, 1)
      auditWarn("live audit trace exceeded 1200 rows; oldest rows were discarded")
    end
  end

  local function auditBoolTransitions(kind, previous, current, diag)
    previous = type(previous) == "table" and previous or {}
    current = type(current) == "table" and current or {}
    local keys, seen = {}, {}
    for key, value in pairs(previous) do
      if type(key) == "string" and type(value) == "boolean" then
        seen[key] = true
        keys[#keys + 1] = key
      end
    end
    for key, value in pairs(current) do
      if type(key) == "string" and type(value) == "boolean" and not seen[key] then
        keys[#keys + 1] = key
      end
    end
    table.sort(keys)
    local changes = {}
    for _, key in ipairs(keys) do
      local before = previous[key] == true
      local after = current[key] == true
      if before ~= after then changes[#changes + 1] = key .. "=" .. tostring(after) end
    end
    if #changes > 0 then auditTrace(kind, diag, { changes = changes }) end
    return copyPlain(current)
  end

  local function auditSemanticTransitions(diag)
    if type(diag) ~= "table" then return end
    liveAudit.lastProofs = auditBoolTransitions(
      "PROOF_TRANSITION", liveAudit.lastProofs, diag.proofs, diag)
    local usable = diag.fieldMoves and diag.fieldMoves.usable or {}
    liveAudit.lastFieldUsable = auditBoolTransitions(
      "FIELD_MOVE_TRANSITION", liveAudit.lastFieldUsable, usable, diag)
  end

  auditRecord = function(kind, save, game, extra)
    if not liveAudit.active then return end
    game = game or liveGame
    save = save or (game and game.save) or {}
    local diag = auditDiag(save, game)
    local primary = diag and diag.selectedPrimary and diag.selectedPrimary.id or nil
    auditSemanticTransitions(diag)

    if kind == "MAP_ENTERED" then
      local map = diag and diag.currentMap
        or (type(extra) == "table" and extra.mapId) or "UNKNOWN"
      liveAudit.mapVisits[map] = (liveAudit.mapVisits[map] or 0) + 1
      -- Map travel is extremely chatty.  Keep a trace row only when it reveals
      -- a new primary objective; aggregate all visits separately.
      if primary ~= liveAudit.lastPrimary then
        auditTrace("OBJECTIVE_TRANSITION", diag, {
          trigger = "MAP_ENTERED",
          fromMapId = type(extra) == "table" and extra.fromMapId or nil,
        })
      end
    elseif kind == "HELP_OPEN" then
      liveAudit.helpOpenCount = liveAudit.helpOpenCount + 1
      if primary then
        liveAudit.objectiveSeen[primary] = (liveAudit.objectiveSeen[primary] or 0) + 1
      end
      auditTrace(kind, diag, extra)
    elseif kind == "HELP_PAGE" then
      liveAudit.pageViewCount = liveAudit.pageViewCount + 1
      auditTrace(kind, diag, extra)
    elseif kind == "HELP_CLOSE" then
      auditTrace(kind, diag, extra)
    elseif kind == "GAME_READY" then
      auditTrace(kind, diag, extra)
    elseif kind == "START" or kind == "STOP" or kind == "MARK" then
      auditTrace(kind, diag, extra)
    end

    liveAudit.lastPrimary = primary
  end

  local function resetLiveAudit()
    liveAudit.active = false
    liveAudit.sequence = 0
    liveAudit.generation = nil
    liveAudit.start = nil
    liveAudit.lastPrimary = nil
    liveAudit.lastProofs = {}
    liveAudit.lastFieldUsable = {}
    liveAudit.helpOpenCount = 0
    liveAudit.pageViewCount = 0
    liveAudit.mapVisits = {}
    liveAudit.objectiveSeen = {}
    liveAudit.trace = {}
    liveAudit.warnings = {}
  end

  local function liveAuditReport(save, game)
    game = game or liveGame
    save = save or (game and game.save) or {}
    local current = auditDiag(save, game)
    local maps, objectives = {}, {}
    for map, visits in pairs(liveAudit.mapVisits) do
      maps[#maps + 1] = { map = map, visits = visits }
    end
    table.sort(maps, function(a, b) return a.map < b.map end)
    for id, count in pairs(liveAudit.objectiveSeen) do
      objectives[#objectives + 1] = { id = id, helpOpens = count }
    end
    table.sort(objectives, function(a, b) return a.id < b.id end)
    return {
      format = "HELPLIVE/1",
      auditAnchor = "49d094b14d9e3986313a1f02126db08ac0dc43e9",
      active = liveAudit.active,
      sequence = liveAudit.sequence,
      generation = liveAudit.generation,
      helpOpenCount = liveAudit.helpOpenCount,
      pageViewCount = liveAudit.pageViewCount,
      start = copyPlain(liveAudit.start),
      current = copyPlain(current),
      maps = maps,
      objectives = objectives,
      trace = copyPlain(liveAudit.trace),
      warnings = copyPlain(liveAudit.warnings),
    }
  end

  local function liveAuditSummary(save, game)
    local report = liveAuditReport(save, game)
    local stack = report.current and report.current.modStack or {}
    local loadedMods, forcedMods = 0, 0
    for _, row in ipairs(stack) do
      if row.enabled and row.state == "loaded" then loadedMods = loadedMods + 1 end
      if row.forcedGen2 then forcedMods = forcedMods + 1 end
    end
    return {
      format = report.format,
      active = report.active,
      sequence = report.sequence,
      generation = report.generation,
      helpOpenCount = report.helpOpenCount,
      pageViewCount = report.pageViewCount,
      uniqueMaps = #report.maps,
      uniqueObjectives = #report.objectives,
      warningCount = #report.warnings,
      loadedMods = loadedMods,
      forcedMods = forcedMods,
      currentMap = report.current and report.current.currentMap or "UNKNOWN",
      currentPrimary = report.current and report.current.selectedPrimary
        and report.current.selectedPrimary.id or nil,
    }
  end

  local function liveAuditTail(limit)
    limit = math.max(1, math.min(20, tonumber(limit) or 8))
    local first = math.max(1, #liveAudit.trace - limit + 1)
    local out = {}
    for i = first, #liveAudit.trace do out[#out + 1] = copyPlain(liveAudit.trace[i]) end
    return out
  end

  local function startLiveAudit(save, game)
    game = game or liveGame
    save = save or (game and game.save) or {}
    resetLiveAudit()
    local start = diagnostics(save, game)
    liveAudit.active = true
    liveAudit.generation = start.generation
    liveAudit.start = copyPlain(start)
    liveAudit.lastPrimary = start.selectedPrimary and start.selectedPrimary.id or nil
    liveAudit.lastProofs = copyPlain(start.proofs or {})
    liveAudit.lastFieldUsable = copyPlain(
      start.fieldMoves and start.fieldMoves.usable or {})
    auditRecord("START", save, game)
    return liveAuditReport(save, game)
  end

  local function markLiveAudit(label, save, game)
    if not liveAudit.active then return nil, "live audit is not active" end
    label = tostring(label or ""):gsub("[%c]", " "):sub(1, 64)
    if label == "" then return nil, "mark label is empty" end
    auditRecord("MARK", save, game, { label = label })
    return true
  end

  local function stopLiveAudit(save, game)
    if liveAudit.active then auditRecord("STOP", save, game) end
    liveAudit.active = false
    return liveAuditReport(save, game)
  end

  -- Existing exports remain stable; Gold-specific/pure exports are additive.
  mod.exports.normalize = normalize
  mod.exports.normalizeForGame = normalizeForGame
  mod.exports.normalizeGold = normalizeGold
  mod.exports.resolve = resolve
  mod.exports.resolveForGame = resolveForGame
  mod.exports.resolveGold = resolveGold
  mod.exports.resolveAll = resolveAll
  mod.exports.resolveAllForGame = resolveAllForGame
  mod.exports.resolveAllGold = resolveAllGold
  mod.exports.diagnostics = diagnostics
  mod.exports.startLiveAudit = startLiveAudit
  mod.exports.stopLiveAudit = stopLiveAudit
  mod.exports.liveAuditReport = liveAuditReport
  mod.exports.liveAuditSummary = liveAuditSummary
  mod.exports.liveAuditTail = liveAuditTail
  mod.exports.markLiveAudit = markLiveAudit
  mod.exports.goldFlagIds = { events = GOLD_EVENT_IDS, engine = GOLD_ENGINE_IDS }
  mod.exports.goldEventSemantics = GOLD_EVENT_SEMANTICS

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
      local results = resolveAllForGame(game.save, game)
      if type(results) ~= "table" or #results == 0 then
        local fallback = resolveForGame(game.save, game)
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

      if auditRecord then
        local ids = {}
        for _, page in ipairs(results) do ids[#ids + 1] = page.id end
        auditRecord("HELP_OPEN", game.save, game, {
          via = openedBySelect and "SELECT" or "START",
          pageCount = #results,
          pages = ids,
        })
      end

      local function stepPage(dir)
        local n = #self.results
        if n <= 1 then return end
        self.index = ((self.index - 1 + dir) % n) + 1
        if auditRecord then
          local page = self.results[self.index]
          auditRecord("HELP_PAGE", game.save, game, {
            index = self.index,
            pageCount = n,
            pageId = page and page.id or nil,
          })
        end
      end

      function self:update(dt)
        local input = game.input
        if not self.selectArmed and not input:isDown("select") then
          self.selectArmed = true
        end

        if input:wasPressed("b") then
          if auditRecord then
            local page = self.results[self.index]
            auditRecord("HELP_CLOSE", game.save, game, {
              index = self.index, pageId = page and page.id or nil,
            })
          end
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
      -- Gold's START menu renders descriptor rows when MENU ACCOUNT is on;
      -- Gen 1 safely ignores this shared descriptor field.
      desc = { "Story and", "route guide" },
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
    if not game or not game.stack then return false end

    -- Gen 1: intentionally preserve the exact v1.0.5 safety contract.
    -- Gold work must never opportunistically change Red/Blue/Yellow behavior.
    if game.overworld then
      if game.stack:top() ~= game.overworld then return false end
      local ow = game.overworld
      if ow.transitioning then return false end
      if ow.runner and ow.runner.isRunning and ow.runner:isRunning() then return false end
      if ow.scriptMoves and #ow.scriptMoves > 0 then return false end
      if ow.engaging or ow.emote then return false end
      return true
    end

    -- Gold: Game2 owns `world` instead of Gen 1's `overworld`.  Reuse the
    -- engine's own START/SELECT admission gate rather than guessing from
    -- individual VM/step fields.  In normal overworld play Game2's state stack
    -- is empty; any top state is a modal screen and HELP must not steal SELECT.
    if game.world and game.phase == "play" then
      if game.stack:top() ~= nil then return false end
      if not game.world.map then return false end
      if type(game.world.acceptsMenuInput) ~= "function" then return false end
      return game.world:acceptsMenuInput() == true
    end

    return false
  end

  -- Exact route visitation is best recorded on map entry. The game's own
  -- save.visited deliberately covers fly towns only, not ordinary routes.
  mod.events:on("map.entered", function(ev)
    if type(ev) == "table" then
      markRouteJournal(ev.mapId, ev.fromMapId)
      if auditRecord then
        local game = ev.game or liveGame
        auditRecord("MAP_ENTERED", game and game.save, game, {
          mapId = ev.mapId, fromMapId = ev.fromMapId,
        })
      end
    end
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
