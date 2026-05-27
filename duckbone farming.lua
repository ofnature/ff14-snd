-- ============================================================
-- [GIL_MISTWAKE] Mistwake Dungeon Gil Farming Loop
-- Version: 1.0.0
-- Requires: SomethingNeedDoing (Jaksuhn fork), AutoDuty,
--           vnavmesh, YesAlready, TextAdvance, Lifestream
-- ============================================================
-- LOOP OVERVIEW:
--   1. Run Mistwake via AutoDuty for X runs (configurable)
--   2. Teleport to your Grand Company city
--   3. Navigate to Personnel Officer → Expert Delivery
--   4. Turn in ALL armor/gear loot until seals are capped
--   5. Navigate to GC Merchant → buy Duckbones until out of seals
--   6. Repeat from step 1 indefinitely until script is stopped
-- ============================================================

-- ============================================================
-- ██████╗  ██████╗ ███╗   ██╗███████╗██╗ ██████╗
-- ██╔════╝██╔═══██╗████╗  ██║██╔════╝██║██╔════╝
-- ██║     ██║   ██║██╔██╗ ██║█████╗  ██║██║  ███╗
-- ██║     ██║   ██║██║╚██╗██║██╔══╝  ██║██║   ██║
-- ╚██████╗╚██████╔╝██║ ╚████║██║     ██║╚██████╔╝
--  ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚═╝     ╚═╝ ╚═════╝
-- ============================================================
local CONFIG = {

    -- ── DUTY SETTINGS ─────────────────────────────────────────
    -- How many Mistwake runs to complete before heading to GC.
    -- After this many runs the seal turn-in / buy loop triggers,
    -- then the dungeon loop resets and runs again.
    runs_per_cycle = 5,

    -- AutoDuty uses internal content IDs. Mistwake (patch 7.4)
    -- content ID is 1017. Verify with /ad list in-game if needed.
    autoduty_content_id = 1017,

    -- Seconds to wait for AutoDuty to finish one full run before
    -- the script times out and retries. 30-min cap is safe.
    duty_timeout = 1800,

    -- ── GRAND COMPANY ─────────────────────────────────────────
    -- Which GC are you in?
    --   1 = Maelstrom       (Limsa Lominsa)
    --   2 = Order of the Twin Adder (Gridania)
    --   3 = Immortal Flames  (Ul'dah)
    grand_company = 1,

    -- Max seals your character can hold (default 90,000 at max rank)
    seal_cap = 90000,

    -- Stop buying Duckbones when seals drop below this threshold
    -- to leave a small reserve (avoids over-spending edge case)
    seal_reserve = 1500,

    -- Duckbone item ID (used for inventory count checks)
    -- Duckbone (food item) = 39228  [Maelstrom/Flames/Adder shop]
    -- If you prefer a different cheap GC item, swap the ID and
    -- update buy_item_shop_index below to match its shop row.
    buy_item_name        = "Duckbone",
    buy_item_shop_index  = 0,     -- 0-based row in GCShop list (adjust if needed)
    buy_item_seal_cost   = 200,   -- seal cost per Duckbone stack purchase

    -- ── GC TELEPORT & NAVIGATION ──────────────────────────────
    -- Lifestream /tp command name for your GC city:
    --   Maelstrom  → "Limsa Lominsa Lower Decks"
    --   Twin Adder → "New Gridania"
    --   Flames     → "Ul'dah - Steps of Nald"
    gc_tp_name = "Limsa Lominsa Lower Decks",

    -- Zone ID for your GC home city
    --   Limsa Lower Decks = 129
    --   New Gridania      = 133
    --   Ul'dah Steps Nald = 130
    gc_zone_id = 129,

    -- Personnel Officer (Expert Delivery NPC) coords.
    -- Maelstrom: The Aftcastle, Limsa Lower Decks
    gc_officer_x =  -67.8,
    gc_officer_y =   21.4,
    gc_officer_z =  -18.1,

    -- GC Shop (Exchange Officer / Quartermaster) coords.
    -- Maelstrom: same room, slightly different position
    gc_shop_x    =  -72.2,
    gc_shop_y =     21.4,
    gc_shop_z    =  -14.9,

    -- ── TIMING ────────────────────────────────────────────────
    -- Generic interaction delay (seconds)
    interact_delay = 1.5,
    -- Navigation arrival tolerance (yalms)
    nav_stop_dist  = 3.0,
}

-- ============================================================
-- GC LOOKUP TABLE
-- NPC target names vary per GC. Edit if your client uses a
-- different locale or if SE ever renames them.
-- ============================================================
local GC_OFFICER_NAMES = {
    [1] = "Storm Personnel Officer",
    [2] = "Serpent Personnel Officer",
    [3] = "Flame Personnel Officer",
}
local GC_SHOP_NAMES = {
    [1] = "Storm Quartermaster",
    [2] = "Serpent Quartermaster",
    [3] = "Flame Quartermaster",
}

-- ============================================================
-- STATE
-- ============================================================
local total_runs_completed = 0
local total_cycles         = 0
local total_seals_earned   = 0
local total_duckbones      = 0
local run_start_seals      = 0
local script_start_time    = os.time()

-- ============================================================
-- UTILITY
-- ============================================================

local function Log(msg)
    LogInfo("[GIL_MISTWAKE] " .. tostring(msg))
end

local function Wait(s)
    yield("/wait " .. tostring(s))
end

local function WaitFor(addon, timeout)
    timeout = timeout or 10
    local t = 0
    while not IsAddonVisible(addon) and t < timeout do
        Wait(0.5)
        t = t + 0.5
    end
    if not IsAddonVisible(addon) then
        Log("WARN: " .. addon .. " not visible after " .. timeout .. "s")
        return false
    end
    while not IsAddonReady(addon) and t < timeout + 5 do
        Wait(0.3)
        t = t + 0.3
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

local function MoveToCoords(x, y, z, stop_dist)
    stop_dist = stop_dist or CONFIG.nav_stop_dist
    Log(string.format("Pathing to %.1f, %.1f, %.1f", x, y, z))
    PathfindAndMoveTo(x, y, z)
    local timeout = 60
    local elapsed = 0
    while (PathfindInProgress() or PathIsRunning()) and elapsed < timeout do
        if GetDistanceToPoint(x, y, z) <= stop_dist then
            PathStop()
            break
        end
        Wait(0.5)
        elapsed = elapsed + 0.5
    end
    PathStop()
    Wait(1)
end

local function TeleportTo(name, zone_id)
    if IsInZone(zone_id) then return true end
    Log("Teleporting to " .. name)
    yield("/tp " .. name)
    Wait(2)
    local t = 0
    while not IsInZone(zone_id) and t < 30 do
        Wait(1)
        t = t + 1
    end
    if not IsInZone(zone_id) then
        Log("ERROR: Teleport to " .. name .. " failed (zone mismatch)")
        return false
    end
    Wait(2)
    return true
end

local function GetCurrentSeals()
    -- SND exposes GetGrandCompanySeals() → returns current seal count
    local seals = GetGrandCompanySeals()
    return seals or 0
end

local function SealsToNextCap()
    return CONFIG.seal_cap - GetCurrentSeals()
end

local function FormatTime(secs)
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = secs % 60
    return string.format("%02d:%02d:%02d", h, m, s)
end

local function PrintStats()
    local elapsed = os.time() - script_start_time
    Log("════════════════════════════════════")
    Log(string.format("  Cycles completed : %d", total_cycles))
    Log(string.format("  Total runs       : %d", total_runs_completed))
    Log(string.format("  Seals earned     : %d", total_seals_earned))
    Log(string.format("  Duckbones bought : %d", total_duckbones))
    Log(string.format("  Current seals    : %d", GetCurrentSeals()))
    Log(string.format("  Runtime          : %s", FormatTime(elapsed)))
    Log("════════════════════════════════════")
end

-- ============================================================
-- PHASE 1 — AUTODUTY DUNGEON RUNS
-- ============================================================

local function WaitForDutyComplete(timeout)
    -- Poll until AutoDuty reports it's no longer running.
    -- AutoDuty exposes /ad status — we check IsAddonVisible
    -- for the duty complete screen OR poll GetCharacterCondition.
    -- Condition 34 = bound by duty; when it drops, duty is done.
    Log("Waiting for duty to complete (timeout " .. timeout .. "s)...")
    local elapsed = 0
    -- First wait a moment for the duty to actually start
    Wait(15)
    while elapsed < timeout do
        -- Condition 34 = BoundByDuty
        if not GetCharacterCondition(34) then
            Log("Duty complete flag cleared — run finished")
            return true
        end
        Wait(5)
        elapsed = elapsed + 5
        if elapsed % 60 == 0 then
            Log(string.format("  Still in duty... (%ds elapsed)", elapsed))
        end
    end
    Log("ERROR: Duty timeout reached (" .. timeout .. "s)")
    return false
end

local function RunDungeonCycle(num_runs)
    Log(string.format("=== DUNGEON PHASE: %d runs of Mistwake ===", num_runs))

    for run = 1, num_runs do
        Log(string.format("--- Starting run %d/%d (total: %d) ---",
            run, num_runs, total_runs_completed + 1))

        -- Make sure we're not already in a duty
        if GetCharacterCondition(34) then
            Log("WARN: Already in duty at run start — waiting for it to clear...")
            local t = 0
            while GetCharacterCondition(34) and t < 600 do
                Wait(5) ; t = t + 5
            end
        end

        -- Queue Mistwake via AutoDuty
        -- /autoduty start <contentID> — uses Trust/Duty Support
        Log("Queuing Mistwake (content ID " .. CONFIG.autoduty_content_id .. ")")
        yield("/autoduty start " .. CONFIG.autoduty_content_id)
        Wait(5)

        -- Wait for duty to load (condition 34 = BoundByDuty)
        local queue_timeout = 300
        local qt = 0
        while not GetCharacterCondition(34) and qt < queue_timeout do
            Wait(5) ; qt = qt + 5
        end
        if not GetCharacterCondition(34) then
            Log("ERROR: Never entered duty after " .. queue_timeout .. "s — skipping run")
            goto next_run
        end

        -- Wait for the duty run to finish
        local ok = WaitForDutyComplete(CONFIG.duty_timeout)
        if not ok then
            Log("ERROR: Duty timed out — attempting to leave")
            yield("/dutyleave")
            Wait(10)
        end

        total_runs_completed = total_runs_completed + 1
        Log(string.format("Run %d complete. Total runs: %d | Seals: %d",
            run, total_runs_completed, GetCurrentSeals()))

        -- Brief cooldown between runs
        Wait(5)

        ::next_run::
    end

    Log(string.format("=== Dungeon phase done. %d total runs completed ===",
        total_runs_completed))
end

-- ============================================================
-- PHASE 2 — EXPERT DELIVERY (turn in armor for seals)
-- ============================================================

local function DoExpertDelivery()
    Log("=== EXPERT DELIVERY PHASE ===")

    -- Navigate to Personnel Officer
    MoveToCoords(CONFIG.gc_officer_x, CONFIG.gc_officer_y, CONFIG.gc_officer_z)

    -- Target and interact
    local npc = GC_OFFICER_NAMES[CONFIG.grand_company]
    yield("/target " .. npc)
    Wait(1)
    yield("/interact")
    Wait(CONFIG.interact_delay)

    -- Personnel Officer opens a SelectString menu.
    -- Option layout (0-indexed):
    --   0 = View your standing
    --   1 = Expert Delivery (turn in gear for seals)
    --   2 = View Grand Company Ranks
    --   3 = Cancel
    if not WaitFor("SelectString", 10) then
        Log("ERROR: Personnel Officer menu did not open")
        return
    end

    -- Select "Expert Delivery" (index 1)
    yield("/callback SelectString true 1")
    Wait(CONFIG.interact_delay)

    -- GrandCompanySupplyList is the expert delivery window
    if not WaitFor("GrandCompanySupplyList", 10) then
        Log("ERROR: Expert Delivery window did not open")
        CloseAddon("SelectString")
        return
    end

    Log("Expert Delivery window open. Turning in items...")

    -- The window shows deliverable items in a list. Each row can
    -- be clicked (callback index 0 = select item at slot N,
    -- then a confirm dialog appears).
    -- We loop: click item at slot 0 (always first available),
    -- confirm delivery, repeat until list is empty or seals cap.

    local items_turned_in = 0
    local seal_before = GetCurrentSeals()

    local max_attempts = 50   -- safety cap — no dungeon drops 50 items
    local attempt = 0

    while attempt < max_attempts do
        attempt = attempt + 1

        -- Refresh: is the window still open and are there items?
        if not IsAddonVisible("GrandCompanySupplyList") then
            Log("Expert delivery window closed — done delivering")
            break
        end

        -- Check seal cap: stop if we're at or very near cap
        local cur_seals = GetCurrentSeals()
        if cur_seals >= CONFIG.seal_cap - 100 then
            Log(string.format("Seals at cap (%d) — stopping delivery", cur_seals))
            break
        end

        -- Try to select item at list row 0 (always the first available item).
        -- Callback: GrandCompanySupplyList, true, 0, <slot_index>
        yield("/callback GrandCompanySupplyList true 0 0")
        Wait(CONFIG.interact_delay)

        -- A SelectYesno confirmation should appear
        if IsAddonVisible("SelectYesno") then
            yield("/callback SelectYesno true 0")   -- "Yes"
            Wait(CONFIG.interact_delay)
            items_turned_in = items_turned_in + 1
            Log(string.format("Turned in item #%d | Seals: %d",
                items_turned_in, GetCurrentSeals()))
        elseif IsAddonVisible("GrandCompanySupplyList") then
            -- No confirm dialog appeared — list may be empty or item was non-selectable
            -- Try checking if list is actually empty by checking node text
            local list_count_text = GetNodeText("GrandCompanySupplyList", 12)
            if list_count_text == "0" or list_count_text == nil or list_count_text == "" then
                Log("No more items available for expert delivery")
                break
            end
            -- If we got here with a non-empty list but no confirm, something is off
            -- Wait a moment and retry once
            Wait(1)
        else
            -- Neither window — something unexpected happened
            Log("WARN: Neither delivery nor confirm window visible — breaking")
            break
        end
    end

    -- Close the window
    CloseAddon("GrandCompanySupplyList")
    Wait(1)
    CloseAddon("SelectString")
    Wait(0.5)

    local seals_gained = GetCurrentSeals() - seal_before
    total_seals_earned = total_seals_earned + math.max(0, seals_gained)

    Log(string.format("Expert delivery complete: %d items turned in | +%d seals | Total seals now: %d",
        items_turned_in, seals_gained, GetCurrentSeals()))
end

-- ============================================================
-- PHASE 3 — BUY DUCKBONES WITH SEALS
-- ============================================================

local function BuyDuckbones()
    Log("=== BUY DUCKBONES PHASE ===")

    local seals_before = GetCurrentSeals()
    if seals_before <= CONFIG.seal_reserve then
        Log(string.format("Not enough seals to buy (%d <= reserve %d), skipping",
            seals_before, CONFIG.seal_reserve))
        return
    end

    -- Navigate to Quartermaster / Shop NPC
    MoveToCoords(CONFIG.gc_shop_x, CONFIG.gc_shop_y, CONFIG.gc_shop_z)

    local shop_npc = GC_SHOP_NAMES[CONFIG.grand_company]
    yield("/target " .. shop_npc)
    Wait(1)
    yield("/interact")
    Wait(CONFIG.interact_delay)

    -- Quartermaster opens a SelectString (or directly opens shop)
    -- Maelstrom layout (0-indexed):
    --   0 = Purchase Items
    --   1 = Exchange Items
    --   2 = Cancel
    if WaitFor("SelectString", 8) then
        yield("/callback SelectString true 0")   -- "Purchase Items"
        Wait(CONFIG.interact_delay)
    end

    -- GCShop is the shop window
    if not WaitFor("GCShop", 10) then
        Log("ERROR: GC Shop window did not open")
        CloseAddon("SelectString")
        return
    end

    Log("GC Shop open. Buying Duckbones...")

    -- GCShop tabs: 0 = Materiel (general supplies including food)
    -- Click tab 0 to make sure we're on the right page
    yield("/callback GCShop true 0")
    Wait(1)

    local bought = 0

    while true do
        local cur_seals = GetCurrentSeals()
        if cur_seals - CONFIG.buy_item_seal_cost < CONFIG.seal_reserve then
            Log(string.format("Seals too low to buy another stack (%d, reserve %d)",
                cur_seals, CONFIG.seal_reserve))
            break
        end

        -- Select item at shop row CONFIG.buy_item_shop_index
        -- GCShop callback: index 0 = select row, second arg = row number
        yield("/callback GCShop true 0 " .. CONFIG.buy_item_shop_index)
        Wait(CONFIG.interact_delay)

        -- A quantity/confirm dialog appears: ShopExchangeDialog or SelectYesno
        if IsAddonVisible("ShopExchangeDialog") then
            -- Set quantity to max we can afford and confirm
            local max_qty = math.floor(
                (cur_seals - CONFIG.seal_reserve) / CONFIG.buy_item_seal_cost
            )
            max_qty = math.max(1, math.min(max_qty, 99))
            -- Set quantity field (node 6 is typically the quantity input)
            yield("/callback ShopExchangeDialog true 0 " .. max_qty .. " 0")
            Wait(CONFIG.interact_delay)
            bought = bought + max_qty
            Log(string.format("Bought %d Duckbones | Seals remaining: %d",
                max_qty, GetCurrentSeals()))
            -- After a bulk buy, check if we're done
            if GetCurrentSeals() - CONFIG.buy_item_seal_cost < CONFIG.seal_reserve then
                break
            end
        elseif IsAddonVisible("SelectYesno") then
            yield("/callback SelectYesno true 0")
            Wait(CONFIG.interact_delay)
            bought = bought + 1
        elseif IsAddonVisible("GCShop") then
            -- Item row click didn't trigger a dialog — may be wrong row
            Log("WARN: Buy dialog did not appear. Check buy_item_shop_index in CONFIG.")
            break
        else
            Log("WARN: GCShop window closed unexpectedly")
            break
        end
    end

    CloseAddon("GCShop")
    Wait(0.5)
    CloseAddon("SelectString")

    total_duckbones = total_duckbones + bought
    Log(string.format("Bought %d Duckbones this cycle | Total bought: %d | Seals: %d",
        bought, total_duckbones, GetCurrentSeals()))
end

-- ============================================================
-- MAIN LOOP
-- ============================================================

Log("╔══════════════════════════════════════╗")
Log("║   Mistwake Gil Farming Script v1.0   ║")
Log("╚══════════════════════════════════════╝")
Log(string.format("Config: %d runs/cycle | GC: %d | Seal cap: %d",
    CONFIG.runs_per_cycle, CONFIG.grand_company, CONFIG.seal_cap))
Log("Script will loop until manually stopped.")
Log("")

-- Sanity checks
if not HasPlugin("AutoDuty") then
    Log("FATAL: AutoDuty plugin not found — install it first!")
    return
end
if not HasPlugin("vnavmesh") then
    Log("FATAL: vnavmesh not found — navigation will fail!")
    return
end

while true do
    total_cycles = total_cycles + 1
    Log(string.format("════ CYCLE %d START ════", total_cycles))

    -- ── Phase 1: Dungeon runs ──────────────────────────────────
    local ok, err = pcall(RunDungeonCycle, CONFIG.runs_per_cycle)
    if not ok then
        Log("ERROR in dungeon phase: " .. tostring(err))
        Log("Attempting to recover — leaving duty if needed...")
        if GetCharacterCondition(34) then
            yield("/dutyleave")
            Wait(15)
        end
    end

    -- ── Teleport to GC city ───────────────────────────────────
    local tp_ok = TeleportTo(CONFIG.gc_tp_name, CONFIG.gc_zone_id)
    if not tp_ok then
        Log("ERROR: Could not reach GC — retrying cycle...")
        Wait(10)
        goto cycle_end
    end

    -- Small buffer after zone load
    Wait(3)

    -- ── Phase 2: Expert delivery ──────────────────────────────
    local del_ok, del_err = pcall(DoExpertDelivery)
    if not del_ok then
        Log("ERROR in delivery phase: " .. tostring(del_err))
    end

    -- ── Phase 3: Buy Duckbones ────────────────────────────────
    local buy_ok, buy_err = pcall(BuyDuckbones)
    if not buy_ok then
        Log("ERROR in buy phase: " .. tostring(buy_err))
    end

    ::cycle_end::

    -- Print cycle summary
    PrintStats()
    Log(string.format("════ CYCLE %d END ════", total_cycles))

    -- Brief rest before next cycle
    Wait(5)
end