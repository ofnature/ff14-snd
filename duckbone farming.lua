--[=====[
[[SND Metadata]]
author: ofnature
version: 2.0.0
description: |
  Run Mistwake repeatedly via AutoDuty, turn in armor loot to Grand Company
  Expert Delivery for seals, then spend seals on Duckbones. Loops until stopped.
  Open AutoDuty, pick your trust party, then close it before starting.
plugin_dependencies:
- AutoDuty
- Lifestream
- vnavmesh

configs:
  Runs Per Cycle:
    description: How many Mistwake runs to complete before heading to the Grand Company.
    default: 5
    min: 1
    max: 50

  Grand Company:
    description: Which Grand Company are you in?
    default: "Maelstrom"
    is_choice: true
    choices: ["Maelstrom", "Order of the Twin Adder", "Immortal Flames"]

  List Mode:
    description: |
      Blacklist = turn in everything EXCEPT item IDs in your list.
      Whitelist = ONLY turn in item IDs that are in your list.
      Off       = turn in everything, ignore the item list entirely.
    default: "Off"
    is_choice: true
    choices: ["Off", "Blacklist", "Whitelist"]

  Protected Item IDs:
    description: |
      Comma-separated item IDs to protect (Blacklist) or exclusively deliver (Whitelist).
      Find IDs by hovering an item and running: /snd echo {itemid}
      Example: 44301, 44302, 44305
    default: ""

  Seal Cap:
    description: Maximum seals your character can hold. Default 90000 at max GC rank.
    default: 90000
    min: 10000
    max: 90000

  Seal Reserve:
    description: Stop buying Duckbones when seals drop to this amount.
    default: 1500
    min: 0
    max: 10000

  Duckbone Shop Row:
    description: |
      0-based row index of Duckbones in the GC Shop item list.
      Open the shop manually and count rows from 0 to find the right number.
    default: 0
    min: 0
    max: 99

[[End Metadata]]
--]=====]

-- =========================================================
-- REQUIRED IMPORT
-- =========================================================
import("System.Numerics")

-- =========================================================
-- PREFIX / ECHO LOG
-- =========================================================
PREFIX  = "[DUCKBONE]"
echoLog = true

local function _echo(s)
    yield("/echo " .. tostring(s))
end

local function _log(s)
    local msg = tostring(s)
    Dalamud.Log(msg)
    if echoLog then _echo(msg) end
end

local function _fmt(msg, ...)
    return string.format("%s %s", PREFIX, string.format(msg, ...))
end

function Logf(msg, ...)  _log(_fmt(msg, ...))  end
function Echof(msg, ...) _echo(_fmt(msg, ...)) end

Log  = Logf
Echo = Echof

-- =========================================================
-- SLEEP / TIMING
-- =========================================================
TIME = {
    POLL    = 0.10,
    TIMEOUT = 10.0,
    STABLE  = 0.30,
}

local function _sleep(seconds)
    local s = tonumber(seconds) or 0
    if s < 0 then s = 0 end
    s = math.floor(s * 10 + 0.5) / 10
    yield("/wait " .. s)
end

Sleep = _sleep

-- =========================================================
-- WAIT UNTIL HELPER
-- =========================================================
local function WaitUntil(predicateFn, timeoutSec, pollSec, stableSec)
    timeoutSec = tonumber(timeoutSec) or TIME.TIMEOUT
    pollSec    = tonumber(pollSec)    or TIME.POLL
    stableSec  = tonumber(stableSec)  or TIME.STABLE

    local start     = os.clock()
    local holdStart = nil

    while (os.clock() - start) < timeoutSec do
        local ok, res = pcall(predicateFn)
        if ok and res then
            if not holdStart then holdStart = os.clock() end
            if (os.clock() - holdStart) >= stableSec then return true end
        else
            holdStart = nil
        end
        _sleep(pollSec)
    end
    return false
end

-- =========================================================
-- ADDON HELPERS
-- =========================================================
local function _get_addon(name)
    local ok, addon = pcall(Addons.GetAddon, name)
    if ok and addon ~= nil then return addon end
    return nil
end

function IsAddonReady(name)
    local addon = _get_addon(name)
    return addon and addon.Ready or false
end

