--[=====[
[[SND Metadata]]
author: ofnature
version: 1.2.0
description: |
  Run Mistwake repeatedly, turn in armor loot to Grand Company Expert Delivery,
  then spend seals on Duckbones. Loops until stopped.
  Requires: AutoDuty, vnavmesh, Lifestream, YesAlready, TextAdvance

plugin_dependencies:
  - AutoDuty
  - vnavmesh
  - Lifestream

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
      Blacklist = turn in everything EXCEPT items in your protected list.
      Whitelist = ONLY turn in items that are in your list.
      Off       = turn in everything, ignore the item list entirely.
    default: "Blacklist"
    is_choice: true
    choices: ["Blacklist", "Whitelist", "Off"]

  Protected Item IDs:
    description: |
      Comma-separated item IDs to protect (Blacklist) or exclusively deliver (Whitelist).
      Find IDs by hovering an item and running: /snd echo {itemid}
      Example: 44301, 44302, 44305
    default: ""

  Seal Cap:
    description: Maximum seals your character can hold. Default is 90000 at max GC rank.
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
      Open the shop manually and count from 0 to find the right row.
    default: 0
    min: 0
    max: 99

[[End Metadata]]
--]=====]

-- ============================================================
-- READ CONFIG FROM SND UI
-- ============================================================

local function ParseItemIdList(str)
    local ids = {}
    if not str or str == "" then return ids end
    for chunk in tostring(str):gmatch("[^,]+") do
        local trimmed = chunk:match("^%s*(.-)%s*$")
        local id = tonumber(trimmed)
        if id then
            ids[id] = true
        end
    end
    return ids
end

local GC_NAME_MAP = {
    ["Maelstrom"]              = 1,
    ["Order of the Twin Adder"] = 2,
    ["Immortal Flames"]        = 3,
}

local runs_per_cycle    = tonumber(Config.Get("Runs Per Cycle"))   or 5
local gc_choice         = tostring(Config.Get("Grand Company")     or "Maelstrom")
local list_mode         = tostring(Config.Get("List Mode")         or "Blacklist"):lower()
local item_id_str       = tostring(Config.Get("Protected Item IDs") or "")
local seal_cap          = tonumber(Config.Get("Seal Cap"))         or 90000
local seal_reserve      = tonumber(Config.Get("Seal Reserve"))     or 1500
local shop_row          = tonumber(Config.Get("Duckbone Shop Row")) or 0

local gc_index          = GC_NAME_MAP[gc_choice] or 1
local ITEM_LIST         = ParseItemIdList(item_id_str)