function IsAddonVisible(name)
    local addon = _get_addon(name)
    return addon and addon.Exists or false
end

local function WaitForAddon(name, timeoutSec)
    Log("awaiting addon: %s", name)
    local ok = WaitUntil(function()
        local addon = _get_addon(name)
        return addon and addon.Ready
    end, timeoutSec or TIME.TIMEOUT, TIME.POLL, 0.0)
    if not ok then Log("WaitForAddon timeout: %s", name) end
    return ok
end

local function CloseAddon(name)
    if IsAddonVisible(name) then
        yield("/callback " .. name .. " true -1")
        Sleep(TIME.STABLE)
    end
end

-- =========================================================
-- CHARACTER / ZONE / CONDITIONS
-- =========================================================
local CharacterCondition = {
    casting             = 27,
    betweenAreas        = 45,
    betweenAreasForDuty = 51,
    boundByDuty34       = 34,
    boundByDuty56       = 56,
}

local function GetCharacterCondition(i, bool)
    if bool == nil then bool = true end
    return Svc and Svc.Condition and (Svc.Condition[i] == bool) or false
end

local function GetZoneId()
    local cs = Svc and Svc.ClientState
    return cs and cs.TerritoryType or nil
end

local function IsInZone(zone_id)
    return GetZoneId() == zone_id
end

local function InDuty()
    return GetCharacterCondition(CharacterCondition.boundByDuty34, true)
        or GetCharacterCondition(CharacterCondition.boundByDuty56, true)
end

local function PlayerAvailable()
    return Player ~= nil and Player.Available == true
end

-- =========================================================
-- SAFE CALLBACK
-- =========================================================
local function SafeCallback(addon, update, ...)
    local updateStr = (update == false) and "false" or "true"
    local call = "/callback " .. addon .. " " .. updateStr
    for _, v in ipairs({...}) do
        call = call .. " " .. tostring(v)
    end
    Log("callback: %s", call)
    if IsAddonReady(addon) and IsAddonVisible(addon) then
        yield(call)
        return true
    end
    Log("SafeCallback: addon not ready/visible: %s", addon)
    return false
end

-- =========================================================
-- NAVIGATION (vnavmesh IPC)
-- =========================================================
local function StopVnav()
    if IPC and IPC.vnavmesh then
        if IPC.vnavmesh.IsRunning and IPC.vnavmesh.IsRunning() then
            IPC.vnavmesh.Stop()
        end
    end
end

local function MoveToCoords(x, y, z, stopDist)
    stopDist = tonumber(stopDist) or 3.0
    if not (IPC and IPC.vnavmesh and IPC.vnavmesh.PathfindAndMoveTo) then
        Log("MoveToCoords: vnavmesh IPC missing")
        return false
    end

    local dest = Vector3(x, y, z)
    Log("Pathing to %.1f, %.1f, %.1f", x, y, z)
    IPC.vnavmesh.PathfindAndMoveTo(dest, false)

    local elapsed = 0
    local timeout = 120
    while elapsed < timeout do
        _sleep(TIME.POLL)
        elapsed = elapsed + TIME.POLL

        local me = Entity and Entity.Player
        if me and me.Position then
            local dist = Vector3.Distance(me.Position, dest)
            if dist <= stopDist then
                StopVnav()
                Log("Arrived at destination")
                return true
            end
        end

        if IPC.vnavmesh.IsRunning and not IPC.vnavmesh.IsRunning() then
            -- Nav stopped on its own, check if close enough
            local me2 = Entity and Entity.Player
            if me2 and me2.Position then
                if Vector3.Distance(me2.Position, dest) <= stopDist + 2.0 then
                    Log("Nav stopped near destination")
                    return true
                end
            end
            Log("Nav stopped but not at destination, retrying")
            IPC.vnavmesh.PathfindAndMoveTo(dest, false)
        end
    end

    StopVnav()
    Log("MoveToCoords: timeout")
    return false
end

-- =========================================================
-- TELEPORT (Lifestream IPC)
-- =========================================================
local function TeleportTo(tp_name, zone_id)
    if IsInZone(zone_id) then return true end

    if not (IPC and IPC.Lifestream and IPC.Lifestream.ExecuteCommand) then
        Log("TeleportTo: Lifestream IPC missing")
        return false
    end

    Log("Teleporting to %s", tp_name)
    IPC.Lifestream.ExecuteCommand(tp_name)

    -- Wait for zoning to start
    WaitUntil(function()
        return GetCharacterCondition(CharacterCondition.betweenAreas, true)
            or GetCharacterCondition(CharacterCondition.betweenAreasForDuty, true)
            or (IPC.Lifestream.IsBusy and IPC.Lifestream.IsBusy())
    end, 5.0, TIME.POLL, 0.0)

    -- Wait for zoning to finish
    local arrived = WaitUntil(function()
        return IsInZone(zone_id) and PlayerAvailable()
    end, 60.0, TIME.POLL, 1.0)

    if not arrived then
        Log("TeleportTo: failed to reach %s", tp_name)
        return false
    end

    Sleep(TIME.STABLE)
    Log("Arrived in zone %d", zone_id)
    return true
end

-- =========================================================
-- AUTODUTY IPC
-- =========================================================
local function IsAutoDutyRunning()
    return IPC and IPC.AutoDuty and (not IPC.AutoDuty.IsStopped())
end

local function StopAutoDuty()
    if IPC and IPC.AutoDuty and IPC.AutoDuty.Stop then
        IPC.AutoDuty.Stop()
        Sleep(TIME.STABLE)
    end
end

local function StartAutoDuty(dungeonId, numRuns)
    if not (IPC and IPC.AutoDuty and IPC.AutoDuty.Run) then
        Log("StartAutoDuty: AutoDuty IPC missing")
        return false
    end
    Log("Starting AutoDuty: dungeonId=%d runs=%d", dungeonId, numRuns)
    IPC.AutoDuty.Run(dungeonId, numRuns, false)
    Sleep(TIME.STABLE)
    return true
end

-- =========================================================
-- INVENTORY
-- =========================================================
local INVENTORY_BAGS = {0, 1, 2, 3}

local function GetItemCount(itemId)
    return tonumber(Inventory.GetItemCount(itemId)) or 0
end

local function SnapshotInventory()
    local snap = {}
    for _, bag in ipairs(INVENTORY_BAGS) do
        for slot = 0, 34 do
            local ok, item = pcall(function()
                return Inventory.GetItemInSlot(bag, slot)
            end)
            if ok and item and item.ItemId and item.ItemId ~= 0 then
                local id = item.ItemId
                snap[id] = (snap[id] or 0) + (item.Count or 1)
            end
        end
    end
    return snap
end

local function LogNewDrops(before, after)
    local any = false
    for id, count in pairs(after) do
        local gained = count - (before[id] or 0)
        if gained > 0 then
            Log("  DROP: ItemID %d x%d", id, gained)
            any = true
        end
    end
    if not any then Log("  No new items this run.") end
end

-- =========================================================
-- READ CONFIG FROM SND UI
-- =========================================================
local function ParseItemIdList(str)
    local ids = {}
    if not str or str == "" then return ids end
    for chunk in tostring(str):gmatch("[^,]+") do
        local trimmed = chunk:match("^%s*(.-)%s*$")
        local id = tonumber(trimmed)
        if id then ids[id] = true end
    end
    return ids
end

local GC_NAME_TO_INDEX = {
    ["Maelstrom"]               = 1,
    ["Order of the Twin Adder"] = 2,
    ["Immortal Flames"]         = 3,
}

local GC_SEAL_CURRENCY = {[1]=20, [2]=21, [3]=22}

local GC_TP_NAME = {
    [1] = "Limsa Lominsa Lower Decks",
    [2] = "New Gridania",
    [3] = "Ul'dah - Steps of Nald",
}

local GC_ZONE_ID = {
    [1] = 129,
    [2] = 133,
    [3] = 130,
}

local GC_OFFICER_POS = {
    [1] = {x = -67.8, y = 21.4, z = -18.1},
    [2] = {x = -72.3, y = -1.0, z = -14.1},
    [3] = {x = -148.9, y = 4.1,  z = -107.0},
}

local GC_SHOP_POS = {
    [1] = {x = -72.2, y = 21.4, z = -14.9},
    [2] = {x = -74.5, y = -1.0, z = -12.0},
    [3] = {x = -145.7, y = 4.1,  z = -107.0},
}