-- ============================================================
-- STATIC CONFIG (things that don't need a UI toggle)
-- ============================================================
local CONFIG = {
    autoduty_content_id  = 1017,     -- Mistwake patch 7.4
    duty_timeout         = 1800,     -- 30 min hard timeout per run
    buy_item_name        = "Duckbone",
    buy_item_seal_cost   = 200,
    interact_delay       = 1.5,
    nav_stop_dist        = 3.0,

    -- GC-specific data indexed by gc_index (1/2/3)
    gc_tp = {
        [1] = "Limsa Lominsa Lower Decks",
        [2] = "New Gridania",
        [3] = "Ul'dah - Steps of Nald",
    },
    gc_zone = {
        [1] = 129,
        [2] = 133,
        [3] = 130,
    },
    gc_officer_pos = {
        [1] = { x = -67.8, y = 21.4, z = -18.1 },
        [2] = { x = -72.3, y = -1.0, z = -14.1 },
        [3] = { x = -148.9, y = 4.1,  z = -107.0 },
    },
    gc_shop_pos = {
        [1] = { x = -72.2, y = 21.4, z = -14.9 },
        [2] = { x = -74.5, y = -1.0, z = -12.0 },
        [3] = { x = -145.7, y = 4.1,  z = -107.0 },
    },
    gc_officer_name = {
        [1] = "Storm Personnel Officer",
        [2] = "Serpent Personnel Officer",
        [3] = "Flame Personnel Officer",
    },
    gc_shop_name = {
        [1] = "Storm Quartermaster",
        [2] = "Serpent Quartermaster",
        [3] = "Flame Quartermaster",
    },
}

-- ============================================================
-- STATE COUNTERS
-- ============================================================
local total_runs_completed = 0
local total_cycles         = 0
local total_seals_earned   = 0
local total_duckbones      = 0
local script_start_time    = os.time()

-- ============================================================
-- LOGGING
-- ============================================================
local PREFIX = "[GIL_MISTWAKE]"

local function Log(msg)
    Dalamud.Log(PREFIX .. " " .. tostring(msg))
end

local function Echo(msg)
    yield("/echo " .. PREFIX .. " " .. tostring(msg))
end

local function EchoLog(msg)
    Dalamud.Log(PREFIX .. " " .. tostring(msg))
    yield("/echo " .. PREFIX .. " " .. tostring(msg))
end

-- ============================================================
-- UTILITY
-- ============================================================

local function Wait(s)
    yield("/wait " .. tostring(s))
end

local function WaitFor(addon, timeout)
    timeout = timeout or 10
    local t = 0
    while not IsAddonVisible(addon) and t < timeout do
        Wait(0.5) ; t = t + 0.5
    end
    if not IsAddonVisible(addon) then
        Log("WARN: " .. addon .. " not visible after " .. timeout .. "s")
        return false
    end
    while not IsAddonReady(addon) and t < timeout + 5 do
        Wait(0.3) ; t = t + 0.3
    end
    return IsAddonReady(addon)
end

local function CloseAddon(addon)
    if IsAddonVisible(addon) then
        yield("/callback " .. addon .. " true -1")
        Wait(0.8)
    end
end

local function IsInZone(zone_id)
    return GetZoneID() == zone_id
end

local function MoveToCoords(x, y, z)
    Log(string.format("Pathing to %.1f, %.1f, %.1f", x, y, z))
    PathfindAndMoveTo(x, y, z)
    local elapsed = 0
    while (PathfindInProgress() or PathIsRunning()) and elapsed < 60 do
        if GetDistanceToPoint(x, y, z) <= CONFIG.nav_stop_dist then
            PathStop() ; break
        end
        Wait(0.5) ; elapsed = elapsed + 0.5
    end
    PathStop()
    Wait(1)
end

local function TeleportTo(tp_name, zone_id)
    if IsInZone(zone_id) then return true end
    Log("Teleporting to " .. tp_name)
    yield("/tp " .. tp_name)
    Wait(2)
    local t = 0
    while not IsInZone(zone_id) and t < 30 do
        Wait(1) ; t = t + 1
    end
    if not IsInZone(zone_id) then
        Log("ERROR: Teleport to " .. tp_name .. " failed")
        return false
    end
    Wait(2)
    return true
end

local function GetCurrentSeals()
    return GetGrandCompanySeals() or 0
end

local function FormatTime(secs)
    return string.format("%02d:%02d:%02d",
        math.floor(secs/3600),
        math.floor((secs%3600)/60),
        secs % 60)
end

local function PrintStats()
    local elapsed = os.time() - script_start_time
    EchoLog("════════════════════════════════════")
    EchoLog(string.format("  Cycles    : %d", total_cycles))
    EchoLog(string.format("  Runs      : %d", total_runs_completed))
    EchoLog(string.format("  Seals +   : %d", total_seals_earned))
    EchoLog(string.format("  Duckbones : %d", total_duckbones))
    EchoLog(string.format("  Seals now : %d", GetCurrentSeals()))
    EchoLog(string.format("  Runtime   : %s", FormatTime(elapsed)))
    EchoLog("════════════════════════════════════")
end

-- ============================================================
-- INVENTORY / FILTER UTILITIES
-- ============================================================

local INVENTORY_BAGS = {0, 1, 2, 3}

local function SnapshotInventory()
    local snap = {}
    for _, bag in ipairs(INVENTORY_BAGS) do
        for slot = 0, 34 do
            local item = GetInventoryItem(bag, slot)
            if item and item.ItemId and item.ItemId ~= 0 then
                snap[item.ItemId] = (snap[item.ItemId] or 0) + (item.Count or 1)
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
            local label = ITEM_LIST[id] and ("(protected) ID:"..id) or ("ID:"..id)
            Log(string.format("  DROP: %s x%d", label, gained))
            any = true
        end
    end
    if not any then Log("  No new items this run.") end
end

local function ShouldTurnIn(item_id)
    if list_mode == "off" then return true end
    local in_list = ITEM_LIST[item_id] == true
    if list_mode == "whitelist" then return in_list end
    if list_mode == "blacklist" then return not in_list end
    return true
end

local function GetDeliverableItems()
    local out = {}
    for _, bag in ipairs(INVENTORY_BAGS) do
        for slot = 0, 34 do
            local item = GetInventoryItem(bag, slot)
            if item and item.ItemId and item.ItemId ~= 0 then
                if ShouldTurnIn(item.ItemId) then
                    table.insert(out, {
                        id   = item.ItemId,
                        bag  = bag,
                        slot = slot,
                        label = "ID:" .. item.ItemId,
                    })
                end
            end
        end
    end
    return out
end

-- ============================================================
-- PHASE 1 — AUTODUTY DUNGEON RUNS
-- ============================================================

local function WaitForDutyComplete(timeout)
    Log("Waiting for duty to finish (max " .. timeout .. "s)...")
    local elapsed = 0
    Wait(15)
    while elapsed < timeout do
        if not GetCharacterCondition(34) then
            Log("Duty complete")
            return true
        end
        Wait(5) ; elapsed = elapsed + 5
        if elapsed % 60 == 0 then
            Log(string.format("  In duty... %ds elapsed", elapsed))
        end
    end
    Log("ERROR: Duty timeout")
    return false
end

local function RunDungeonCycle(num_runs)
    EchoLog(string.format("=== DUNGEON PHASE: %d Mistwake runs ===", num_runs))

    for run = 1, num_runs do
        EchoLog(string.format("-- Run %d/%d (total %d) --",
            run, num_runs, total_runs_completed + 1))

        if GetCharacterCondition(34) then
            Log("Already in duty at start — waiting to clear...")
            local t = 0
            while GetCharacterCondition(34) and t < 600 do
                Wait(5) ; t = t + 5
            end
        end

        local snap_before = SnapshotInventory()

        Log("Queueing Mistwake via AutoDuty (ID " .. CONFIG.autoduty_content_id .. ")")
        yield("/autoduty start " .. CONFIG.autoduty_content_id)
        Wait(5)

        -- Wait for duty to load
        local qt = 0
        while not GetCharacterCondition(34) and qt < 300 do
            Wait(5) ; qt = qt + 5
        end
        if not GetCharacterCondition(34) then
            Log("ERROR: Never entered duty — skipping run")
            goto next_run
        end

        local ok = WaitForDutyComplete(CONFIG.duty_timeout)
        if not ok then
            Log("Duty timed out — leaving")
            yield("/dutyleave")
            Wait(10)
        end

        Log("--- Loot this run ---")
        LogNewDrops(snap_before, SnapshotInventory())

        total_runs_completed = total_runs_completed + 1
        EchoLog(string.format("Run %d done | Total: %d | Seals: %d",
            run, total_runs_completed, GetCurrentSeals()))
        Wait(5)

        ::next_run::
    end

    EchoLog("=== Dungeon phase complete ===")
end

-- ============================================================
-- PHASE 2 — EXPERT DELIVERY
-- ============================================================

local function DoExpertDelivery()
    EchoLog("=== EXPERT DELIVERY PHASE ===")

    local mode_display = list_mode:upper()
    local protected_count = 0
    for _ in pairs(ITEM_LIST) do protected_count = protected_count + 1 end
    Log(string.format("Mode: %s | Protected IDs: %d", mode_display, protected_count))

    local deliverable = GetDeliverableItems()
    if #deliverable == 0 then
        EchoLog("No deliverable items — skipping delivery")
        return
    end

    EchoLog(string.format("%d item(s) queued for delivery", #deliverable))
    for _, item in ipairs(deliverable) do
        Log("  → " .. item.label)
    end

    -- Navigate to officer
    local pos = CONFIG.gc_officer_pos[gc_index]
    MoveToCoords(pos.x, pos.y, pos.z)

    yield("/target " .. CONFIG.gc_officer_name[gc_index])
    Wait(1)
    yield("/interact")
    Wait(CONFIG.interact_delay)

    if not WaitFor("SelectString", 10) then
        Log("ERROR: Officer menu did not open")
        return
    end
    yield("/callback SelectString true 1")   -- Expert Delivery
    Wait(CONFIG.interact_delay)

    if not WaitFor("GrandCompanySupplyList", 10) then
        Log("ERROR: Expert Delivery window did not open")
        CloseAddon("SelectString")
        return
    end

    EchoLog("Delivering items...")

    local items_turned_in = 0
    local items_skipped   = 0
    local seal_before     = GetCurrentSeals()
    local current_row     = 0
    local total_rows      = #deliverable
    local attempt         = 0

    while attempt < 60 do
        attempt = attempt + 1

        if not IsAddonVisible("GrandCompanySupplyList") then break end
        if GetCurrentSeals() >= seal_cap - 100 then
            EchoLog("Seal cap reached — stopping delivery")
            break
        end
        if current_row >= total_rows then
            Log("End of item list")
            break
        end

        local item = deliverable[current_row + 1]
        if not item then break end

        if not ShouldTurnIn(item.id) then
            Log("Skipping " .. item.label)
            current_row = current_row + 1
            items_skipped = items_skipped + 1
        else
            yield("/callback GrandCompanySupplyList true 0 " .. current_row)
            Wait(CONFIG.interact_delay)

            if IsAddonVisible("SelectYesno") then
                yield("/callback SelectYesno true 0")
                Wait(CONFIG.interact_delay)
                items_turned_in = items_turned_in + 1
                Log(string.format("Delivered %s | Seals: %d", item.label, GetCurrentSeals()))
                -- Rescan after delivery since list shifts
                deliverable = GetDeliverableItems()
                current_row = items_skipped
                total_rows  = #deliverable + items_skipped
            else
                Log("WARN: No confirm dialog for row " .. current_row .. " — advancing")
                current_row = current_row + 1
            end
        end
    end

    CloseAddon("GrandCompanySupplyList")
    Wait(1)
    CloseAddon("SelectString")
    Wait(0.5)

    local gained = GetCurrentSeals() - seal_before
    total_seals_earned = total_seals_earned + math.max(0, gained)

    EchoLog(string.format("Delivery done: %d in | %d skipped | +%d seals | Now: %d",
        items_turned_in, items_skipped, gained, GetCurrentSeals()))
end

-- ============================================================
-- PHASE 3 — BUY DUCKBONES
-- ============================================================

local function BuyDuckbones()
    EchoLog("=== BUY DUCKBONES PHASE ===")

    if GetCurrentSeals() <= seal_reserve then
        EchoLog(string.format("Seals too low (%d) — skipping purchase", GetCurrentSeals()))
        return
    end

    local pos = CONFIG.gc_shop_pos[gc_index]
    MoveToCoords(pos.x, pos.y, pos.z)

    yield("/target " .. CONFIG.gc_shop_name[gc_index])
    Wait(1)
    yield("/interact")
    Wait(CONFIG.interact_delay)

    if WaitFor("SelectString", 8) then
        yield("/callback SelectString true 0")   -- "Purchase Items"
        Wait(CONFIG.interact_delay)
    end

    if not WaitFor("GCShop", 10) then
        Log("ERROR: GC Shop did not open")
        CloseAddon("SelectString")
        return
    end

    EchoLog("GC Shop open — buying Duckbones...")
    yield("/callback GCShop true 0")
    Wait(1)

    local bought = 0

    while true do
        local cur = GetCurrentSeals()
        if cur - CONFIG.buy_item_seal_cost < seal_reserve then
            Log("Not enough seals for another purchase — done")
            break
        end

        yield("/callback GCShop true 0 " .. shop_row)
        Wait(CONFIG.interact_delay)

        if IsAddonVisible("ShopExchangeDialog") then
            local max_qty = math.floor((cur - seal_reserve) / CONFIG.buy_item_seal_cost)
            max_qty = math.max(1, math.min(max_qty, 99))
            yield("/callback ShopExchangeDialog true 0 " .. max_qty .. " 0")
            Wait(CONFIG.interact_delay)
            bought = bought + max_qty
            EchoLog(string.format("Bought %d Duckbones | Seals left: %d",
                max_qty, GetCurrentSeals()))
            if GetCurrentSeals() - CONFIG.buy_item_seal_cost < seal_reserve then break end
        elseif IsAddonVisible("SelectYesno") then
            yield("/callback SelectYesno true 0")
            Wait(CONFIG.interact_delay)
            bought = bought + 1
        elseif IsAddonVisible("GCShop") then
            Log("WARN: No buy dialog — check Duckbone Shop Row in config")
            break
        else
            Log("WARN: Shop closed unexpectedly")
            break
        end
    end

    CloseAddon("GCShop")
    Wait(0.5)
    CloseAddon("SelectString")

    total_duckbones = total_duckbones + bought
    EchoLog(string.format("Bought %d Duckbones this cycle | Total: %d | Seals: %d",
        bought, total_duckbones, GetCurrentSeals()))
end

-- ============================================================
-- STARTUP CHECKS
-- ============================================================

EchoLog("╔══════════════════════════════════════╗")
EchoLog("║   Mistwake Gil Farming Script v1.2   ║")
EchoLog("╚══════════════════════════════════════╝")
EchoLog(string.format("Runs/cycle: %d | GC: %s | Mode: %s | Seal cap: %d",
    runs_per_cycle, gc_choice, list_mode:upper(), seal_cap))

if item_id_str ~= "" then
    local ids = {}
    for id in pairs(ITEM_LIST) do table.insert(ids, tostring(id)) end
    EchoLog("Protected IDs: " .. table.concat(ids, ", "))
else
    EchoLog("No item IDs configured — " ..
        (list_mode == "off" and "turning in everything" or
         list_mode == "blacklist" and "turning in everything (empty blacklist)" or
         "whitelist is empty — nothing will be delivered"))
end

if not HasPlugin("AutoDuty") then
    EchoLog("FATAL: AutoDuty not found!")
    return
end
if not HasPlugin("vnavmesh") then
    EchoLog("FATAL: vnavmesh not found!")
    return
end

-- ============================================================
-- MAIN LOOP
-- ============================================================

while true do
    total_cycles = total_cycles + 1
    EchoLog(string.format("════ CYCLE %d START ════", total_cycles))

    local run_ok, run_err = pcall(RunDungeonCycle, runs_per_cycle)
    if not run_ok then
        Log("ERROR in dungeon phase: " .. tostring(run_err))
        if GetCharacterCondition(34) then
            yield("/dutyleave") ; Wait(15)
        end
    end

    local gc_zone = CONFIG.gc_zone[gc_index]
    local gc_tp   = CONFIG.gc_tp[gc_index]
    local tp_ok   = TeleportTo(gc_tp, gc_zone)

    if tp_ok then
        Wait(3)

        local del_ok, del_err = pcall(DoExpertDelivery)
        if not del_ok then Log("ERROR in delivery: " .. tostring(del_err)) end

        local buy_ok, buy_err = pcall(BuyDuckbones)
        if not buy_ok then Log("ERROR in buy phase: " .. tostring(buy_err)) end
    else
        Log("ERROR: Could not reach GC — skipping to next cycle")
    end

    PrintStats()
    EchoLog(string.format("════ CYCLE %d END ════", total_cycles))
    Wait(5)
end