local GC_OFFICER_NAME = {
    [1] = "Storm Personnel Officer",
    [2] = "Serpent Personnel Officer",
    [3] = "Flame Personnel Officer",
}

local GC_SHOP_NAME = {
    [1] = "Storm Quartermaster",
    [2] = "Serpent Quartermaster",
    [3] = "Flame Quartermaster",
}

-- Mistwake content ID (verified from Mathematics Farm script)
local MISTWAKE_ID = 1314

-- Read config values
local cfg_runs       = tonumber(Config.Get("Runs Per Cycle"))      or 5
local cfg_gc_name    = tostring(Config.Get("Grand Company")        or "Maelstrom")
local cfg_list_mode  = tostring(Config.Get("List Mode")            or "Off"):lower()
local cfg_item_ids   = tostring(Config.Get("Protected Item IDs")   or "")
local cfg_seal_cap   = tonumber(Config.Get("Seal Cap"))            or 90000
local cfg_seal_res   = tonumber(Config.Get("Seal Reserve"))        or 1500
local cfg_shop_row   = tonumber(Config.Get("Duckbone Shop Row"))   or 0

local gc_index  = GC_NAME_TO_INDEX[cfg_gc_name] or 1
local ITEM_LIST = ParseItemIdList(cfg_item_ids)

-- =========================================================
-- SEALS
-- =========================================================
local function GetCurrentSeals()
    local seal_id = GC_SEAL_CURRENCY[gc_index] or 20
    return tonumber(Inventory.GetItemCount(seal_id)) or 0
end

-- =========================================================
-- ITEM FILTER
-- =========================================================
local function ShouldTurnIn(item_id)
    if cfg_list_mode == "off" then return true end
    local in_list = ITEM_LIST[item_id] == true
    if cfg_list_mode == "whitelist" then return in_list end
    if cfg_list_mode == "blacklist" then return not in_list end
    return true
end

local function GetDeliverableItems()
    local out = {}
    for _, bag in ipairs(INVENTORY_BAGS) do
        for slot = 0, 34 do
            local ok, item = pcall(function()
                return Inventory.GetItemInSlot(bag, slot)
            end)
            if ok and item and item.ItemId and item.ItemId ~= 0 then
                if ShouldTurnIn(item.ItemId) then
                    table.insert(out, {
                        id    = item.ItemId,
                        label = "ID:" .. item.ItemId,
                    })
                end
            end
        end
    end
    return out
end

-- =========================================================
-- STATS
-- =========================================================
local total_runs_completed = 0
local total_cycles         = 0
local total_seals_earned   = 0
local total_duckbones      = 0
local script_start_time    = os.time()

local function FormatTime(secs)
    return string.format("%02d:%02d:%02d",
        math.floor(secs / 3600),
        math.floor((secs % 3600) / 60),
        secs % 60)
end

local function PrintStats()
    local elapsed = os.time() - script_start_time
    Log("════════════════════════════════════")
    Log("  Cycles    : %d", total_cycles)
    Log("  Runs      : %d", total_runs_completed)
    Log("  Seals +   : %d", total_seals_earned)
    Log("  Duckbones : %d", total_duckbones)
    Log("  Seals now : %d", GetCurrentSeals())
    Log("  Runtime   : %s", FormatTime(os.time() - script_start_time))
    Log("════════════════════════════════════")
end

-- =========================================================
-- INTERACT BY NAME HELPER
-- =========================================================
local function InteractWithNPC(name, timeout)
    timeout = tonumber(timeout) or 5.0
    local e = Entity and Entity.GetEntityByName and Entity.GetEntityByName(name)
    if not e then
        Log("InteractWithNPC: entity not found '%s'", name)
        return false
    end

    local start = os.clock()
    while (os.clock() - start) < timeout do
        e:SetAsTarget()
        _sleep(TIME.POLL)
        local tgt = Entity and Entity.Target
        if tgt and tgt.Name == name then
            e:Interact()
            Sleep(TIME.STABLE)
            return true
        end
        _sleep(TIME.POLL)
    end
    Log("InteractWithNPC: timeout '%s'", name)
    return false
end

-- =========================================================
-- PHASE 1 — AUTODUTY DUNGEON RUNS
-- =========================================================
local function WaitForDutyComplete(timeout)
    Log("Waiting for duty to finish (max %ds)...", timeout)
    -- Give AutoDuty a moment to actually enter the duty
    Sleep(15)

    local elapsed = 0
    while elapsed < timeout do
        if not InDuty() then
            Log("Duty complete flag cleared")
            return true
        end
        _sleep(5)
        elapsed = elapsed + 5
        if elapsed % 60 == 0 then
            Log("Still in duty... %ds elapsed", elapsed)
        end
    end
    Log("ERROR: Duty timeout after %ds", timeout)
    return false
end

local function RunDungeonCycle(num_runs)
    Log("=== DUNGEON PHASE: %d Mistwake runs ===", num_runs)

    for run = 1, num_runs do
        Log("-- Run %d/%d (total so far: %d) --", run, num_runs, total_runs_completed + 1)

        -- If somehow already in duty, wait for it to clear
        if InDuty() then
            Log("Already in duty at run start, waiting to clear...")
            local t = 0
            while InDuty() and t < 600 do
                _sleep(5) ; t = t + 5
            end
        end

        -- Snapshot inventory before run for loot logging
        local snap_before = SnapshotInventory()

        -- Start AutoDuty
        if not StartAutoDuty(MISTWAKE_ID, 1) then
            Log("ERROR: Could not start AutoDuty — skipping run")
            goto next_run
        end

        -- Wait for duty to actually start (condition 34)
        local entered = WaitUntil(function()
            return InDuty()
        end, 120.0, 1.0, 0.0)

        if not entered then
            Log("ERROR: Never entered duty after 120s — skipping run")
            StopAutoDuty()
            goto next_run
        end

        -- Wait for run to finish
        local finished = WaitForDutyComplete(1800)
        if not finished then
            Log("Duty timed out — stopping AutoDuty and leaving")
            StopAutoDuty()
            yield("/dutyleave")
            Sleep(15)
        end

        -- Log what dropped
        Log("--- Loot this run ---")
        LogNewDrops(snap_before, SnapshotInventory())

        total_runs_completed = total_runs_completed + 1
        Log("Run %d complete | Total: %d | Seals: %d",
            run, total_runs_completed, GetCurrentSeals())

        Sleep(5)
        ::next_run::
    end

    Log("=== Dungeon phase done. %d total runs ===", total_runs_completed)
end

-- =========================================================
-- PHASE 2 — EXPERT DELIVERY
-- =========================================================
local function DoExpertDelivery()
    Log("=== EXPERT DELIVERY PHASE ===")
    Log("Mode: %s", cfg_list_mode:upper())

    local deliverable = GetDeliverableItems()
    if #deliverable == 0 then
        Log("No deliverable items found — skipping delivery")
        return
    end

    Log("%d item(s) queued for delivery:", #deliverable)
    for _, item in ipairs(deliverable) do
        Log("  -> %s", item.label)
    end

    -- Navigate to Personnel Officer
    local opos = GC_OFFICER_POS[gc_index]
    MoveToCoords(opos.x, opos.y, opos.z)

    -- Interact with officer NPC
    local officer = GC_OFFICER_NAME[gc_index]
    if not InteractWithNPC(officer, 8.0) then
        Log("ERROR: Could not interact with %s", officer)
        return
    end

    -- Officer opens SelectString menu
    -- Option 1 (0-based) = Expert Delivery
    if not WaitForAddon("SelectString", 10) then
        Log("ERROR: Officer menu did not open")
        return
    end
    SafeCallback("SelectString", true, 1)
    Sleep(TIME.STABLE)

    -- Wait for Expert Delivery window
    if not WaitForAddon("GrandCompanySupplyList", 10) then
        Log("ERROR: Expert Delivery window did not open")
        CloseAddon("SelectString")
        return
    end

    Log("Expert Delivery window open, processing items...")

    local items_turned_in = 0
    local items_skipped   = 0
    local seal_before     = GetCurrentSeals()
    local current_row     = 0
    local attempt         = 0
    local max_attempts    = 60

    -- Refresh deliverable list
    deliverable = GetDeliverableItems()
    local total_rows = #deliverable

    while attempt < max_attempts do
        attempt = attempt + 1

        if not IsAddonVisible("GrandCompanySupplyList") then
            Log("Delivery window closed")
            break
        end

        -- Check seal cap
        if GetCurrentSeals() >= cfg_seal_cap - 100 then
            Log("Seal cap reached (%d) — stopping delivery", GetCurrentSeals())
            break
        end

        if current_row >= total_rows then
            Log("End of item list")
            break
        end

        local item = deliverable[current_row + 1]
        if not item then break end

        if not ShouldTurnIn(item.id) then
            Log("Skipping row %d: %s", current_row, item.label)
            current_row = current_row + 1
            items_skipped = items_skipped + 1
        else
            -- Click item row in delivery window
            SafeCallback("GrandCompanySupplyList", true, 0, current_row)
            Sleep(TIME.STABLE)

            if IsAddonVisible("SelectYesno") then
                SafeCallback("SelectYesno", true, 0)
                Sleep(TIME.STABLE)
                items_turned_in = items_turned_in + 1
                Log("Delivered %s | Seals: %d", item.label, GetCurrentSeals())

                -- Rescan after delivery since list shifts
                deliverable = GetDeliverableItems()
                current_row = items_skipped
                total_rows  = #deliverable + items_skipped
            else
                Log("WARN: No confirm dialog for row %d — advancing", current_row)
                current_row = current_row + 1
            end
        end
    end

    CloseAddon("GrandCompanySupplyList")
    Sleep(TIME.STABLE)
    CloseAddon("SelectString")
    Sleep(TIME.POLL)

    local gained = GetCurrentSeals() - seal_before
    total_seals_earned = total_seals_earned + math.max(0, gained)

    Log("Delivery complete: %d turned in | %d skipped | +%d seals | Now: %d",
        items_turned_in, items_skipped, gained, GetCurrentSeals())
end

-- =========================================================
-- PHASE 3 — BUY DUCKBONES
-- =========================================================
local function BuyDuckbones()
    Log("=== BUY DUCKBONES PHASE ===")

    local cur_seals = GetCurrentSeals()
    if cur_seals <= cfg_seal_res then
        Log("Seals too low (%d <= reserve %d) — skipping purchase", cur_seals, cfg_seal_res)
        return
    end

    -- Navigate to Quartermaster
    local spos = GC_SHOP_POS[gc_index]
    MoveToCoords(spos.x, spos.y, spos.z)

    local shopnpc = GC_SHOP_NAME[gc_index]
    if not InteractWithNPC(shopnpc, 8.0) then
        Log("ERROR: Could not interact with %s", shopnpc)
        return
    end

    -- Quartermaster opens SelectString — "Purchase Items" is option 0
    if IsAddonVisible("SelectString") then
        if WaitForAddon("SelectString", 8) then
            SafeCallback("SelectString", true, 0)
            Sleep(TIME.STABLE)
        end
    end

    if not WaitForAddon("GCShop", 10) then
        Log("ERROR: GC Shop did not open")
        CloseAddon("SelectString")
        return
    end

    Log("GC Shop open — buying Duckbones (shop row %d)...", cfg_shop_row)

    -- Make sure we're on the right tab
    SafeCallback("GCShop", true, 0)
    Sleep(TIME.STABLE)

    local bought       = 0
    local DUCKBONE_COST = 200
    local max_loops    = 200

    for _ = 1, max_loops do
        cur_seals = GetCurrentSeals()

        if cur_seals - DUCKBONE_COST < cfg_seal_res then
            Log("Not enough seals for another purchase (%d) — done", cur_seals)
            break
        end

        -- Click the item row
        SafeCallback("GCShop", true, 0, cfg_shop_row)
        Sleep(TIME.STABLE)

        if IsAddonVisible("ShopExchangeDialog") then
            -- Calculate max we can buy in one go
            local max_qty = math.floor((cur_seals - cfg_seal_res) / DUCKBONE_COST)
            max_qty = math.max(1, math.min(max_qty, 99))
            SafeCallback("ShopExchangeDialog", true, 0, max_qty, 0)
            Sleep(TIME.STABLE)
            bought = bought + max_qty
            Log("Bought %d Duckbones | Seals remaining: %d", max_qty, GetCurrentSeals())

        elseif IsAddonVisible("SelectYesno") then
            SafeCallback("SelectYesno", true, 0)
            Sleep(TIME.STABLE)
            bought = bought + 1
            Log("Bought 1 Duckbone | Seals remaining: %d", GetCurrentSeals())

        elseif IsAddonVisible("GCShop") then
            Log("WARN: No buy dialog appeared — check Duckbone Shop Row in config (currently %d)", cfg_shop_row)
            break

        else
            Log("WARN: GCShop closed unexpectedly")
            break
        end

        -- If seals dropped below threshold after purchase, stop
        if GetCurrentSeals() - DUCKBONE_COST < cfg_seal_res then
            break
        end
    end

    CloseAddon("GCShop")
    Sleep(TIME.POLL)
    CloseAddon("SelectString")

    total_duckbones = total_duckbones + bought
    Log("Bought %d Duckbones this cycle | Total ever: %d | Seals: %d",
        bought, total_duckbones, GetCurrentSeals())
end

-- =========================================================
-- STOP HANDLER
-- =========================================================
function OnStop()
    StopVnav()
    StopAutoDuty()
    Log("Script stopped by user")
end

-- =========================================================
-- STARTUP BANNER
-- =========================================================
Log("╔══════════════════════════════════════════╗")
Log("║   Mistwake Duckbone Farm  v2.0.0         ║")
Log("╚══════════════════════════════════════════╝")
Log("Runs/cycle : %d", cfg_runs)
Log("GC         : %s (index %d)", cfg_gc_name, gc_index)
Log("List mode  : %s", cfg_list_mode:upper())
Log("Seal cap   : %d | Reserve: %d", cfg_seal_cap, cfg_seal_res)
Log("Shop row   : %d", cfg_shop_row)
Log("Dungeon ID : %d (Mistwake)", MISTWAKE_ID)

if cfg_item_ids ~= "" then
    local ids = {}
    for id in pairs(ITEM_LIST) do table.insert(ids, tostring(id)) end
    Log("Item list  : %s", table.concat(ids, ", "))
else
    if cfg_list_mode ~= "off" then
        Log("WARN: List mode is %s but Protected Item IDs is empty!", cfg_list_mode:upper())
    end
end

-- Verify IPC availability
if not (IPC and IPC.AutoDuty) then
    Log("FATAL: AutoDuty IPC not available — is AutoDuty installed and enabled?")
    return
end
if not (IPC and IPC.vnavmesh) then
    Log("FATAL: vnavmesh IPC not available — is vnavmesh installed and enabled?")
    return
end
if not (IPC and IPC.Lifestream) then
    Log("FATAL: Lifestream IPC not available — is Lifestream installed and enabled?")
    return
end

Log("All plugins verified. Starting loop...")
Sleep(2)

-- =========================================================
-- MAIN LOOP
-- =========================================================
while true do
    total_cycles = total_cycles + 1
    Log("════ CYCLE %d START ════", total_cycles)

    -- Phase 1: Dungeon runs
    local run_ok, run_err = pcall(RunDungeonCycle, cfg_runs)
    if not run_ok then
        Log("ERROR in dungeon phase: %s", tostring(run_err))
        if InDuty() then
            StopAutoDuty()
            yield("/dutyleave")
            Sleep(15)
        end
    end

    -- Teleport to GC city
    local gc_zone = GC_ZONE_ID[gc_index]
    local gc_tp   = GC_TP_NAME[gc_index]

    if TeleportTo(gc_tp, gc_zone) then
        Sleep(3)

        -- Phase 2: Expert delivery
        local del_ok, del_err = pcall(DoExpertDelivery)
        if not del_ok then
            Log("ERROR in delivery phase: %s", tostring(del_err))
        end

        -- Phase 3: Buy duckbones
        local buy_ok, buy_err = pcall(BuyDuckbones)
        if not buy_ok then
            Log("ERROR in buy phase: %s", tostring(buy_err))
        end
    else
        Log("ERROR: Could not reach GC (%s) — skipping sell/buy this cycle", gc_tp)
    end

    PrintStats()
    Log("════ CYCLE %d END ════", total_cycles)
    Sleep(5)
end
